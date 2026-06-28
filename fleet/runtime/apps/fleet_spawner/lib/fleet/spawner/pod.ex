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
  FS lit un `state.json` snapshot, `recovery_action/1` tranche sur la phase :
  terminale → `:release` (rien à relancer), tout le reste → `:recreate`
  (re-spawn FRESH depuis `:allocate`, session neuve).

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
  `recovery_action/1` sur la phase : terminale → `:release`, sinon →
  `:recreate` (session neuve, from scratch). La recovery ne reprend JAMAIS
  une session morte par `--resume` (= pod zombie, prouvé live).
  """

  # Tous les pods sont `:temporary` (le supervisor ne ressuscite jamais ; la
  # recovery est délibérée). NB : `pod_child_spec/1` (spawner.ex) construit
  # le child_spec explicite et fixe lui aussi `restart: :temporary` — c'est lui
  # qui fait foi au spawn ; cette valeur de module reste alignée par honnêteté.
  use GenServer, restart: :temporary

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.Pod.Events
  alias Fleet.Spawner.Pod.Fs
  alias Fleet.Spawner.Pod.Kick
  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Liveness
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.TaskProbe
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
          # SLOT-FREEZE : un pipe est :publishing entre son submit et la confirmation que son livrable est
          # sur la forge (event deliverable.published). Levee -> pret a reset/re-mandater (etape 4).
          | :publishing

  @type state :: %{
          phase: phase(),
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          ticket_id: String.t(),
          session_id: String.t() | nil,
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
      # Plus de `capability` exposée ici : l'identité du pod n'est plus un secret présenté sur le fil mais
      # le CANAL lui-même — chaque pod a sa socket MCP AF_UNIX, montée dans son seul sandbox (R9). « Quelle
      # socket reçoit » = « quel pod » → le central n'a plus de secret à vérifier (cf. Fleet.MCP.PodSocketAcceptor).
      phase: state.phase,
      conditions: MapSet.to_list(state.conditions),
      # SLOT-FREEZE : le gate du dispatcher distingue un pipe IDLE (re-mandatable) d'un pipe qui TRAVAILLE
      # encore une tache (pending/assigned/in_progress) — sans ca il resetterait un workspace en plein
      # travail. Combine a :publishing pour decider :ready (idle ET dernier livrable confirme sur la forge).
      has_active_task: TaskProbe.pod_has_active_task?(state.pod_id),
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
  # SLOT-FREEZE : reset COLD in-place du workspace d'un pipe RESIDENT pour le ticket suivant (cable par
  # le gate a l'etape 4). PAS de rm_rf (bind mount vivant) — reset --hard base + clean + checkout -B
  # feature/work via ProjectBootstrap.reset_in_place, puis /clear du REPL. Appele quand le pod est :ready
  # (livrable du ticket precedent confirme sur la forge -> le push a deja LU le workspace : reset sur).
  def handle_call({:reprovision_pipe_workspace, project, opts}, _from, state) do
    eff_cap = %{state.cap_profile | spec: Map.put(state.cap_profile.spec, "project", project)}

    case Fleet.ProjectBootstrap.Phase.Clone.reset_in_place(state.pod_dir, eff_cap, opts) do
      {:ok, ws, branch} ->
        _ = Fleet.Spawner.PodTmux.send_keys(state.pod_id, "/clear")

        Logger.info(
          "pod #{state.pod_id} workspace reprovisionne COLD (#{ws} branch=#{branch}) + /clear"
        )

        {:reply, :ok, state}

      {:error, reason} = err ->
        Logger.error("pod #{state.pod_id} reprovision workspace ECHOUE : #{inspect(reason)}")
        {:reply, err, state}
    end
  end

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

  # Teardown GARANTI du backend à la mort du Pod GenServer, quel que soit le chemin d'arrêt. OTP appelle
  # `terminate/2` sur TOUT `{:stop, _, _}` (succès, kill, échec de transition, exit-avant-résultat) ET sur
  # un crash de callback (raise/exit dans un `handle_*`). On NE trappe PAS les exits : ça ne couvrirait QUE
  # le `:shutdown` envoyé par le superviseur (cas où le BEAM s'arrête de toute façon et où `--die-with-parent`
  # fait déjà tomber claude+tmux), au prix de changer la sémantique des liens du process.
  #
  # Les chemins succès (`do_release`) et kill (`handle_call :kill`) appellent DÉJÀ `teardown_backend`
  # explicitement AVANT leur `{:stop}` — on les garde : l'ordre « checkpoint le seed AVANT de tuer le
  # backend » y est co-localisé, et le `:ok` rendu par `kill_pod` y signifie « teardown fait » (sémantique
  # synchrone). `terminate/2` est le FILET pour les autres arrêts (échec de transition, exit-avant-résultat)
  # qui, sinon, laisseraient le backend ORPHELIN vivant : claude continue à brûler l'OAuth et la RAM
  # jusqu'à ce que le reaper périodique le repêche bien plus tard, et seulement s'il tourne. Couvre aussi
  # l'orphelin d'un crash de `handle_*` (bonus du callback OTP).
  #
  # `teardown_backend/1` est idempotent (Port déjà fermé → la garde `Port.info` court-circuite la branche
  # port ; le kill tmux = `kill-server` + `pkill` ancré, no-op sur une cible déjà morte ; `File.rm_rf` ne
  # lève pas sur l'absent), donc le double appel sur les chemins succès/kill est inoffensif. Protégé par
  # rescue/catch : `terminate` ne doit JAMAIS lever, sinon il masque la vraie raison d'arrêt — un échec de
  # teardown est loggé, pas propagé.
  #
  # Le FILET libère AUSSI la socket MCP per-pod du pod (transport AF_UNIX, R9) : la clause `after` la
  # release sur TOUT chemin (succès, kill, échec de transition, crash) — même si `teardown_backend` lève
  # (le `after` court quand même). Sans elle, le fichier socket + son dir per-pod FUITERAIENT à chaque mort
  # (fermer la socket libère le FD, PAS le fichier — même famille de fuite FS que le pod_dir orphelin).
  @impl GenServer
  def terminate(reason, state) do
    teardown_backend(state)
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{Map.get(state, :pod_id)} terminate: teardown a levé (non-fatal ; arrêt=#{inspect(reason)}) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning(
        "pod #{Map.get(state, :pod_id)} terminate: teardown #{kind} (non-fatal ; arrêt=#{inspect(reason)}) — #{inspect(value)}"
      )

      :ok
  after
    # Toujours exécuté (succès OU rescue/catch du teardown) → la socket est libérée même si le teardown
    # backend lève. `release_pod_socket/1` est self-protégé (ne lève jamais) : un raise ici se propagerait
    # hors de `terminate`, ce qui masquerait la vraie raison d'arrêt.
    release_pod_socket(state)
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

    # SLOT-FREEZE : un pipe traite N tickets ; son `ticket_id` fige au SPAWN est stale des le 2e. On ADOPTE
    # le ticket_id de la TACHE complétée (porte par l'event task_completed : payload.ticket_id =
    # completed.ticket_id) -> le livrable (pod_completed_payload -> HopConsumer push HEAD:lcars/issue-N)
    # est attribue a la BONNE brique. Sinon le 2e livrable+ ecrase la branche/PR du 1er ticket (bug
    # hello-buddy : Bob#3 pousse sur la PR de Zorro#4, 2 notes empilees, juges flip-flop).
    state = adopt_task_ticket_id(state, payload)
    {:noreply, Map.put(state, :submitted_result, result), {:continue, :extract}}
  end

  # %Fleet.Event{task_completed} d'un autre pod, ou hors phase :monitoring → ignore.
  def handle_info(%Fleet.Event{source: :task_queue, type: :task_completed}, state),
    do: {:noreply, state}

  # SLOT-FREEZE : le livrable de CE pod est confirme sur la forge (push + PR OK -> le push a deja LU le
  # workspace). On leve :publishing -> le pod est :ready (reset/re-mandate surs, etape 4). Matche par
  # pod_id (bind `pid` des deux cotes). Les deliverable.published d'AUTRES pods -> ignores (catch-all).
  def handle_info(
        %Fleet.Event{type: :"deliverable.published", pod_id: pid},
        %{pod_id: pid} = state
      ) do
    if MapSet.member?(state.conditions, :publishing) do
      Logger.info("pod #{state.pod_id} livrable confirme sur forge -> :ready")
    end

    {:noreply, leave_publishing(state)}
  end

  def handle_info(%Fleet.Event{type: :"deliverable.published"}, state), do: {:noreply, state}

  # Deadline : timeout de RÉPONSE. Au FIRE, on distingue :
  #   - task active (pending/assigned/in_progress) → le pod n'a PAS répondu à temps → échec.
  #   - aucune task active → le pod attendait juste sa prochaine task (idle) ; ce n'est
  #     PAS un timeout de réponse → on laisse lapser, PAS de kill (sinon on re-crée un
  #     idle-kill : tuer un pod sain qui attend du travail). La vérif est à l'instant du
  #     fire (≠ à l'armement) → couvre la race d'enqueue worker ET l'inter-stage pipe d'un coup.
  def handle_info(:result_deadline, %{phase: :monitoring} = state) do
    if TaskProbe.pod_has_active_task?(state.pod_id) do
      transition_failed(state, {:result_timeout, state.pod_id})
    else
      {:noreply, Map.put(state, :result_deadline_ref, nil)}
    end
  end

  def handle_info(:result_deadline, state), do: {:noreply, state}

  # SLOT-FREEZE fail-safe : la confirmation deliverable.published n'est pas arrivee dans le delai (role
  # sans livrable git, ou push KO). On leve :publishing quand meme — sinon le pod resterait jamais-:ready
  # donc jamais re-mandate (wedge). Logge WARNING : une confirmation manquee doit etre visible.
  def handle_info(:publish_deadline, state) do
    if MapSet.member?(state.conditions, :publishing) do
      Logger.warning(
        "pod #{state.pod_id} :publishing -> :ready par DEADLINE (deliverable.published non recu a temps)"
      )
    end

    {:noreply, leave_publishing(state)}
  end

  # Watchdog de LIVENESS (pas de durée). Tick récurrent (workers seulement, armé par
  # arm_result_deadline) : si le pod a BOUGÉ depuis le tick précédent (taille jsonl ↑ OU jiffies CPU ↑)
  # → ré-arme le deadline (repousse le kill) ; sinon → laisse le deadline courir. Résultat : un engineer qui
  # bosse ne timeout JAMAIS ; le `:result_deadline` ne fire que sur silence total. Hors :monitoring → no-op
  # (tick résiduel après transition).
  def handle_info(:liveness_tick, %{phase: :monitoring} = state) do
    sample = Liveness.liveness_sample(state)
    moved? = Liveness.liveness_moved?(Map.get(state, :liveness_sample), sample)
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

      Events.best_effort_broadcast("pod.failed", %{
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
    # l'enqueue du mandat (ms après spawn, par le rail forge-driven) précède largement le 1er kick
    # (+2s) → un worker a déjà son mandat `pending`, un pod permanent a `pod_status == {:ok, nil}`.
    bootstrap? = TaskProbe.no_pending_mandate?(state.pod_id)

    # polled? = l'agent a déjà appelé get_task (ACK in-band). Calculé 1× : sert au bootstrap-stop ET au
    # choix du mot-clé (pas encore pollé = bootstrap-arm "yop" ; déjà pollé = pod running → fallback "wake").
    polled = TaskProbe.polled?(state)
    cap = if bootstrap?, do: Kick.kick_bootstrap_max(), else: Kick.kick_max_attempts()
    retry = if bootstrap?, do: Kick.kick_bootstrap_retry_ms(), else: Kick.kick_retry_ms()

    cond do
      # ACK (pull pour un wake / poll pour un bootstrap, cf. acked?/3) = l'agent a tendu la main →
      # on STOPPE la boucle (cancel timer ; le porteur/flag prend le relais). On se fie à l'ACTE de
      # l'agent (last_poll/pod_status TaskQueue), pas à un proxy host-side (« process watch.sh existe »).
      Kick.acked?(TaskProbe.mandate_pulled?(state.pod_id), bootstrap?, polled) ->
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
        Events.best_effort_broadcast("wake.failed", %{
          "pod_id" => state.pod_id,
          "reason" => {:no_ack, phase},
          "pane" => Fleet.Spawner.PodTmux.capture_pane(state.pod_id)
        })

        {:noreply, cancel_kick(state)}

      Fleet.Spawner.PodTmux.alive?(state.pod_id) ->
        _ = Kick.kick_send(state, polled)
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
         :ok <- Fs.safe_mkdir_p(state.pod_dir),
         :ok <-
           Fs.safe_write(
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
         :ok <- Fs.safe_mkdir_p(lcars_dir),
         # `.claude/` pod-owned = cible du bind creds-only (bwrap_launch). On ne crée QUE le dir,
         # aucun settings.json dedans → 0 hook humain. bwrap y monte `.credentials.json`.
         :ok <- Fs.safe_mkdir_p(pod_claude_dir),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         # CLAUDE.md custom à la RACINE du pod (projet/cwd, non masquée) ; le reste en .lcars/.
         :ok <- Fs.safe_write(Path.join(state.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "settings.json"), pod_settings_json()),
         # creds : plus de copie. Seul `.credentials.json` de l'humain est monté RW par
         # bwrap_launch.sh dans `pod_dir/.claude/` (refresh OAuth natif, écriture en place). `.claude/`
         # reste pod-owned → pas de hook humain. Les fichiers pod sont en .lcars/ + racine pod.
         # Le `.claude.json` (onboarding + remote-control) est écrit par claude_launch.sh
         # (frontière vendor N1) — PAS ici. Une version N0 serait clobberée à l'exec (claude_launch le
         # ré-écrit sans condition) ET porterait de la connaissance vendor dans N0.
         :ok <- Fs.safe_mkdir_p(tickets_dir),
         :ok <-
           Fs.safe_write(
             Path.join(tickets_dir, "#{ticket_id_to_filename(state.ticket_id)}.md"),
             default_brief(state)
           ),
         # Le scaffold ci-dessus est le contexte LISIBLE ; le canal CANONIQUE du mandat est
         # la TaskQueue (`get_task`). Un dispatch stage enqueue AVANT le spawn (StageDispatcher) ; mais
         # `admin.spawn` (lcars spawn --mandate) n'a PAS de dispatcher → sans cet enqueue, `get_task` rend
         # `{done:true}` et le pod reste idle. Idempotent (skip si déjà en file).
         :ok <- maybe_enqueue_mandate(state),
         # Provisionne la socket MCP per-pod AVANT le launch (le bind bwrap échoue si le fichier socket
         # n'existe pas encore). Le chemin host rendu est posé en `LCARS_FLEET_MCP_SOCKET` du `.mcp-fleet.json`
         # (cf. McpProvision). Échec → propagé au `with` → transition_failed (pod sans canal = inutile).
         {:ok, mcp_socket_path} <- ensure_pod_socket(state.pod_id),
         :ok <-
           McpProvision.maybe_provision_mcp_config(
             state.pod_dir,
             LaunchSpec.sandbox_home(state.cap_profile, state.pod_dir),
             state.pod_id,
             mcp_socket_path,
             launch_backend()
           ),
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
  defp read_agent_draft(%Fleet.CapProfile{} = cap) do
    role = Fleet.CapProfile.name(cap)
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
    Application.get_env(:fleet_spawner, :claude_dir) || Path.join(Paths.runtime_home(), ".claude")
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
              LaunchSpec.pod_cwd(state.opts, state.cap_profile, state.pod_dir),
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
        # Creds résolus UNE fois (fail-loud si passwd humain introuvable) : sert au HOME host
        # (`launch_home`, parent du claude_dir) ET à CLAUDE_DIR. Valeur déterministe (config + passwd).
        claude_dir = claude_dir_for(human)

        env =
          state.env_vars
          |> Map.merge(LaunchSpec.skills_plugins_env(state.cap_profile))
          |> Map.merge(
            McpProvision.mcp_channel_env(
              state.pod_id,
              cap_profile_name(state.cap_profile)
            )
          )
          # HOME — dépend du containment.
          #   bwrap (défaut) : HOME=pod_dir (cohérent ; bwrap fait `--setenv HOME` de toute façon,
          #     cette valeur est ignorée sous le sandbox).
          #   none (host)    : HOME = home RÉEL de l'humain → claude lit son `~/.claude` natif. C'est l'auth
          #     `:bind` réalisée NATIVEMENT sur l'hôte (refresh OAuth, full scope, pas de falaise 8h — l'arch
          #     est un pod forever). host_launch.sh ne re-setenv PAS (pas de namespace) : ce HOME EST l'env réel.
          |> Map.put("HOME", LaunchSpec.launch_home(containment, state.pod_dir, claude_dir))
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
          |> Map.put("LCARS_PERMISSION_MODE", LaunchSpec.permission_mode(state.cap_profile))
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
          |> Map.put("CLAUDE_DIR", claude_dir)
          |> maybe_put_vendor_bin(human)
          |> LaunchSpec.maybe_put_pod_cwd(state.opts, state.cap_profile, state.pod_dir)
          # Relocalise le home intra-pod (bwrap only) → bwrap masque le pod_dir réel.
          |> LaunchSpec.maybe_put_sandbox_home(state.cap_profile, state.pod_dir)
          # LCARS_POD_DIR (racine pod vue par l'agent, où vivent watch.sh/turn.flag) n'est PAS posée ici —
          # ce serait du dead code : bwrap_launch `--clearenv` la strippe, et host_launch l'`export`e
          # lui-même (= $POD_DIR). Le SP/watch.sh lisent `${LCARS_POD_DIR:-$HOME}` :
          # host → la var ; bwrap → fallback `$HOME` (= /home/.pod = racine pod).
          # Mounts CATALOGUE (cap-profile-driven) → bwrap_launch les bind. Vide / host_launch = inerte.
          # `system_mounts` préfixe le dir des launchers (install) → claude_launch.sh visible dans le sandbox.
          |> Map.put(
            "LCARS_POD_MOUNTS",
            LaunchSpec.pod_mounts_env(state.cap_profile, claude_launch_path())
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
             :ok <- Fleet.Credentials.Gate.validate(claude_dir_for(human), state.cap_profile) do
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
    case Events.required_broadcast("pod.completed", pod_completed_payload(state, result)) do
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
          # SLOT-FREEZE : enter_publishing -> le pipe est :publishing tant que son livrable n'est pas
          # confirme sur la forge (le HopConsumer le LIT + push en async) ; il n'est pas re-mandatable
          # tant qu'il publie (etape 4), sinon on courserait le push. Leve par deliverable.published.
          |> enter_publishing()
          |> arm_result_deadline()

        {:noreply, new_state}
    end
  end

  # Délègue à la source unique `Fleet.CapProfile.lifetime_scope/1`.
  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  # pod.completed porte le contexte pipeline (pipeline_id+stage) SI le pod est spawné
  # avec ces clés en spawn_opts. C'était le cas avec le moteur RAM `Fleet.Pipeline.Executor`
  # (supprimé) ; plus aucun appelant ne les pose aujourd'hui → en pratique le payload est nu.
  # Conservé : un consommateur qui reçoit un payload nu ignore le contexte pipeline (no-op).
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
        case LaunchSpec.effective_project(state.opts, state.cap_profile) do
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
    case LaunchSpec.rc_project(state.opts, state.cap_profile) do
      nil ->
        :ok

      projet ->
        _ =
          Fleet.Spawner.SeedStore.checkpoint(
            state.pod_dir,
            projet,
            cap_profile_name(state.cap_profile),
            state.session_id
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
  ou phase EN VOL (`:launching`/`:monitoring`/… → la recovery `:recreate` reste
  intacte — on ne touche QUE les tombstones).
  """
  @spec clear_terminal_snapshot(String.t(), Fleet.CapProfile.t(), keyword()) :: :ok
  def clear_terminal_snapshot(pod_id, %Fleet.CapProfile{} = cap_profile, opts \\ [])
      when is_binary(pod_id) and is_list(opts) do
    state_fs_path = Paths.state_fs_path_for(pod_id, cap_profile, opts)

    with {:ok, json} <- File.read(state_fs_path),
         {:ok, %{"phase" => phase_str}} <- Jason.decode(json),
         phase when phase in [:succeeded, :released, :killed] <- phase_from_string(phase_str) do
      rm_terminal_artifacts(
        Path.dirname(state_fs_path),
        Paths.pod_dir_for(pod_id, cap_profile, opts)
      )

      Logger.info(
        "Pod.clear_terminal_snapshot #{pod_id}: tombstone :#{phase} effacée (re-spawn FRESH, BL-055)"
      )

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Efface les DEUX dossiers qui composent l'empreinte disque d'un pod terminé : son **state-dir** (le
  dossier du `state.json`) et son **pod_dir** (clone git + `.lcars`/`.claude`/`tickets`) — deux arbres
  distincts. Idempotent (`rm_rf` ne lève pas sur l'absent). Geste PARTAGÉ, un seul site qui sait quels
  deux dossiers forment l'empreinte d'un pod : appelé par `clear_terminal_snapshot/3` (au re-spawn du
  même pod_id) ET par le `PodWarden` (GC périodique des tombstones orphelines jamais re-mandatées). Ne
  lit ni ne vérifie la phase : l'appelant garantit déjà que le pod est terminal. Sûr car le seed
  `--resume` vit ailleurs (seed-store `projects.work/<projet>/pods/`), pas dans le pod_dir.
  """
  @spec rm_terminal_artifacts(String.t(), String.t()) :: :ok
  def rm_terminal_artifacts(state_dir, pod_dir)
      when is_binary(state_dir) and is_binary(pod_dir) do
    _ = File.rm_rf(state_dir)
    _ = File.rm_rf(pod_dir)
    :ok
  end

  defp recover_or_init(args) do
    base = initial_state(args)

    with {:ok, json} <- File.read(base.state_fs_path),
         {:ok, %{"session_id" => sid, "phase" => phase_str}} when is_binary(sid) <-
           Jason.decode(json) do
      phase = phase_from_string(phase_str) || :launching
      apply_recovery(base, recovery_action(phase), sid, phase)
    else
      _ -> base
    end
  end

  @doc """
  Décision de recovery d'un pod (re)spawné dont un `state.json` snapshot existe.
  PURE, fonction de la seule **phase observée**. Sous `:temporary` le supervisor
  ne ressuscite jamais : c'est un (re)spawn délibéré qui appelle `init/1`, et la
  décision est explicite (pas de reprise implicite
  `first_continue_for(:monitoring)` sur un backend mort).

    * `:release`  — phase terminale (`:succeeded`/`:released`/`:killed`) → rien à relancer.
    * `:recreate` — tout le reste (`:failed`/`:pending`/phase EN VOL `:launching`/
                    `:monitoring`/`:extracting`/`:releasing`/ambiguë) → from scratch,
                    session neuve. Une phase en vol sur un (re)spawn = backend mort
                    (sous `:temporary`) : on reroll. On NE tente PAS de `--resume` sur
                    une session morte côté serveur → claude exit → pod zombie (prouvé
                    live) ; la tâche reste en queue et re-drive un REPL neuf.
  """
  @spec recovery_action(atom()) :: :release | :recreate
  def recovery_action(phase) do
    cond do
      phase in [:succeeded, :released, :killed] -> :release
      true -> :recreate
    end
  end

  # :recreate → fresh, nouvelle session (base intacte : session_id neuf, resume=false).
  defp apply_recovery(base, :recreate, _sid, _phase), do: Map.put(base, :recovery, :recreate)

  # :release → terminal ; le pod stoppera proprement (do_release sur backend nil).
  defp apply_recovery(base, :release, _sid, phase) do
    base |> Map.put(:phase, phase) |> Map.put(:recovery, :release)
  end

  # Un pod (re)spawné avec un snapshot suit la décision explicite de
  # `recover_or_init`/`recovery_action` : `:recreate` repart de zéro (`:allocate`,
  # session neuve), `:release` s'arrête (phase terminale, rien à relancer). JAMAIS
  # reprendre en `:monitor` sur un backend mort (le supervisor ne ressuscite jamais
  # sous `:temporary`).
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

  # session_id DÉTERMINISTE hexspeak calculé au spawn pour un rôle catalogué. La SOURCE du QUOI
  # (index de rôle, tier protégé, fleet-level) est le cap-profile (`metadata.role_index`/`protected`/
  # `fleet_level`, lus via `Fleet.CapProfile`) ; `Fleet.Spawner.SessionId.encode/4` n'est qu'un encodeur
  # pur de ce triplet. `opts[:session_id]` (seed explicite, ex. recall arch) PRIME au call-site et
  # court-circuite ce calcul.
  #
  #   * rôle NON catalogué (pas de `role_index` au cap-profile : ad-hoc/inconnu, hors-fleet) — aucune
  #     identité déterministe à reconstruire → `UUID.uuid4()` est légitime.
  #   * fleet-level (arch, gatekeeper) — une seule instance par rôle → repo `0000`, pas de dimension projet.
  #   * project-bound (eng, juges) — l'identité hexspeak EXIGE le repo (sinon collision inter-projet/rework).
  #       - AVEC repo → on minte l'id déterministe.
  #       - SANS repo → on REFUSE (raise). L'absence de repo signifie que la forge n'a pas résolu l'id
  #         (forge down / amont cassé) ; la forge est un organe de LCARS, forge down = stop. On ne fabrique
  #         JAMAIS un UUID random pour masquer ça — un random silencieux donnerait une fausse identité, NON
  #         reconstructible. C'est un filet de dernier recours : le stop propre vit en amont (côté dispatch) ;
  #         ici on fail-loud plutôt que de mentir.
  #
  # Ordre des bras VOLONTAIRE : non-catalogué d'abord (sinon `role_index/1` raise sur un ad-hoc), puis
  # fleet-level (repo 0000), puis repo résolu, puis le refus.
  #
  # Pas de clause non-struct : `cap_profile` est TOUJOURS un `%CapProfile{}` ici (l'unique entrée
  # `Fleet.Spawner.spawn_pod/3` gate sur la struct, et `initial_state`/recovery ne la remplacent jamais) —
  # un state corrompu doit fail-loud par function-clause, pas pondre un UUID de complaisance.
  defp deterministic_session_id(%Fleet.CapProfile{} = cap_profile, opts) do
    repo = Keyword.get(opts, :repo_id)

    cond do
      not Fleet.CapProfile.catalogued?(cap_profile) ->
        UUID.uuid4()

      Fleet.CapProfile.fleet_level?(cap_profile) ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.protected?(cap_profile),
          0x0000
        )

      is_integer(repo) ->
        Fleet.Spawner.SessionId.encode(
          Fleet.CapProfile.role_index(cap_profile),
          Fleet.CapProfile.protected?(cap_profile),
          repo
        )

      true ->
        raise ArgumentError,
              "deterministic_session_id: rôle project-bound #{Fleet.CapProfile.name(cap_profile)} " <>
                "sans repo_id — la forge n'a pas résolu l'id (forge down ?). " <>
                "On ne fabrique pas d'UUID random."
    end
  end

  defp initial_state(args) do
    state_fs_path = Paths.state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = Paths.pod_dir_for(args.pod_id, args.cap_profile, args.opts)

    %{
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      ticket_id: args.ticket_id,
      # Session UUID PRÉ-ALLOUÉ au spawn : `--session-id <uuid>` à la 1ʳᵉ création.
      # Remplace le modèle -p (capture `init_msg["session_id"]`, mort). La recovery
      # depuis state.json ne réutilise PAS ce sid (recreate = session neuve).
      session_id:
        Keyword.get(args.opts, :session_id) ||
          deterministic_session_id(args.cap_profile, args.opts),
      # Timestamp ISO8601 figé à la création du GenServer, persisté tel quel dans
      # state.json.
      started_at: DateTime.utc_now(),
      # défaut false ; SEUL le recall délibéré (`opts[:resume]`) le passe à true →
      # claude `--resume <session_id>` (ressuscite un pod archivé). La recovery sur
      # state.json ne resume jamais (terminale → release, sinon → recreate fresh).
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

  @doc """
  pod_dir d'un pod : `<pod_dir_root>/pod_<pod_id>` (clone git complet + `.lcars`/`.claude`/`tickets`).
  Reconstructible du SEUL pod_id (le cap_profile N'ENTRE PAS dans le calcul) → c'est ce qui rend le GC
  par scan possible (le `PodWarden` dérive le pod_dir à effacer depuis la tombstone). Délégation mince
  vers `Fleet.Spawner.Pod.Paths.pod_dir/2` (résolution de chemins extraite) ; l'API publique
  `Fleet.Spawner.Pod.pod_dir/2` reste appelée par le `PodWarden`, contrat préservé. Config
  `:fleet_spawner, :pod_dir_root`, défaut `~/pods`.
  """
  @spec pod_dir(String.t(), keyword()) :: String.t()
  def pod_dir(pod_id, opts \\ []) when is_binary(pod_id), do: Paths.pod_dir(pod_id, opts)

  @doc """
  Racine FS des snapshots `state.json` (`<root>/<scope>/<pod_id>/state.json`, scope ∈ {pipes,runs,pods}) :
  base SCANNABLE des tombstones, balayée par le `PodWarden` pour GC les pod_dirs orphelins. Délégation
  mince vers `Fleet.Spawner.Pod.Paths.state_fs_root/0` (résolution de chemins extraite) ; l'API publique
  `Fleet.Spawner.Pod.state_fs_root/0` reste appelée par le `PodWarden`, contrat préservé. Config
  `:fleet_spawner, :state_fs_root`, défaut `~/.lcars/state`.
  """
  @spec state_fs_root() :: String.t()
  def state_fs_root, do: Paths.state_fs_root()

  # Accesseur UNIQUE du rôle (= metadata.name) pour TOUS les sites du pod (launch/payload/brief/
  # persistance state.json) : sans cette source unique, des défauts divergents inlinés ("engineer"
  # côté launch, "unknown" côté state) mésattribueraient silencieusement un profil sans name tout le
  # hop. Délègue à la SOURCE UNIQUE `Fleet.CapProfile.name/1`, qui RAISE si le name est absent/vide —
  # PAS de défaut fabriqué : un cap-profile sans name est un état que le domaine interdit (le
  # `minLength:1` du schema le garantit déjà à load). Pas de clause catch-all non-struct : `state.cap_profile`
  # est TOUJOURS un `%CapProfile{}` (l'unique entrée `Fleet.Spawner.spawn_pod/3` gate sur la struct, et
  # `initial_state`/recovery ne la remplacent jamais) — un state corrompu doit fail-loud par function-clause.
  defp cap_profile_name(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.name(cap)

  # `metadata.containment` ∈ {"bwrap","none"} (défaut conservateur "bwrap").
  # "none" = host_native (architect, starfleet) → host_launch.sh (PAS de sandbox) ; sinon la
  # chaîne bwrap. Lu ICI, sur le chemin de lancement (sinon `do_launch` bwrapperait tout aveuglément).
  # Délègue à la SOURCE UNIQUE `Fleet.CapProfile.containment/1` (même lecture/défaut que l'API spawn qui
  # interdit le host-native) — pas de re-décodage local du champ.
  defp cap_profile_containment(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.containment(cap)
  defp cap_profile_containment(_), do: "bwrap"

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
    Events.best_effort_broadcast("pod.failed", %{
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
      |> arm_managed_timer(
        :result_deadline_ref,
        :result_deadline,
        Liveness.monitor_timeout_ms(state)
      )
      |> schedule_liveness_tick()
    end
  end

  # SLOT-FREEZE : un pipe entre :publishing au submit (condition + deadline fail-safe). La levee
  # (deliverable.published OU deadline) retire la condition et annule le timer. publish_deadline_ms est
  # genereux (> le timeout de push git 30s + marge) : il ne fire QUE si la confirmation n'arrive jamais.
  defp enter_publishing(state) do
    state
    |> add_condition(:publishing)
    |> arm_managed_timer(:publish_deadline_ref, :publish_deadline, publish_deadline_ms())
  end

  defp leave_publishing(state) do
    state
    |> remove_condition(:publishing)
    |> cancel_managed_timer(:publish_deadline_ref)
  end

  defp publish_deadline_ms,
    do: Application.get_env(:fleet_spawner, :publish_deadline_ms, 120_000)

  # SLOT-FREEZE : adopte le ticket_id de la tache complétée (de l'event task_completed) comme ticket
  # courant du pod. Un pipe re-mandate change de brique a chaque tache ; sans ca state.ticket_id resterait
  # celui du spawn -> toutes les attributions (livrable, logs) pointeraient la 1ere brique. Absent/vide ->
  # on garde l'existant (pas de regression sur le one-shot, ou ticket_id == spawn == tache unique).
  defp adopt_task_ticket_id(state, payload) do
    case payload[:ticket_id] || payload["ticket_id"] do
      t when is_binary(t) and t != "" -> %{state | ticket_id: t}
      _ -> state
    end
  end

  defp cancel_result_deadline(state) do
    state
    |> cancel_managed_timer(:result_deadline_ref)
    |> cancel_managed_timer(:liveness_tick_ref)
  end

  defp schedule_liveness_tick(state),
    do:
      arm_managed_timer(
        state,
        :liveness_tick_ref,
        :liveness_tick,
        Liveness.liveness_tick_ms(state)
      )

  defp maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  defp maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  defp maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  # Brief du pod = sa TÂCHE (livrée par l'orchestrateur, modèle PUSH).
  # Le travail vient de `opts[:mandate]` (le rail forge-driven construit le mandat via
  # `Pilot.StageDispatcher.build_mandate` ; ou pod direct via `Fleet.Spawner.spawn_pod` opts).
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

      not TaskProbe.no_pending_mandate?(state.pod_id) ->
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

  # Délègue à la source unique du backend (config + défaut canon vivent dans LaunchBackend) —
  # le spawn et la readiness lisent le MÊME résolveur, pas deux copies du défaut.
  defp launch_backend, do: Fleet.Spawner.LaunchBackend.resolved()

  # SEAM RUNTIME du provisionneur de socket MCP per-pod. `fleet_spawner` est Ring 1, `fleet_mcp` est
  # Ring 3 : une dep mix.exs `fleet_spawner → fleet_mcp` serait une dépendance INVERSÉE (ring bas → ring
  # haut), INTERDITE. On résout donc le module au RUNTIME (`Application.get_env` + `apply`), exactement
  # comme `Fleet.MCP.PodTools` appelle `Fleet.Pilot.ForgeClient`/`ProjectOnboard`/`Fleet.Spawner` : le
  # défaut est un ATOM littéral (pas un `alias`/appel direct) → AUCUNE dep compile-time, donc aucun cycle.
  # L'umbrella démarre toutes les apps → `Fleet.MCP.PodSocketSupervisor` est vivant quand le pod tourne.
  # Override en test : `:mcp_socket_provisioner` = un stub qui rend un chemin SANS créer de vrai socket
  # `/run/lcars/...` (mirror du pattern `launch_backend: StubBackend`).
  defp mcp_socket_provisioner,
    do:
      Application.get_env(:fleet_spawner, :mcp_socket_provisioner, Fleet.MCP.PodSocketSupervisor)

  # ENSURE (do_project, avant le launch) : crée le listener + le fichier socket de CE pod (idempotent côté
  # central) et rend `{:ok, socket_path}` (chemin host). Le fichier DOIT exister avant le bind bwrap.
  defp ensure_pod_socket(pod_id) when is_binary(pod_id) do
    apply(mcp_socket_provisioner(), :ensure_pod_socket, [pod_id])
  end

  # RELEASE (filet terminate/2, clause `after`) : arrête le listener ET retire le fichier socket (idempotent
  # côté central). Self-protégé (rescue/catch → log, rend `:ok`) : il tourne dans l'`after` de `terminate`,
  # un raise s'y propagerait et masquerait la raison d'arrêt. Clause `_state` (pod_id absent) = no-op.
  defp release_pod_socket(%{pod_id: pod_id}) when is_binary(pod_id) do
    _ = apply(mcp_socket_provisioner(), :release_pod_socket, [pod_id])
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{pod_id} release_pod_socket a levé (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning("pod #{pod_id} release_pod_socket #{kind} (non-fatal) — #{inspect(value)}")
      :ok
  end

  defp release_pod_socket(_state), do: :ok

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

  # Boucle de kick (timer géré `:kick_ref`, 1 seul vivant). Politique : 1er tick après
  # kick_first_delay_ms (on laisse le flag porteur livrer d'abord) ; armé au bootstrap (inject_brief) ET à
  # chaque wake (cast :arm_kick) → un wake_pod pendant le bootstrap ne crée pas une 2e boucle. Mécanique
  # FACTORISÉE dans arm_managed_timer/cancel_managed_timer (cf. la deadline de réponse). Les bornes/cadences
  # + la décision/I-O du kick vivent dans `Pod.Kick` ; ici on n'ARME que le timer.
  defp arm_kick(state), do: schedule_kick(state, 0, Kick.kick_first_delay_ms())

  defp schedule_kick(state, n, delay),
    do: arm_managed_timer(state, :kick_ref, {:kick_attempt, n}, delay)

  defp cancel_kick(state), do: cancel_managed_timer(state, :kick_ref)

  # `acked?/3` (décision PURE de stop de la boucle) vit dans `Pod.Kick` ; le handler appelle `Kick.acked?`.
  # Wrapper délégant CONSERVÉ : le test `pod_test.exs` exerce l'API publique `Fleet.Spawner.Pod.acked?/3`.
  @doc false
  defdelegate acked?(pulled?, bootstrap?, polled), to: Kick

  # `kick_keyword/2` (décision PURE du mot-clé) + `kick_send/2`/`do_send_keys/2` (I-O d'envoi) vivent dans
  # `Pod.Kick` ; le handler appelle `Kick.kick_send`. Wrapper délégant CONSERVÉ : le test `pod_test.exs`
  # exerce l'API publique `Fleet.Spawner.Pod.kick_keyword/2`.
  @doc false
  defdelegate kick_keyword(polled, fallback_on?), to: Kick

  defp inject_brief_to_tmux_pod(%{tmux_session: nil} = state), do: state

  defp inject_brief_to_tmux_pod(%{tmux_session: session} = state) when is_binary(session) do
    # Arme (cancel+rearm, 1 seul timer) la boucle de kick ack-driven. Le 1er send-keys sera `yop`
    # (bootstrap : pas encore pollé) ; le SP `agent-worker-base.md` porte le workflow get_task→submit_result.
    arm_kick(state)
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
  # Découplage architectural : c'est `pod.ex` qui câble `ProjectBootstrap` pour les pods
  # avec projet (workspace per-pod). (Le provisioning de workspace per-stage du moteur RAM
  # `Pipeline.WorkspaceProvisioner` est supprimé ; le rail forge-driven épingle la base au clone.)
  # 2 sites callers d'un même mécanisme, paramétré par cap-profile. Le projet EFFECTIF
  # (mandat > statique) est résolu par `LaunchSpec.effective_project/2` (source unique).
  defp maybe_bootstrap_project_workspace(state) do
    project = LaunchSpec.effective_project(state.opts, state.cap_profile)

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
        with :ok <- Fs.safe_write(dst, content) do
          _ = File.chmod(dst, 0o755)
          :ok
        end

      {:error, reason} ->
        {:error, {:watch_asset_unreadable, reason}}
    end
  end
end
