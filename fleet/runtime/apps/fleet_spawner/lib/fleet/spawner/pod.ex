defmodule Fleet.Spawner.Pod do
  @moduledoc """
  GenServer state machine du cycle 8 phases ALLOCATE → RELEASE pour un pod.

  ## Phases

      :pending → :allocating → :cleaning → :projecting → :injecting →
      :launching → :monitoring → :extracting → :releasing → :succeeded
                                                          ↓
                                                        :failed

  Chaque transition est dirigée par `handle_continue/2`. L'`init/1`
  démarre la chaîne avec `{:continue, :allocate}`. Si recovery state
  FS détecte un `session_id` (pré-alloué au spawn, persisté `state.json`),
  l'`init/1` reprend directement en phase `:launching` (le respawn
  passera `--resume <session_id>`).

  ## Conditions

  Set d'événements observables ajoutés au passage des phases :
  `:home_projected`, `:context_injected`, `:process_launched`,
  `:stream_alive`, `:init_validated`, `:output_extracted`,
  `:home_released`. Permet à `pod_info/1` de distinguer "phase X
  atteinte" de "condition Y vérifiée".

  ## Recovery state FS

  `<state_fs_root>/<scope>/<id>/state.json` écrit dès post-ALLOCATE
  (le `session_id` est pré-alloué au spawn — ADR-G IV.1/IV.2 : plus de
  frame `init` NDJSON, modèle `-p` mort). `<scope>` ∈ `pods` (one-shot/forever) /
  `pipes` (pipe) / `runs` (run). Au prochain `init/1`, lecture du fichier →
  reprise directe en phase `:launching` avec le `session_id`
  (`--resume <session_id>` au respawn).
  """

  # DN-recovery B : tous les pods `:temporary` (le supervisor ne ressuscite
  # jamais ; recovery délibérée). NB : `pod_child_spec/1` (spawner.ex) construit
  # le child_spec explicite et fixe lui aussi `restart: :temporary` — c'est lui
  # qui fait foi au spawn ; cette valeur de module reste alignée par honnêteté.
  use GenServer, restart: :temporary

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.SPBuilder

  # R-CORE.comm 2.2 — completion EVENT-DRIVEN : le résultat arrive via l'event Bus
  # `task_queue.task_completed (struct %Fleet.Event{})` (émis par le central sur submit_result), PAS via un fichier.

  @type phase ::
          :pending
          | :allocating
          | :cleaning
          | :projecting
          | :injecting
          | :launching
          | :monitoring
          | :extracting
          | :releasing
          | :succeeded
          | :failed
          | :unknown

  @type condition ::
          :home_projected
          | :context_injected
          | :process_launched
          | :stream_alive
          | :init_validated
          | :output_extracted
          | :home_released

  @type state :: %{
          phase: phase(),
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          ticket_id: String.t(),
          session_id: String.t() | nil,
          # DN spawner-orchestrator §C-3 : `started_at` ISO8601 figé à la création du
          # Pod GenServer, persisté tel quel dans `state.json` (point de recovery).
          started_at: DateTime.t(),
          cap_profile: Fleet.CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          ndjson_log_path: Path.t() | nil,
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          init_message: map() | nil,
          last_error: term() | nil,
          opts: keyword(),
          # R1.2 — Port owned par le Pod (détection exit + kill en RELEASE).
          port: port() | nil,
          # R-CORE.comm 2.2 — résultat reçu via l'event Bus task_queue.task_completed (struct %Fleet.Event{}) (completion).
          submitted_result: map() | nil,
          last_result: map() | nil,
          # U4 — nom tmux session si TmuxBackend a lancé (sinon nil). do_release
          # kill via TmuxBackend.kill_session/1 quand présent.
          tmux_session: String.t() | nil
        }

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Démarre un Pod GenServer pour un nouveau pod éphémère.

  Invoqué par `Fleet.Spawner.spawn_pod/3` via le child_spec passé à
  `DynamicSupervisor.start_child/2`. L'`init/1` enchaîne ensuite
  les phases via `handle_continue/2`.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args.pod_id))
  end

  @doc """
  Renvoie le nom registry-via du Pod GenServer pour un `pod_id`.

  Utilisé pour `GenServer.call` ciblé + `kill_pod` lookup
  (`Fleet.Spawner.Registry`).
  """
  @spec name(String.t()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t()}}
  def name(pod_id) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id}}
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(args) do
    state = recover_or_init(args)
    {:ok, state, {:continue, first_continue_for(state)}}
  end

  @impl GenServer
  def handle_continue(:allocate, state), do: do_allocate(state)
  def handle_continue(:clean, state), do: do_clean(state)
  def handle_continue(:project, state), do: do_project(state)
  def handle_continue(:inject, state), do: do_inject(state)
  def handle_continue(:launch, state), do: do_launch(state)
  def handle_continue(:monitor, state), do: do_monitor(state)
  def handle_continue(:extract, state), do: do_extract(state)
  def handle_continue(:release, state), do: do_release(state)

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      pod_id: state.pod_id,
      ticket_id: state.ticket_id,
      phase: state.phase,
      conditions: MapSet.to_list(state.conditions),
      session_id: state.session_id,
      pod_dir: state.pod_dir,
      state_fs_path: state.state_fs_path,
      last_error: state.last_error,
      init_message: state.init_message,
      last_result: state.last_result,
      # tmux_session : nom de la session tmux du pod si TmuxBackend (RC long-
      # lived), nil sinon (LauncherPortBackend/Stub). Exposé pour Fleet.Spawner.wake_
      # pod/1 (send-keys `yop` au pod cible pour nouveau cycle).
      tmux_session: state.tmux_session
    }

    {:reply, info, state}
  end

  # LIFE-003 (DN-recovery B §5) : kill = transition de release DÉLIBÉRÉE, pas un
  # kill brutal du supervisor. Teardown backend + libère la task (abort, pas
  # succès → clear_for_pod) + état terminal `:killed`, puis arrêt :normal. Le
  # fallback brutal (terminate_child) ne sert que si ce call timeout (cf. kill_pod/1).
  def handle_call(:kill, _from, state) do
    teardown_backend(state)
    clear_pod_task(state.pod_id)

    new_state =
      state
      |> Map.put(:phase, :killed)
      |> add_condition(:home_released)

    write_state_fs(new_state)
    {:stop, :normal, :ok, new_state}
  end

  # ============================================================
  # #593 D11 — handle_info Port lifecycle
  # ============================================================
  #
  # LauncherPortBackend.launch ouvre `Port.open` (sous le process Pod) et bloque
  # jusqu'à la 1ʳᵉ frame `init` NDJSON. Après, le Pod reprend la main
  # (handle_continue :monitor → :extract → :release → :succeeded). Le
  # Port n'est PAS fermé : claude continue à streamer (assistant events,
  # result event final, exit_status). Sans clause handle_info, ces
  # messages tombent dans le default → log unexpected message, state
  # machine ne note JAMAIS la complétion réelle.
  #
  # Format Port options actuelles (LauncherPortBackend ligne 47-53) : `:binary`
  # + `:exit_status`, PAS `{:line, _}` ni `{:packet, :line}` → on reçoit
  # `{port, {:data, binary_chunk}}` (multi-events ou partial), buffering
  # + split sur "\n" requis.

  # R-CORE.comm ADR-G — completion event-driven : le broker fleet_task_queue broadcast
  # %Fleet.Event{task_completed} sur fleet.events. On ne réagit qu'au NÔTRE (pod_id) en :monitoring.
  @impl GenServer
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :task_completed, pod_id: pid, payload: payload},
        %{phase: :monitoring, pod_id: pid} = state
      ) do
    result = payload[:result] || payload["result"] || %{}
    {:noreply, Map.put(state, :submitted_result, result), {:continue, :extract}}
  end

  # %Fleet.Event{task_completed} d'un autre pod, ou hors phase :monitoring → ignore.
  def handle_info(%Fleet.Event{source: :task_queue, type: :task_completed}, state),
    do: {:noreply, state}

  # Deadline : aucun résultat soumis dans le budget durée → échec.
  def handle_info(:result_deadline, %{phase: :monitoring} = state) do
    transition_failed(state, {:result_timeout, state.pod_id})
  end

  def handle_info(:result_deadline, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state)
      when is_port(port) do
    # R-CORE.comm 2.2 — completion event-driven : si le résultat a été extrait (event
    # task_queue.task_completed (struct %Fleet.Event{}) reçu → :output_extracted), l'exit est l'arrêt normal post-release.
    # Sinon le process est mort SANS soumettre de résultat → échec (plus de salvage fichier).
    if MapSet.member?(state.conditions, :output_extracted) do
      {:stop, :normal, state}
    else
      # STATE-004 : process mort SANS résultat soumis → task active orpheline. Libère.
      clear_pod_task(state.pod_id)

      safe_broadcast("pod.failed", %{
        "pod_id" => state.pod_id,
        "ticket_id" => state.ticket_id,
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{state.pod_id} exited before submitting result (exit=#{exit_code})")
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, state}
    end
  end

  # R3b / F-C4b-2 — Kick AUTONOME readiness-gated. Tick borné (indépendant du cycle
  # ALLOCATE→RELEASE, le pod est en :monitoring quand ces messages arrivent) :
  #   - mandat déjà pull → stop (plus rien à faire) ;
  #   - cap atteint → abandon loggé (REPL jamais joignable OU mandat jamais pull) ;
  #   - tmux joignable → yop (le pull peut prendre un tour → on revérifie au prochain tick) ;
  #   - tmux pas encore up → on retente sans consommer un yop perdu.
  # Une erreur send-keys n'interrompt pas le pod (le monitor time-out couvre).
  def handle_info({:kick_attempt, n}, %{tmux_session: session} = state)
      when is_binary(session) do
    cond do
      mandate_pulled?(state.pod_id) ->
        {:noreply, state}

      n >= kick_max_attempts() ->
        Logger.warning(
          "pod #{state.pod_id} kick autonome abandonné après #{n} tentatives " <>
            "(REPL jamais joignable OU mandat jamais pull)"
        )

        {:noreply, state}

      Fleet.Spawner.PodTmux.alive?(state.pod_id) ->
        case Fleet.Spawner.PodTmux.send_keys(state.pod_id, "yop") do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("pod #{state.pod_id} kick (yop) failed : #{inspect(reason)}")
        end

        Process.send_after(self(), {:kick_attempt, n + 1}, kick_retry_ms())
        {:noreply, state}

      true ->
        Process.send_after(self(), {:kick_attempt, n + 1}, kick_retry_ms())
        {:noreply, state}
    end
  end

  # Pas de tmux_session (StubBackend, ou session disparue/kill race) → pas de kick.
  def handle_info({:kick_attempt, _n}, state), do: {:noreply, state}

  # Catch-all silencieux : autres messages (down, monitor, etc.) ignorés.
  def handle_info(_other, state), do: {:noreply, state}

  # (R1.2 — parser NDJSON `parse_chunks`/`handle_event` retiré : modèle -p mort.
  #  La complétion vient du livrable fichier, pas d'un event `result` NDJSON.)

  # Broadcast Bus avec rescue : un crash event_router (bus down, atom
  # invalide) ne doit JAMAIS faire crash le Pod GenServer.
  #
  # BL-021 chantier 9 (B) — schema canon strict %Fleet.Event{source: :spawner}.
  defp safe_broadcast(event_type, payload) when is_binary(event_type) do
    type_atom = String.to_existing_atom(event_type)
    pod_id = Map.get(payload, "pod_id")

    event = %Fleet.Event{
      source: :spawner,
      type: type_atom,
      timestamp: DateTime.utc_now(),
      pod_id: pod_id,
      correlation_id: nil,
      payload: payload
    }

    Bus.broadcast("fleet.events", event)
  rescue
    e ->
      Logger.warning(
        "Pod safe_broadcast #{event_type} rescue (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  end

  # ============================================================
  # Phases
  # ============================================================

  defp do_allocate(state) do
    # Vulcan #5 : I/O non-bang via safe_*. audit elixir #3 :
    # `with_resolved_disallowed_tools` peut raise sur baseline corrupt
    # (fail-closed intangible) — catch via rescue + transition_failed clean
    # plutôt que crash brutal du GenServer.
    cap_profile_path = Path.join(state.pod_dir, ".cap-profile.json")

    with {:ok, resolved} <- safe_resolve_disallowed(state.cap_profile),
         :ok <- safe_mkdir_p(state.pod_dir),
         :ok <-
           safe_write(
             cap_profile_path,
             Jason.encode!(Map.from_struct(resolved), pretty: true)
           ) do
      new_state = %{state | phase: :cleaning}
      {:noreply, new_state, {:continue, :clean}}
    else
      {:error, reason} -> transition_failed(state, {:allocate_failed, reason})
    end
  end

  defp safe_resolve_disallowed(cap_profile) do
    {:ok, Fleet.CapProfile.with_resolved_disallowed_tools(cap_profile)}
  rescue
    e -> {:error, {:baseline_corrupt, Exception.message(e)}}
  end

  defp do_clean(state) do
    # POD_DIR vient d'être créé en :allocate ; rien à clean ici tant que
    # le respawn (recovery) ne réutilise pas le même path.
    new_state = %{state | phase: :projecting}
    {:noreply, new_state, {:continue, :project}}
  end

  defp do_project(state) do
    # Vulcan #5 : toutes les I/O dans la chaîne `with` (non-bang) → erreur
    # propagée → transition_failed clean (state.json phase=failed écrit).
    #
    # POC ticket-driven : le brief n'est PAS un prompt user-canal (safety
    # guardrail refus). Il est :
    #   1. Écrit en `tickets/<ticket_id>.md` (claude le voit comme contenu
    #      projet via Read tool — pas comme injection)
    #   2. Pushé dans la TaskQueue centrale (le pod PULL via tool MCP
    #      get_task déclenché par le mot-clé `yop`)
    # Le SP draft `agent-worker-base.md` (append au SP composé) déclare le
    # workflow yop → get_task → traite → submit_result + convention fail.
    # Le `.claude/protocole-user.md` est injecté pour le mot-clé `yop`.
    skills_root = Application.get_env(:fleet_spawner, :skills_root, nil)
    repo_md = Path.join(state.pod_dir, "CLAUDE.md.repo-source")

    # Provisioning HORS .claude/ : le bind CLAUDE_DIR→.claude de bwrap_launch MASQUE tout fichier pod
    # sous .claude/. settings/SP/protocole → .lcars/ (où claude_launch lit settings + merge le
    # skip-dialog) ; CLAUDE.md custom → racine pod (projet, cwd, non masquée).
    lcars_dir = Path.join(state.pod_dir, ".lcars")
    tickets_dir = Path.join(state.pod_dir, "tickets")

    with {:ok, sp_compose} <-
           SPBuilder.compose(state.cap_profile, [], pod_id: state.pod_id, job_id: state.ticket_id),
         {:ok, claude_md} <- SPBuilder.compose_claude_md(state.cap_profile, maybe_path(repo_md)),
         {:ok, _skills_paths} <- maybe_filter_skills(state.cap_profile, skills_root),
         {:ok, agent_draft} <- read_agent_worker_draft(),
         {:ok, protocole_user} <- read_protocole_user(),
         :ok <- safe_mkdir_p(lcars_dir),
         :ok <-
           safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         # CLAUDE.md custom à la RACINE du pod (projet/cwd, non masquée) ; le reste en .lcars/.
         :ok <- safe_write(Path.join(state.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <- safe_write(Path.join(lcars_dir, "settings.json"), pod_settings_json()),
         # creds : plus de copie (adr-f). Le claudeDir de l'humain est monté RW par bwrap_launch.sh
         # en ~/.claude (CLAUDE_DIR), refresh OAuth délégué au lockfile natif. Les fichiers pod
         # ci-dessus sont en .lcars/ + racine pod (HORS .claude/) → plus masqués par le bind (résolu).
         :ok <- write_pod_claude_json(state),
         :ok <- safe_mkdir_p(tickets_dir),
         :ok <-
           safe_write(
             Path.join(tickets_dir, "#{ticket_id_to_filename(state.ticket_id)}.md"),
             default_brief(state)
           ),
         :ok <- maybe_provision_mcp_config(state),
         :ok <- maybe_bootstrap_project_workspace(state) do
      new_state =
        state
        |> Map.put(:phase, :injecting)
        # SP composé stocké pour l'argv4 inline (do_launch) — la chaîne bwrap le passe en
        # `--system-prompt` (inline), pas en fichier ; .lcars/system-prompt.md reste dispo en miroir.
        |> Map.put(:sp, sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft)
        |> add_condition(:home_projected)

      {:noreply, new_state, {:continue, :inject}}
    else
      {:error, reason} -> transition_failed(state, {:project_failed, reason})
    end
  end

  # Pré-écrit `pod_dir/.claude.json` (state file global claude REPL) avec
  # les flags onboarding + remote-control pré-acceptés. Sans, claude REPL
  # affiche le login screen interactif (même creds valides) ou bloque sur
  # le dialog remote-control au boot. Cohérent avec le gate U-RC e2e qui
  # pré-pose ce fichier.
  defp write_pod_claude_json(state) do
    version =
      case System.cmd("/usr/bin/claude", ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/\d+\.\d+\.\d+/, output) do
            [v | _] -> v
            _ -> "2.1.150"
          end

        _ ->
          "2.1.150"
      end

    payload = %{
      "hasCompletedOnboarding" => true,
      "lastOnboardingVersion" => version,
      "migrationVersion" => 13,
      "remoteControlAtStartup" => true,
      "hasUsedRemoteControl" => true,
      "remoteDialogSeen" => true,
      "projects" => %{
        state.pod_dir => %{
          "allowedTools" => [],
          "hasTrustDialogAccepted" => true,
          "projectOnboardingSeenCount" => 10
        }
      }
    }

    safe_write(Path.join(state.pod_dir, ".claude.json"), Jason.encode!(payload, pretty: true))
  end

  # creds : write_claude_credentials/lead_credentials_path SUPPRIMÉS (adr-f).
  # Plus de copie du `.credentials.json` du lead vers le pod : le claudeDir de
  # l'humain est monté RW par bwrap_launch.sh (CLAUDE_DIR → ~/.claude), refresh
  # OAuth délégué au lockfile cross-process natif Anthropic. Historique : git.

  # settings.json minimal pour le claude REPL du pod.
  #
  # `skipDangerousModePermissionPrompt: true` — pré-accepte le warning
  # interactif que claude affiche au premier boot sous
  # `--dangerously-skip-permissions`. Sans cette clé, le pod tmux session
  # se fige sur "By proceeding, you accept..." (option 1/2 + Enter).
  # Pattern repris du consultant LCARS v1 (`/home/consultant/.claude/
  # settings.json`).
  #
  # `hasCompletedOnboarding: true` — skip aussi l'onboarding step. Le
  # `.claude.json` legacy n'a pas vocation à être touché ici (config
  # globale du user host).
  defp pod_settings_json do
    Jason.encode!(
      %{
        "hasCompletedOnboarding" => true,
        "hasAcknowledgedCostThreshold" => true,
        "skipDangerousModePermissionPrompt" => true
      },
      pretty: true
    )
  end

  # SP draft minimal POC — déclare le rôle agent worker + workflow yop →
  # get_task → submit_result + convention de retour (ok|failed). Le SP
  # final par rôle = chantier séparé post-code.
  defp read_agent_worker_draft do
    path = Application.app_dir(:fleet_sp_builder, "priv/sp_drafts/agent-worker-base.md")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:agent_worker_draft_missing, path, reason}}
    end
  end

  # protocole-user.md (mots-clés personnalisés `yop`/`SeeU`).
  #
  # Default = `priv/sp_drafts/protocole-user-worker.md` shippé avec
  # fleet_sp_builder : version WORKER (yop = trigger workflow ticket-driven,
  # SeeU = no-op). Override par config `:fleet_spawner, :protocole_user_path`
  # si besoin (instance utilisateur custom).
  #
  # PIÈGE évité : pointer sur le protocole-user d'une instance humaine
  # (ex. `/home/starfleet/sp-sources/user/protocole-user.md`) qui définit
  # `yop` comme "reprise de session lire handoff" ou neutralisé (instance
  # v1 éclatée) → le claude REPL du pod ne déclenche PAS le workflow worker.
  # Le gate U-RC live a hit ce piège (cf. chantier U-RC).
  defp read_protocole_user do
    case Application.get_env(:fleet_spawner, :protocole_user_path) do
      nil ->
        path = Application.app_dir(:fleet_sp_builder, "priv/sp_drafts/protocole-user-worker.md")

        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:protocole_user_worker_missing, path, reason}}
        end

      path when is_binary(path) ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:protocole_user_missing, path, reason}}
        end
    end
  end

  defp do_inject(state) do
    # adr-f : plus de resolve_env OAuth (coffre/RT-env déprécié). Le pod
    # s'authentifie via le claudeDir de l'humain, bindé RW par bwrap_launch.sh
    # (env CLAUDE_DIR → ~/.claude, refresh natif Anthropic). La résolution
    # per-humain vient de la registration (DN onboarding/catalogue déférée,
    # adr-e) ; minimal ici = config `:fleet_spawner, :claude_dir`.
    env_vars = %{"CLAUDE_DIR" => claude_dir()}

    new_state =
      state
      |> Map.put(:phase, :launching)
      |> Map.put(:env_vars, env_vars)
      |> add_condition(:context_injected)

    {:noreply, new_state, {:continue, :launch}}
  end

  defp claude_dir do
    Application.get_env(:fleet_spawner, :claude_dir, "/home/starfleet/.claude")
  end

  # Creds du pod = ceux de l'HUMAIN (/home/<human>/.claude), même règle que pod_dir. Override config
  # `:claude_dir` respecté (déploiement non-standard) ; sinon dérivé de l'humain (PAS /home/starfleet).
  defp claude_dir_for(human) do
    Application.get_env(:fleet_spawner, :claude_dir) || "/home/#{human}/.claude"
  end

  # BL-021 chantier 6 — auth mode switch :
  #   :bind     (défaut)  — bind RW de `<claude_dir>/.credentials.json` via bwrap_launch.sh
  #                         (mécanique native Anthropic : lockfile POSIX + mtime cross-process sync
  #                         + refresh atomique). Voie ADR-F historique.
  #   :token_arg          — extrait l'access_token côté hôte depuis creds.json + injecte via
  #                         ANTHROPIC_AUTH_TOKEN env var ; aucun bind du claudeDir humain (pod isolé).
  #                         ATTENTION : désactive le refresh OAuth interne au binaire claude
  #                         (`isAnthropicAuthEnabled` retourne false avec ANTHROPIC_AUTH_TOKEN posé) —
  #                         la viabilité dépend de la durée de vie du token (~8h vérifié) vs la durée
  #                         des pods (one-shot < forever).
  # Toggle via `config :fleet_spawner, :auth_mode, :bind | :token_arg`. Mode posé aussi dans l'env
  # comme `LCARS_AUTH_MODE` pour que bwrap_launch.sh sache quoi faire (bind xor setenv token).
  defp auth_mode do
    Application.get_env(:fleet_spawner, :auth_mode, :bind)
  end

  # Lit l'access_token OAuth depuis `<claude_dir>/.credentials.json` (slot canonique `claudeAiOauth`,
  # cf. inbox/src #0_ref_oauth-token-lifecycle.md §2.2).
  # R15 (verrou I-CBC) : en mode `:token_arg`, l'absence/illisibilité du token est FAIL-LOUD —
  # `{:error, reason}` propagé → `transition_failed`. L'ancien retour `nil` silencieux lançait un
  # pod SANS `LCARS_ANTHROPIC_AUTH_TOKEN` (en `:token_arg` il n'y a pas de bind → 401, pas de
  # fallback `/login`) : un pod inutile au lieu d'un refus net.
  defp read_oauth_access_token(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => %{"accessToken" => token}}} when is_binary(token) <-
           Jason.decode(raw) do
      {:ok, token}
    else
      err ->
        Logger.error(
          "pod auth_mode=:token_arg : read_oauth_access_token ÉCHEC (#{inspect(err)}) — " <>
            "path=#{creds_path} — spawn BLOQUÉ (R15 fail-loud)"
        )

        {:error, {:oauth_token_unreadable, creds_path}}
    end
  end

  # Binaire vendor = celui de l'HUMAIN (~/.local/bin/claude résolu), posé en LCARS_VENDOR_BIN.
  # Honore le contrat bwrap_launch.sh:55 « autorité = LCARS_VENDOR_BIN (spawner) » : sans ça, bwrap
  # retombe sur `command -v claude` = PATH du daemon → binaire système périmé (terrain : /usr/local/bin
  # 2.1.114 au lieu du 2.1.159 user, outil Monitor absent). readlink -f ⇒ bwrap_launch dérive
  # VENDOR_SHARE = dirname(dirname(bin)) juste. Absent ⇒ on ne pose rien (fallback bwrap conservé).
  # BL-021 chantier 6 — branche bwrap_launch.sh sur le mode auth choisi (cf. `auth_mode/0`).
  # `LCARS_AUTH_MODE` est toujours posé (bwrap_launch lit `${LCARS_AUTH_MODE:-bind}` strict) ;
  # `LCARS_ANTHROPIC_AUTH_TOKEN` n'est posé qu'en mode `:token_arg` ET si l'extraction du token
  # depuis creds.json a réussi (sinon le pod part sans token, voir `read_oauth_access_token/1`).
  # R15 : rend `{:ok, env}` | `{:error, reason}`. En mode `:token_arg`, un token
  # absent/illisible → `{:error, _}` (fail-loud, propagé par do_launch →
  # transition_failed). Mode `:bind` (défaut) : toujours `{:ok, _}` (le token
  # n'est pas requis, le claudeDir est bindé).
  defp maybe_put_auth_token(env, human) do
    mode = auth_mode()
    env_with_mode = Map.put(env, "LCARS_AUTH_MODE", Atom.to_string(mode))

    case mode do
      :token_arg ->
        case read_oauth_access_token(claude_dir_for(human)) do
          {:ok, token} -> {:ok, Map.put(env_with_mode, "LCARS_ANTHROPIC_AUTH_TOKEN", token)}
          {:error, _reason} = err -> err
        end

      _ ->
        {:ok, env_with_mode}
    end
  end

  defp maybe_put_vendor_bin(env, human) do
    link = "/home/#{human}/.local/bin/claude"

    if File.exists?(link) do
      bin =
        case System.cmd("readlink", ["-f", link], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> link
        end

      Map.put(env, "LCARS_VENDOR_BIN", bin)
    else
      env
    end
  end

  defp do_launch(state) do
    role = Map.get(state.cap_profile.metadata, "name", "engineer")

    # R0.8-brick4 : plus de budget côté pod (OAuth pool, pas d'API). Le timeout
    # de réponse est géré par `monitor_timeout_ms/1` côté Pod GenServer
    # (Process.send_after :result_deadline). Les backends qui n'ont pas
    # leur propre script de lancement (TmuxBackend, StubBackend) n'ont pas
    # besoin de la valeur ; LauncherPortBackend (legacy bwrap+print) recevait
    # `budget_sec`/`budget_usd` comme args du script — ces clés sont retirées
    # de l'API LaunchBackend (cf. behaviour `Fleet.Spawner.LaunchBackend`).
    human =
      Keyword.get(state.opts, :human, Application.get_env(:fleet_spawner, :pod_human, "fleet"))

    args = %{
      role: role,
      pod_id: state.pod_id,
      pod_dir: state.pod_dir,
      bwrap_launch_path: bwrap_launch_path(),
      claude_launch_path: claude_launch_path(),
      session_id: state.session_id,
      # SP composé inline (argv4 claude_launch) — le fichier .claude/system-prompt.md est masqué
      # par le bind bwrap, donc le SP voyage en argv (cohérent contrat claude_launch.sh).
      sp: state.sp
    }

    env =
      state.env_vars
      |> Map.merge(skills_plugins_env(state.cap_profile))
      |> Map.merge(mcp_channel_env(state.pod_id))
      # U4 — HOME=pod_dir cohérent bwrap pattern (LauncherPortBackend sous bwrap fait
      # `--setenv HOME` de toute façon — ce HOME ici est ignoré). TmuxBackend
      # propage via `tmux -e HOME=...` → claude REPL lit pod_dir/.claude/* (creds
      # OAuth + trust dialog skip) isolé du host. POC scope (containment dégradé).
      |> Map.put("HOME", state.pod_dir)
      # Chaîne de session (DN spawner-orchestrator §D) : bwrap_launch les `--setenv` dans le pod,
      # claude_launch les lit `:?` strict (no-boot sinon). PRÉFIXE nom RC = <human>_<role>.
      |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
      |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
      |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", "#{human}_#{role}")
      # Base sock tmux : bwrap_launch crée la socket sous <base>/<pod_id>/, PodTmux (host) y tape.
      # MÊME valeur des deux côtés ⇒ le sock calculé coïncide. (Défaut /run/lcars/tmux-sock partagé.)
      |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
      # Le pod est celui de l'HUMAIN : creds ET binaire vendor suivent /home/<human> (même règle que
      # pod_dir). Quel binaire = robuste ici (depuis ~/.local/bin, pas le pari `command -v`). Tourner
      # SOUS l'UID de l'humain (ownership/perms/multi-user gratis OS, drop systemd-run --uid) = chantier
      # substrat (cf. journal § reste) — orthogonal et complémentaire à ce qui suit.
      |> Map.put("CLAUDE_DIR", claude_dir_for(human))
      |> maybe_put_vendor_bin(human)

    # R15 : l'étape auth sort du pipe — en mode :token_arg un token absent
    # bloque le spawn (fail-loud) au lieu de lancer un pod sans token.
    with {:ok, env} <- maybe_put_auth_token(env, human) do
      do_launch_backend(state, args, env)
    else
      {:error, reason} -> transition_failed(state, {:auth_token_required, reason})
    end
  end

  defp do_launch_backend(state, args, env) do
    case launch_backend().launch(args, env) do
      {:ok, %{init_message: init_msg, ndjson_log: ndjson_log} = launched} ->
        # #593 D11 — extract port (LauncherPortBackend l'inclut, StubBackend non).
        # nil-able : tests stub n'ont pas de Port → handle_info clauses
        # ne matchent jamais → comportement legacy préservé.
        port = Map.get(launched, :port)

        # tmux_session posé par LauncherPortBackend (chaîne bwrap) ET TmuxBackend ; nil pour StubBackend.
        tmux_session = Map.get(launched, :tmux_session)

        new_state =
          state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:init_message, init_msg)
          |> Map.put(:ndjson_log_path, ndjson_log)
          |> Map.put(:port, port)
          |> Map.put(:tmux_session, tmux_session)
          # session_id PRÉ-ALLOUÉ (state) — plus de capture `init_msg["session_id"]` (modèle -p mort ;
          # init_msg est nil en RC interactif). L'UUID a été alloué à l'init / restauré en recovery.
          |> Map.put(:session_id, state.session_id)
          |> add_condition(:process_launched)
          |> add_condition(:stream_alive)

        write_state_fs(new_state)

        # U4 — Brief delivery au pod long-lived RC.
        #
        # Path actuel : TmuxBackend → send_prompt (tmux load-buffer + paste-buffer).
        #   Pourquoi pas MCP channel push : reverse #5b §2.3 → gate 2
        #   `isChannelsEnabled = tengu_harbor` GrowthBook flag default false côté
        #   Anthropic. send-keys (control plane) reste universel, le brief est
        #   injecté tel quel dans le REPL, claude l'exécute comme prompt.
        #
        # Path LauncherPortBackend : pas applicable (brief.md sur disk lu par claude_launch).
        # Path Stub (tests) : no-op (pas de tmux_session retourné).
        inject_brief_to_tmux_pod(new_state)

        {:noreply, new_state, {:continue, :monitor}}

      {:error, reason} ->
        transition_failed(state, {:launch_failed, reason})
    end
  end

  defp do_monitor(state) do
    # R-CORE.comm 2.2 — completion EVENT-DRIVEN (Iron Law : un seul mécanisme). On souscrit au Bus
    # (Ring 0) et on attend `task_queue.task_completed (struct %Fleet.Event{}){pod_id == mien}` émis par le central (fleet_mcp)
    # sur submit_result. PLUS de poll du fichier result.md (mode fichier retiré). Deadline = budget
    # durée → :failed si aucun résultat. pod.ex (Ring 1) ne lit JAMAIS fleet_mcp (Ring 4) en direct.
    Bus.subscribe()
    Process.send_after(self(), :result_deadline, monitor_timeout_ms(state))
    {:noreply, %{state | phase: :monitoring}}
  end

  defp do_extract(state) do
    # R-CORE.comm 2.2 — le résultat vient de l'event Bus (state.submitted_result), plus d'un fichier.
    #
    # Branche lifetime_scope (chantier engineer long-lived) :
    #   - `one-shot` : extract → release → kill (cycle complet 1 task = 1 vie pod).
    #   - autres (`pipe`/`run`/`forever`) : pod long-lived. Le
    #     broadcast pod.completed remonte le résultat au pipeline / starfleet
    #     (qui décide promote/renvoi), mais le pod RESTE vivant. Retour à
    #     :monitoring, reset submitted_result, re-arm result_deadline pour
    #     attendre la prochaine task (réveillée par `Fleet.Spawner.wake_pod/1`
    #     → send-keys `yop`). Release uniquement sur signal externe
    #     (`Fleet.Spawner.kill_pod/1` invoqué par gatekeeper au promote/abandon)
    #     ou timeout result_deadline → transition_failed.
    #
    # Cf. doctrine `00_doctrine/moon-shot-ref/#02_methodology/pipeline-
    # implementation.md` Phase III étapes 11.0-11.3 + boucles renvoi-au-dev.
    result = state.submitted_result || %{}
    safe_broadcast("pod.completed", pod_completed_payload(state, result))

    new_state =
      state
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(state.cap_profile) do
      "one-shot" ->
        new_state = Map.put(new_state, :phase, :releasing)
        {:noreply, new_state, {:continue, :release}}

      _other ->
        new_state =
          new_state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:submitted_result, nil)

        # Re-arm le deadline (do_monitor n'est pas re-emprunté → on duplique
        # le send_after ici). Bus.subscribe pas re-appelé : déjà subscribed
        # depuis do_monitor au 1er cycle.
        Process.send_after(self(), :result_deadline, monitor_timeout_ms(new_state))
        {:noreply, new_state}
    end
  end

  # Rework #4 : délègue à la source unique `Fleet.CapProfile.lifetime_scope/1`.
  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  # R1.3 (hole C1) : pod.completed porte le contexte pipeline (pipeline_id+stage) si
  # le pod a été spawné par fleet_pipeline (via spawn_opts). L'Executor corrèle alors
  # le pod terminé à sa stage. Pod hors-pipeline → opts sans ces clés → payload nu
  # (le bridge Executor ignore : pas de pipeline_id ⇒ no-op).
  defp pod_completed_payload(state, result) do
    base = %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "result" => result
    }

    opts = state.opts || []

    case {Keyword.get(opts, :pipeline_id), Keyword.get(opts, :stage)} do
      {nil, _} -> base
      {pipeline_id, stage} -> Map.merge(base, %{"pipeline_id" => pipeline_id, "stage" => stage})
    end
  end

  defp do_release(state) do
    # R1.2 — tue le pod interactif (Port.close → claude/bwrap/script terminés) puis ARRÊT NORMAL
    # du GenServer (H-S1 : avant, le Pod restait vivant après :succeeded → memory leak du
    # DynamicSupervisor). Sous `:temporary` (DN-recovery B) l'arrêt :normal n'est jamais ressuscité.
    # NB : pas de clear_for_pod ici — do_release = succès post-EXTRACT, la task a déjà été
    # soumise/complétée (pas de task active à libérer).
    teardown_backend(state)

    new_state =
      state
      |> Map.put(:phase, :succeeded)
      |> add_condition(:home_released)

    write_state_fs(new_state)
    {:stop, :normal, new_state}
  end

  # Teardown du backend du pod (mutuellement exclusif — un seul par lifecycle).
  # U4 — TmuxBackend (RC long-lived) : kill_session via tmux. LauncherPortBackend : Port.close.
  defp teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        Fleet.Spawner.LaunchBackend.TmuxBackend.kill_session(state.tmux_session)

      true ->
        :ok
    end
  end

  @doc """
  Tue le pod de la chaîne bwrap. Le holder (`exec sleep infinity` dans bwrap) IGNORE l'EOF stdin →
  `Port.close` seul l'ORPHELINE (pod survit — PROVEN e2e Elixir 2026-06-01). On SIGTERM le process
  bwrap par son os_pid : bwrap propage au holder → PID1 exit → namespace + serveur tmux + claude
  tombent ensemble. Port.close ensuite (libère le port BEAM). `--die-with-parent` = filet si le BEAM
  meurt avant d'arriver ici. Public pour test direct du fix.
  """
  @spec terminate_pod_port(port()) :: :ok
  def terminate_pod_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    safe_port_close(port)
  end

  @doc """
  Ferme le port BEAM en absorbant l'`ArgumentError` de RACE : le port peut se fermer
  entre notre check et le close (claude finit tout seul après submit_result → son process
  exit → le port disparaît). La garde `Port.info` seule est insuffisante (TOCTOU) — un port
  déjà fermé EST l'état voulu, donc on rescue plutôt que crash (observé F-C4b-3 : do_release
  → `:erlang.port_close` ArgumentError → GenServer du pod crashe sur une complétion RÉUSSIE).
  Public pour test direct.
  """
  @spec safe_port_close(port()) :: :ok
  def safe_port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ============================================================
  # Recovery / state FS
  # ============================================================

  defp recover_or_init(args) do
    base = initial_state(args)

    with {:ok, json} <- File.read(base.state_fs_path),
         {:ok, %{"session_id" => sid, "phase" => phase_str}} when is_binary(sid) <-
           Jason.decode(json) do
      phase = phase_from_string(phase_str) || :launching
      scope = Fleet.CapProfile.lifetime_scope(base.cap_profile)
      apply_recovery(base, recovery_action(phase, scope), sid, phase)
    else
      _ -> base
    end
  end

  @doc """
  Décision de recovery (DN-recovery B) d'un pod (re)spawné dont un `state.json`
  snapshot existe. PURE, fonction de la **phase observée** (pas du scope : le
  scope joue au niveau orchestrateur — faut-il re-spawner un pod absent — pas au
  niveau action-sur-snapshot). Sous `:temporary` le supervisor ne ressuscite
  jamais : c'est un (re)spawn délibéré qui appelle `init/1`, et la décision est
  explicite (plus de reprise implicite `first_continue_for(:monitoring)` sur
  backend mort — LIFE-002).

    * `:release`  — phase terminale (`:succeeded`/`:released`) → rien à relancer.
    * `:resume`   — en vol (`:launching`/`:monitoring`/`:extracting`/`:releasing`) →
                    reprend la session (`--resume`) en RE-LANÇANT le backend (mort) ;
                    jamais `:monitor` direct. Préserve le travail, tout scope.
    * `:recreate` — `:failed` / `:pending` / phase ambiguë → from scratch, session neuve.
  """
  @spec recovery_action(atom(), String.t() | nil) :: :release | :resume | :recreate
  def recovery_action(phase, scope \\ nil) do
    cond do
      phase in [:succeeded, :released, :killed] -> :release
      phase in [:launching, :monitoring, :extracting, :releasing] -> resume_or_recreate(scope)
      true -> :recreate
    end
  end

  # `:resume` (préserver le travail) seulement si (1) le GATE global est ON et (2) le pod
  # porte un contexte reprenable. Sinon `:recreate` (reroll, sûr). F-C4b-1 — `--resume`
  # jamais prouvé live (« pas poncé »), deux cas l'invalident :
  #   * gate OFF (`:recovery_resume_enabled` false) → `:recreate` PARTOUT. Escape-hatch :
  #     si `--resume` se révèle mauvais à l'usage (session morte → claude exit → boot raté
  #     silencieux, observé C4b), on coupe et tout reroll proprement.
  #   * `one-shot` → `:recreate` TOUJOURS (indépendant du gate) : la clear-policy fait
  #     `/clear` chaque cycle (IV.6) → pas de contexte à reprendre, ET le sessionId LOCAL
  #     régénéré par `/clear` diverge du `session_id` snapshot → `--resume` reprendrait la
  #     mauvaise/ancienne session. Le reroll est correct ET sûr.
  #   * `pipe`/`forever` (ou scope inconnu/nil) + gate ON → `:resume` : préserve le travail
  #     mid-mandat (engineer en cours, gatekeeper avec contexte accumulé). Reste exposé au
  #     cas « session morte » → c'est le gate qui sert d'interrupteur si ça se passe mal.
  defp resume_or_recreate(scope) do
    cond do
      not resume_enabled?() -> :recreate
      scope == "one-shot" -> :recreate
      true -> :resume
    end
  end

  defp resume_enabled?, do: Application.get_env(:fleet_spawner, :recovery_resume_enabled, true)

  # :resume → session reprise + RE-LAUNCH (le backend est mort sous `:temporary`).
  defp apply_recovery(base, :resume, sid, phase) do
    base
    |> Map.put(:session_id, sid)
    |> Map.put(:resume, true)
    |> Map.put(:phase, phase)
    |> Map.put(:recovery, :resume)
  end

  # :recreate → fresh, nouvelle session (base intacte : session_id neuf, resume=false).
  defp apply_recovery(base, :recreate, _sid, _phase), do: Map.put(base, :recovery, :recreate)

  # :release → terminal ; le pod stoppera proprement (do_release sur backend nil).
  defp apply_recovery(base, :release, _sid, phase) do
    base |> Map.put(:phase, phase) |> Map.put(:recovery, :release)
  end

  # DN-recovery B : un pod (re)spawné avec un snapshot suit la décision explicite
  # de `recover_or_init`/`recovery_action`. `:resume` RE-MATÉRIALISE (→ :project :
  # le SP + les fichiers .lcars NE sont PAS dans le snapshot minimal, ils se
  # re-composent depuis le cap-profile, déterministe) PUIS launch(resume) —
  # `do_project` pose `state.sp` ; aller directement à :launch laissait sp=nil →
  # `build_spawn` `:invalid_args` (bug exposé live par le gatekeeper-permanent qui
  # recovere d'un `phase:monitoring`, 2026-06-06). JAMAIS reprendre en `:monitor`
  # sur backend mort (LIFE-002). NB : `do_project` re-clone le workspace si
  # `spec.project.repo_path` — idempotence du clone = STATE-003 (séparé) ; pour les
  # pods sans projet (gatekeeper, judges) c'est un no-op.
  defp first_continue_for(%{recovery: :resume}), do: :project
  defp first_continue_for(%{recovery: :recreate}), do: :allocate
  defp first_continue_for(%{recovery: :release}), do: :release
  defp first_continue_for(%{phase: :pending}), do: :allocate
  defp first_continue_for(%{phase: :launching}), do: :launch
  defp first_continue_for(%{phase: phase}), do: phase_to_continue(phase)

  defp phase_to_continue(:allocating), do: :allocate
  defp phase_to_continue(:cleaning), do: :clean
  defp phase_to_continue(:projecting), do: :project
  defp phase_to_continue(:injecting), do: :inject
  defp phase_to_continue(:launching), do: :launch
  defp phase_to_continue(:monitoring), do: :monitor
  defp phase_to_continue(:extracting), do: :extract
  defp phase_to_continue(:releasing), do: :release
  defp phase_to_continue(_), do: :allocate

  defp phase_from_string(s) when is_binary(s) do
    s
    |> String.to_existing_atom()
    |> case do
      atom when is_atom(atom) -> atom
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp phase_from_string(_), do: nil

  defp initial_state(args) do
    state_fs_path = state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = pod_dir_for(args.pod_id, args.cap_profile, args.opts)

    %{
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      ticket_id: args.ticket_id,
      # Session UUID PRÉ-ALLOUÉ au spawn (DN spawner-orchestrator §A) : `--session-id <uuid>` à la
      # 1ʳᵉ création ; `recover_or_init` le RESTAURE depuis state.json → `--resume <uuid>`. Remplace
      # le modèle -p (capture `init_msg["session_id"]`, mort). `resume`=false ; recovery le passe à true.
      session_id: Keyword.get(args.opts, :session_id) || UUID.uuid4(),
      # DN spawner-orchestrator §C-3 (BL-021 chantier 4) : timestamp ISO8601 figé
      # à la création du GenServer, persisté tel quel dans state.json.
      started_at: DateTime.utc_now(),
      resume: false,
      # SP composé (do_project) stocké en state pour l'argv4 inline de claude_launch — le fichier
      # `.claude/system-prompt.md` est MASQUÉ par le bind CLAUDE_DIR→.claude de bwrap_launch.
      sp: nil,
      cap_profile: args.cap_profile,
      env_vars: %{},
      ndjson_log_path: nil,
      pod_dir: pod_dir,
      state_fs_path: state_fs_path,
      init_message: nil,
      last_error: nil,
      opts: args.opts,
      port: nil,
      submitted_result: nil,
      last_result: nil,
      tmux_session: nil
    }
  end

  defp pod_dir_for(pod_id, _cap_profile, opts) do
    # DÉCISION session 2026-06-01 (monde-invoqué / ADR-E) : le pod vit SOUS LE HOME DU HUMAIN
    # (`/home/<human>/pods/pod_<id>`), 0700, isolé OS gratis — PAS un `/home/pods` PARTAGÉ à
    # perms-manuelles (l'anti-pattern qu'on a explicitement rejeté). L'humain est dans le PATH, pas
    # dans le nom ; `pod_<id>` = nom stable (pod_id = clé de recovery, unique par construction → même
    # pod_id = même dossier = stable pour --resume). `:pod_dir_root` reste un override (tests /
    # déploiement non-standard) ; non-set ⇒ défaut per-humain.
    # NB : l'OWNERSHIP effective UID-humain (le pod tourne EN tant que l'humain, owns 0700) via
    # `systemd-run --uid`/setuid = substrat à brancher (cf. journal § reste) — ici on pose le PATH décidé.
    human = Keyword.get(opts, :human, Application.get_env(:fleet_spawner, :pod_human, "fleet"))

    base =
      Keyword.get(opts, :pod_dir_root) ||
        Application.get_env(:fleet_spawner, :pod_dir_root) ||
        "/home/#{human}/pods"

    Path.join(base, "pod_#{pod_id}")
  end

  defp state_fs_path_for(pod_id, cap_profile, opts) do
    root =
      Keyword.get(
        opts,
        :state_fs_root,
        Application.get_env(:fleet_spawner, :state_fs_root, "/var/lib/lcars")
      )

    scope = scope_for(Fleet.CapProfile.lifetime_scope(cap_profile, nil))
    Path.join([root, scope, pod_id, "state.json"])
  end

  defp cap_profile_name(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "name") || Map.get(meta, :name) || "unknown"
  end

  defp cap_profile_name(_), do: "unknown"

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  # DN spawner-orchestrator §C-3 + cap-profiles-schema §B (F-Q5) : `forever` partage
  # le scope FS `pods/` avec `one_shot` (les deux = pods avec lifetime propre).
  defp scope_for("forever"), do: "pods"
  defp scope_for(_), do: "pods"

  defp write_state_fs(state) do
    # DN spawner-orchestrator §C-3 + BL-021 chantier 4 : schéma complet
    # {v, session_id, cap_profile_name, started_at, phase, conditions, ticket_id}.
    payload = %{
      "v" => 1,
      "session_id" => state.session_id,
      "cap_profile_name" => cap_profile_name(state.cap_profile),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "phase" => Atom.to_string(state.phase),
      "conditions" => state.conditions |> MapSet.to_list() |> Enum.map(&Atom.to_string/1),
      "ticket_id" => state.ticket_id
    }

    tmp = state.state_fs_path <> ".tmp"

    # Vulcan #5 : write_state_fs est appelé depuis transition_failed et autres
    # sites — un crash ici provoquerait une régression du fix. Non-bang +
    # log warn ; échec d'écriture state.json = perte du point de recovery
    # uniquement (le {:stop, ...} prévu se passe quand même).
    result =
      with :ok <- File.mkdir_p(Path.dirname(state.state_fs_path)),
           :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)),
           :ok <- File.rename(tmp, state.state_fs_path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "pod #{state.pod_id} write_state_fs failed (non-fatal, recovery dégradé) : " <>
            inspect(reason)
        )

        :ok
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp transition_failed(state, reason) do
    Logger.warning("pod #{state.pod_id} failed: #{inspect(reason)}")

    # STATE-004 (couplage DN-recovery B) : le pod meurt sans relaunch → libérer
    # sa task active sinon elle reste orpheline (assigned/pending sans pod).
    clear_pod_task(state.pod_id)

    new_state =
      state
      |> Map.put(:phase, :failed)
      |> Map.put(:last_error, reason)

    write_state_fs(new_state)
    {:stop, {:shutdown, reason}, new_state}
  end

  defp add_condition(state, condition) do
    Map.update!(state, :conditions, &MapSet.put(&1, condition))
  end

  # STATE-004 : libère la task active d'un pod qui meurt sans l'avoir complétée.
  # Appel direct best-effort (non-fatal) : le Pod est sinon découplé de TaskQueue
  # (complétion event-driven via le bus) — on ne fait pas crasher la mort d'un
  # pod si TaskQueue est indisponible (ex. contexte de test sans broker).
  defp clear_pod_task(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} clear_for_pod échec (non-fatal) : #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("pod #{pod_id} clear_for_pod indisponible (non-fatal) : #{inspect(reason)}")
      :ok
  end

  # R0.8-brick4 : timeout de RÉPONSE (pas budget de durée de vie) au tool MCP
  # submit_result. Si pas de réponse dans le délai → :result_deadline →
  # transition_failed → le pod MEURT (tous `:temporary`, DN-recovery B) : PAS de
  # relaunch OTP. Conséquence (couplage) : la task active est à libérer
  # (`TaskQueue.clear_for_pod`, STATE-004) sinon elle reste orpheline, et le
  # re-dispatch est délibéré (recovery boot-orchestrator).
  #
  # Override par cap-profile optionnel : `spec.timeouts.response_sec`. Sinon
  # default codé par scope (one-shot=300s par défaut ; pour les pods
  # always-on/forever 60s, response time monk = sub-minute).
  defp monitor_timeout_ms(state) do
    override = get_in(state.cap_profile.spec, ["timeouts", "response_sec"])

    sec =
      cond do
        is_number(override) and override > 0 ->
          override

        true ->
          default_response_timeout_sec(state.cap_profile)
      end

    sec * 1000
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      "forever" -> 60
      _other -> 300
    end
  end

  defp maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  defp maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  defp maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  @doc false
  # DN ring1/pod-bootstrap-superpowers : LCARS_SKILLS_PLUGINS = noms
  # plugins uniques extraits des skills QUALIFIÉS `plugin:skill` du
  # cap-profile.spec.knowledge.skills. Consommé par bin/bwrap_launch.sh
  # (mount-bind RO). Anti-M1 : un skill non-qualifié (sans `:`) n'est
  # PAS un plugin → filtré. Vide → pas d'env var (rétro-compatible).
  # Public @doc false : pure, testable directement (pas d'intégration
  # mock-backend lourde pour de la logique triviale).
  def skills_plugins_env(%Fleet.CapProfile{spec: spec}) do
    plugins =
      (spec || %{})
      |> Map.get("knowledge", %{})
      |> Kernel.||(%{})
      |> Map.get("skills", [])
      |> Kernel.||([])
      |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ":")))
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case plugins do
      [] -> %{}
      list -> %{"LCARS_SKILLS_PLUGINS" => Enum.join(list, " ")}
    end
  end

  # Brief du pod = sa TÂCHE (livrée par l'orchestrateur, modèle PUSH).
  # Le travail vient de `opts[:mandate]` (Pipeline → StageRunner construit le mandat depuis
  # la stage ; ou pod direct via Fleet.Spawner.spawn_pod opts).
  #
  # Ton naturel (pas multi-section formalisée "## Tâche / ## Livrable") : claude REPL en
  # mode interactif peut interpréter un format trop structuré comme tentative de prompt
  # injection et refuser. Le contexte fleet (convention submit_result) est posé en
  # préambule conversationnel, pas comme directive impérative ("EXACTEMENT ce payload",
  # "appelle ce tool", etc.).
  # Convertit ticket_id (peut contenir `/`, `#`, etc. — ex.
  # "fleet/lcars#600" depuis Gitea) en filename safe (sans `/` qui
  # créerait des sous-dirs). Convention POC : remplace `/` par `_` et
  # garde `#` (lisible humain).
  defp ticket_id_to_filename(ticket_id) when is_binary(ticket_id) do
    String.replace(ticket_id, "/", "_")
  end

  defp default_brief(state) do
    mandate = Keyword.get(state.opts || [], :mandate)

    body =
      if is_binary(mandate) and mandate != "" do
        mandate
      else
        "(Pas de mandat fourni — ticket #{state.ticket_id}.)"
      end

    """
    Salut. Tu es un worker LCARS (engineer, role pod #{state.pod_id}) ; cette session
    a été lancée par le fleet pour traiter une demande référencée ticket #{state.ticket_id}.

    Le fleet attend que tu utilises le tool MCP `submit_result` quand ton travail est
    terminé — c'est la convention LCARS, le canal de retour structuré équivalent d'un
    Slack DM signed-off. Pas besoin d'écrire de fichier toi-même.

    Voici la demande :

    #{body}
    """
  end

  defp launch_backend do
    Application.get_env(
      :fleet_spawner,
      :launch_backend,
      Fleet.Spawner.LaunchBackend.LauncherPortBackend
    )
  end

  defp bwrap_launch_path do
    Application.get_env(:fleet_spawner, :bwrap_launch_path, "/usr/local/bin/bwrap_launch.sh")
  end

  defp claude_launch_path do
    Application.get_env(:fleet_spawner, :claude_launch_path, "/usr/local/bin/claude_launch.sh")
  end

  # R-CORE.comm — serveur MCP fleet (canal de comm UNIQUE pod↔fleet ; jamais de scraping).
  # Config = chemin pod-accessible (hors /home,/tmp, comme bwrap/claude_launch). IRON LAW : un pod
  # RÉEL parle MCP, point — il n'y a PAS de mode fichier alternatif. `nil` n'est légitime QUE pour
  # les tests à launch-stub (claude pas lancé) ; un backend réel (LauncherPortBackend) sans spec MCP est un
  # bug de config (le brief instruit submit_result, impossible sans serveur).
  #
  # UN mécanisme paramétré (Iron Law) : la config fournit la spec serveur (`command`/`args`/`env`),
  # pod.ex y force `alwaysLoad`. La spec décide — PROD : pont stdio→central (env LCARS_FLEET_MCP_URL),
  # TESTS : fixture file-backed. Même mécanisme, spec différente.
  defp mcp_server_spec, do: Application.get_env(:fleet_spawner, :mcp_server_spec)

  # Env vars MCP à propager au pod (consommés par bridge.py côté pod). `LCARS_POD_ID`
  # est TOUJOURS posé : nécessaire pour que bridge.py injecte `_lcars_pod_id` dans
  # chaque tool call MCP (corrélation côté central PodTools, filtrage TaskQueue.next_for).
  # Sans ça le pod est anonyme — get_task ne retournerait QUE les untargeted (rate les
  # tasks ciblées via wake_pod).
  #
  # BL-021 chantier 7 — purge ADR-G C5.1 : `LCARS_FLEET_MCP_CHANNEL_URL` retiré
  # (push channel ChannelHTTP supprimé, drive via tools pull `get_task`).
  defp mcp_channel_env(pod_id) when is_binary(pod_id) do
    %{"LCARS_POD_ID" => pod_id}
  end

  # Kick AUTONOME « yop » readiness-gated (R3b / F-C4b-2). Déclenche le pull du mandat
  # par MCP get_task — le mandat n'est PAS injecté (il vit dans tickets/ + TaskQueue).
  # No-op si pas de tmux_session (StubBackend ; LauncherPortBackend ET TmuxBackend en posent un).
  #
  # Pourquoi pas un délai FIXE : le claude REPL n'est pas prêt à un instant connu — il
  # boote (tmux server up, banner, init MCP servers via .mcp-fleet.json), durée variable.
  # Un yop à délai fixe arrive trop tôt et est perdu (observé C4b live : « no server
  # running on .../pod.sock » à T+5s). On planifie donc une BOUCLE bornée : à chaque tick,
  # si le serveur tmux est joignable (`PodTmux.alive?`) on envoie yop ; on s'arrête dès que
  # le mandat est pull (task ≠ pending) ou au cap. Non-bloquant (send_after + handle_info),
  # le pod passe à :monitor entretemps. Intervalles configurables (test : valeurs ~ms).
  defp kick_first_delay_ms, do: Application.get_env(:fleet_spawner, :kick_first_delay_ms, 2_000)
  defp kick_retry_ms, do: Application.get_env(:fleet_spawner, :kick_retry_ms, 2_500)
  defp kick_max_attempts, do: Application.get_env(:fleet_spawner, :kick_max_attempts, 12)

  defp inject_brief_to_tmux_pod(%{tmux_session: nil}), do: :ok

  defp inject_brief_to_tmux_pod(%{tmux_session: session}) when is_binary(session) do
    # Démarre la boucle de kick readiness-gated. `yop` = trigger pur (mot-clé
    # protocole-user) ; le SP `agent-worker-base.md` porte le workflow get_task→submit_result.
    Process.send_after(self(), {:kick_attempt, 1}, kick_first_delay_ms())
    :ok
  end

  # Le mandat est-il déjà pull par le pod ? « Pull » = la task est dans un état qui
  # PROUVE que claude a appelé get_task : `:assigned | :in_progress | :completed`.
  # Volontairement PAS : `:pending`/`nil` (pas encore pull / pas encore enqueué — on
  # continue de kicker, ce qui couvre aussi la race spawn↔enqueue), ni `:cleared`/`:failed`
  # (kill délibéré / deadline broker — le pod n'a rien pull, ne PAS arrêter le kick sur
  # un faux « pull » ; au pire on kicke jusqu'au cap, harmless, le result_deadline couvre).
  # Best-effort : exception/exit broker → false (on retentera). Sert à ARRÊTER la boucle.
  defp mandate_pulled?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, s} when s in [:assigned, :in_progress, :completed] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Provisionne $POD_DIR/.mcp-fleet.json (serveur MCP UNIQUE du pod). claude_launch le détecte
  # (--mcp-config --strict-mcp-config). Force `alwaysLoad:true` (VISIBILITÉ : sinon tout tool MCP est
  # déféré derrière ToolSearch — isDeferredTool isMcp→defer — absent du prompt turn-1 ; clé serveur
  # 2.1.150 dé-défère + attend la connexion regular-required. PERMISSION = mcp__fleet__* dans le
  # cap-profile allowedTools. cf corpus #0_ref_mcp-tool-deferral-oneshot.md). Le pod soumet via
  # submit_result → le central broadcaste task_queue.task_completed (struct %Fleet.Event{}) (brick 2.1) → pod.ex extrait (event-driven).
  # #596 — câblage Fleet.ProjectBootstrap.Phase.Clone pour les pods qui
  # déclarent `spec.project.repo_path` (futur use-case : pod sur un projet
  # utilisateur cloné). Aujourd'hui aucun cap-profile prod n'a ce champ, donc
  # no-op. Si présent : clone le repo dans `<pod_dir>/workspace/` + checkout
  # feature branch. Le workspace n'est pas utilisé en aval (claude REPL cwd
  # reste pod_dir) — chantier futur pour wire cwd → workspace.
  #
  # Découplage architectural : Pipeline.WorkspaceProvisioner (Face 2) câble
  # ProjectBootstrap pour les stages git (workspace per-stage). pod.ex câble
  # ProjectBootstrap pour les pods one-shot avec projet (workspace per-pod).
  # 2 sites callers d'un même mécanisme, paramétré par cap-profile.
  defp maybe_bootstrap_project_workspace(state) do
    case get_in(state.cap_profile.spec, ["project", "repo_path"]) do
      nil ->
        :ok

      _repo_path ->
        case Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
               state.pod_dir,
               state.cap_profile,
               []
             ) do
          {:ok, workspace, branch} ->
            Logger.info(
              "pod #{state.pod_id} project workspace cloned: #{workspace} (branch=#{branch || "default"})"
            )

            :ok

          {:error, reason} ->
            {:error, {:project_workspace_clone_failed, reason}}
        end
    end
  end

  defp maybe_provision_mcp_config(state) do
    case {mcp_server_spec(), launch_backend()} do
      # Seam test explicite : StubBackend ne lance pas claude → pas de MCP requis.
      {nil, Fleet.Spawner.LaunchBackend.StubBackend} ->
        :ok

      # R14 (verrou I-CBC) : un backend RÉEL sans spec MCP est un bug de config —
      # le pod réel parle MCP (le brief instruit submit_result, impossible sans
      # serveur). Refus net (propagé au with do_project → transition_failed)
      # plutôt qu'un pod lancé puis bloqué en timeout silencieux.
      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
        fleet_entry = Map.put(spec, "alwaysLoad", true)
        config = %{"mcpServers" => %{"fleet" => fleet_entry}}

        # Vulcan #5 : non-bang + retour {:ok|:error} propagé au with chain
        # do_project (où l'erreur déclenche transition_failed proprement).
        safe_write(
          Path.join(state.pod_dir, ".mcp-fleet.json"),
          Jason.encode!(config, pretty: true)
        )
    end
  end

  # ============================================================
  # Safe FS helpers — Vulcan #5
  # ============================================================
  # Bang variants (File.mkdir_p!, File.write!, File.rename!) raise sur
  # erreur → kill brutal du GenServer → supervisor restart sans transition
  # propre → state.json potentiellement obsolète/corrompu côté recovery.
  # Ces helpers retournent {:ok|:error} avec contexte (path + reason) →
  # propagation via `with` → transition_failed clean (state.json
  # phase=failed écrit avant {:stop, ...}).

  defp safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp safe_write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end
end
