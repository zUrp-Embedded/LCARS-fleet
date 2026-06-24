defmodule Fleet.Spawner.Pod do
  @moduledoc """
  GenServer state machine du cycle 8 phases ALLOCATE → RELEASE pour un pod.

  ## Phases

      :pending → :allocating → :cleaning → :projecting → :injecting →
      :launching → :monitoring → :extracting → :releasing → :succeeded
                                                          ↓
                                                        :failed

  Chaque transition est dirigée par `handle_continue/2`. L'`init/1`
  démarre la chaîne avec `{:continue, :allocate}`. Si la recovery sur l'état
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
  (le `session_id` est pré-alloué au spawn : plus de frame `init` NDJSON,
  le modèle `-p` est mort). `<scope>` ∈ `pods` (one-shot/forever) /
  `pipes` (pipe) / `runs` (run). Au prochain `init/1`, lecture du fichier →
  reprise directe en phase `:launching` avec le `session_id`
  (`--resume <session_id>` au respawn).
  """

  # Tous les pods sont `:temporary` (le supervisor ne ressuscite jamais ; la
  # recovery est délibérée). NB : `pod_child_spec/1` (spawner.ex) construit
  # le child_spec explicite et fixe lui aussi `restart: :temporary` — c'est lui
  # qui fait foi au spawn ; cette valeur de module reste alignée par honnêteté.
  use GenServer, restart: :temporary

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.SPBuilder

  # Complétion event-driven : le résultat arrive via l'event Bus
  # `task_queue.task_completed` (%Fleet.Event{}, émis par le central sur submit_result), PAS via un fichier.

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
          # Secret aléatoire par-pod, généré au spawn. C'est la PREUVE D'IDENTITÉ du pod auprès
          # du serveur MCP central : non-dérivable du pod_id (qui, lui, est déterministe et devinable),
          # injecté UNIQUEMENT dans l'env de CE pod, et stocké ICI côté serveur (lu par `pod_info/1`).
          # Le central refuse tout tool-call dont la capability présentée ne correspond pas à celle
          # enregistrée pour le pod_id → un pod ne peut plus se faire passer pour un autre en présentant
          # son pod_id deviné. Régénérée à chaque (re)spawn (l'env du pont est ré-écrit au même cycle →
          # toujours cohérente) ; pas dans le snapshot state.json (rien à reprendre, tout est recréé).
          capability: String.t(),
          # `started_at` ISO8601 figé à la création du Pod GenServer, persisté tel
          # quel dans `state.json` (point de recovery).
          started_at: DateTime.t(),
          cap_profile: Fleet.CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          ndjson_log_path: Path.t() | nil,
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          init_message: map() | nil,
          last_error: term() | nil,
          opts: keyword(),
          # Port owné par le Pod (détection exit + kill en RELEASE).
          port: port() | nil,
          # Résultat reçu via l'event Bus task_queue.task_completed (%Fleet.Event{}, complétion).
          submitted_result: map() | nil,
          last_result: map() | nil,
          # Nom de la session tmux du pod (`lcars-pod-<id>` sur le sock PAR-POD, posé par
          # LauncherPortBackend). Sert au kick/wake (PodTmux) et au teardown sock-aware.
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
      # Le RÔLE est gravé au SPAWN (= `metadata.name` du cap-profile, source `cap_profile_name/1`),
      # exposé côté serveur via le Registry. C'est l'identité de rôle AUTHENTIFIÉE (le pod ne peut pas la
      # forger via le wire) : `PodTools` la résout depuis le `pod_id` au lieu du `_lcars_role` du fil
      # (non authentifié → usurpation `architect` par POST direct). Le wire propose, le SPAWN dispose.
      role: cap_profile_name(state.cap_profile),
      # capability : le secret par-pod (généré au spawn). Le serveur MCP central le lit ici (via
      # `Fleet.Spawner.pod_info`) pour VÉRIFIER que le tool-call vient bien de CE pod et pas d'un autre
      # qui aurait deviné son pod_id. C'est le pendant authentifié du pod_id : le wire propose une identité,
      # le central la prouve contre cette capability enregistrée au spawn.
      capability: state.capability,
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
      # Fleet.Spawner.wake_pod/1 (décide trigger+armement vs `:not_a_tmux_pod` ; la boucle send-keys ensuite).
      tmux_session: state.tmux_session
    }

    {:reply, info, state}
  end

  # kill = transition de release DÉLIBÉRÉE, pas un kill brutal du supervisor.
  # Teardown backend + libère la task (abort, pas succès → clear_for_pod) + état
  # terminal `:killed`, puis arrêt :normal. Le fallback brutal (terminate_child)
  # ne sert que si ce call timeout (cf. kill_pod/1).
  def handle_call(:kill, _from, state) do
    # Checkpoint le seed même sur kill délibéré (mémoire préservée).
    maybe_checkpoint_seed(state)
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
  # handle_info — cycle de vie du Port
  # ============================================================
  #
  # LauncherPortBackend.launch ouvre `Port.open` (sous le process Pod) et bloque
  # jusqu'à la 1ʳᵉ frame `init` NDJSON. Après, le Pod reprend la main
  # (handle_continue :monitor → :extract → :release → :succeeded). Le
  # Port n'est PAS fermé : claude continue à streamer (assistant events,
  # result event final, exit_status). Sans clause handle_info, ces
  # messages tombent dans le default → log unexpected message, la state
  # machine ne note JAMAIS la complétion réelle.
  #
  # Format Port options actuelles (LauncherPortBackend) : `:binary`
  # + `:exit_status`, PAS `{:line, _}` ni `{:packet, :line}` → on reçoit
  # `{port, {:data, binary_chunk}}` (multi-events ou partial), buffering
  # + split sur "\n" requis.

  # Complétion event-driven : le broker fleet_task_queue broadcast
  # %Fleet.Event{task_completed} sur fleet.events. On ne réagit qu'au NÔTRE (pod_id) en :monitoring.
  @impl GenServer
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :task_completed, pod_id: pid, payload: payload},
        %{phase: :monitoring, pod_id: pid} = state
      ) do
    result = payload[:result] || payload["result"] || %{}
    # Le résultat est arrivé → annuler le deadline AVANT d'extraire (sinon le timer
    # du cycle courant fire plus tard en :monitoring et tue le pod sain).
    state = cancel_result_deadline(state)
    {:noreply, Map.put(state, :submitted_result, result), {:continue, :extract}}
  end

  # %Fleet.Event{task_completed} d'un autre pod, ou hors phase :monitoring → ignore.
  def handle_info(%Fleet.Event{source: :task_queue, type: :task_completed}, state),
    do: {:noreply, state}

  # Deadline : timeout de RÉPONSE. Au FIRE, on distingue :
  #   - task active (pending/assigned/in_progress) → le pod n'a PAS répondu à temps → échec.
  #   - aucune task active → le pod attendait juste sa prochaine task (idle) ; ce n'est
  #     PAS un timeout de réponse → on laisse lapser, PAS de kill (sinon on re-crée un
  #     idle-kill : tuer un pod sain qui attend du travail). La vérif est à l'instant du
  #     fire (≠ à l'armement) → couvre la race d'enqueue worker ET l'inter-stage pipe d'un coup.
  def handle_info(:result_deadline, %{phase: :monitoring} = state) do
    if pod_has_active_task?(state.pod_id) do
      transition_failed(state, {:result_timeout, state.pod_id})
    else
      {:noreply, Map.put(state, :result_deadline_ref, nil)}
    end
  end

  def handle_info(:result_deadline, state), do: {:noreply, state}

  # Watchdog de LIVENESS (pas de durée). Tick récurrent (workers seulement, armé par
  # arm_result_deadline) : si le pod a BOUGÉ depuis le tick précédent (taille jsonl ↑ OU jiffies CPU ↑)
  # → ré-arme le deadline (repousse le kill) ; sinon → laisse le deadline courir. Résultat : un engineer qui
  # bosse ne timeout JAMAIS ; le `:result_deadline` ne fire que sur silence total. Hors :monitoring → no-op
  # (tick résiduel après transition).
  def handle_info(:liveness_tick, %{phase: :monitoring} = state) do
    sample = liveness_sample(state)
    moved? = liveness_moved?(Map.get(state, :liveness_sample), sample)
    state = Map.put(state, :liveness_sample, sample)

    state =
      if moved?,
        do: arm_result_deadline(state),
        else: schedule_liveness_tick(state)

    {:noreply, state}
  end

  def handle_info(:liveness_tick, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state)
      when is_port(port) do
    # Complétion event-driven : si le résultat a été extrait (event
    # task_queue.task_completed reçu → :output_extracted), l'exit est l'arrêt normal post-release.
    # Sinon le process est mort SANS soumettre de résultat → échec (plus de salvage fichier).
    if MapSet.member?(state.conditions, :output_extracted) do
      {:stop, :normal, state}
    else
      # Process mort SANS résultat soumis → task active orpheline. Libère.
      clear_pod_task(state.pod_id)

      best_effort_broadcast("pod.failed", %{
        "pod_id" => state.pod_id,
        "ticket_id" => state.ticket_id,
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{state.pod_id} exited before submitting result (exit=#{exit_code})")
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, state}
    end
  end

  # Boucle KICK ack-driven UNIFIÉE (bootstrap + wake-fallback, paramétrée : cap/retry/mot-clé/ACK).
  # Tick borné (le pod est en :monitoring). Le contrôle = l'ACK de l'agent (`acked?/3`), JAMAIS un proxy :
  #   - ACK (pull pour un wake / poll pour un bootstrap) → stop + cancel timer ;
  #   - cap sans ACK → broadcast `wake.failed` (escalade ring-propre) + cancel ;
  #   - tmux joignable → kick_send (mot-clé `yop` bootstrap / `wake` fallback) + reschedule ;
  #   - tmux pas encore up → reschedule sans consommer de send-keys.
  # Une erreur send-keys n'interrompt pas le pod (le monitor time-out couvre).
  def handle_info({:kick_attempt, n}, %{tmux_session: session} = state)
      when is_binary(session) do
    # Un pod SANS mandat en attente (interactif/forever comme l'architecte, ou permanent booté
    # à froid comme le gatekeeper) n'a RIEN à puller : ses mandats arrivent plus tard via
    # `wake_pod`. On se contente alors d'un BOOTSTRAP — réveil du REPL + armement du Monitor
    # — borné et ESPACÉ (pas de rafale de 12 yops qui distrait l'agent). Un worker
    # (mandat enqueué au spawn) garde le kick fréquent jusqu'au pull. Détection race-safe :
    # l'enqueue StageRunner (ms après spawn) précède largement le 1er kick (+2s) → un worker a
    # déjà son mandat `pending`, un pod permanent a `pod_status == {:ok, nil}`.
    bootstrap? = no_pending_mandate?(state.pod_id)

    # polled? = l'agent a déjà appelé get_task (ACK in-band). Calculé 1× : sert au bootstrap-stop ET au
    # choix du mot-clé (pas encore pollé = bootstrap-arm "yop" ; déjà pollé = pod running → fallback "wake").
    polled = polled?(state)
    cap = if bootstrap?, do: kick_bootstrap_max(), else: kick_max_attempts()
    retry = if bootstrap?, do: kick_bootstrap_retry_ms(), else: kick_retry_ms()

    cond do
      # ACK (pull pour un wake / poll pour un bootstrap, cf. acked?/3) = l'agent a tendu la main →
      # on STOPPE la boucle (cancel timer ; le porteur/flag prend le relais). On se fie à l'ACTE de
      # l'agent (last_poll/pod_status TaskQueue), pas à un proxy host-side (« process watch.sh existe »).
      acked?(mandate_pulled?(state.pod_id), bootstrap?, polled) ->
        Logger.debug(
          "pod #{state.pod_id} acké (pull/poll) → kick stoppé (porteur prend le relais)"
        )

        {:noreply, cancel_kick(state)}

      n >= cap ->
        # Cap épuisé = l'agent n'a JAMAIS acké (ni flag, ni send-keys). bootstrap = jamais
        # pollé (démarrage KO) ; wake/worker = jamais pull (mandat non-acké). Ring-propre : on BROADCAST
        # (Ring 1) → un consumer fleet_pilot (Ring 2) `record_or_escalate` → récurrent = `:sp_suspect`.
        phase = if bootstrap?, do: :bootstrap, else: :wake

        Logger.warning(
          "pod #{state.pod_id} kick (#{phase}) abandonné après #{n} tentatives — agent jamais acké → escalade #5.2"
        )

        # Capture l'écran (fallback-ACK déporté, best-effort) → le consumer l'attache au ticket.
        best_effort_broadcast("wake.failed", %{
          "pod_id" => state.pod_id,
          "reason" => {:no_ack, phase},
          "pane" => Fleet.Spawner.PodTmux.capture_pane(state.pod_id)
        })

        {:noreply, cancel_kick(state)}

      Fleet.Spawner.PodTmux.alive?(state.pod_id) ->
        _ = kick_send(state, polled)
        {:noreply, schedule_kick(state, n + 1, retry)}

      true ->
        {:noreply, schedule_kick(state, n + 1, retry)}
    end
  end

  # Pas de tmux_session (StubBackend, ou session disparue/kill race) → pas de kick.
  def handle_info({:kick_attempt, _n}, state), do: {:noreply, state}

  # Catch-all silencieux : autres messages (down, monitor, etc.) ignorés.
  def handle_info(_other, state), do: {:noreply, state}

  # Ré-armement de la deadline de réponse — déclenché par `wake_pod` quand une nouvelle tâche
  # est assignée à un pod long-lived. Seulement en :monitoring (hors-monitoring = pas de fenêtre de
  # réponse active) ; sinon no-op. arm_result_deadline annule l'ancien timer + en arme un neuf.
  @impl GenServer
  def handle_cast(:rearm_deadline, %{phase: :monitoring} = state) do
    {:noreply, arm_result_deadline(state)}
  end

  def handle_cast(:rearm_deadline, state), do: {:noreply, state}

  # `wake_pod` arme la boucle ack-driven. Le porteur (flag) vient d'être touché ; la boucle est le
  # FALLBACK — elle ne send-keys `"wake"` QUE si le pull n'arrive pas (mandate_pulled? faux), puis escalade
  # au cap. 1er tick après `kick_first_delay_ms` : on laisse le flag livrer d'abord (pas de double-trigger).
  def handle_cast(:arm_kick, state) do
    {:noreply, arm_kick(state)}
  end

  # (Parser NDJSON `parse_chunks`/`handle_event` retiré : le modèle -p est mort.
  #  La complétion vient de l'event Bus task_queue.task_completed, pas d'un event `result` NDJSON.)

  # Classification load-bearing vs best-effort du broadcast (cf. task_queue/server.ex, même move).
  # Un `safe_broadcast` unique qui avalerait TOUTE exception en `:ok` engloutirait aussi `pod.completed`
  # dont le HopConsumer DÉPEND pour finir le hop : un `pod.completed` avalé = le pod « réussit » (release/
  # kill pour un one-shot) MAIS la fin-de-hop ne se déclenche jamais → verrou forge conservé à vie (wedge
  # silencieux). D'où la SÉPARATION :
  #   - `best_effort_broadcast/2` : OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`). Un échec est
  #     non-bloquant (rescue → log) — un consumer fleet_pilot les enregistre en best-effort, personne ne
  #     FINIT un hop dessus.
  #   - `required_broadcast/2` : LIFECYCLE load-bearing (`pod.completed`). L'échec n'est PAS avalé : il
  #     remonte `{:error, {:broadcast_failed, _}}` → `do_extract` NE release/kill PAS le pod sur une
  #     complétion orpheline ; il reste vivant (re-wake re-fire l'extract), fail-loud. Les deux passent
  #     par l'enveloppe canon stricte `%Fleet.Event{source: :spawner}` (build_spawner_event).

  # Broadcast Bus avec rescue : un crash event_router (bus down, atom invalide) ne doit JAMAIS faire crash
  # le Pod GenServer. RÉSERVÉ aux events NON-lifecycle (observabilité/escalade).
  # Enveloppe : schema canon strict %Fleet.Event{source: :spawner}.
  defp best_effort_broadcast(event_type, payload) when is_binary(event_type) do
    event_bus().broadcast("fleet.events", build_spawner_event(event_type, payload))
  rescue
    e ->
      Logger.warning(
        "Pod best_effort_broadcast #{event_type} rescue (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  end

  # Broadcast LIFECYCLE load-bearing (`pod.completed`) : l'échec n'est PAS avalé. Retourne `:ok` ou
  # `{:error, {:broadcast_failed, reason}}` (raise OU `{:error, _}` de Bus.broadcast). Loggé ERROR : un
  # `pod.completed` non diffusé = wedge potentiel (le hop ne finit pas, verrou conservé).
  defp required_broadcast(event_type, payload) when is_binary(event_type) do
    case event_bus().broadcast("fleet.events", build_spawner_event(event_type, payload)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Pod required_broadcast #{event_type} ÉCHEC (pod=#{Map.get(payload, "pod_id")}) : " <>
            "#{inspect(reason)} — lifecycle NON diffusé (le hop ne finira pas ; pod pas release/kill, fail-loud)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      Logger.error(
        "Pod required_broadcast #{event_type} a LEVÉ (pod=#{Map.get(payload, "pod_id")}) : " <>
          "#{Exception.message(e)} — lifecycle NON diffusé (pod pas release/kill, fail-loud)"
      )

      {:error, {:broadcast_failed, e}}
  end

  # Seam du bus (défaut = le vrai `Fleet.EventRouter.Bus`). App-env override (même pattern que les
  # autres seams pod : claude_dir, state_fs_root…) → un test injecte un bus stub qui rend `{:error,_}` / lève
  # sur `pod.completed`, sans toucher le registry global.
  defp event_bus, do: Application.get_env(:fleet_spawner, :event_bus, Bus)

  # Construit l'enveloppe canon %Fleet.Event{source: :spawner} (factorisé — un seul site de construction
  # pour best_effort/required, schema canon strict).
  defp build_spawner_event(event_type, payload) do
    %Fleet.Event{
      source: :spawner,
      type: String.to_existing_atom(event_type),
      timestamp: DateTime.utc_now(),
      pod_id: Map.get(payload, "pod_id"),
      correlation_id: nil,
      payload: payload
    }
  end

  # ============================================================
  # Phases
  # ============================================================

  defp do_allocate(state) do
    # I/O non-bang via safe_* (erreur propagée → transition_failed clean, pas de
    # crash brutal du GenServer). `with_resolved_disallowed_tools` peut raise sur
    # baseline corrompue (fail-closed intangible) → catch via rescue +
    # transition_failed plutôt que crash brutal.
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

  # Porte de containment (dont le deny des server-tools natifs Anthropic) câblée au
  # boundary spawn. Si `validate/1` (toute la sémantique de containment) n'était appelée
  # QUE par les tests, la porte serait creuse : un profil neuf ou un modop qui remplace
  # `disallowedTools` bypasserait silencieusement. Fail-loud : profil containment-invalide
  # → :failed, le pod n'est JAMAIS lancé. Le JSON-schema (load/compose) ne couvre PAS
  # toutes ces règles de containment — d'où le besoin de validate/1 ici.
  defp gate_cap_profile(resolved) do
    case Fleet.CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end

  defp do_clean(state) do
    # GC d'UUID : avec des session_id DÉTERMINISTES + pod_dir survivant (kill -9 / crash →
    # teardown raté → `safe_mkdir_p` PRÉSERVE le dir en :allocate), un re-spawn en `--session-id`
    # (resume=false) heurterait `Session ID already in use` si un `<uuid>.jsonl` traîne. On le supprime
    # → `--session-id` crée toujours frais. (resume=true → `SeedStore.restore` écrase le jsonl : pas de GC.)
    unless state.resume, do: gc_stale_session_jsonl(state)

    new_state = %{state | phase: :projecting}
    {:noreply, new_state, {:continue, :project}}
  end

  # Supprime tout `<session_id>.jsonl` résiduel sous le pod_dir (tous cwd-slugs) → libère l'UUID pour
  # `--session-id`. Best-effort : un échec ne casse pas le spawn.
  defp gc_stale_session_jsonl(state) do
    [state.pod_dir, ".claude", "projects", "*", "#{state.session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(fn f ->
      _ = File.rm(f)

      Logger.info(
        "Pod.gc #{state.pod_id}: jsonl stale #{Path.basename(f)} retiré (GC UUID → session frais)"
      )
    end)
  end

  defp do_project(state) do
    # Toutes les I/O dans la chaîne `with` (non-bang) → erreur propagée →
    # transition_failed clean (state.json phase=failed écrit).
    #
    # Modèle ticket-driven : le brief n'est PAS un prompt user-canal (safety
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

    # `.claude/` est POD-OWNED. bwrap ne bind QUE `.credentials.json` dedans (pas le .claude
    # humain entier). Sinon fuite de hooks : cwd=HOME=POD_DIR, donc les tiers settings
    # `project`/`local` (racine = cwd) résoudraient dans `$POD_DIR/.claude/` = le `.claude`
    # humain bindé → le settings.json humain (et ses hooks) lu comme settings *projet*.
    # `--setting-sources project,local` n'y peut rien (il autorise project/local). D'où :
    # `.claude/` pod-owned + aucun settings.json dedans → tiers project/local vides → 0 hook
    # humain. Fichiers pod (settings/SP/protocole) en .lcars/ ; CLAUDE.md → racine pod.
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
         # aucun settings.json dedans → 0 hook humain. bwrap y monte `.credentials.json`.
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
         # creds : plus de copie. Seul `.credentials.json` de l'humain est monté RW par
         # bwrap_launch.sh dans `pod_dir/.claude/` (refresh OAuth natif, écriture en place). `.claude/`
         # reste pod-owned → pas de hook humain. Les fichiers pod sont en .lcars/ + racine pod.
         # Le `.claude.json` (onboarding + remote-control) est écrit par claude_launch.sh
         # (frontière vendor N1) — PAS ici. Une version N0 serait clobberée à l'exec (claude_launch le
         # ré-écrit sans condition) ET porterait de la connaissance vendor dans N0.
         :ok <- safe_mkdir_p(tickets_dir),
         :ok <-
           safe_write(
             Path.join(tickets_dir, "#{ticket_id_to_filename(state.ticket_id)}.md"),
             default_brief(state)
           ),
         # Le scaffold ci-dessus est le contexte LISIBLE ; le canal CANONIQUE du mandat est
         # la TaskQueue (`get_task`). Un dispatch stage enqueue AVANT le spawn (StageDispatcher) ; mais
         # `admin.spawn` (lcars spawn --mandate) n'a PAS de dispatcher → sans cet enqueue, `get_task` rend
         # `{done:true}` et le pod reste idle. Idempotent (skip si déjà en file).
         :ok <- maybe_enqueue_mandate(state),
         :ok <- maybe_provision_mcp_config(state),
         :ok <- provision_monitor_watch(state),
         :ok <- maybe_bootstrap_project_workspace(state),
         # Recall délibéré — restaure le seed AVANT le launch (après workspace = cwd réglé).
         :ok <- maybe_recall_restore(state) do
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

  # `write_pod_claude_json` + `detect_claude_version` RETIRÉS. Le `.claude.json`
  # (onboarding + remote-control pré-acceptés) est l'unique responsabilité de
  # `claude_launch.sh` (frontière vendor N1) : une version N0 serait (1) systématiquement clobberée
  # par le `cat >` du launcher juste avant l'exec — donc morte — et perdrait au passage les 3 clés RC
  # (`remoteControlAtStartup`/`hasUsedRemoteControl`/`remoteDialogSeen`), ré-introduisant le blocage
  # dialog RC qu'elle prétendait éviter ; (2) placerait de la connaissance schéma-vendor dans N0. Les
  # clés RC vivent dans le launcher (clé `projects` correcte = `LCARS_POD_CWD`, pas `pod_dir`).

  # creds : write_claude_credentials/lead_credentials_path SUPPRIMÉS.
  # Plus de copie du `.credentials.json` du lead vers le pod : le claudeDir de
  # l'humain est monté RW par bwrap_launch.sh (CLAUDE_DIR → ~/.claude), refresh
  # OAuth délégué au lockfile cross-process natif Anthropic.

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

  # SP draft minimal — déclare le rôle agent worker + workflow yop →
  # get_task → submit_result + convention de retour (ok|failed). Le SP
  # final par rôle est un chantier séparé.
  # Draft SP role-aware : le draft d'un rôle est `agent-<role>-base.md` s'il
  # EXISTE, sinon le draft worker générique. Convention catalogue (le draft suit le `metadata.name`),
  # plus de rôle gravé en `case` : l'architecte tombe sur son draft délégateur (qualité+économie +
  # create_ticket), tout rôle sans draft dédié sur le draft worker (get_task/submit_result). `role`
  # est interpolé dans un path (`agent-<role>-base.md`) → validé via le smart-constructor slug
  # (source unique du charset path-safe ; un `role` malformé retombe juste sur le draft par défaut).
  defp read_agent_draft(%Fleet.CapProfile{metadata: meta}) do
    role = Map.get(meta || %{}, "name", "")
    default = "priv/sp_drafts/agent-worker-base.md"

    file =
      if Fleet.Slug.valid?(role) do
        candidate = "priv/sp_drafts/agent-#{role}-base.md"

        if File.exists?(Application.app_dir(:fleet_sp_builder, candidate)),
          do: candidate,
          else: default
      else
        default
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
  # (Piège réellement rencontré sur une instance dont le protocole-user redéfinissait `yop`.)
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
    # Plus de resolve_env OAuth (coffre/RT-env déprécié). Le pod s'authentifie
    # via le claudeDir de l'humain, bindé RW par bwrap_launch.sh (env CLAUDE_DIR
    # → ~/.claude, refresh natif Anthropic). La résolution per-humain viendra de
    # la registration (onboarding/catalogue déférés) ; minimal ici = config
    # `:fleet_spawner, :claude_dir`.
    env_vars = %{"CLAUDE_DIR" => claude_dir()}

    new_state =
      state
      |> Map.put(:phase, :launching)
      |> Map.put(:env_vars, env_vars)
      |> add_condition(:context_injected)

    {:noreply, new_state, {:continue, :launch}}
  end

  # L'humain qui fait tourner la fleet = l'user du process runtime lui-même : les SEULS users de
  # l'instance sont les users fleet → l'user courant EST l'humain. Pas de config, pas de défaut
  # littéral (un défaut masquerait un trou de câblage au lieu de le faire échouer). Le pod, enfant
  # du runtime (Port/tmux), HÉRITE de cet UID → tourne dans le home de l'humain, bind ses creds. Si
  # demain quelqu'un d'autre installe LCARS, c'est SON user qui lance, SON home — rien à hardcoder.
  # Fail-loud si HOME/user irrésoluble (impossible en pratique, mais jamais rattrapé en silence).
  defp runtime_home, do: System.user_home!()

  # Source UNIQUE `Fleet.Credentials.Human` (pas de `id -un` shellé en double — sinon
  # spawn-ownership et commit-identity peuvent diverger, ce qui casserait la gate d'identité forge).
  # Fail-loud (raise), rattrapé par le try/rescue de do_launch.
  defp runtime_user, do: Fleet.Credentials.Human.current!()

  # ════════════════════════════════════════════════════════════════════════════════════════
  # MÉCANIQUE CREDENTIAL — ON N'Y TOUCHE PAS (et surtout pas pour la « durcir »).
  #
  # Le pod s'authentifie en montant le `.credentials.json` OAuth de SON humain (le `~/.claude`
  # de l'user runtime), bindé RW par le launcher. Ce fichier est PARTAGÉ et WRITABLE entre tous
  # les pods du même humain, et c'est VOULU : c'est la SEULE mécanique multi-agent que le vendor
  # supporte sous abonnement — N process Claude Code se coordonnent pour rafraîchir l'unique token
  # via un verrou cross-process sur `~/.claude/` (refresh natif, conçu « fleet-wide » côté vendor).
  #
  # Conséquence connue et ACCEPTÉE : un pod avec un shell peut lire le token de son PROPRE humain,
  # et peut écraser le fichier partagé. Ce n'est PAS un trou à fixer :
  #   - écraser/corrompre le creds = se suicider (sans creds, pas d'agent) → rien à défendre ;
  #   - le lire = le pod tourne DÉJÀ AS l'humain (il hérite de son UID) → c'est SON propre token,
  #     dans la frontière que l'OS lui accorde de toute façon.
  # Le seul vrai vecteur — lire le token d'un AUTRE humain — est rendu impossible ICI : le claudeDir
  # est dérivé PER-HUMAIN (`claude_dir_for/1` ; jamais un dir global partagé entre humains).
  #
  # Tout « fix » qui retirerait le bind RW, isolerait un credential par-pod, ou passerait par un
  # broker CASSE forcément un des trois piliers durs :
  #   - un token inference-only (`claude setup-token`) ne peut PAS tenir une session Remote Control
  #     (= notre mode interactif) ;
  #   - injecter l'access-token live = falaise ~8h sans refresh (déjà tenté, déjà reverté) ;
  #   - un apiKeyHelper / une clé API = facturation MÉTRÉE = sortie de l'abonnement (interdit).
  # Donc : per-humain OUI, partagé-writable OUI, broker NON. NE PAS « améliorer » ceci.
  # ════════════════════════════════════════════════════════════════════════════════════════
  defp claude_dir do
    Application.get_env(:fleet_spawner, :claude_dir) || Path.join(runtime_home(), ".claude")
  end

  # Creds du pod = `~/.claude` de l'HUMAIN (= l'user runtime). Override config `:claude_dir` respecté
  # (tests / déploiement non-standard) ; sinon dérivé de son home passwd. Per-humain par construction
  # (cf. le gros bloc ci-dessus) — JAMAIS un claudeDir partagé entre humains.
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

  # Porte credentials au spawn-boundary. Defense-in-depth : APRÈS maybe_put_auth_token
  # (mode bind). Lit le claudeDir de l'humain UNE fois → valide scope-coverage
  # (ScopeValidator, par-rôle via flags) + plan payant (PlanValidator). Le binaire claude
  # impose déjà scope+plan (401) ; ces gates font échouer TÔT au lieu du 1ᵉʳ appel API du
  # pod. Erreurs taguées `{:credentials_invalid, _}` pour les distinguer de l'auth-token au
  # call-site.
  defp gate_credentials(human, cap_profile) do
    with {:ok, oauth} <- read_oauth_creds(claude_dir_for(human)),
         :ok <- gate_scopes(oauth, cap_profile),
         :ok <- gate_plan(oauth) do
      :ok
    end
  end

  # SOURCE UNIQUE de lecture du creds natif `<claude_dir>/.credentials.json` : un seul
  # File.read + Jason.decode + extraction du bloc `claudeAiOauth`. `gate_credentials/2` (scope+plan)
  # consomme CE parse — source unique, pas de parsers driftables du même fichier.
  defp read_oauth_creds(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw) do
      {:ok, oauth}
    else
      # Hygiène creds : la cause est CATÉGORISÉE, jamais le JSON décodé (qui porte
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
  # Honore le contrat bwrap_launch.sh « autorité = LCARS_VENDOR_BIN (spawner) » : sans ça, bwrap
  # retombe sur `command -v claude` = PATH du daemon → binaire système périmé (version périmée,
  # outil Monitor absent). readlink -f ⇒ bwrap_launch dérive VENDOR_SHARE = dirname(dirname(bin))
  # juste. Absent ⇒ on ne pose rien (fallback bwrap conservé).
  # Identité git du pod = l'HUMAIN du mandat (author ET committer ; le pod commite EN TANT QUE
  # l'humain qui le run), résolue via le catalogue (`Fleet.Credentials.ForgeIdentity`). Remplace
  # un DÉFAUT COOPÉRATIF role-based de `bwrap_launch.sh` (GIT_AUTHOR=LCARS-$ROLE) : le rôle ne
  # signe plus l'identité — il passe en trailer `Co-authored-by`. bwrap_launch.sh forward ces
  # GIT_AUTHOR_*/GIT_COMMITTER_*. Catalogue absent → fail-loud {:forge_identity_unresolved,_}
  # (pas de pod sans identité vérifiable au push — la garantie reste côté MONDE, gate
  # `allowed_emails=[humain]`).
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

  # Auth = mode `bind` UNIQUEMENT. bwrap monte le `.credentials.json` de l'humain en RW → refresh
  # OAuth natif (proactif 5min + réactif 401 + lockfile), full scope, PAS de falaise ~8h. Un mode
  # token_arg fuirait le token en argv (`--setenv CLAUDE_CODE_OAUTH_TOKEN`) ET ne refresherait pas
  # (expiresAt:null) → un eng long (>8h) perdrait l'auth en plein travail. Pas de toggle.
  defp maybe_put_auth_token(env, _human) do
    {:ok, Map.put(env, "LCARS_AUTH_MODE", "bind")}
  end

  # Binaire vendor posé en LCARS_VENDOR_BIN (honore le contrat bwrap_launch.sh) = `~/.local/bin/claude`
  # de l'HUMAIN (= l'user runtime), résolu via son home passwd. PAS de fallback `lcars` : le pod EST
  # l'humain, c'est SON binaire. Introuvable → fail-loud (sinon bwrap retombe sur `command -v claude`
  # = binaire système périmé, outil Monitor absent).
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
    env = Map.put(env, "LCARS_POD_CWD", pod_cwd(state))

    # Worker projet : le cwd `/home/<project>` est un REMAP du workspace réel → bwrap doit le binder
    # (LCARS_POD_CWD_SRC). Orchestrateur (mount catalogue) / permanent / legacy (relocalisés sous le
    # bind HOME) → déjà bindés, pas de SRC à créer.
    if rc_project(state),
      do: Map.put(env, "LCARS_POD_CWD_SRC", pod_cwd_real(state)),
      else: env
  end

  # cwd VU PAR L'AGENT dans le pod (= LCARS_POD_CWD + base du slug recall). Pour un pod-PROJET,
  # l'agent voit `/home/<project>` (containment : ni human ni pod_id) ; bwrap y bind le workspace
  # RÉEL (`pod_cwd_real`). Sinon (pas de projet nommé) = le réel. Le pod_dir RÉEL ne bouge PAS
  # (reste `/home/<human>/pods/...`) — seul le CWD intra-pod est remappé.
  defp pod_cwd(state) do
    cond do
      # Worker projet → /home/<project>.
      project = rc_project(state) -> "/home/#{project}"
      # Orchestrateur → son mount RW déclaré (arch → /home/projects.work). Data-driven (cap-profile).
      rw = first_rw_mount(state) -> rw
      # Permanent / legacy (projet sans rc_name) → le chemin RÉEL relocalisé (pod_dir → sandbox_home).
      # Home-relocalisé : sandbox_home=/home/.pod → workspace/home relocalisés ; off → pod_dir = identité.
      true -> String.replace_prefix(pod_cwd_real(state), state.pod_dir, sandbox_home(state))
    end
  end

  # Home INTRA-POD. bwrap → /home/.pod (le pod_dir réel masqué derrière) ; sinon (host) → le pod_dir
  # réel (pas de relocalisation). Doit matcher LCARS_POD_HOME posé par maybe_put_sandbox_home.
  defp sandbox_home(state) do
    case cap_profile_containment(state.cap_profile) do
      "bwrap" -> "/home/.pod"
      _ -> state.pod_dir
    end
  end

  # cwd d'un orchestrateur = son 1er mount RW (DÉJÀ bindé via LCARS_POD_MOUNTS, donc pas de bind à
  # créer). nil si aucun rw. Réutilise l'accesseur unique cap_profile_mounts (pas de logique dupliquée).
  defp first_rw_mount(state) do
    state.cap_profile
    |> cap_profile_mounts()
    |> Enum.find_value(fn m -> if (m["mode"] || m[:mode]) == "rw", do: m["path"] || m[:path] end)
  end

  # Relocalise le home intra-pod (bwrap UNIQUEMENT). LCARS_POD_HOME=/home/.pod → bwrap_launch masque
  # le pod_dir réel derrière (SANDBOX_HOME) : l'agent ne voit ni human ni pod_id, et `ls /home` ne
  # montre que les mounts. Host pods (containment none) : pas relocalisés (home réel).
  defp maybe_put_sandbox_home(env, state) do
    case cap_profile_containment(state.cap_profile) do
      "bwrap" -> Map.put(env, "LCARS_POD_HOME", sandbox_home(state))
      _ -> env
    end
  end

  # Workspace RÉEL (hôte) sous le pod_dir : `pod_dir/workspace` si projet cloné, sinon `pod_dir`.
  # C'est la SOURCE du bind cwd (bwrap mappe ce réel sur le `/home/<project>` vu par l'agent).
  defp pod_cwd_real(state) do
    case effective_project(state)["repo_path"] do
      nil -> state.pod_dir
      _ -> Fleet.Spawner.pod_workspace_path(state.pod_dir)
    end
  end

  # Nom de projet PROPRE depuis `rc_name` (`<project>_<role>`, source canonique sanitizée par le
  # dispatcher). `nil` si pas de rc_name (pods permanents / admin → pas de remap cwd). Partagé avec le checkpoint.
  #
  # BOUNDARY de confinement E : ce `projet` est l'UNIQUE dérivation du nom de projet depuis `rc_name`
  # (entrée de dispatch/recall, non maîtrisée), et il finit interpolé dans des chemins/segments — cwd
  # `/home/<project>`, home intra-pod, dossier seed-store. On exige donc qu'il soit un slug ICI, au plus
  # tôt : un `rc_name` malformé (`../evil_role`, `a/b_role`) → `nil` (pod sans remap ni seed, état neutre)
  # plutôt qu'un `projet` traversant qui atteindrait un `Path.join`. Source unique → un seul point à tenir.
  defp rc_project(state) do
    with rc when is_binary(rc) <- Keyword.get(state.opts, :rc_name),
         role <- cap_profile_name(state.cap_profile),
         stripped when stripped != rc <- String.replace_suffix(rc, "_" <> role, ""),
         true <- Fleet.Slug.valid?(stripped) do
      stripped
    else
      _ -> nil
    end
  end

  # Recall délibéré. Si `opts[:recall_seed_jsonl]` est fourni (par `Fleet.Spawner.recall`),
  # restaure le seed à `projects/<slugify(cwd)>/<session_id>.jsonl` AVANT le launch ; claude
  # `--resume <session_id>` (resume:true via opts) le retrouve. Gaté : absent → no-op (spawn normal
  # intact). Le seed est validé (read_map) côté `Spawner.recall` ; absent ICI = fail-loud (transition_failed).
  defp maybe_recall_restore(state) do
    case Keyword.get(state.opts, :recall_seed_jsonl) do
      nil ->
        :ok

      jsonl when is_binary(jsonl) ->
        if File.exists?(jsonl) do
          {:ok, _} =
            Fleet.Spawner.SeedStore.restore(
              jsonl,
              state.pod_dir,
              pod_cwd(state),
              state.session_id
            )

          :ok
        else
          {:error, {:recall_seed_missing, jsonl}}
        end
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
    # Un crash du Pod GenServer ne tue PAS le bwrap/tmux/claude (`--die-with-parent` = BEAM, pas
    # GenServer) → pod ORPHELIN vivant (OAuth+RAM). Avant tout (re)launch, on REAP un éventuel
    # orphelin du même pod_id : no-op pour un pod neuf ; sur recovery (:recreate) ça nettoie le
    # mort-vivant AVANT de relancer (sinon collision sock/process), ce qui rend la recovery viable
    # en prod. Le reaper périodique (orphelins jamais re-spawnés) est un mécanisme distinct (PodWarden).
    reap_orphan_pod(state.pod_id)
    role = cap_profile_name(state.cap_profile)
    containment = cap_profile_containment(state.cap_profile)

    # Le launcher N0 dépend du containment, lu ICI (sinon bwrap aveugle pour tous).
    # "none" (host_native : architect, starfleet) → host_launch.sh (host, sans sandbox) ;
    # sinon la chaîne bwrap. `PermanentBoot` reste générique — la branche vit sur le chemin de lancement.
    launcher_path = if containment == "none", do: host_launch_path(), else: bwrap_launch_path()

    # Pas de budget côté pod (OAuth pool, pas d'API). Le timeout
    # de réponse est géré par `monitor_timeout_ms/1` côté Pod GenServer
    # (Process.send_after :result_deadline). Les backends qui n'ont pas
    # leur propre script de lancement (StubBackend) n'ont pas
    # besoin de la valeur ; les clés `budget_sec`/`budget_usd` sont
    # retirées de l'API LaunchBackend (cf. behaviour
    # `Fleet.Spawner.LaunchBackend`).
    args = %{
      role: role,
      pod_id: state.pod_id,
      pod_dir: state.pod_dir,
      # Launcher N0 sélectionné par containment (host_launch.sh | bwrap_launch.sh). L'exe du
      # Port (build_spawn) ; l'argv reste identique des deux côtés (même contrat <role> <pod_id> <pod_dir>
      # <command...>). Le command opaque (claude_launch.sh …) est claude_launch_path ci-dessous.
      launcher_path: launcher_path,
      claude_launch_path: claude_launch_path(),
      # SP plus dans l'argv (fuite /proc/cmdline + frôle ARG_MAX) : claude_launch lit
      # pod_dir/.lcars/system-prompt.md via --system-prompt-file (écrit en do_project). C'est la SOURCE.
      session_id: state.session_id
    }

    # La résolution humain + le pipeline env peuvent RAISE (runtime_user /
    # claude_dir_from_passwd / maybe_put_vendor_bin = fail-loud sur host sans claude
    # per-user ou home irrésoluble). Un raise non rattrapé ICI crasherait le Pod GenServer SANS
    # transition_failed → task orpheline :pending + state.json à la phase périmée. On
    # rabat tout raise de construction-env sur transition_failed (même cleanup que les
    # autres échecs launch : clear_pod_task + phase=failed).
    launch_env =
      try do
        human = Keyword.get(state.opts, :human) || runtime_user()

        env =
          state.env_vars
          |> Map.merge(skills_plugins_env(state.cap_profile))
          |> Map.merge(
            mcp_channel_env(
              state.pod_id,
              cap_profile_name(state.cap_profile),
              state.capability
            )
          )
          # HOME — dépend du containment.
          #   bwrap (défaut) : HOME=pod_dir (cohérent ; bwrap fait `--setenv HOME` de toute façon,
          #     cette valeur est ignorée sous le sandbox).
          #   none (host)    : HOME = home RÉEL de l'humain → claude lit son `~/.claude` natif. C'est l'auth
          #     `:bind` réalisée NATIVEMENT sur l'hôte (refresh OAuth, full scope, pas de falaise 8h — l'arch
          #     est un pod forever). host_launch.sh ne re-setenv PAS (pas de namespace) : ce HOME EST l'env réel.
          |> Map.put("HOME", launch_home(containment, human, state.pod_dir))
          # Chaîne de session : bwrap_launch les `--setenv` dans le pod,
          # claude_launch les lit `:?` strict (no-boot sinon).
          |> Map.put("LCARS_POD_SESSION_ID", state.session_id)
          |> Map.put("LCARS_POD_RESUME", if(state.resume, do: "1", else: "0"))
          # Mode permission : défaut `default` → claude_launch passe `--permission-mode default`
          # (allow/deny lists ENFORCED) au lieu de `--dangerously-skip-permissions` (héritage « agents dans la
          # nature » qui bypasse TOUT). Monde shapé (bwrap RO/RW + cap-profile) → le bypass est inutile, il ne
          # ferait que neutraliser nos listes. Override par cap-profile `spec.invocation.permission_mode`
          # (ex. "bypassPermissions" pour ré-ouvrir le yolo explicitement). NB : l'enforcement de l'écriture =
          # le MOUNT (RO/RW), pas la tool-list → les juges gardent Write/Edit (rapports), bornés par le mount.
          |> Map.put("LCARS_PERMISSION_MODE", permission_mode(state.cap_profile))
          # Nom RC Desktop : `<projet>_<role>` fourni par le dispatch (`opts[:rc_name]`) ; défaut = role
          # seul (pods permanents / sans projet). claude_launch le passe en
          # `--remote-control "<nom>"` EXACT (zéro suffixe auto → pas de « noms random qui s'empilent »).
          # Sessions RC per-user (l'humain ne voit QUE les siennes). Visibilité Desktop gatée côté
          # claude_launch.sh (lit `invocation.remote_control` du cap-profile). NB : la VALEUR est le nom
          # EXACT, pas un préfixe — le nom d'env legacy (`_NAME_PREFIX`) est conservé (moins de churn).
          |> Map.put("LCARS_POD_SESSION_NAME_PREFIX", Keyword.get(state.opts, :rc_name, role))
          # Base sock tmux : bwrap_launch crée la socket sous <base>/<pod_id>/, PodTmux (host) y tape.
          # MÊME valeur des deux côtés ⇒ le sock calculé coïncide. (Défaut /run/lcars/tmux-sock partagé.)
          |> Map.put("LCARS_TMUX_SOCK_BASE", Fleet.Spawner.PodTmux.sock_base())
          # Le pod est celui de l'HUMAIN : creds ET binaire vendor suivent /home/<human> (même règle que
          # pod_dir). Le binaire est résolu robustement ici (depuis ~/.local/bin, pas le pari `command -v`).
          # Le pod tourne SOUS l'UID de l'humain PAR CONSTRUCTION : le runtime tourne *as* l'humain
          # (chaque humain = SA fleet sous son user), le pod = Port BEAM hérite cet UID →
          # ownership/perms/isolation OS gratis, PAS de systemd-run --uid. (Seul starfleet a un user
          # dédié, hors-fleet.)
          |> Map.put("CLAUDE_DIR", claude_dir_for(human))
          |> maybe_put_vendor_bin(human)
          |> maybe_put_pod_cwd(state)
          # Relocalise le home intra-pod (bwrap only) → bwrap masque le pod_dir réel.
          |> maybe_put_sandbox_home(state)
          # LCARS_POD_DIR (racine pod vue par l'agent, où vivent watch.sh/turn.flag) n'est PAS posée ici —
          # ce serait du dead code : bwrap_launch `--clearenv` la strippe, et host_launch l'`export`e
          # lui-même (= $POD_DIR). Le SP/watch.sh lisent `${LCARS_POD_DIR:-$HOME}` :
          # host → la var ; bwrap → fallback `$HOME` (= /home/.pod = racine pod).
          # Mounts CATALOGUE (cap-profile-driven) → bwrap_launch les bind. Vide / host_launch = inerte.
          # `system_mounts` préfixe le dir des launchers (install) → claude_launch.sh visible dans le sandbox.
          |> Map.put(
            "LCARS_POD_MOUNTS",
            mounts_env(system_mounts() ++ cap_profile_mounts(state.cap_profile))
          )

        {:ok, human, env}
      rescue
        e -> {:error, {:launch_env_unresolved, Exception.message(e)}}
      end

    # L'étape auth sort du pipe (pose LCARS_AUTH_MODE=bind, fail-loud sur erreur). La porte
    # credentials (scope/plan) suit, taguée {:credentials_invalid, _} pour un refus distinct de l'auth.
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

  # Reap un orphelin (bwrap/tmux/claude survivant à un crash GenServer) du même pod_id avant
  # un (re)launch. Ne fait RIEN si aucun orphelin vivant (cas pod neuf). Le kill (tmux kill-server +
  # pkill -f ancré) est centralisé dans `PodTmux.kill_holder/1` (anti self-kill).
  defp reap_orphan_pod(pod_id) do
    if Fleet.Spawner.PodTmux.alive?(pod_id) do
      Logger.warning("pod #{pod_id} : orphelin vivant détecté avant launch (BL-036) — reap")
      Fleet.Spawner.PodTmux.kill_holder(pod_id)
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
        # Extrait le port (LauncherPortBackend l'inclut, StubBackend non).
        # nil-able : un test stub n'a pas de Port → les clauses handle_info
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
          # session_id PRÉ-ALLOUÉ (state) — pas de capture `init_msg["session_id"]` (le modèle -p est
          # mort ; init_msg est nil en RC interactif). L'UUID a été alloué à l'init / restauré en recovery.
          |> Map.put(:session_id, state.session_id)
          |> add_condition(:process_launched)
          |> add_condition(:stream_alive)

        write_state_fs(new_state)

        # Brief delivery au pod long-lived RC.
        #
        # Path actuel : PodTmux send-keys sur le sock par-pod (universel, bwrap ET host).
        #   Pourquoi pas le push par MCP channel : la feature channels est gardée par un
        #   flag `isChannelsEnabled` default false côté Anthropic. send-keys (control
        #   plane) reste universel, le brief est injecté tel quel dans le REPL, claude
        #   l'exécute comme prompt.
        #
        # Path LauncherPortBackend : pas applicable (brief.md sur disk lu par claude_launch).
        # Path Stub (tests) : no-op (pas de tmux_session retourné).
        new_state = inject_brief_to_tmux_pod(new_state)

        {:noreply, new_state, {:continue, :monitor}}

      {:error, reason} ->
        transition_failed(state, {:launch_failed, reason})
    end
  end

  defp do_monitor(state) do
    # Complétion EVENT-DRIVEN (un seul mécanisme). On souscrit au Bus (Ring 0) et on attend
    # `task_queue.task_completed` (%Fleet.Event{}, pod_id == mien) émis par le central (fleet_mcp)
    # sur submit_result. Pas de poll du fichier result.md (mode fichier retiré). Deadline = budget
    # durée → :failed si aucun résultat. pod.ex (Ring 1) ne lit JAMAIS fleet_mcp (Ring 4) en direct.
    Bus.subscribe()
    new_state = arm_result_deadline(%{state | phase: :monitoring})
    {:noreply, new_state}
  end

  defp do_extract(state) do
    # Le résultat vient de l'event Bus (state.submitted_result), pas d'un fichier.
    #
    # Branche selon lifetime_scope :
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
    # Le cycle promote/renvoi-au-dev d'un pod long-lived est piloté côté pipeline,
    # pas ici (do_extract ne fait que remonter le résultat et ré-armer le monitoring).
    result = state.submitted_result || %{}

    # `pod.completed` est LIFECYCLE load-bearing (le HopConsumer en dépend pour finir le hop).
    # Diffusion via `required_broadcast` : son échec n'est PAS avalé. Si elle échoue, on NE progresse PAS
    # vers release/kill (one-shot) ni vers le re-monitoring qui DROPPE `submitted_result` (long-lived) : le
    # pod RESTE vivant avec son résultat RETENU + deadline ré-armée → un re-wake re-fire `do_extract` (la
    # complétion sera ré-émise) au lieu d'une complétion ORPHELINE (pod tué, hop jamais fini, verrou à vie).
    case required_broadcast("pod.completed", pod_completed_payload(state, result)) do
      :ok ->
        do_extract_proceed(state, result)

      {:error, _reason} ->
        # Fail-loud (déjà loggé ERROR par required_broadcast). Pod conservé en :monitoring, résultat
        # RETENU (pas de drop), deadline ré-armée : le re-wake/poll re-déclenchera l'extract. PAS de
        # release/kill sur une complétion non diffusée.
        retry_state =
          state
          |> Map.put(:phase, :monitoring)
          |> arm_result_deadline()

        {:noreply, retry_state}
    end
  end

  # Progression normale APRÈS un `pod.completed` diffusé avec succès (extrait du chemin pour que
  # l'échec de broadcast n'avance JAMAIS vers release/kill ni vers le drop de `submitted_result`).
  defp do_extract_proceed(state, result) do
    new_state =
      state
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(state.cap_profile) do
      "one-shot" ->
        new_state = Map.put(new_state, :phase, :releasing)
        {:noreply, new_state, {:continue, :release}}

      _other ->
        # Reset :output_extracted au re-monitoring (sinon un crash REPL au cycle 2 est
        # masqué en {:stop,:normal} via la garde du handler exit_status → pod.failed/clear
        # jamais émis). arm_result_deadline annule le timer du cycle précédent avant de
        # ré-armer (pas d'accumulation). Bus.subscribe pas re-appelé : déjà subscribed
        # depuis do_monitor au 1er cycle.
        new_state =
          new_state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)
          |> arm_result_deadline()

        {:noreply, new_state}
    end
  end

  # Délègue à la source unique `Fleet.CapProfile.lifetime_scope/1`.
  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  # pod.completed porte le contexte pipeline (pipeline_id+stage) si le pod a été spawné
  # par fleet_pipeline (via spawn_opts). L'Executor corrèle alors le pod terminé à sa
  # stage. Pod hors-pipeline → opts sans ces clés → payload nu (le bridge Executor
  # ignore : pas de pipeline_id ⇒ no-op).
  defp pod_completed_payload(state, result) do
    base = %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "result" => result
    }

    opts = state.opts || []

    case {Keyword.get(opts, :pipeline_id), Keyword.get(opts, :stage)} do
      {nil, _} ->
        # Pod stage-dispatch (assignee-driven) hors pipeline.
        # S'il porte un PROJET (repo cloné), le payload embarque le contexte de
        # fin-de-hop : le consumer `Fleet.Pilot.HopConsumer` est stateless (l'event
        # porte l'état, pas de query `pod_info` racy). workspace+base_sha+role
        # suffisent au `Deliverable.publish` côté système. Pod sans projet
        # (memory-X, architect) → payload nu (base), filtré en aval.
        case effective_project(state) do
          %{"repo_path" => rp} = proj when is_binary(rp) and rp != "" ->
            base
            |> Map.merge(%{
              # Autorité unique du sous-dossier workspace (Fleet.Spawner), pas un littéral recopié.
              "workspace" => Fleet.Spawner.pod_workspace_path(state.pod_dir),
              "base_sha" => proj["base_sha"],
              # Base de la GATE de livraison, DÉCONFLÉE de la clone-base (`base_sha`). Pour
              # une résolution par rebase, le livrable doit DESCENDRE de `main` (cible du rebase), pas de
              # l'ancien tip de feature (réécrit → `base_not_ancestor`). Le resolver l'égale à `base_sha`
              # pour le forward (build/rework) → comportement inchangé. Fallback `base_sha` : projet d'un
              # spawn antérieur au champ (re-mandate vivant dont le project est figé au build initial).
              "gate_base_sha" => proj["gate_base_sha"] || proj["base_sha"],
              "role" => cap_profile_name(state.cap_profile)
            })
            |> maybe_put_repo(proj)
            |> maybe_put_carte_ctx(opts)

          _ ->
            base
        end

      {pipeline_id, stage} ->
        Map.merge(base, %{"pipeline_id" => pipeline_id, "stage" => stage})
    end
  end

  # Contexte carte (pipeline+stage) injecté au spawn par StageDispatcher via `:pipeline`/
  # `:stage` (≠ `:pipeline_id` du chemin pipeline legacy). Permet au HopConsumer de naviguer la
  # carte (CarteNav.next_stage). Absent (carte 1-stage) → payload inchangé.
  defp maybe_put_carte_ctx(payload, opts) do
    case {Keyword.get(opts, :pipeline), Keyword.get(opts, :stage)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        Map.merge(payload, %{"pipeline" => p, "stage" => s})

      _ ->
        payload
    end
  end

  # Multi-projet : embarque le REPO du projet dans `pod.completed` → le HopConsumer (singleton
  # multi-projet) sait sur quel repo agir + où pousser, sans le re-dériver de la config (« l'event porte
  # tout l'état »). `"repository" => %{"full_name"}` = identifiant forge (API) ; `"remote"` = l'URL de push
  # (= `repo_path`, l'URL clonée). Projet sans `"repo"` (cap_profile statique legacy : pas de full_name) →
  # payload inchangé → le HopConsumer retombe sur son repo/remote de config (fallback single-repo).
  defp maybe_put_repo(payload, %{"repo" => repo} = proj) when is_binary(repo) and repo != "" do
    payload
    |> Map.put("repository", %{"full_name" => repo})
    |> maybe_put_remote(proj["repo_path"])
  end

  defp maybe_put_repo(payload, _proj), do: payload

  defp maybe_put_remote(payload, remote) when is_binary(remote) and remote != "",
    do: Map.put(payload, "remote", remote)

  defp maybe_put_remote(payload, _), do: payload

  defp do_release(state) do
    # Tue le pod interactif (Port.close → claude/bwrap/script terminés) puis ARRÊT NORMAL
    # du GenServer (sinon le Pod resterait vivant après :succeeded → memory leak du
    # DynamicSupervisor). Sous `:temporary` l'arrêt :normal n'est jamais ressuscité.
    # NB : pas de clear_for_pod ici — do_release = succès post-EXTRACT, la task a déjà été
    # soumise/complétée (pas de task active à libérer).
    # Checkpoint le seed AVANT de tuer le backend (JSONl encore intact).
    maybe_checkpoint_seed(state)
    teardown_backend(state)

    new_state =
      state
      |> Map.put(:phase, :succeeded)
      |> add_condition(:home_released)

    write_state_fs(new_state)
    {:stop, :normal, new_state}
  end

  # À la mort d'un pod-PROJET (rc_name = `<projet>_<role>` présent), checkpointe son JSONl de
  # session ACTIF vers le seed-store (`projects.work/<projet>/pods/<role>`) pour rappel ultérieur
  # (`--resume`). Permanents (sans rc_name) → pas de seed-store. Best-effort (SeedStore ne raise
  # jamais ici ; un échec ne casse pas le teardown).
  defp maybe_checkpoint_seed(state) do
    case rc_project(state) do
      nil ->
        :ok

      projet ->
        _ =
          Fleet.Spawner.SeedStore.checkpoint(
            state.pod_dir,
            projet,
            cap_profile_name(state.cap_profile)
          )

        :ok
    end
  end

  # Teardown du backend du pod. Port vivant → Port.close (le SIGTERM du holder bwrap fait tomber
  # namespace+tmux+claude). Port déjà mort mais session bwrap/tmux/claude survivante → kill
  # SOCK-AWARE.
  defp teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        # La session du pod bwrap (`lcars-pod-<id>`) vit sur le sock PAR-POD (PodTmux), PAS
        # le serveur tmux par défaut. Un kill ciblant le défaut serait un no-op silencieux →
        # le claude sandboxé continuerait à consommer l'OAuth. On kill via le sock par-pod
        # (même geste que reap_orphan_pod), centralisé dans `PodTmux.kill_holder/1` (anti self-kill).
        Fleet.Spawner.PodTmux.kill_holder(state.pod_id)

      true ->
        :ok
    end

    # Retire le sock-dir APRÈS le kill. Le kill est fiable (terminate_pod_port ET kill_holder tuent
    # claude+namespace) → pas besoin de garder le sock-dir « tant que le kill n'est pas sûr ». Sans ce
    # nettoyage, le sock-dir traînerait après un teardown gracieux → le PodWarden le ramasserait ~60s
    # plus tard en loguant un FAUX « orphelin persistant » (bruit qui masque les vrais). Le PodWarden
    # reste le filet des VRAIS orphelins (GenServer crashé → teardown jamais exécuté → sock-dir + claude
    # survivent → reap). Gardé `tmux_session` : pods réels (bwrap/host), pas StubBackend (sock_path
    # nominal, rm_rf no-op de toute façon).
    if is_binary(state.tmux_session) do
      _ = File.rm_rf(Path.dirname(Fleet.Spawner.PodTmux.sock_path(state.pod_id)))
    end

    :ok
  end

  @doc """
  Tue le pod (chaîne bwrap OU host — geste générique). Le holder (`sleep infinity`) IGNORE l'EOF stdin →
  `Port.close` seul l'ORPHELINE (le pod survit). On SIGTERM donc le process holder
  par son os_pid :
  - **bwrap** : bwrap propage au holder → PID1 exit → namespace + serveur tmux + claude tombent ensemble
    (`--die-with-parent` = filet si le BEAM meurt avant d'arriver ici).
  - **host** : pas de namespace → le holder `host_launch.sh` trap le SIGTERM → `tmux
    kill-server` explicite sur le sock par-pod (teardown self-contained ; cf. `bin/host_launch.sh`).
  Port.close ensuite (libère le port BEAM). Public pour test direct.
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
  déjà fermé EST l'état voulu, donc on rescue plutôt que crash (sinon `:erlang.port_close`
  ArgumentError dans do_release → GenServer du pod crashe sur une complétion RÉUSSIE).
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

  @doc """
  Efface la TOMBSTONE d'un `pod_id` AVANT un (re)spawn délibéré (appelé par
  `Fleet.Spawner.spawn_pod/3`).

  Sous l'id pod DÉTERMINISTE, un re-dispatch retombe sur le MÊME `pod_id`
  (`issue-N-role`). Si un `state.json` TERMINAL (`:succeeded`/`:released`/`:killed`)
  subsiste d'un cycle précédent — même d'une AUTRE issue #N sur un autre repo, l'id
  ne porte que le numéro —, `recover_or_init` le lit → `recovery_action` rend
  `:release` → le pod s'arrête AUSSITÔT (`do_release` sur backend nil, `{:stop,
  :normal}` MUET) sans rien lancer. Le poller voit alors le verrou in-flight sans
  complétion → réclame l'orphelin → re-dispatch → MÊME tombstone → boucle infinie
  (le pod ne lance jamais de claude).

  Un (re)spawn est TOUJOURS délibéré (sous `:temporary` le superviseur ne ressuscite
  jamais) → une tombstone terminale n'a rien à protéger ici : on l'efface + le pod_dir
  → `init` repart FRESH (`:allocate`). **No-op** si pas de snapshot, snapshot illisible,
  ou phase EN VOL (`:launching`/`:monitoring`/… → la recovery `:resume`/`:recreate`
  reste intacte — on ne touche QUE les tombstones).
  """
  @spec clear_terminal_snapshot(String.t(), Fleet.CapProfile.t(), keyword()) :: :ok
  def clear_terminal_snapshot(pod_id, %Fleet.CapProfile{} = cap_profile, opts \\ [])
      when is_binary(pod_id) and is_list(opts) do
    state_fs_path = state_fs_path_for(pod_id, cap_profile, opts)

    with {:ok, json} <- File.read(state_fs_path),
         {:ok, %{"phase" => phase_str}} <- Jason.decode(json),
         phase when phase in [:succeeded, :released, :killed] <- phase_from_string(phase_str) do
      _ = File.rm_rf(Path.dirname(state_fs_path))
      _ = File.rm_rf(pod_dir_for(pod_id, cap_profile, opts))

      Logger.info(
        "Pod.clear_terminal_snapshot #{pod_id}: tombstone :#{phase} effacée (re-spawn FRESH, BL-055)"
      )

      :ok
    else
      _ -> :ok
    end
  end

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
  Décision de recovery d'un pod (re)spawné dont un `state.json` snapshot existe.
  PURE, fonction de la **phase observée** (pas du scope : le scope joue au niveau
  orchestrateur — faut-il re-spawner un pod absent — pas au niveau
  action-sur-snapshot). Sous `:temporary` le supervisor ne ressuscite jamais :
  c'est un (re)spawn délibéré qui appelle `init/1`, et la décision est explicite
  (pas de reprise implicite `first_continue_for(:monitoring)` sur un backend
  mort).

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
  # porte un contexte reprenable. Sinon `:recreate` (reroll, sûr). `--resume` est fragile,
  # deux cas l'invalident :
  #   * gate OFF (`:recovery_resume_enabled` false) → `:recreate` PARTOUT. Escape-hatch :
  #     si `--resume` se révèle mauvais à l'usage (session morte → claude exit → boot raté
  #     silencieux), on coupe et tout reroll proprement.
  #   * `one-shot` → `:recreate` TOUJOURS (indépendant du gate) : la clear-policy fait
  #     `/clear` chaque cycle → pas de contexte à reprendre, ET le sessionId LOCAL régénéré
  #     par `/clear` diverge du `session_id` snapshot → `--resume` reprendrait la
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

  # Défaut FALSE : recovery `:resume` relancerait claude `--resume <session-MORTE>` → claude exit →
  # pod ZOMBIE (Elixir croit :monitoring, REPL mort, OAuth consommé). Après un crash, la session
  # claude n'existe plus serveur-side, donc `--resume` est voué à l'échec. `:recreate` (session
  # neuve) relance un REPL VIVANT et la tâche (toujours en queue) re-drive le travail. Le gate reste
  # un opt-in (`true`) si un jour `--resume` se révèle capable de ressusciter une session
  # serveur-side (douteux).
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

  # Un pod (re)spawné avec un snapshot suit la décision explicite de
  # `recover_or_init`/`recovery_action`. `:resume` RE-MATÉRIALISE (→ :project :
  # le SP + les fichiers .lcars NE sont PAS dans le snapshot minimal, ils se
  # re-composent depuis le cap-profile, déterministe) PUIS launch(resume) —
  # `do_project` pose `state.sp` ; aller directement à :launch laisserait sp=nil →
  # `build_spawn` `:invalid_args` (cas d'un gatekeeper-permanent qui recovere
  # d'un `phase:monitoring`). JAMAIS reprendre en `:monitor` sur un backend mort.
  # NB : `do_project` re-clone le workspace si `spec.project.repo_path` —
  # l'idempotence du clone est gérée ailleurs ; pour les pods sans projet
  # (gatekeeper, judges) c'est un no-op.
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

  # session_id DÉTERMINISTE hexspeak (`Fleet.Spawner.SessionId`) si le rôle est catalogué.
  # - fleet-level (arch, gatekeeper) → repo `0000` (une instance/rôle, pas de collision).
  # - project-bound (eng, juges) → SEULEMENT si `opts[:repo_id]` fourni ; sinon random (pas de
  #   collision inter-projet/rework tant que le pipeline ne passe pas le repo).
  # - starfleet / rôle inconnu → `UUID.uuid4()`. `opts[:session_id]` (seed arch, recall) PRIME au call-site.
  defp deterministic_session_id(%Fleet.CapProfile{metadata: meta}, opts) do
    role = Map.get(meta || %{}, "name", "")
    repo = Keyword.get(opts, :repo_id)

    cond do
      Fleet.Spawner.SessionId.fleet_level?(role) ->
        Fleet.Spawner.SessionId.build!(role, 0x0000)

      Fleet.Spawner.SessionId.deterministic?(role) and is_integer(repo) ->
        Fleet.Spawner.SessionId.build!(role, repo)

      true ->
        UUID.uuid4()
    end
  end

  defp deterministic_session_id(_, _), do: UUID.uuid4()

  # Mode permission du pod : `spec.invocation.permission_mode` du cap-profile, défaut
  # `"default"` (→ `--permission-mode default`, listes allow/deny ENFORCED). Non-vide → claude_launch
  # passe `--permission-mode <mode>` ; pour ré-ouvrir le bypass, un cap-profile pose `"bypassPermissions"`.
  defp permission_mode(%Fleet.CapProfile{spec: spec}),
    do: get_in(spec || %{}, ["invocation", "permission_mode"]) || "default"

  defp permission_mode(_), do: "default"

  defp initial_state(args) do
    state_fs_path = state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = pod_dir_for(args.pod_id, args.cap_profile, args.opts)

    %{
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      ticket_id: args.ticket_id,
      # Session UUID PRÉ-ALLOUÉ au spawn : `--session-id <uuid>` à la 1ʳᵉ création ;
      # `recover_or_init` le RESTAURE depuis state.json → `--resume <uuid>`. Remplace
      # le modèle -p (capture `init_msg["session_id"]`, mort). `resume`=false ; recovery le passe à true.
      session_id:
        Keyword.get(args.opts, :session_id) ||
          deterministic_session_id(args.cap_profile, args.opts),
      # Capability par-pod = preuve d'identité auprès du serveur MCP central. Générée FRAÎCHE à
      # chaque (re)spawn (256 bits aléatoires) : non-dérivable du pod_id déterministe, donc indevinable
      # même en connaissant le pod_id. Elle est stockée ici (lue par `pod_info`) ET injectée dans l'env
      # du pont MCP de CE pod (cf. mcp_channel_env / build_fleet_mcp_entry) → les deux côtés portent la
      # MÊME valeur, posée au même cycle. Pas persistée dans state.json : au recovery, tout (env du pont
      # + ce state) est régénéré ensemble, donc une nouvelle capability cohérente.
      capability: generate_capability(),
      # Timestamp ISO8601 figé à la création du GenServer, persisté tel quel dans
      # state.json.
      started_at: DateTime.utc_now(),
      # défaut false ; la recovery (apply_recovery) ET le recall délibéré (opts[:resume])
      # le passent à true → claude `--resume <session_id>`.
      resume: Keyword.get(args.opts, :resume, false),
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
      # Ref du timer :result_deadline (timeout de RÉPONSE). nil = non armé.
      # Armé seulement pour les scopes bornés (pas `forever`), annulé à l'arrivée du
      # résultat / avant ré-arme. Cf. arm_result_deadline/1.
      result_deadline_ref: nil,
      # Ref du timer {:kick_attempt}. 1 SEUL vivant (cancel+rearm, cf. arm_kick/1) : un wake_pod
      # pendant le bootstrap ne crée pas une 2e boucle. nil = boucle non armée / stoppée.
      kick_ref: nil
    }
  end

  # Génère le secret par-pod (256 bits aléatoires cryptographiques, encodé URL-safe sans padding pour
  # voyager proprement en JSON / variable d'env). C'est l'UNIQUE site de génération de capability : le
  # secret est posé dans le state du pod ET dans l'env de son pont MCP, jamais re-tiré ailleurs.
  defp generate_capability do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
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
        Application.get_env(:fleet_spawner, :state_fs_root, default_state_fs_root())
      )

    scope = scope_for(Fleet.CapProfile.lifetime_scope(cap_profile, nil))
    Path.join([root, scope, pod_id, "state.json"])
  end

  # Fleet sous l'humain : le state FS des pods suit le HOME de l'humain (= l'user runtime),
  # comme `~/pods` (pod_dir) et `~/.lcars/workspaces`, PAS `/var/lib/lcars`.
  # Override via env `LCARS_STATE_FS_ROOT` (→ `config :fleet_spawner, :state_fs_root`). Fallback
  # `/var/lib/lcars` si home irrésoluble (jamais en pratique).
  defp default_state_fs_root,
    do: Path.join(System.user_home() || "/var/lib/lcars", ".lcars/state")

  # Accesseur UNIQUE du rôle (= metadata.name). Si plusieurs sites inlinaient
  # `Map.get(metadata, "name", "engineer")` (launch/payload/brief) tandis que la persistance
  # state.json passait par ici (défaut "unknown"), un profil SANS metadata.name se lancerait
  # "engineer" mais persisterait "unknown" (mésattribution silencieuse tout le hop). D'où l'unification ici.
  defp cap_profile_name(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "name") || Map.get(meta, :name) || "unknown"
  end

  defp cap_profile_name(_), do: "unknown"

  # `metadata.containment` ∈ {"bwrap","none"} (défaut conservateur "bwrap").
  # "none" = host_native (architect, starfleet) → host_launch.sh (PAS de sandbox) ; sinon la
  # chaîne bwrap. Lu ICI, sur le chemin de lancement (sinon `do_launch` bwrapperait tout aveuglément).
  defp cap_profile_containment(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "containment") || Map.get(meta, :containment) || "bwrap"
  end

  defp cap_profile_containment(_), do: "bwrap"

  # Mounts CATALOGUE (cap-profile-driven) : le monde projeté dans le sandbox bwrap est
  # DÉCLARÉ par le cap-profile (`metadata.mounts`), pas hardcodé dans le launcher. bwrap_launch les bind
  # (RO/RW) au MÊME path, après la tmpfs /home. Vide ⇒ aucun mount extra (worker bare). Inerte pour
  # containment: none (host = accès natif).
  defp cap_profile_mounts(%Fleet.CapProfile{metadata: meta}) when is_map(meta) do
    Map.get(meta, "mounts") || Map.get(meta, :mounts) || []
  end

  defp cap_profile_mounts(_), do: []

  # Mount SYSTÈME universel : le dir des launchers (= `dirname(claude_launch_path)`) doit être VISIBLE
  # dans le sandbox bwrap, car `claude_launch.sh` y tourne en PID1. `/usr/local/bin` l'était par accident
  # (`--ro-bind /usr`) ; depuis l'install (`/local/LCARS_v2/bin`) ou le source dev (`/home/.../bin`) il faut
  # le bind explicite. Dérivé du path launcher (= paramètre d'install) → suit le déploiement sans hardcode.
  # Passe par le canal catalogue `LCARS_POD_MOUNTS` (appliqué APRÈS `--tmpfs /home` → re-expose même un
  # chemin `/home/...`) ⇒ sanctuaire `bwrap_launch.sh` INTACT. Skip si déjà sous `/usr` (couvert par
  # `--ro-bind /usr` → bind redondant inutile ; cas du défaut legacy `/usr/local/bin`, dont les tests).
  defp system_mounts do
    bin = Path.dirname(claude_launch_path())
    if String.starts_with?(bin, "/usr/"), do: [], else: [%{"mode" => "ro", "path" => bin}]
  end

  # Sérialise les mounts pour bwrap_launch (`LCARS_POD_MOUNTS`) : une ligne "mode:path" par mount.
  defp mounts_env(mounts) when is_list(mounts) do
    mounts
    |> Enum.map(fn m ->
      mode = Map.get(m, "mode") || Map.get(m, :mode)
      path = Map.get(m, "path") || Map.get(m, :path)
      "#{mode}:#{path}"
    end)
    |> Enum.join("\n")
  end

  defp mounts_env(_), do: ""

  # HOME du pod selon containment. host (none) = home réel de l'humain (claude → `~/.claude`
  # natif, refresh OAuth) ; bwrap = pod_dir (ignoré sous le sandbox de toute façon). `claude_dir_for/1`
  # honore l'override config `:claude_dir` (tests) et fail-loud si le passwd de l'humain est introuvable.
  # NB mono-humain : si `:claude_dir` est overridé (path GLOBAL, non lié à `human`), `Path.dirname` rend
  # son parent pour TOUT pod host. OK en prod mono-humain (1 runtime = 1 humain) ; en multi-humain il
  # faudrait dériver le home par-humain via `passwd_home/1` quand l'override n'est pas posé.
  defp launch_home("none", human, _pod_dir), do: Path.dirname(claude_dir_for(human))
  defp launch_home(_containment, _human, pod_dir), do: pod_dir

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  # `forever` partage le scope FS `pods/` avec `one_shot` (les deux = pods avec
  # lifetime propre).
  defp scope_for("forever"), do: "pods"
  defp scope_for(_), do: "pods"

  defp write_state_fs(state) do
    # Schéma complet du snapshot :
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

    # write_state_fs est appelé depuis transition_failed et d'autres sites — un
    # crash ici ferait régresser le cleanup. Non-bang (le {:stop, ...} prévu se
    # passe quand même).
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
        # Échec d'écriture state.json = perte du point de recovery durable. C'est une
        # ERREUR (pas un warning) — `:ok` reste rendu (non-fatal : ne pas crasher ici)
        # mais le breach est LOUD (error-level → monitoring).
        Logger.error(
          "pod #{state.pod_id} write_state_fs ÉCHEC — point de recovery durable perdu " <>
            "(non-fatal) : #{inspect(reason)}"
        )

        :ok
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp transition_failed(state, reason) do
    Logger.warning("pod #{state.pod_id} failed: #{inspect(reason)}")

    # Le pod meurt sans relaunch → libérer sa task active sinon elle reste
    # orpheline (assigned/pending sans pod).
    clear_pod_task(state.pod_id)

    new_state =
      state
      |> Map.put(:phase, :failed)
      |> Map.put(:last_error, reason)

    write_state_fs(new_state)

    # Signale l'échec sur le Bus → un consumer fleet_pilot l'enregistre au registre d'incidents
    # (parité avec wake-`{:error}` : un échec de pod récurrent devient un pattern → root-cause). `reason` =
    # terme brut (le consumer le catégorise). Ring-propre : Ring 1 PUBLIE, Ring 2 consomme (pas d'appel
    # montant). Jumeau du broadcast `pod.failed` du handler exit_status.
    best_effort_broadcast("pod.failed", %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "reason" => reason
    })

    {:stop, {:shutdown, reason}, new_state}
  end

  defp add_condition(state, condition) do
    Map.update!(state, :conditions, &MapSet.put(&1, condition))
  end

  # Retire une condition. `:output_extracted` DOIT être reset au re-monitoring
  # d'un pod long-lived (do_extract _other) — sinon un crash REPL au cycle 2 reste masqué
  # en {:stop, :normal} (la garde du handler exit_status reste vraie) → pod.failed/clear jamais émis.
  defp remove_condition(state, condition) do
    Map.update!(state, :conditions, &MapSet.delete(&1, condition))
  end

  # Libère la task active d'un pod qui meurt sans l'avoir complétée.
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

  # Gestion du timer :result_deadline (timeout de RÉPONSE).
  #
  # arm : annule TOUJOURS le timer précédent (pas d'accumulation, pas de stale-kill)
  # puis arme un nouveau — SAUF pour un pod `forever` (permanent : gatekeeper/
  # architect/monk) qui ne porte PAS de timeout de réponse (idle = normal, slow-task =
  # légitime ; gouverné par kill_pod externe). Stocke la ref dans l'état.
  # Mécanique « timer géré » FACTORISÉE (deadline + kick = même moteur paramétré).
  # Un ref de timer vit sous `key` dans le state ; (re)armer = cancel l'ancien +
  # send_after + stocker ; annuler = cancel + nil. 1 seul timer vivant par clé. Les appelants gardent leur
  # POLITIQUE (forever-skip, quel message, quel délai) — cf. arm_result_deadline / schedule_kick.
  defp arm_managed_timer(state, key, msg, delay) do
    state = cancel_managed_timer(state, key)
    Map.put(state, key, Process.send_after(self(), msg, delay))
  end

  defp cancel_managed_timer(state, key) do
    case Map.get(state, key) do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    Map.put(state, key, nil)
  end

  # Deadline de RÉPONSE. Politique : pas d'armement pour un pod `forever` (un permanent n'a pas de
  # fenêtre de réponse bornée) → on garantit juste l'absence de timer.
  defp arm_result_deadline(state) do
    if lifetime_scope(state.cap_profile) == "forever" do
      # Un permanent (arch) n'a pas de fenêtre de réponse bornée → ni deadline ni watchdog liveness.
      state
      |> cancel_managed_timer(:result_deadline_ref)
      |> cancel_managed_timer(:liveness_tick_ref)
    else
      # Le deadline N'EST PAS un budget « temps pour finir » (un vrai livrable a une durée inconnaissable
      # a priori) — c'est un watchdog de SILENCE. Le `:liveness_tick` ré-arme ce deadline tant que le pod
      # BOUGE (taille jsonl ↑ OU jiffies CPU /proc ↑) → un agent qui bosse ne timeout JAMAIS ; le deadline
      # ne tombe que sur silence total = stuck/mort. C'est ce qui rend VRAIE la promesse du commentaire
      # kick (« le deadline se ré-arme sur activité »).
      state
      |> arm_managed_timer(:result_deadline_ref, :result_deadline, monitor_timeout_ms(state))
      |> schedule_liveness_tick()
    end
  end

  defp cancel_result_deadline(state) do
    state
    |> cancel_managed_timer(:result_deadline_ref)
    |> cancel_managed_timer(:liveness_tick_ref)
  end

  defp schedule_liveness_tick(state),
    do: arm_managed_timer(state, :liveness_tick_ref, :liveness_tick, liveness_tick_ms(state))

  defp liveness_tick_ms(state) do
    keyword_opt(state, :liveness_tick_ms) ||
      Application.get_env(:fleet_spawner, :liveness_tick_ms, 30_000)
  end

  # Lit une option per-pod depuis `state.opts` (keyword passé au spawn) → `nil` si absente/illisible. Permet
  # d'injecter en test SANS config globale (async-safe) : `:liveness_probe_fun`, `:liveness_tick_ms`.
  defp keyword_opt(state, key) do
    case Map.get(state, :opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  # Sonde de liveness : `{taille_jsonl, jiffies_cpu}` — deux signaux complémentaires (le jsonl couvre « a
  # produit une sortie », le CPU couvre « moud sans sortie encore »). Injectable (test) via l'opt per-pod
  # `:liveness_probe_fun` (fun/1) ou la config. `nil` sur un signal = indisponible (pas de fichier / pas de
  # port) → ne compte pas comme mouvement (biais anti-kill : on ne tue pas sur un nil).
  defp liveness_sample(state) do
    case keyword_opt(state, :liveness_probe_fun) ||
           Application.get_env(:fleet_spawner, :liveness_probe_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> {jsonl_size(state), proc_cpu_jiffies(state)}
    end
  end

  # Mouvement = au moins UN des deux signaux a crû. Pas de baseline (1er tick) → vivant (bénéfice du doute).
  defp liveness_moved?(nil, _now), do: true
  defp liveness_moved?({pj, pc}, {nj, nc}), do: grew?(pj, nj) or grew?(pc, nc)

  defp grew?(prev, now) when is_integer(prev) and is_integer(now), do: now > prev
  defp grew?(_, _), do: false

  # Taille cumulée des `<session_id>.jsonl` du pod (append-only → croît à chaque message/tool-result).
  # `nil` si aucun jsonl (session pas encore écrite).
  defp jsonl_size(state) do
    [state.pod_dir, ".claude", "projects", "*", "#{state.session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn f ->
      case File.stat(f) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end
    end)
    |> case do
      [] -> nil
      sizes -> Enum.sum(sizes)
    end
  end

  # utime+stime (jiffies) du process claude via `/proc/<os_pid>/stat`. Robuste au `comm` (champ 2, entre
  # parenthèses, peut contenir espaces/`)`) : on découpe après le DERNIER `)` (champ 3 = index 0 du reste →
  # utime = index 11, stime = index 12). `nil` si pas de port / process parti / proc illisible. NB : mesure
  # le process PARENT (un tool enfant CPU-lourd n'y figure pas — couvert par le OU-jsonl + la fenêtre de
  # silence).
  defp proc_cpu_jiffies(state) do
    with port when is_port(port) <- Map.get(state, :port),
         {:os_pid, pid} <- Port.info(port, :os_pid),
         {:ok, raw} <- File.read("/proc/#{pid}/stat") do
      fields =
        raw |> String.split(")") |> List.last() |> String.trim() |> String.split(~r/\s+/)

      case {to_int(Enum.at(fields, 11)), to_int(Enum.at(fields, 12))} do
        {u, s} when is_integer(u) and is_integer(s) -> u + s
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp to_int(nil), do: nil

  defp to_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  # Timeout de RÉPONSE (pas budget de durée de vie) au tool MCP submit_result.
  # Si pas de réponse dans le délai → :result_deadline → transition_failed → le
  # pod MEURT (tous `:temporary`) : PAS de relaunch OTP. Conséquence (couplage) :
  # la task active est à libérer (`TaskQueue.clear_for_pod`) sinon elle reste
  # orpheline (assigned/pending sans pod), et le re-dispatch est délibéré
  # (recovery boot-orchestrator).
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

    # `Process.send_after` exige un entier non-négatif. `is_number(override)` accepte les
    # FLOATS (un cap-profile `timeouts.response_sec: 1.5` passe la validation) → `sec * 1000` = float
    # → ArgumentError dans arm_result_deadline qui CRASHERAIT le Pod sans transition_failed. `round/1`
    # coerce → entier (ms), quel que soit l'override.
    round(sec * 1000)
  end

  defp default_response_timeout_sec(%Fleet.CapProfile{spec: spec}) do
    # Pas de band-aid `forever -> 60_000` : arm_result_deadline n'arme PAS pour `forever`
    # (un permanent n'a pas de timeout de réponse), et le fire ne tue que si une task est
    # réellement active. La valeur `forever` ci-dessous est donc inerte (forever n'arme
    # jamais) ; conservée par cohérence si un override `spec.timeouts.response_sec` la
    # réactivait un jour.
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
  # LCARS_SKILLS_PLUGINS = noms plugins uniques extraits des skills
  # QUALIFIÉS `plugin:skill` du cap-profile.spec.knowledge.skills.
  # Consommé par bin/bwrap_launch.sh (mount-bind RO). Un skill
  # non-qualifié (sans `:`) n'est PAS un plugin → filtré. Vide → pas
  # d'env var (rétro-compatible). Public @doc false : pure, testable
  # directement (pas d'intégration mock-backend lourde pour de la
  # logique triviale).
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
  # créerait des sous-dirs). Convention : remplace `/` par `_` et
  # garde `#` (lisible humain).
  defp ticket_id_to_filename(ticket_id) when is_binary(ticket_id) do
    String.replace(ticket_id, "/", "_")
  end

  defp default_brief(state) do
    mandate = Keyword.get(state.opts || [], :mandate)
    # Interpoler le RÔLE résolu, ne pas hardcoder "engineer". Un gatekeeper (juge) sans
    # mandat explicite ne doit PAS être amorcé "worker engineer" (un mauvais priming de persona).
    # Cadre neutre "pod LCARS (rôle X)" — le mandat (GateBrief pour le juge) porte la persona réelle.
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

  # Enqueue le mandat dans la TaskQueue (le canal CANONIQUE `get_task`), idempotent :
  #   - pas de mandat (pod permanent/interactif booté à froid) → rien à puller → bootstrap (skip) ;
  #   - mandat DÉJÀ en file (`pod_status != {:ok, nil}` : dispatch stage, StageDispatcher a enqueué AVANT
  #     le spawn) → pas de double-enqueue (skip) ;
  #   - sinon (`admin.spawn` / `lcars spawn --mandate` : aucun dispatcher) → on enqueue ici, sinon
  #     `get_task` rend `{done:true}` et le pod reste idle (cf. StageDispatcher.enqueue_mandate).
  # Mirror des `attrs` de StageDispatcher (`ticket_id`/`role`/`brief`/`metadata`).
  defp maybe_enqueue_mandate(state) do
    mandate = Keyword.get(state.opts || [], :mandate)

    cond do
      not (is_binary(mandate) and mandate != "") ->
        :ok

      not no_pending_mandate?(state.pod_id) ->
        :ok

      true ->
        attrs = %{
          ticket_id: state.ticket_id,
          role: cap_profile_name(state.cap_profile),
          brief: mandate,
          metadata: %{"source" => "admin.spawn"}
        }

        case Fleet.TaskQueue.enqueue(state.pod_id, attrs) do
          {:ok, _task} -> :ok
          {:error, reason} -> {:error, {:mandate_enqueue_failed, reason}}
        end
    end
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

  # Launcher N0 host (containment: none) — frère sans-sandbox de bwrap_launch, même argv-shape.
  defp host_launch_path do
    Application.get_env(:fleet_spawner, :host_launch_path, "/usr/local/bin/host_launch.sh")
  end

  defp claude_launch_path do
    Application.get_env(:fleet_spawner, :claude_launch_path, "/usr/local/bin/claude_launch.sh")
  end

  # Serveur MCP fleet (canal de comm UNIQUE pod↔fleet ; jamais de scraping).
  # Config = chemin pod-accessible (hors /home,/tmp, comme bwrap/claude_launch). Un pod
  # RÉEL parle MCP, point — il n'y a PAS de mode fichier alternatif. `nil` n'est légitime QUE pour
  # les tests à launch-stub (claude pas lancé) ; un backend réel (LauncherPortBackend) sans spec MCP est un
  # bug de config (le brief instruit submit_result, impossible sans serveur).
  #
  # UN seul mécanisme paramétré : la config fournit la spec serveur (`command`/`args`/`env`),
  # pod.ex y force `alwaysLoad`. La spec décide — PROD : pont stdio→central (env LCARS_FLEET_MCP_URL),
  # TESTS : fixture file-backed. Même mécanisme, spec différente.
  defp mcp_server_spec, do: Application.get_env(:fleet_spawner, :mcp_server_spec)

  # Env vars MCP à propager au pod (consommés par bridge.py côté pod). `LCARS_POD_ID`
  # est TOUJOURS posé : nécessaire pour que bridge.py injecte `_lcars_pod_id` dans
  # chaque tool call MCP (corrélation côté central PodTools, filtrage TaskQueue.next_for).
  # Sans ça le pod est anonyme — get_task ne retournerait QUE les untargeted (rate les
  # tasks ciblées via wake_pod).
  #
  # `LCARS_ROLE` (= `metadata.name` du cap-profile = rôle métier) : bridge.py l'injecte en `_lcars_role`.
  # Ce champ du fil est INDICATIF (surface de tools du pod, descriptif), PAS la source de la décision
  # de token de rôle : `PodTools.create_ticket` résout le rôle depuis le SPAWN (`pod_id → role` gravé
  # côté serveur, `Fleet.Spawner.pod_info`), pas du wire (non authentifié → usurpation). Posé ICI
  # (env du process pod) → couvre host_launch ET bwrap (qui le re-`--setenv` dans son sandbox).
  #
  # `LCARS_POD_CAPABILITY` (= le secret par-pod, généré au spawn) : bridge.py l'injecte en
  # `_lcars_pod_capability` dans chaque tool-call, exactement comme `LCARS_POD_ID` → `_lcars_pod_id`.
  # Le central VÉRIFIE cette capability contre celle enregistrée pour le pod_id avant de servir le moindre
  # tool corrélé pod (get_task/submit_result/résolution de rôle) : un pod qui présente le pod_id deviné
  # d'un AUTRE pod n'a pas sa capability → REFUS. C'est la fermeture du trou d'usurpation : le pod_id seul
  # ne prouve plus rien. TOUJOURS posée (tout pod spawné par la fleet en reçoit une) ; un pod sans elle
  # ne peut RIEN faire au central (fail-closed, pas de fallback anonyme).
  #
  # `LCARS_FLEET_MCP_CHANNEL_URL` n'est plus posé (push channel ChannelHTTP supprimé,
  # le drive se fait via les tools pull `get_task`).
  defp mcp_channel_env(pod_id, role, capability)
       when is_binary(pod_id) and is_binary(capability) do
    base = %{"LCARS_POD_ID" => pod_id, "LCARS_POD_CAPABILITY" => capability}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  # Kick AUTONOME « yop » readiness-gated. Déclenche le pull du mandat
  # par MCP get_task — le mandat n'est PAS injecté (il vit dans tickets/ + TaskQueue).
  # No-op si pas de tmux_session (StubBackend ; LauncherPortBackend en pose un, bwrap ou host).
  #
  # Pourquoi pas un délai FIXE : le claude REPL n'est pas prêt à un instant connu — il
  # boote (tmux server up, banner, init MCP servers via .mcp-fleet.json), durée variable.
  # Un yop à délai fixe arrive trop tôt et est perdu (le sock du serveur tmux n'existe pas
  # encore). On planifie donc une BOUCLE bornée : à chaque tick, si le serveur tmux est
  # joignable (`PodTmux.alive?`) on envoie yop ; on s'arrête dès que le mandat est pull
  # (task ≠ pending) ou au cap. Non-bloquant (send_after + handle_info), le pod passe à
  # :monitor entretemps. Intervalles configurables (test : valeurs ~ms).
  defp kick_first_delay_ms, do: Application.get_env(:fleet_spawner, :kick_first_delay_ms, 2_000)
  defp kick_retry_ms, do: Application.get_env(:fleet_spawner, :kick_retry_ms, 2_500)
  defp kick_max_attempts, do: Application.get_env(:fleet_spawner, :kick_max_attempts, 12)

  # Bootstrap (pod sans mandat) : kicks BORNÉS + ESPACÉS jusqu'à ce que le REPL claude réponde (appel
  # get_task = ack). La fenêtre doit couvrir le COLD-START réel de claude en bwrap (binaire ~238 MB,
  # caches froids, contention multi-fleet) : un défaut trop court (≈32s, calé sur un boot ~15s)
  # verrait tous les kicks tomber avant REPL prêt → pod jamais onboardé. D'où 30×8s ≈ 4 min : couvre
  # le cold-start, et le deadline résultat se RÉ-ARME sur activité (donc dès le mandat reçu, plus de
  # timeout). Une fois acké, le réveil-par-flag prend le relais.
  defp kick_bootstrap_max, do: Application.get_env(:fleet_spawner, :kick_bootstrap_max, 30)

  defp kick_bootstrap_retry_ms,
    do: Application.get_env(:fleet_spawner, :kick_bootstrap_retry_ms, 8_000)

  # Boucle de kick (timer géré `:kick_ref`, 1 seul vivant). Politique : 1er tick après
  # kick_first_delay_ms (on laisse le flag porteur livrer d'abord) ; armé au bootstrap (inject_brief) ET à
  # chaque wake (cast :arm_kick) → un wake_pod pendant le bootstrap ne crée pas une 2e boucle. Mécanique
  # FACTORISÉE dans arm_managed_timer/cancel_managed_timer (cf. la deadline de réponse).
  defp arm_kick(state), do: schedule_kick(state, 0, kick_first_delay_ms())

  defp schedule_kick(state, n, delay),
    do: arm_managed_timer(state, :kick_ref, {:kick_attempt, n}, delay)

  defp cancel_kick(state), do: cancel_managed_timer(state, :kick_ref)

  @doc false
  # ACK (décision PURE, testable) = l'agent a tendu la main. C'est LE contrôle de la boucle :
  # pas d'ACK → on (re)trigger ; ACK → stop ; cap sans ACK → escalade. Wake → `pulled?` (mandate_pulled? :
  # le pull PROUVE get_task) ; bootstrap (permanent sans mandat) → `polled` (last_poll = up + SP lu).
  def acked?(pulled?, bootstrap?, polled), do: pulled? or (bootstrap? and polled)

  # L'agent a-t-il POLLÉ (appelé get_task) ? = ACK in-band RÉEL : l'agent a tendu la main via l'API
  # officielle (last_poll, tracké par le TaskQueue), pas un proxy host-side comme un
  # `pgrep watch.sh` (« le process existe » ≠ « l'agent agit »). Sert à stopper le kick bootstrap dès que
  # l'agent est up. Override test : `:polled_fun`.
  defp polled?(%{pod_id: pod_id} = state) when is_binary(pod_id) do
    case Map.get(state, :polled_fun) || Application.get_env(:fleet_spawner, :polled_fun) do
      fun when is_function(fun, 1) -> fun.(state)
      _ -> Fleet.TaskQueue.last_poll(pod_id) != nil
    end
  rescue
    _ -> false
  catch
    # `last_poll` est un GenServer.call → TaskQueue down/restarting EXIT (ne raise pas), `rescue` ne
    # l'attrape pas. MÊME garde que mandate_pulled?/no_pending_mandate? : un hoquet broker ne crashe PAS le pod.
    :exit, _ -> false
  end

  defp polled?(_), do: false

  # Mot-clé du kick selon `polled` (= l'agent a déjà appelé get_task) :
  #   - pas encore pollé → `"yop"` : bootstrap-arm, IRRÉDUCTIBLE (seul moyen de démarrer/armer l'agent) ;
  #   - déjà pollé (pod running) → `"wake"` : FALLBACK (le porteur/flag aurait dû livrer), GATÉ par
  #     `:wake_send_keys` (off ⇒ flag-only : on valide le Monitor en isolation, pas de fallback).
  # Le `"yop"` bootstrap n'est JAMAIS gaté (sinon un pod neuf ne démarrerait pas). Mots-clés discriminés
  # ⇒ on sait, en lisant le REPL/les logs, si c'est un kick (démarrage) ou un fallback (Monitor raté).
  defp kick_send(state, polled) do
    case kick_keyword(polled, Application.get_env(:fleet_spawner, :wake_send_keys, true)) do
      nil -> :ok
      key -> do_send_keys(state, key)
    end
  end

  @doc false
  # Décision PURE du mot-clé (testable). `polled` = l'agent a déjà appelé get_task ; `fallback_on?` = knob
  # `:wake_send_keys`. `nil` ⇒ pas de send-keys (flag-only). Le `"yop"` (bootstrap) n'est JAMAIS gaté.
  def kick_keyword(polled, fallback_on?) do
    cond do
      not polled -> "yop"
      fallback_on? -> "wake"
      true -> nil
    end
  end

  defp do_send_keys(state, key) do
    case Fleet.Spawner.PodTmux.send_keys(state.pod_id, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pod #{state.pod_id} kick (#{key}) failed : #{inspect(reason)}")
    end
  end

  defp inject_brief_to_tmux_pod(%{tmux_session: nil} = state), do: state

  defp inject_brief_to_tmux_pod(%{tmux_session: session} = state) when is_binary(session) do
    # Arme (cancel+rearm, 1 seul timer) la boucle de kick ack-driven. Le 1er send-keys sera `yop`
    # (bootstrap : pas encore pollé) ; le SP `agent-worker-base.md` porte le workflow get_task→submit_result.
    arm_kick(state)
  end

  # Le mandat est-il déjà pull par le pod ? « Pull » = la task est dans un état qui
  # PROUVE que claude a appelé get_task : `:assigned | :in_progress | :completed`.
  # Volontairement PAS : `:pending`/`nil` (pas encore pull / pas encore enqueué — on
  # continue de kicker, ce qui couvre aussi la race spawn↔enqueue), ni `:cleared`/`:failed`
  # (kill délibéré / deadline broker — le pod n'a rien pull, ne PAS arrêter le kick sur
  # un faux « pull » ; au pire on kicke jusqu'au cap, harmless, le result_deadline couvre).
  # Best-effort : exception/exit broker → false (on retentera). Sert à ARRÊTER la boucle.
  # Le pod a-t-il une task ACTIVE (pending/assigned/in_progress) là, maintenant ?
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
  # déféré derrière ToolSearch — absent du prompt turn-1 ; cette clé dé-défère + attend la connexion
  # regular-required. La PERMISSION reste mcp__fleet__* dans le cap-profile allowedTools). Le pod
  # soumet via submit_result → le central broadcaste task_queue.task_completed (%Fleet.Event{}) →
  # pod.ex extrait (event-driven).
  # Câblage de Fleet.ProjectBootstrap.Phase.Clone pour les pods porteurs d'un projet
  # (`repo_path`) : le projet EFFECTIF vient du MANDAT (effective_project : opts[:project]
  # injecté par le dispatch ticket->repo) ou du cap_profile statique (pods permanents). Présent :
  # clone le repo dans `<pod_dir>/workspace/` + checkout feature branch ; le cwd du REPL pointe sur
  # ce workspace (maybe_put_pod_cwd -> LCARS_POD_CWD) → l'agent code DANS sa branche (pas dans le
  # pod_dir nu, et le clone est idempotent au respawn).
  #
  # Découplage architectural : Pipeline.WorkspaceProvisioner câble
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

          # Identité git du rôle : pas de `git config` mutable dans le workspace (falsifiable — le pod
          # pourrait l'écraser). L'identité est injectée en env IMMUABLE-par-défaut au lancement
          # (bwrap_launch.sh : GIT_AUTHOR_*/GIT_COMMITTER_* = LCARS-<role> + GIT_CONFIG_GLOBAL
          # /dev/null). La garantie vit côté monde : la gate DeliverableGate rejette au push tout
          # commit hors identité autorisée.

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

      # Un backend RÉEL sans spec MCP est un bug de config — le pod réel parle MCP
      # (le brief instruit submit_result, impossible sans serveur). Refus net
      # (propagé au with do_project → transition_failed) qui rend l'état fautif
      # irreprésentable, plutôt qu'un pod lancé puis bloqué en timeout silencieux.
      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
        # Non-bang + retour {:ok|:error} propagé au with chain do_project
        # (où l'erreur déclenche transition_failed proprement).
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
  # Le bwrap est un SANCTUAIRE — il ne monte que
  # `/usr`, `/etc`, `/sys`, `$POD_DIR`, `$GIT_MIRROR`, le vendor et le sock-dir.
  # `/var/lib/lcars` n'y est PAS monté. Lancer le bridge via son chemin HÔTE
  # (`/var/lib/lcars/bin/...py`) avec un log sous `/var/lib/lcars/` échouerait :
  # DANS le sandbox ce chemin n'existe pas → `bash -c` échoue → le serveur MCP
  # `fleet` ne démarre jamais → le tool `mcp__fleet__get_task` n'est jamais chargé
  # → l'agent improvise du curl et timeout. (Un tel bridge marche en test direct
  # car il tourne sur l'HÔTE, pas dans le sandbox.)
  #
  # Côté N1 (le provisioning) : `bwrap_launch.sh` reste MCP-agnostique (N0).
  # On copie le bridge sous `pod_dir/.lcars/` et on résout les placeholders
  # `{{BRIDGE}}`/`{{BRIDGE_LOG}}` de la spec.
  #
  # ⚠ Piège de relocalisation : poser le path HÔTE (`state.pod_dir = /home/<human>/pods/pod_<id>`) dans
  # le `.mcp-fleet.json` casserait dès lors que bwrap RELOCALISE le pod_dir derrière `/home/.pod`
  # (`sandbox_home`) → le path hôte N'EXISTE PLUS dans le namespace → `bash -c "exec python3 <hôte>.py
  # 2>><hôte>.log"` avorterait au redirect (dossier parent absent) AVANT d'exec python → serveur MCP
  # `fleet` jamais up → 0 tool `mcp__fleet__*`. D'où DEUX chemins distincts : le bridge est COPIÉ sur le
  # path HÔTE (où le spawner écrit), mais le `.mcp-fleet.json` référence le path IN-NAMESPACE
  # (`sandbox_home/.lcars/…`, ce que claude exécute dans le sandbox). Host pods (containment none) :
  # `sandbox_home == state.pod_dir` → identité (rétro-compat stricte). Sans cette séparation, un pod
  # bwrap n'aurait aucun tool `mcp__fleet__*` (le pont ne démarrerait jamais) — donc aucun moyen de
  # puller son mandat ni de soumettre son résultat.
  #
  # Injecte aussi `LCARS_POD_ID` ET `LCARS_POD_CAPABILITY` dans l'env du serveur (le bridge les lit
  # pour corréler `get_task` au bon pod ET prouver son identité au central ; ne pas dépendre de l'héritage
  # env claude→bridge) et force `alwaysLoad:true` (sinon les tools MCP sont déférés derrière ToolSearch,
  # absents du prompt turn-1). La capability est posée ICI, dans l'env du SEUL pont de CE pod : un autre pod
  # ne peut pas la lire (son `.mcp-fleet.json` porte SA propre capability). C'est ce qui rend le pod_id
  # non-suffisant pour usurper — il faut AUSSI le secret, qui ne quitte jamais l'env de son pod.
  defp build_fleet_mcp_entry(spec, state) do
    # HÔTE : où le spawner ÉCRIT réellement le pont (le pod_dir réel sur le disque).
    host_bridge = Path.join([state.pod_dir, ".lcars", "fleet_mcp_bridge.py"])

    # IN-NAMESPACE : ce que claude EXÉCUTE dans le sandbox (pod_dir remappé → /home/.pod en bwrap).
    ns_bridge = Path.join([sandbox_home(state), ".lcars", "fleet_mcp_bridge.py"])
    ns_log = Path.join([sandbox_home(state), ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], host_bridge) do
      args =
        (spec["args"] || [])
        |> Enum.map(fn arg ->
          arg
          |> String.replace("{{BRIDGE}}", ns_bridge)
          |> String.replace("{{BRIDGE_LOG}}", ns_log)
        end)

      pod_env = %{
        "LCARS_POD_ID" => state.pod_id,
        "LCARS_POD_CAPABILITY" => state.capability
      }

      entry =
        spec
        |> Map.drop(["bridge_source"])
        |> Map.put("args", args)
        |> Map.put("alwaysLoad", true)
        |> Map.update("env", pod_env, &Map.merge(&1, pod_env))

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
  # (`turn.flag` touché par la fleet), zéro send-keys de CONTENU (send-keys =
  # kick `yop` + slash-commands uniquement). L'asset vit en `priv/` (résolu app_dir, comme le SP
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
  # Safe FS helpers
  # ============================================================
  # Les variantes bang (File.mkdir_p!, File.write!, File.rename!) raise sur
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
