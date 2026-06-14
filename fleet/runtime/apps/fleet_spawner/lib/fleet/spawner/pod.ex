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
          # Nom de la session tmux du pod (`lcars-pod-<id>` sur le sock PAR-POD, posé par
          # LauncherPortBackend). Sert au kick/wake (PodTmux) et au teardown sock-aware (F124).
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
      # tmux_session : nom de la session tmux du pod, posé par LauncherPortBackend (les deux
      # launchers N0 bwrap/host créent un tmux par-pod), nil pour StubBackend. Exposé pour
      # Fleet.Spawner.wake_pod/1 (send-keys `yop` au pod cible pour nouveau cycle).
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
    # Z1 #3 : le résultat est arrivé → annuler le deadline AVANT d'extraire (sinon le
    # timer du cycle courant fire plus tard en :monitoring et tue le pod sain).
    state = cancel_result_deadline(state)
    {:noreply, Map.put(state, :submitted_result, result), {:continue, :extract}}
  end

  # %Fleet.Event{task_completed} d'un autre pod, ou hors phase :monitoring → ignore.
  def handle_info(%Fleet.Event{source: :task_queue, type: :task_completed}, state),
    do: {:noreply, state}

  # Deadline : timeout de RÉPONSE. Au FIRE, on distingue (Z1) :
  #   - task active (pending/assigned/in_progress) → le pod n'a PAS répondu à temps → échec.
  #   - aucune task active → le pod attendait juste sa prochaine task (idle) ; ce n'est
  #     PAS un timeout de réponse → on laisse lapser, PAS de kill (sinon on re-crée
  #     l'idle-kill que le band-aid 60ks masquait). La vérif est à l'instant du fire
  #     (≠ à l'armement) → couvre la race d'enqueue worker ET l'inter-stage pipe d'un coup.
  def handle_info(:result_deadline, %{phase: :monitoring} = state) do
    if pod_has_active_task?(state.pod_id) do
      transition_failed(state, {:result_timeout, state.pod_id})
    else
      {:noreply, Map.put(state, :result_deadline_ref, nil)}
    end
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
    # Un pod SANS mandat en attente (interactif/forever comme l'architecte, ou permanent booté
    # à froid comme le gatekeeper) n'a RIEN à puller : ses mandats arrivent plus tard via
    # `wake_pod`. R3b se contente alors d'un BOOTSTRAP — réveil du REPL + armement du Monitor
    # (cf. SP) — borné et ESPACÉ (pas de rafale de 12 yops qui distrait l'agent). Un worker
    # (mandat enqueué au spawn) garde le kick fréquent jusqu'au pull. Détection race-safe :
    # l'enqueue StageRunner (ms après spawn) précède largement le 1er kick (+2s) → un worker a
    # déjà son mandat `pending`, un pod permanent a `pod_status == {:ok, nil}`.
    bootstrap? = no_pending_mandate?(state.pod_id)
    cap = if bootstrap?, do: kick_bootstrap_max(), else: kick_max_attempts()
    retry = if bootstrap?, do: kick_bootstrap_retry_ms(), else: kick_retry_ms()

    cond do
      mandate_pulled?(state.pod_id) ->
        {:noreply, state}

      n >= cap ->
        if bootstrap? do
          Logger.debug(
            "pod #{state.pod_id} bootstrap kické (#{n}× sans mandat) → en attente de wake_pod"
          )
        else
          Logger.warning(
            "pod #{state.pod_id} kick autonome abandonné après #{n} tentatives " <>
              "(REPL jamais joignable OU mandat jamais pull)"
          )
        end

        {:noreply, state}

      Fleet.Spawner.PodTmux.alive?(state.pod_id) ->
        case Fleet.Spawner.PodTmux.send_keys(state.pod_id, "yop") do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("pod #{state.pod_id} kick (yop) failed : #{inspect(reason)}")
        end

        Process.send_after(self(), {:kick_attempt, n + 1}, retry)
        {:noreply, state}

      true ->
        Process.send_after(self(), {:kick_attempt, n + 1}, retry)
        {:noreply, state}
    end
  end

  # Pas de tmux_session (StubBackend, ou session disparue/kill race) → pas de kick.
  def handle_info({:kick_attempt, _n}, state), do: {:noreply, state}

  # Catch-all silencieux : autres messages (down, monitor, etc.) ignorés.
  def handle_info(_other, state), do: {:noreply, state}

  # F112 : ré-armement de la deadline de réponse — déclenché par `wake_pod` quand une nouvelle tâche
  # est assignée à un pod long-lived. Seulement en :monitoring (hors-monitoring = pas de fenêtre de
  # réponse active) ; sinon no-op. arm_result_deadline annule l'ancien timer + en arme un neuf.
  @impl GenServer
  def handle_cast(:rearm_deadline, %{phase: :monitoring} = state) do
    {:noreply, arm_result_deadline(state)}
  end

  def handle_cast(:rearm_deadline, state), do: {:noreply, state}

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
         :ok <- gate_cap_profile(resolved),
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

  # Z2 / CAP-D1 — porte de containment G24 (dont F-CONT-RISK g24_9 : deny des
  # server-tools natifs Anthropic) câblée au boundary spawn. `validate/1` (toute la
  # sémantique G24) n'était appelée QUE par les tests → porte creuse : un profil neuf
  # ou un modop qui remplace `disallowedTools` bypassait silencieusement. Fail-loud :
  # profil G24-invalide → :failed, le pod n'est JAMAIS lancé. Le JSON-schema (load/
  # compose) ne couvre PAS g24_1/3/6/8/9/14 — d'où le besoin de validate/1 ici.
  defp gate_cap_profile(resolved) do
    case Fleet.CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
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

    # P1/C9 (2026-06-07) — `.claude/` est désormais POD-OWNED. bwrap ne bind QUE
    # `.credentials.json` dedans (plus le .claude humain entier). Raison de la fuite : cwd=HOME=POD_DIR,
    # donc les tiers settings `project`/`local` (racine = cwd) résolvaient dans `$POD_DIR/.claude/` =
    # le `.claude` humain bindé → le settings.json humain (et ses hooks) lu comme settings *projet*.
    # `--setting-sources project,local` n'y pouvait rien (il autorise project/local). Fix : `.claude/`
    # pod-owned + aucun settings.json dedans → tiers project/local vides → 0 hook humain.
    # cf JOURNAL-P1-hooks.md. Fichiers pod (settings/SP/protocole) en .lcars/ ; CLAUDE.md → racine pod.
    pod_claude_dir = Path.join(state.pod_dir, ".claude")
    lcars_dir = Path.join(state.pod_dir, ".lcars")
    tickets_dir = Path.join(state.pod_dir, "tickets")

    with {:ok, sp_compose} <-
           SPBuilder.compose(state.cap_profile, [], pod_id: state.pod_id, job_id: state.ticket_id),
         {:ok, claude_md} <- SPBuilder.compose_claude_md(state.cap_profile, maybe_path(repo_md)),
         {:ok, _skills_paths} <- maybe_filter_skills(state.cap_profile, skills_root),
         {:ok, agent_draft} <- read_agent_draft(state.cap_profile),
         {:ok, protocole_user} <- read_protocole_user(),
         :ok <- safe_mkdir_p(lcars_dir),
         # `.claude/` pod-owned = cible du bind creds-only (bwrap_launch). On ne crée QUE le dir,
         # aucun settings.json dedans → 0 hook humain (P1/C9). bwrap y monte `.credentials.json`.
         :ok <- safe_mkdir_p(pod_claude_dir),
         :ok <-
           safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         # CLAUDE.md custom à la RACINE du pod (projet/cwd, non masquée) ; le reste en .lcars/.
         :ok <- safe_write(Path.join(state.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <- safe_write(Path.join(lcars_dir, "settings.json"), pod_settings_json()),
         # creds : plus de copie (adr-f). Seul `.credentials.json` de l'humain est monté RW par
         # bwrap_launch.sh dans `pod_dir/.claude/` (refresh OAuth natif, écriture en place). `.claude/`
         # reste pod-owned → pas de hook humain. Les fichiers pod sont en .lcars/ + racine pod.
         # F115/F157 : le `.claude.json` (onboarding + remote-control) est écrit par claude_launch.sh
         # (frontière vendor N1) — PAS ici. La version N0 était clobberée à l'exec (claude_launch le
         # ré-écrit sans condition) ET vivait dans N0 (connaissance vendor) : retirée (ADR-G / N1).
         :ok <- safe_mkdir_p(tickets_dir),
         :ok <-
           safe_write(
             Path.join(tickets_dir, "#{ticket_id_to_filename(state.ticket_id)}.md"),
             default_brief(state)
           ),
         :ok <- maybe_provision_mcp_config(state),
         :ok <- provision_monitor_watch(state),
         :ok <- maybe_bootstrap_project_workspace(state) do
      new_state =
        state
        |> Map.put(:phase, :injecting)
        # SP plus stocké en state (plus en argv) : la SOURCE = .lcars/system-prompt.md (écrit ci-dessus),
        # lu par claude_launch via --system-prompt-file. Supprime la fragilité sp=nil au recovery.
        |> add_condition(:home_projected)

      {:noreply, new_state, {:continue, :inject}}
    else
      {:error, reason} -> transition_failed(state, {:project_failed, reason})
    end
  end

  # F115/F157 — `write_pod_claude_json` + `detect_claude_version` RETIRÉS. Le `.claude.json`
  # (onboarding + remote-control pré-acceptés) est désormais l'unique responsabilité de
  # `claude_launch.sh` (frontière vendor N1) : la version N0 était (1) systématiquement clobberée
  # par le `cat >` du launcher juste avant l'exec — donc morte — et perdait au passage les 3 clés RC
  # (`remoteControlAtStartup`/`hasUsedRemoteControl`/`remoteDialogSeen`), ré-introduisant le blocage
  # dialog RC qu'elle prétendait éviter ; (2) plaçait de la connaissance schéma-vendor dans N0. Les
  # clés RC ont migré dans le launcher (clé `projects` correcte = `LCARS_POD_CWD`, pas `pod_dir`).

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
  # Draft SP role-aware (Rail 2 e2e 2026-06-14) : l'architecte reçoit un draft DÉLÉGATEUR
  # (les 2 leviers qualité+économie + create_ticket), les workers le draft get_task/submit_result.
  # Sélection par metadata.name (string-keyed). Défaut = worker.
  defp read_agent_draft(%Fleet.CapProfile{metadata: meta}) do
    file =
      case Map.get(meta || %{}, "name", "") do
        "architect" -> "priv/sp_drafts/agent-architect-base.md"
        _ -> "priv/sp_drafts/agent-worker-base.md"
      end

    path = Application.app_dir(:fleet_sp_builder, file)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:agent_draft_missing, path, reason}}
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

  # L'humain qui fait tourner la fleet = l'user du process runtime lui-même. Décision 2026-06-09 :
  # sur cette instance les SEULS users sont les users fleet → l'user courant EST l'humain. Pas de
  # config, pas de défaut littéral (un défaut = masquage d'un trou de câblage, I-CBC). Le pod, enfant
  # du runtime (Port/tmux), HÉRITE de cet UID → tourne dans le home de l'humain, bind ses creds. Si
  # demain quelqu'un d'autre installe LCARS, c'est SON user qui lance, SON home — rien à hardcoder.
  # Fail-loud si HOME/user irrésoluble (impossible en pratique, mais jamais rattrapé en silence).
  defp runtime_home, do: System.user_home!()

  # F027 : source UNIQUE `Fleet.Credentials.Human` (plus de `id -un` shellé en double — sinon
  # spawn-ownership et commit-identity peuvent diverger, casse F-01). Fail-loud (raise) conservé,
  # rattrapé par le try/rescue de do_launch (F120).
  defp runtime_user, do: Fleet.Credentials.Human.current!()

  defp claude_dir do
    Application.get_env(:fleet_spawner, :claude_dir) || Path.join(runtime_home(), ".claude")
  end

  # Creds du pod = `~/.claude` de l'HUMAIN (= l'user runtime). Override config `:claude_dir` respecté
  # (tests / déploiement non-standard) ; sinon dérivé de son home passwd.
  defp claude_dir_for(human) do
    Application.get_env(:fleet_spawner, :claude_dir) || claude_dir_from_passwd(human)
  end

  # Creds du pod = `.claude` dans le home de l'humain, résolu via `getent passwd`. Échec passwd =
  # erreur réelle (l'user de l'humain DOIT exister) → fail-loud, pas de `/home/<x>` deviné.
  defp claude_dir_from_passwd(human) do
    case passwd_home(human) do
      {:ok, home} -> Path.join(home, ".claude")
      :error -> raise "claude_dir: home introuvable (getent passwd #{inspect(human)}) — fail-loud"
    end
  end

  # Auth mode (cf. inbox/src #0_ref_oauth-token-lifecycle.md) : DÉFAUT = :bind.
  #   :bind (défaut) — bwrap bind RW le `.credentials.json` de l'HUMAIN (avec son refreshToken) →
  #                    refresh natif (proactif 5min + réactif 401 + lockfile). Full scope, PAS de
  #                    falaise ~8h. Le pod = l'humain → bind son propre claudeDir, zéro copie.
  #   :token_arg     — échappatoire opt-in : extrait l'access_token OAuth (~8h, expiresAt:null côté pod
  #                    donc AUCUN refresh) et l'injecte en CLAUDE_CODE_OAUTH_TOKEN. Fail-loud R15 si
  #                    creds.json illisible. À réserver aux pods one-shot < 8h.
  # Toggle via `config :fleet_spawner, :auth_mode`. Posé aussi en env `LCARS_AUTH_MODE` pour bwrap_launch.sh.
  defp auth_mode do
    Application.get_env(:fleet_spawner, :auth_mode, :bind)
  end

  # Token-extractor au-dessus de la SOURCE UNIQUE `read_oauth_creds/1` (F117/F118/F119 — plus de 2e parser
  # de `.credentials.json` : un seul File.read + Jason.decode + extraction du bloc `claudeAiOauth`). Slot
  # canonique `claudeAiOauth.accessToken` (cf. inbox/src #0_ref_oauth-token-lifecycle.md §2.2).
  # R15 (verrou I-CBC) : en mode `:token_arg`, l'absence/illisibilité du token est FAIL-LOUD —
  # `{:error, {:oauth_token_unreadable, _}}` propagé → `transition_failed`. L'ancien retour `nil` silencieux
  # lançait un pod SANS `LCARS_ANTHROPIC_AUTH_TOKEN` (en `:token_arg` pas de bind → 401, pas de fallback
  # `/login`) : un pod inutile au lieu d'un refus net. La garde `is_binary` distingue « creds lisible mais
  # sans token » (gate scope/plan peut passer) de « token présent » — divergence légitime, MÊME parse.
  defp read_oauth_access_token(claude_dir) do
    case read_oauth_creds(claude_dir) do
      {:ok, %{"accessToken" => token}} when is_binary(token) ->
        {:ok, token}

      other ->
        # Hygiène creds (F117/F118/F119) : on ne logge JAMAIS le contenu OAuth (refreshToken/accessToken) —
        # la cause de `read_oauth_creds/1` est déjà catégorisée, on ne réinspecte que la catégorie.
        detail =
          case other do
            {:ok, _oauth} ->
              "creds lisible mais accessToken absent ou non-binaire"

            {:error, {:credentials_invalid, {:credentials_unreadable, _p, cause}}} ->
              "creds illisible (#{inspect(cause)})"

            _ ->
              "creds illisible"
          end

        Logger.error(
          "pod auth_mode=:token_arg : read_oauth_access_token ÉCHEC (#{detail}) — " <>
            "claude_dir=#{claude_dir} — spawn BLOQUÉ (R15 fail-loud)"
        )

        {:error, {:oauth_token_unreadable, Path.join(claude_dir, ".credentials.json")}}
    end
  end

  # Z2 gates 2&3 — porte credentials au spawn-boundary (CRED-D1 / F-AC-VALIDATE).
  # Defense-in-depth : tourne dans les 2 auth_mode, APRÈS maybe_put_auth_token (préserve
  # le fail-loud R15 en :token_arg — un token absent échoue d'abord là). Lit le claudeDir
  # de l'humain UNE fois → valide scope-coverage (ScopeValidator, par-rôle via flags) +
  # plan payant (PlanValidator). Le binaire claude impose déjà scope+plan (401) ; ces
  # gates font échouer TÔT au lieu du 1ᵉʳ appel API du pod. Erreurs taguées
  # `{:credentials_invalid, _}` pour les distinguer de l'auth-token au call-site.
  defp gate_credentials(human, cap_profile) do
    with {:ok, oauth} <- read_oauth_creds(claude_dir_for(human)),
         :ok <- gate_scopes(oauth, cap_profile),
         :ok <- gate_plan(oauth) do
      :ok
    end
  end

  # SOURCE UNIQUE de lecture du creds natif `<claude_dir>/.credentials.json` (F117/F118/F119) : un seul
  # File.read + Jason.decode + extraction du bloc `claudeAiOauth`. `read_oauth_access_token/1` (token) ET
  # `gate_credentials/2` (scope+plan) consomment CE parse — plus de 2 parsers driftables du même fichier.
  defp read_oauth_creds(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw) do
      {:ok, oauth}
    else
      # Hygiène creds (F117/F118/F119) : la cause est CATÉGORISÉE, jamais le JSON décodé (qui porte
      # refreshToken/accessToken). `:malformed_json` (Jason) / `:no_oauth_block` (décodé sans bloc oauth
      # valide) / posix (File.read) — tous sûrs à propager et logger.
      {:error, %Jason.DecodeError{}} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :malformed_json}}}

      {:ok, _decoded} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :no_oauth_block}}}

      {:error, posix} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, posix}}}
    end
  end

  # ScopeValidator par-rôle : les scopes requis dépendent des flags du cap-profile
  # (bridge_enabled→user:profile, mcp_oauth→user:mcp_servers ; défaut = inference+sessions).
  defp gate_scopes(oauth, cap_profile) do
    scopes =
      case Map.get(oauth, "scopes") do
        l when is_list(l) -> l
        # certains formats portent les scopes en string whitespace-séparée (cf. ScopeValidator)
        s when is_binary(s) -> String.split(s)
        _ -> []
      end

    case Fleet.Credentials.ScopeValidator.validate(scopes, role_profile_flags(cap_profile)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:credentials_invalid, reason}}
    end
  end

  defp gate_plan(oauth) do
    case Map.get(oauth, "subscriptionType") do
      type when is_binary(type) ->
        case Fleet.Credentials.PlanValidator.validate(type) do
          :ok -> :ok
          {:error, reason} -> {:error, {:credentials_invalid, reason}}
        end

      _ ->
        {:error, {:credentials_invalid, :subscription_type_missing}}
    end
  end

  defp role_profile_flags(%Fleet.CapProfile{spec: spec}) do
    inv = Map.get(spec, "invocation", %{})
    inv = if is_map(inv), do: inv, else: %{}

    %{
      "bridge_enabled" => Map.get(inv, "bridge_enabled", false) == true,
      "mcp_oauth" => Map.get(inv, "mcp_oauth", false) == true
    }
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
  # Z4 (forge-identité B') — l'identité git du pod = l'HUMAIN du mandat (author ET committer ;
  # le pod commite EN TANT QUE l'humain qui le run), résolue via le catalogue
  # (`Fleet.Credentials.ForgeIdentity`). Remplace l'ancien DÉFAUT COOPÉRATIF role-based de
  # `bwrap_launch.sh` (GIT_AUTHOR=LCARS-$ROLE) : le rôle ne signe plus l'identité — il passe en
  # trailer `Co-authored-by` (A.2). bwrap_launch.sh forward ces GIT_AUTHOR_*/GIT_COMMITTER_*.
  # Catalogue absent → fail-loud {:forge_identity_unresolved,_} (pas de pod sans identité
  # vérifiable au push — la garantie reste côté MONDE, gate F-01 `allowed_emails=[humain]`).
  defp maybe_put_git_identity(env, human, role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role, human: human) do
      {:ok, id} ->
        {:ok,
         env
         |> Map.put("GIT_AUTHOR_NAME", id.author_name)
         |> Map.put("GIT_AUTHOR_EMAIL", id.author_email)
         |> Map.put("GIT_COMMITTER_NAME", id.committer_name)
         |> Map.put("GIT_COMMITTER_EMAIL", id.committer_email)}

      {:error, reason} ->
        {:error, {:forge_identity_unresolved, reason}}
    end
  end

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

  # Binaire vendor posé en LCARS_VENDOR_BIN (honore bwrap_launch.sh:55) = `~/.local/bin/claude` de
  # l'HUMAIN (= l'user runtime), résolu via son home passwd. PLUS de fallback `lcars` : le pod EST
  # l'humain, c'est SON binaire. Introuvable → fail-loud (sinon bwrap retombe sur `command -v claude`
  # = binaire système périmé, outil Monitor absent — piège #4).
  defp maybe_put_vendor_bin(env, human) do
    case claude_bin_in_home(human) do
      bin when is_binary(bin) ->
        Map.put(env, "LCARS_VENDOR_BIN", bin)

      nil ->
        raise "vendor: binaire claude introuvable dans ~/.local/bin de #{inspect(human)} (fail-loud)"
    end
  end

  # cwd du pod = la branche CODE (`<pod_dir>/workspace`) quand un projet est cloné — l'agent démarre
  # DANS son code, pas dans le pod_dir nu (mundo invocado : « sa branche code »). La branche DOC est à
  # côté (`<pod_dir>/work`). bwrap_launch lit `LCARS_POD_CWD` (défaut `$POD_DIR`). Pas de projet → cwd
  # = pod_dir (pods permanents/memory-X sans repo).
  defp maybe_put_pod_cwd(env, state) do
    case effective_project(state)["repo_path"] do
      nil -> env
      # F121 : dérive le workspace via l'autorité unique (Fleet.Spawner), pas un littéral recopié.
      _ -> Map.put(env, "LCARS_POD_CWD", Fleet.Spawner.pod_workspace_path(state.pod_dir))
    end
  end

  # Cherche `~/.local/bin/claude` dans le home passwd de `user`. Retourne le path réel
  # (readlink -f) ou `nil`. Le home vient de `getent passwd` (NSS), pas d'un `/home/<x>` deviné.
  defp claude_bin_in_home(user) when is_binary(user) do
    with {:ok, home} <- passwd_home(user),
         link = Path.join([home, ".local", "bin", "claude"]),
         true <- File.exists?(link) do
      case System.cmd("readlink", ["-f", link], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> link
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp claude_bin_in_home(_), do: nil

  # Home de `user` via `getent passwd` (champ 6, 0-indexé 5). `{:ok, home}` | `:error`.
  defp passwd_home(user) do
    case System.cmd("getent", ["passwd", user], stderr_to_stdout: true) do
      {line, 0} ->
        case String.split(String.trim(line), ":") do
          fields when length(fields) >= 6 -> {:ok, Enum.at(fields, 5)}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp do_launch(state) do
    # BL-036 (dogfood F7) : un crash du Pod GenServer ne tue PAS le bwrap/tmux/claude (`--die-with-parent`
    # = BEAM, pas GenServer) → pod ORPHELIN vivant (OAuth+RAM). Avant tout (re)launch, on REAP un éventuel
    # orphelin du même pod_id : no-op pour un pod neuf ; sur recovery (:recreate, BL-035) ça nettoie le
    # mort-vivant AVANT de relancer (sinon collision sock/process). Rend la recovery viable en prod
    # (le probe F7 le faisait à la main). Reaper périodique (orphelins jamais re-spawnés) = reste BL-036b.
    reap_orphan_pod(state.pod_id)
    role = cap_profile_name(state.cap_profile)
    containment = cap_profile_containment(state.cap_profile)

    # LAUNCH-Q : le launcher N0 dépend du containment, lu ICI (avant ce fix : bwrap aveugle pour tous).
    # "none" (host_native : architect, starfleet) → host_launch.sh (host, sans sandbox) ;
    # sinon la chaîne bwrap. `PermanentBoot` reste générique — la branche vit sur le chemin de lancement.
    launcher_path = if containment == "none", do: host_launch_path(), else: bwrap_launch_path()

    # R0.8-brick4 : plus de budget côté pod (OAuth pool, pas d'API). Le timeout
    # de réponse est géré par `monitor_timeout_ms/1` côté Pod GenServer
    # (Process.send_after :result_deadline). Les backends qui n'ont pas
    # leur propre script de lancement (StubBackend) n'ont pas
    # besoin de la valeur ; LauncherPortBackend (legacy bwrap+print) recevait
    # `budget_sec`/`budget_usd` comme args du script — ces clés sont retirées
    # de l'API LaunchBackend (cf. behaviour `Fleet.Spawner.LaunchBackend`).
    args = %{
      role: role,
      pod_id: state.pod_id,
      pod_dir: state.pod_dir,
      # LAUNCH-Q : launcher N0 sélectionné par containment (host_launch.sh | bwrap_launch.sh). L'exe du
      # Port (build_spawn) ; l'argv reste identique des deux côtés (même contrat <role> <pod_id> <pod_dir>
      # <command...>). Le command opaque (claude_launch.sh …) est claude_launch_path ci-dessous.
      launcher_path: launcher_path,
      claude_launch_path: claude_launch_path(),
      # SP plus dans l'argv (fuite /proc/cmdline + frôle ARG_MAX) : claude_launch lit
      # pod_dir/.lcars/system-prompt.md via --system-prompt-file (écrit en do_project). C'est la SOURCE.
      session_id: state.session_id
    }

    # F120 : la résolution humain + le pipeline env peuvent RAISE (runtime_user /
    # claude_dir_from_passwd / maybe_put_vendor_bin = fail-loud sur host sans claude
    # per-user ou home irrésoluble). Un raise ICI crashait le Pod GenServer SANS
    # transition_failed → task orphaned :pending + state.json à la phase périmée. On
    # rabat tout raise de construction-env sur transition_failed (même cleanup que les
    # autres échecs launch : clear_pod_task + phase=failed).
    launch_env =
      try do
        human = Keyword.get(state.opts, :human) || runtime_user()

        env =
          state.env_vars
          |> Map.merge(skills_plugins_env(state.cap_profile))
          |> Map.merge(mcp_channel_env(state.pod_id, cap_profile_name(state.cap_profile)))
          # HOME — LAUNCH-Q : dépend du containment.
          #   bwrap (défaut) : HOME=pod_dir (U4 — cohérent ; bwrap fait `--setenv HOME` de toute façon,
          #     cette valeur est ignorée sous le sandbox).
          #   none (host)    : HOME = home RÉEL de l'humain → claude lit son `~/.claude` natif. C'est l'auth
          #     `:bind` réalisée NATIVEMENT sur l'hôte (refresh OAuth, full scope, pas de falaise 8h — l'arch
          #     est un pod forever). host_launch.sh ne re-setenv PAS (pas de namespace) : ce HOME EST l'env réel.
          |> Map.put("HOME", launch_home(containment, human, state.pod_dir))
          # Chaîne de session (DN spawner-orchestrator §D) : bwrap_launch les `--setenv` dans le pod,
          # claude_launch les lit `:?` strict (no-boot sinon). PRÉFIXE nom RC = <human>_<role>.
          |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
          |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", "#{human}_#{role}")
          # Base sock tmux : bwrap_launch crée la socket sous <base>/<pod_id>/, PodTmux (host) y tape.
          # MÊME valeur des deux côtés ⇒ le sock calculé coïncide. (Défaut /run/lcars/tmux-sock partagé.)
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # Le pod est celui de l'HUMAIN : creds ET binaire vendor suivent /home/<human> (même règle que
          # pod_dir). Quel binaire = robuste ici (depuis ~/.local/bin, pas le pari `command -v`). Le pod
          # tourne SOUS l'UID de l'humain PAR CONSTRUCTION : le daemon tourne *as* l'humain (unit
          # `User=<humain>`, doctrine 2026-06-11 — chaque humain = SA fleet sous son user), le pod = Port
          # BEAM hérite cet UID → ownership/perms/isolation OS gratis, PAS de systemd-run --uid. (Seul
          # starfleet a un user dédié, hors-fleet.)
          |> Map.put("CLAUDE_DIR", claude_dir_for(human))
          |> maybe_put_vendor_bin(human)
          |> maybe_put_pod_cwd(state)

        {:ok, human, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    # R15 : l'étape auth sort du pipe — en mode :token_arg un token absent bloque le
    # spawn (fail-loud) au lieu de lancer un pod sans token. Z2 : la porte credentials
    # (scope/plan) suit, taguée {:credentials_invalid, _} pour un refus distinct de l'auth.
    case launch_env do
      {:ok, human, env} ->
        with {:ok, env} <- maybe_put_auth_token(env, human),
             {:ok, env} <- maybe_put_git_identity(env, human, role),
             :ok <- gate_credentials(human, state.cap_profile) do
          do_launch_backend(state, args, env)
        else
          {:error, {:credentials_invalid, _} = reason} -> transition_failed(state, reason)
          {:error, reason} -> transition_failed(state, {:auth_token_required, reason})
        end

      {:error, reason} ->
        transition_failed(state, reason)
    end
  end

  # BL-036 : reap un orphelin (bwrap/tmux/claude survivant à un crash GenServer) du même pod_id avant
  # un (re)launch. Ne fait RIEN si aucun orphelin vivant (cas pod neuf). tmux kill-server tue tmux+claude ;
  # pkill -f <pod_id> tue le holder (bwrap OU host_launch — l'invocation porte le pod_id en argv ; que
  # kill-server laisse vivant). pod_id = UUID unique → ciblé.
  defp reap_orphan_pod(pod_id) do
    if Fleet.Spawner.PodTmux.alive?(pod_id) do
      Logger.warning("pod #{pod_id} : orphelin vivant détecté avant launch (BL-036) — reap")
      sock = Fleet.Spawner.PodTmux.sock_path(pod_id)
      _ = System.cmd("tmux", ["-S", sock, "kill-server"], stderr_to_stdout: true)
      _ = System.cmd("pkill", ["-9", "-f", pod_id], stderr_to_stdout: true)
    end

    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} reap_orphan échec (non-bloquant): #{inspect(e)}")
      :ok
  end

  defp do_launch_backend(state, args, env) do
    case launch_backend().launch(args, env) do
      {:ok, %{init_message: init_msg, ndjson_log: ndjson_log} = launched} ->
        # #593 D11 — extract port (LauncherPortBackend l'inclut, StubBackend non).
        # nil-able : tests stub n'ont pas de Port → handle_info clauses
        # ne matchent jamais → comportement legacy préservé.
        port = Map.get(launched, :port)

        # tmux_session posé par LauncherPortBackend (les deux launchers N0 bwrap/host) ; nil pour StubBackend.
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
        # Path actuel : PodTmux send-keys sur le sock par-pod (universel, bwrap ET host).
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
    new_state = arm_result_deadline(%{state | phase: :monitoring})
    {:noreply, new_state}
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
        # Z1 #15 : reset :output_extracted au re-monitoring (sinon un crash REPL au
        # cycle 2 est masqué en {:stop,:normal} via la garde l.230 → pod.failed/clear
        # jamais émis). Z1 #16 : arm_result_deadline annule le timer du cycle précédent
        # avant de ré-armer (pas d'accumulation). Bus.subscribe pas re-appelé : déjà
        # subscribed depuis do_monitor au 1er cycle.
        new_state =
          new_state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)
          |> arm_result_deadline()

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
      {nil, _} ->
        # Pod stage-dispatch (assignee-driven, DN forge-state-machine) hors pipeline.
        # S'il porte un PROJET (repo cloné), le payload embarque le contexte de
        # fin-de-hop : le consumer `Fleet.Pilot.HopConsumer` est stateless (l'event
        # porte l'état, pas de query `pod_info` racy). workspace+base_sha+role
        # suffisent au `Deliverable.publish` côté système. Pod sans projet
        # (memory-X, architect) → payload nu (base), filtré en aval.
        case effective_project(state) do
          %{"repo_path" => rp} = proj when is_binary(rp) and rp != "" ->
            base
            |> Map.merge(%{
              # F121 : autorité unique du sous-dossier workspace (Fleet.Spawner), pas un littéral recopié.
              "workspace" => Fleet.Spawner.pod_workspace_path(state.pod_dir),
              "base_sha" => proj["base_sha"],
              "role" => cap_profile_name(state.cap_profile)
            })
            |> maybe_put_carte_ctx(opts)

          _ ->
            base
        end

      {pipeline_id, stage} ->
        Map.merge(base, %{"pipeline_id" => pipeline_id, "stage" => stage})
    end
  end

  # A2.1 : contexte carte (pipeline+stage) injecté au spawn par StageDispatcher via `:pipeline`/
  # `:stage` (≠ `:pipeline_id` du chemin pipeline legacy). Permet au HopConsumer de naviguer la
  # carte (CarteNav.next_stage). Absent (1-stage A1) → payload inchangé.
  defp maybe_put_carte_ctx(payload, opts) do
    case {Keyword.get(opts, :pipeline), Keyword.get(opts, :stage)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        Map.merge(payload, %{"pipeline" => p, "stage" => s})

      _ ->
        payload
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

  # Teardown du backend du pod. Port vivant → Port.close (le SIGTERM du holder bwrap fait tomber
  # namespace+tmux+claude). Port déjà mort mais session bwrap/tmux/claude survivante → kill
  # SOCK-AWARE (F124).
  defp teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        # F124 : la session du pod bwrap (`lcars-pod-<id>`) vit sur le sock PAR-POD (PodTmux), PAS
        # le serveur tmux par défaut. L'ancien `TmuxBackend.kill_session` ciblait le défaut → no-op
        # silencieux → le claude sandboxé continuait à consommer l'OAuth. On kill via le sock par-pod
        # (même geste que reap_orphan_pod) : kill-server tue tmux+claude, pkill tue le holder (bwrap ou host).
        sock = Fleet.Spawner.PodTmux.sock_path(state.pod_id)
        _ = System.cmd("tmux", ["-S", sock, "kill-server"], stderr_to_stdout: true)
        _ = System.cmd("pkill", ["-9", "-f", state.pod_id], stderr_to_stdout: true)
        :ok

      true ->
        :ok
    end
  end

  @doc """
  Tue le pod (chaîne bwrap OU host — geste générique). Le holder (`sleep infinity`) IGNORE l'EOF stdin →
  `Port.close` seul l'ORPHELINE (pod survit — PROVEN e2e Elixir 2026-06-01). On SIGTERM le process holder
  par son os_pid :
  - **bwrap** : bwrap propage au holder → PID1 exit → namespace + serveur tmux + claude tombent ensemble
    (`--die-with-parent` = filet si le BEAM meurt avant d'arriver ici).
  - **host** (LAUNCH-Q) : pas de namespace → le holder `host_launch.sh` trap le SIGTERM → `tmux
    kill-server` explicite sur le sock par-pod (teardown self-contained ; cf. `bin/host_launch.sh`).
  Port.close ensuite (libère le port BEAM). Public pour test direct du fix.
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

  # BL-035 (dogfood F7, 2026-06-07) : défaut basculé à FALSE. F-C4b-1 n'est plus une crainte — c'est
  # PROUVÉ live : recovery `:resume` relance claude `--resume <session-MORTE>` → claude exit → pod
  # ZOMBIE (Elixir croit :monitoring, REPL mort, OAuth consommé). Un crash = la session claude n'existe
  # plus serveur-side, `--resume` est voué à l'échec. `:recreate` (session neuve) relance un REPL VIVANT
  # et la tâche (toujours en queue) re-drive le travail. Le gate reste un opt-in (`true`) si un jour
  # `--resume` est prouvé ressusciter une session serveur-side (douteux).
  defp resume_enabled?, do: Application.get_env(:fleet_spawner, :recovery_resume_enabled, false)

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
      # SP composé (do_project) stocké en state pour l'argv4 inline de claude_launch
      # (--system-prompt) ; pas de fichier SP côté pod (.lcars/system-prompt.md = miroir lisible).
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
      tmux_session: nil,
      # Z1 — ref du timer :result_deadline (timeout de RÉPONSE). nil = non armé.
      # Armé seulement pour les scopes bornés (pas `forever`), annulé à l'arrivée du
      # résultat / avant ré-arme. Cf. arm_result_deadline/1.
      result_deadline_ref: nil
    }
  end

  defp pod_dir_for(pod_id, _cap_profile, opts) do
    # Le pod vit SOUS LE HOME DE L'HUMAIN (= l'user runtime) : `~/pods/pod_<id>`, 0700, isolé OS
    # gratis (le pod hérite de l'UID du runtime). Le home ENCODE déjà l'humain (pas de `/home/<human>`
    # construit). `:pod_dir_root` (opts ou config) = override tests/déploiement non-standard ; non-set
    # ⇒ home du runtime. `pod_<id>` = nom stable (pod_id = clé de recovery, stable pour --resume).
    base =
      Keyword.get(opts, :pod_dir_root) ||
        Application.get_env(:fleet_spawner, :pod_dir_root) ||
        Path.join(runtime_home(), "pods")

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

  # F122 : accesseur UNIQUE du rôle (= metadata.name). Avant, 3 sites inlinaient
  # `Map.get(metadata, "name", "engineer")` (launch/payload/brief) tandis que la persistance
  # state.json passait par ici (défaut "unknown") → un profil SANS metadata.name se lançait
  # "engineer" mais persistait "unknown" (mésattribution silencieuse tout le hop). Tous unifiés ici.
  defp cap_profile_name(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "name") || Map.get(meta, :name) || "unknown"
  end

  defp cap_profile_name(_), do: "unknown"

  # LAUNCH-Q : `metadata.containment` ∈ {"bwrap","none"} (cap_profile G24-1, défaut conservateur "bwrap").
  # "none" = host_native (architect, starfleet) → host_launch.sh (PAS de sandbox) ; sinon la
  # chaîne bwrap. Lu ICI, sur le chemin de lancement — avant ce fix `do_launch` bwrappait tout aveuglément.
  defp cap_profile_containment(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "containment") || Map.get(meta, :containment) || "bwrap"
  end

  defp cap_profile_containment(_), do: "bwrap"

  # LAUNCH-Q : HOME du pod selon containment. host (none) = home réel de l'humain (claude → `~/.claude`
  # natif, refresh OAuth) ; bwrap = pod_dir (ignoré sous le sandbox de toute façon). `claude_dir_for/1`
  # honore l'override config `:claude_dir` (tests) et fail-loud si le passwd de l'humain est introuvable.
  # NB mono-humain : si `:claude_dir` est overridé (path GLOBAL, non lié à `human`), `Path.dirname` rend
  # son parent pour TOUT pod host. OK en prod mono-humain (1 daemon = 1 humain, unit `User=<humain>`) ;
  # TODO multi-humain : dériver le home par-humain via `passwd_home/1` quand l'override n'est pas posé.
  defp launch_home("none", human, _pod_dir), do: Path.dirname(claude_dir_for(human))
  defp launch_home(_containment, _human, pod_dir), do: pod_dir

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

  # Z1 #15 : retire une condition. `:output_extracted` DOIT être reset au re-monitoring
  # d'un pod long-lived (do_extract _other) — sinon un crash REPL au cycle 2 reste masqué
  # en {:stop, :normal} (la garde l.230 reste vraie) → pod.failed/clear jamais émis.
  defp remove_condition(state, condition) do
    Map.update!(state, :conditions, &MapSet.delete(&1, condition))
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

  # Z1 — gestion du timer :result_deadline (timeout de RÉPONSE).
  #
  # arm : annule TOUJOURS le timer précédent (pas d'accumulation #16, pas de stale-kill
  # #3) puis arme un nouveau — SAUF pour un pod `forever` (permanent : gatekeeper/
  # architect/monk) qui ne porte PAS de timeout de réponse (idle = normal, slow-task =
  # légitime ; gouverné par kill_pod externe). Stocke la ref dans l'état.
  defp arm_result_deadline(state) do
    state = cancel_result_deadline(state)

    if lifetime_scope(state.cap_profile) == "forever" do
      state
    else
      ref = Process.send_after(self(), :result_deadline, monitor_timeout_ms(state))
      Map.put(state, :result_deadline_ref, ref)
    end
  end

  defp cancel_result_deadline(state) do
    case Map.get(state, :result_deadline_ref) do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    Map.put(state, :result_deadline_ref, nil)
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

    # F126 : `Process.send_after` exige un entier non-négatif. `is_number(override)` accepte les
    # FLOATS (un cap-profile `timeouts.response_sec: 1.5` passe la validation) → `sec * 1000` = float
    # → ArgumentError dans arm_result_deadline qui CRASHE le Pod sans transition_failed. `round/1`
    # coerce → entier (ms), quel que soit l'override.
    round(sec * 1000)
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    # Z1 (2026-06-09) — band-aid `forever -> 60_000` (≈16.6h) REVERTÉ. Le vrai fix est
    # appliqué : arm_result_deadline n'arme PAS pour `forever` (un permanent n'a pas de
    # timeout de réponse), et le fire ne tue que si une task est réellement active. La
    # valeur `forever` ci-dessous est donc inerte (forever n'arme jamais) ; conservée
    # par cohérence si un override `spec.timeouts.response_sec` la réactivait un jour.
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
    # F128 : interpoler le RÔLE résolu, ne pas hardcoder "engineer". Un gatekeeper (juge) sans
    # mandat explicite ne doit PAS être amorcé "worker engineer" (priming I-CBC PASSE-9). Cadre
    # neutre "pod LCARS (rôle X)" — le mandat (GateBrief pour le juge) porte la persona réelle.
    role = cap_profile_name(state.cap_profile)

    body =
      if is_binary(mandate) and mandate != "" do
        mandate
      else
        "(Pas de mandat fourni — ticket #{state.ticket_id}.)"
      end

    """
    Salut. Tu es un pod LCARS (rôle #{role}, pod #{state.pod_id}) ; cette session
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

  # LAUNCH-Q : launcher N0 host (containment: none) — frère sans-sandbox de bwrap_launch, même argv-shape.
  defp host_launch_path do
    Application.get_env(:fleet_spawner, :host_launch_path, "/usr/local/bin/host_launch.sh")
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
  # `LCARS_ROLE` (= `metadata.name` du cap-profile = rôle métier) : bridge.py l'injecte en
  # `_lcars_role` → le central résout le compte/token de rôle (create_ticket poste l'issue EN SON NOM).
  # Posé ICI (env du process pod) → couvre host_launch ET bwrap (qui le re-`--setenv` dans son sandbox).
  #
  # BL-021 chantier 7 — purge ADR-G C5.1 : `LCARS_FLEET_MCP_CHANNEL_URL` retiré
  # (push channel ChannelHTTP supprimé, drive via tools pull `get_task`).
  defp mcp_channel_env(pod_id, role) when is_binary(pod_id) do
    base = %{"LCARS_POD_ID" => pod_id}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  # Kick AUTONOME « yop » readiness-gated (R3b / F-C4b-2). Déclenche le pull du mandat
  # par MCP get_task — le mandat n'est PAS injecté (il vit dans tickets/ + TaskQueue).
  # No-op si pas de tmux_session (StubBackend ; LauncherPortBackend en pose un, bwrap ou host).
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

  # Bootstrap (pod sans mandat) : kicks BORNÉS + ESPACÉS — ~4 tentatives à 8s d'intervalle
  # couvrent le boot claude (~15s) sans rafale. Le réveil-par-flag (Monitor) prend le relais ensuite.
  defp kick_bootstrap_max, do: Application.get_env(:fleet_spawner, :kick_bootstrap_max, 4)

  defp kick_bootstrap_retry_ms,
    do: Application.get_env(:fleet_spawner, :kick_bootstrap_retry_ms, 8_000)

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
  # Z1 — le pod a-t-il une task ACTIVE (pending/assigned/in_progress) là, maintenant ?
  # Utilisé au FIRE de :result_deadline : oui = vrai timeout de réponse (kill) ; non =
  # le pod attendait juste sa prochaine task (idle), on laisse lapser. Même source que
  # mandate_pulled?/no_pending_mandate? (TaskQueue.pod_status), même garde rescue/catch
  # (TaskQueue indisponible ⇒ pas de task active connue ⇒ pas de kill, fail-safe).
  defp pod_has_active_task?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, s} when s in [:pending, :assigned, :in_progress] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

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

  # AUCUN mandat (task) en attente pour ce pod : `pod_status == {:ok, nil}` (jamais enqueué).
  # Distingue le pod permanent/interactif (rien à puller à froid → bootstrap) du worker (mandat
  # `pending` enqueué au spawn). En cas d'erreur → `false` (défaut sûr : on traite comme un
  # worker, kick fréquent — on ne suspend pas par erreur les kicks d'un vrai mandat).
  defp no_pending_mandate?(pod_id) do
    case Fleet.TaskQueue.pod_status(pod_id) do
      {:ok, nil} -> true
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
  # Projet EFFECTIF = celui du MANDAT (`opts[:project]`, injecté par le dispatch ticket→repo via
  # `spawn_opts`) sinon le cap_profile statique (pods permanents sur un repo fixe). Rend la feature
  # pod-projet utilisable : un engineer dispatché sur un ticket reçoit LE repo du ticket, pas un projet
  # figé au catalogue. `%{}` si ni l'un ni l'autre (pods sans projet : memory-X, architect).
  defp effective_project(state) do
    Keyword.get(state.opts || [], :project) || get_in(state.cap_profile.spec, ["project"]) || %{}
  end

  defp maybe_bootstrap_project_workspace(state) do
    project = effective_project(state)

    case project["repo_path"] do
      nil ->
        :ok

      _repo_path ->
        # cap_profile porteur du projet EFFECTIF (mandat > statique) pour les Clone.* (qui lisent spec.project).
        eff_cap = %{state.cap_profile | spec: Map.put(state.cap_profile.spec, "project", project)}

        with {:ok, workspace, branch} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_or_skip(
                 state.pod_dir,
                 eff_cap,
                 []
               ),
             # Doc-mount (mundo invocado) : la branche `work/ops` (plans/backlog/conventions) à côté
             # du code. nil si le projet n'a pas de branche doc ; fail-loud si déclarée mais absente.
             {:ok, doc} <-
               Fleet.ProjectBootstrap.Phase.Clone.clone_work_doc(
                 state.pod_dir,
                 eff_cap
               ) do
          # CLAUDE.md composé (pod-identité + conventions repo) à la racine du CWD (workspace) :
          # l'agent pop dans un projet déjà documenté. Le do_project l'écrit au pod_dir (parent) ;
          # avec cwd=workspace il doit être DANS le cwd (sinon l'agent code sans sa codebase-doc en cwd).
          _ = File.cp(Path.join(state.pod_dir, "CLAUDE.md"), Path.join(workspace, "CLAUDE.md"))

          # Identité git du rôle : O5 — plus de `git config` mutable dans le workspace (F-01
          # falsifiable, le pod l'écrasait). L'identité est injectée en env IMMUABLE-par-défaut au
          # lancement (bwrap_launch.sh : GIT_AUTHOR_*/GIT_COMMITTER_* = LCARS-<role> + GIT_CONFIG_GLOBAL
          # /dev/null). La garantie F-01 vit côté monde : la gate DeliverableGate rejette au push tout
          # commit hors identité autorisée. Voir JOURNAL-deliverable-model-2026-06-07 (Brick 5).

          Logger.info(
            "pod #{state.pod_id} workspace=#{workspace} (branch=#{branch || "default"})" <>
              if(doc, do: " doc=#{doc}", else: " (pas de branche doc)")
          )

          :ok
        else
          {:error, reason} -> {:error, {:project_workspace_clone_failed, reason}}
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
        # Vulcan #5 : non-bang + retour {:ok|:error} propagé au with chain
        # do_project (où l'erreur déclenche transition_failed proprement).
        with {:ok, fleet_entry} <- build_fleet_mcp_entry(spec, state) do
          config = %{"mcpServers" => %{"fleet" => fleet_entry}}

          safe_write(
            Path.join(state.pod_dir, ".mcp-fleet.json"),
            Jason.encode!(config, pretty: true)
          )
        end
    end
  end

  # Construit l'entrée serveur MCP `fleet` du `.mcp-fleet.json`, en provisionnant
  # le bridge stdio DANS le pod_dir.
  #
  # PASSE-9 root-cause (2026-06-08) : le bwrap est un SANCTUAIRE — il ne monte que
  # `/usr`, `/etc`, `/sys`, `$POD_DIR`, `$GIT_MIRROR`, le vendor et le sock-dir.
  # `/var/lib/lcars` n'y est PAS monté. Or l'ancienne spec lançait le bridge via
  # son chemin HÔTE (`/var/lib/lcars/bin/...py`) avec un log sous `/var/lib/lcars/`
  # → DANS le sandbox ce chemin n'existe pas → `bash -c` échoue → le serveur MCP
  # `fleet` ne démarre jamais → le tool `mcp__fleet__get_task` n'est jamais chargé
  # → l'agent improvise du curl et timeout. Le bridge marchait en test direct car
  # il tournait sur l'HÔTE, pas dans le sandbox.
  #
  # Fix (couche N1, le provisioning) : `bwrap_launch.sh` reste MCP-agnostique (N0).
  # On copie le bridge sous `pod_dir/.lcars/` (pod_dir est bind RW AU MÊME chemin
  # absolu hôte+sandbox via `--bind "$POD_DIR" "$POD_DIR"`) et on résout les
  # placeholders `{{BRIDGE}}`/`{{BRIDGE_LOG}}` de la spec sur ces chemins pod-locaux.
  # Le monde MCP (config + bridge + log) est ainsi entièrement projeté dans le pod.
  #
  # Injecte aussi `LCARS_POD_ID` dans l'env du serveur (ceinture A2.3b PASSE-7 : le
  # bridge l.37 le lit pour corréler `get_task` au bon pod ; ne pas dépendre de
  # l'héritage env claude→bridge) et force `alwaysLoad:true` (sinon les tools MCP
  # sont déférés derrière ToolSearch, absents du prompt turn-1).
  defp build_fleet_mcp_entry(spec, state) do
    pod_bridge = Path.join([state.pod_dir, ".lcars", "fleet_mcp_bridge.py"])
    pod_log = Path.join([state.pod_dir, ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], pod_bridge) do
      args =
        (spec["args"] || [])
        |> Enum.map(fn arg ->
          arg
          |> String.replace("{{BRIDGE}}", pod_bridge)
          |> String.replace("{{BRIDGE_LOG}}", pod_log)
        end)

      entry =
        spec
        |> Map.drop(["bridge_source"])
        |> Map.put("args", args)
        |> Map.put("alwaysLoad", true)
        |> Map.update(
          "env",
          %{"LCARS_POD_ID" => state.pod_id},
          &Map.put(&1, "LCARS_POD_ID", state.pod_id)
        )

      {:ok, entry}
    end
  end

  # nil = spec sans bridge à projeter (stub/legacy : la spec porte alors un
  # `command`/`args` déjà autonome, pas de placeholder à résoudre).
  defp copy_bridge_into_pod(nil, _dest), do: :ok

  defp copy_bridge_into_pod(source, dest) when is_binary(source) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _bytes} <- File.copy(source, dest),
         :ok <- File.chmod(dest, 0o755) do
      :ok
    else
      {:error, reason} -> {:error, {:mcp_bridge_provision_failed, source, reason}}
    end
  end

  # Provisionne le monitor in-pod (`watch.sh`) dans le pod_dir (= HOME bwrap). L'agent
  # l'arme via l'outil natif `Monitor` (cf. SP `agent-worker-base.md`) → réveil-par-flag
  # (`turn.flag` touché par la fleet), zéro send-keys de CONTENU (ADR-G pt3 : send-keys =
  # kick `yop` + slash uniquement). L'asset vit en `priv/` (résolu app_dir, comme le SP
  # draft). chmod best-effort : l'agent lance `bash ~/watch.sh`, le bit exec n'est pas requis.
  defp provision_monitor_watch(state) do
    src = Application.app_dir(:fleet_spawner, "priv/watch.sh")
    dst = Path.join(state.pod_dir, "watch.sh")

    case File.read(src) do
      {:ok, content} ->
        with :ok <- safe_write(dst, content) do
          _ = File.chmod(dst, 0o755)
          :ok
        end

      {:error, reason} ->
        {:error, {:watch_asset_unreadable, reason}}
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
