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
  FS détecte un `session_id` capturé, l'`init/1` reprend directement
  en phase `:launching` (le respawn passera `--resume <session_id>`).

  ## Conditions

  Set d'événements observables ajoutés au passage des phases :
  `:home_projected`, `:context_injected`, `:process_launched`,
  `:stream_alive`, `:init_validated`, `:output_extracted`,
  `:home_released`. Permet à `pod_info/1` de distinguer "phase X
  atteinte" de "condition Y vérifiée".

  ## F-INIT-VALIDATE (handoff consultant SDK)

  Au passage `:monitoring`, le module valide les 9 champs critiques
  de la première frame `init` NDJSON émise par claude -p :
  `tools`, `model`, `permission_mode`, `api_key_source`, `cwd`,
  `claude_code_version`, `mcp_servers`, `slash_commands`, `agents`.
  Si la frame `init` reçue manque > 0 champs requis ou si
  `api_key_source` ≠ `"oauth"`, le pod transitionne `:failed`.

  ## Recovery state FS

  `<state_fs_root>/<scope>/<id>/state.json` écrit après `:launching`
  (capture `session_id`). `<scope>` ∈ `pods` (one-shot) /
  `pipes` (pipe) / `runs` (run/session-user/forever). Au prochain
  `init/1`, lecture du fichier → reprise directe en phase
  `:launching` avec le `session_id` (claude -p `--resume`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.SPBuilder

  # R-CORE.comm 2.2 — completion EVENT-DRIVEN : le résultat arrive via l'event Bus
  # `pod.result_submitted` (émis par le central sur submit_result), PAS via un fichier.

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
          # R-CORE.comm 2.2 — résultat reçu via l'event Bus pod.result_submitted (completion).
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

  # R-CORE.comm 2.2 — completion event-driven : le central (fleet_mcp) a broadcasté le résultat
  # d'un pod. On ne réagit qu'au NÔTRE (corrélation pod_id, brick 1a/1b) et seulement en :monitoring.
  @impl GenServer
  def handle_info({:"pod.result_submitted", event}, %{phase: :monitoring} = state) do
    if is_map(event) and event["pod_id"] == state.pod_id do
      {:noreply, Map.put(state, :submitted_result, event["payload"] || %{}),
       {:continue, :extract}}
    else
      # Résultat d'un autre pod → ignore (le Bus est partagé).
      {:noreply, state}
    end
  end

  # Event reçu hors phase :monitoring (déjà extrait/released) ou d'un autre pod → ignore.
  def handle_info({:"pod.result_submitted", _event}, state), do: {:noreply, state}

  # Deadline : aucun résultat soumis dans le budget durée → échec.
  def handle_info(:result_deadline, %{phase: :monitoring} = state) do
    transition_failed(state, {:result_timeout, state.pod_id})
  end

  def handle_info(:result_deadline, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state)
      when is_port(port) do
    # R-CORE.comm 2.2 — completion event-driven : si le résultat a été extrait (event
    # pod.result_submitted reçu → :output_extracted), l'exit est l'arrêt normal post-release.
    # Sinon le process est mort SANS soumettre de résultat → échec (plus de salvage fichier).
    if MapSet.member?(state.conditions, :output_extracted) do
      {:stop, :normal, state}
    else
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

  # U4 — Inject brief asynchrone (post-délai) au claude REPL TmuxBackend.
  # Phase indépendante du cycle ALLOCATE→RELEASE : le pod est probably en :monitoring
  # quand ce message arrive. Une erreur send-keys n'interrompt pas le pod (warning
  # + le monitor pourra time-out si claude n'a rien reçu).
  def handle_info({:inject_brief, brief}, %{tmux_session: session} = state)
      when is_binary(session) and is_binary(brief) do
    case Fleet.Spawner.LaunchBackend.TmuxBackend.send_prompt(session, brief) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "pod #{state.pod_id} brief injection failed (tmux=#{session}) : #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  # tmux_session disparue (kill_session race) ou pod stoppé → ignore.
  def handle_info({:inject_brief, _}, state), do: {:noreply, state}

  # Catch-all silencieux : autres messages (down, monitor, etc.) ignorés.
  def handle_info(_other, state), do: {:noreply, state}

  # (R1.2 — parser NDJSON `parse_chunks`/`handle_event` retiré : modèle -p mort.
  #  La complétion vient du livrable fichier, pas d'un event `result` NDJSON.)

  # Broadcast Bus avec rescue : un crash event_router (bus down, atom
  # invalide) ne doit JAMAIS faire crash le Pod GenServer.
  defp safe_broadcast(event_type, payload) do
    Bus.broadcast(event_type, payload)
  rescue
    e ->
      Logger.warning(
        "Pod safe_broadcast #{event_type} rescue (non-fatal) — " <>
          Exception.message(e)
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
    sp_dir = Path.join(state.pod_dir, ".claude")
    tickets_dir = Path.join(state.pod_dir, "tickets")

    with {:ok, sp_compose} <-
           SPBuilder.compose(state.cap_profile, [], pod_id: state.pod_id, job_id: state.ticket_id),
         {:ok, claude_md} <- SPBuilder.compose_claude_md(state.cap_profile, maybe_path(repo_md)),
         {:ok, _skills_paths} <- maybe_filter_skills(state.cap_profile, skills_root),
         {:ok, agent_draft} <- read_agent_worker_draft(),
         {:ok, protocole_user} <- read_protocole_user(),
         :ok <- safe_mkdir_p(sp_dir),
         :ok <-
           safe_write(
             Path.join(sp_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         :ok <- safe_write(Path.join(sp_dir, "CLAUDE.md"), claude_md),
         :ok <- safe_write(Path.join(sp_dir, "protocole-user.md"), protocole_user),
         :ok <- safe_write(Path.join(sp_dir, "settings.json"), pod_settings_json()),
         # creds : plus de copie (adr-f). Le claudeDir de l'humain est monté RW
         # par bwrap_launch.sh en ~/.claude (CLAUDE_DIR) ; refresh OAuth délégué
         # au lockfile cross-process natif Anthropic. RUNTIME-TODO (secondaire) :
         # les fichiers pod-spécifiques ci-dessus (sp/CLAUDE.md/settings) sous
         # .claude/ sont masqués/clobbés par le bind → à relocaliser hors ~/.claude
         # au build (cf. worklog EXEC-consolidation §interaction share-claudeDir).
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

  defp do_launch(state) do
    role = Map.get(state.cap_profile.metadata, "name", "engineer")

    # R0.8-brick4 : plus de budget côté pod (OAuth pool, pas d'API). Le timeout
    # de réponse est géré par `monitor_timeout_ms/1` côté Pod GenServer
    # (Process.send_after :result_deadline). Les backends qui n'ont pas
    # leur propre script de lancement (TmuxBackend, StubBackend) n'ont pas
    # besoin de la valeur ; LauncherPortBackend (legacy bwrap+print) recevait
    # `budget_sec`/`budget_usd` comme args du script — ces clés sont retirées
    # de l'API LaunchBackend (cf. behaviour `Fleet.Spawner.LaunchBackend`).
    args = %{
      role: role,
      pod_id: state.pod_id,
      pod_dir: state.pod_dir,
      bwrap_launch_path: bwrap_launch_path(),
      claude_launch_path: claude_launch_path(),
      session_id: state.session_id
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

    case launch_backend().launch(args, env) do
      {:ok, %{init_message: init_msg, ndjson_log: ndjson_log} = launched} ->
        # #593 D11 — extract port (LauncherPortBackend l'inclut, StubBackend non).
        # nil-able : tests stub n'ont pas de Port → handle_info clauses
        # ne matchent jamais → comportement legacy préservé.
        port = Map.get(launched, :port)
        # U4 — tmux_session présent quand TmuxBackend, nil sinon (LauncherPortBackend/Stub).
        tmux_session = Map.get(launched, :tmux_session)

        new_state =
          state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:init_message, init_msg)
          |> Map.put(:ndjson_log_path, ndjson_log)
          |> Map.put(:port, port)
          |> Map.put(:tmux_session, tmux_session)
          |> Map.put(
            :session_id,
            (is_map(init_msg) && init_msg["session_id"]) || launched[:session_id] ||
              state.session_id
          )
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
        #
        # PushDispatcher + ChannelHTTP (U2) restent en place pour activation future
        # quand tengu_harbor sera dispo (zéro code à toucher côté pod.ex à ce moment).
        inject_brief_to_tmux_pod(new_state)

        {:noreply, new_state, {:continue, :monitor}}

      {:error, reason} ->
        transition_failed(state, {:launch_failed, reason})
    end
  end

  defp do_monitor(state) do
    # R-CORE.comm 2.2 — completion EVENT-DRIVEN (Iron Law : un seul mécanisme). On souscrit au Bus
    # (Ring 0) et on attend `pod.result_submitted{pod_id == mien}` émis par le central (fleet_mcp)
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
    #   - autres (`pipe`/`run`/`session-user`/`forever`) : pod long-lived. Le
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

  defp lifetime_scope(%Fleet.CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) || "one-shot"
  end

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
    # DynamicSupervisor). restart: :transient → pas de respawn sur :normal.
    # U4 — TmuxBackend (RC long-lived) : kill_session via tmux. LauncherPortBackend : Port.close.
    # Sélection mutuellement exclusive (un seul backend par lifecycle pod).
    cond do
      is_port(state.port) and Port.info(state.port) ->
        Port.close(state.port)

      is_binary(state.tmux_session) ->
        Fleet.Spawner.LaunchBackend.TmuxBackend.kill_session(state.tmux_session)

      true ->
        :ok
    end

    new_state =
      state
      |> Map.put(:phase, :succeeded)
      |> add_condition(:home_released)

    write_state_fs(new_state)
    {:stop, :normal, new_state}
  end

  # ============================================================
  # Recovery / state FS
  # ============================================================

  defp recover_or_init(args) do
    base = initial_state(args)

    case File.read(base.state_fs_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"session_id" => session_id, "phase" => phase}} when is_binary(session_id) ->
            base
            |> Map.put(:session_id, session_id)
            |> Map.put(:phase, phase_from_string(phase) || :launching)

          _ ->
            base
        end

      {:error, _} ->
        base
    end
  end

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
      session_id: nil,
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

  defp pod_dir_for(pod_id, cap_profile, opts) do
    base =
      Keyword.get(
        opts,
        :pod_dir_root,
        Application.get_env(:fleet_spawner, :pod_dir_root, "/home/pods")
      )

    # Nom = <human>_<role>_<pod_id>. Repère humain+role lisible en tête ; pod_id
    # comme discriminateur : unique PAR CONSTRUCTION (collision irreprésentable),
    # stateless (pas de compteur _XX à allouer = pas de registre = pas de smell
    # I-CBC), et déjà la clé de recovery (state_fs keyé pod_id) → MÊME pod_id =
    # MÊME dossier → stable pour --resume. Le nom est une fonction pure de
    # (human, role, pod_id) : différenciation par data, aucun branchement.
    role = Map.get(cap_profile.metadata, "name", "worker")

    human =
      Keyword.get(
        opts,
        :human,
        Application.get_env(:fleet_spawner, :pod_human, "fleet")
      )

    Path.join(base, "#{human}_#{role}_#{pod_id}")
  end

  defp state_fs_path_for(pod_id, cap_profile, opts) do
    root =
      Keyword.get(
        opts,
        :state_fs_root,
        Application.get_env(:fleet_spawner, :state_fs_root, "/var/lib/lcars")
      )

    scope = scope_for(get_in(cap_profile.spec, ["invocation", "lifetime_scope"]))
    Path.join([root, scope, pod_id, "state.json"])
  end

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  defp scope_for("session-user"), do: "runs"
  defp scope_for("forever"), do: "runs"
  defp scope_for(_), do: "pods"

  defp write_state_fs(state) do
    payload = %{
      "v" => 1,
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "session_id" => state.session_id,
      "phase" => Atom.to_string(state.phase)
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

  # R0.8-brick4 : timeout de RÉPONSE (pas budget de durée de vie) au tool MCP
  # submit_result. Si pas de réponse dans le délai → :result_deadline →
  # transition_failed → kill+relaunch via OTP restart strategy par
  # `lifetime_scope` (one-shot=:temporary, pipe/run/session-user=:transient,
  # forever=:permanent — cf. `Fleet.Spawner.restart_strategy_for/1`).
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

  # U4 — env vars push channel à propager au pod (bridge.py démarré par claude REPL).
  # Le bridge.py active sa thread `channel_poll_loop` SSI les deux vars sont présentes ;
  # absentes → mode legacy tools-only (pas de push channel). `mcp_channel_url/0` retourne
  # nil si non configuré côté daemon → no-op silencieux.
  defp mcp_channel_env(pod_id) when is_binary(pod_id) do
    # LCARS_POD_ID est TOUJOURS propagé au pod : nécessaire pour le
    # bridge.py qui injecte `_lcars_pod_id` dans chaque tool call MCP
    # (corrélation côté central PodTools, filtrage TaskQueue.next_for).
    # Sans, le pod est anonyme — get_task ne retournerait QUE les
    # untargeted (rate les tasks ciblées via wake_pod).
    base = %{"LCARS_POD_ID" => pod_id}

    # LCARS_FLEET_MCP_CHANNEL_URL : optionnel (push channel U2). Activé
    # seulement si configuré côté daemon.
    case mcp_channel_url() do
      nil -> base
      url when is_binary(url) -> Map.put(base, "LCARS_FLEET_MCP_CHANNEL_URL", url)
    end
  end

  defp mcp_channel_url do
    Application.get_env(:fleet_spawner, :mcp_channel_url)
  end

  # U4 — Injection brief au claude REPL via tmux send-keys (load-buffer + paste-buffer).
  # No-op si pas de tmux_session (LauncherPortBackend / StubBackend → brief reste sur disk
  # brief.md, lu par claude_launch.sh).
  #
  # Délai `@brief_inject_delay_ms` avant inject : le claude REPL n'est pas
  # immédiatement prêt à recevoir input — il boote, affiche banner, initialise
  # MCP servers (spawn bridge.py via .mcp-fleet.json). Send-keys arrivés trop
  # tôt sont perdus. 4s = empiriquement suffisant sur cette machine, à calibrer.
  # Le délai est non-bloquant (Process.send_after + handle_info), le Pod GenServer
  # passe à :monitor entretemps.
  #
  # PushDispatcher / ChannelHTTP / Bus event `pod.brief.push` restent disponibles
  # (U2) pour activation future quand le flag `tengu_harbor` channels MCP sera
  # supporté côté Anthropic. Côté pod.ex : changement = swap de cet appel.
  @brief_inject_delay_ms 4_000

  defp inject_brief_to_tmux_pod(%{tmux_session: nil}), do: :ok

  defp inject_brief_to_tmux_pod(%{tmux_session: session}) when is_binary(session) do
    # Trigger pur : `yop` (mot-clé du protocole-user). Le SP draft
    # `agent-worker-base.md` injecté dans system-prompt.md décrit le
    # workflow : sur `yop` → `mcp__fleet__get_task` → traite → `mcp__fleet__
    # submit_result`. Pas de mandate inline (= prompt injection guardrail
    # refus). Pas de "lis ce fichier" non plus — le SP a déjà le workflow,
    # `yop` = juste le démarrage du cycle.
    Process.send_after(self(), {:inject_brief, "yop"}, @brief_inject_delay_ms)
    :ok
  end

  # Provisionne $POD_DIR/.mcp-fleet.json (serveur MCP UNIQUE du pod). claude_launch le détecte
  # (--mcp-config --strict-mcp-config). Force `alwaysLoad:true` (VISIBILITÉ : sinon tout tool MCP est
  # déféré derrière ToolSearch — isDeferredTool isMcp→defer — absent du prompt turn-1 ; clé serveur
  # 2.1.150 dé-défère + attend la connexion regular-required. PERMISSION = mcp__fleet__* dans le
  # cap-profile allowedTools. cf corpus #0_ref_mcp-tool-deferral-oneshot.md). Le pod soumet via
  # submit_result → le central broadcaste pod.result_submitted (brick 2.1) → pod.ex extrait (event-driven).
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
    case mcp_server_spec() do
      nil ->
        :ok

      spec when is_map(spec) ->
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
