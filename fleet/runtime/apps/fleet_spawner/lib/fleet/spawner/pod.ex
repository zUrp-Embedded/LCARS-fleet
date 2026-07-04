defmodule Fleet.Spawner.Pod do
  @moduledoc """
  `gen_statem` (OTP natif) du cycle de vie d'un pod : la chaîne de boot
  ALLOCATE → … → MONITORING, puis EXTRACTING → RELEASING au résultat.

  ## États (= les anciennes `phase`)

      :allocating → :cleaning → :projecting → :injecting → :launching →
      :monitoring  ⇄  :extracting → :releasing  ──▶ (arrêt :normal, phase :succeeded)
                                                ↑
            (un pod long-lived revient en :monitoring depuis :extracting)

  Toute sortie d'erreur passe par `transition_failed/2` → arrêt `{:shutdown, reason}`
  (le snapshot `state.json` grave alors la phase `failed`). Un `kill` délibéré grave
  `killed`. Sous `:temporary` (child_spec de `spawner.ex`) le superviseur ne ressuscite
  jamais ; la recovery au prochain `init/1` est explicite (cf. `Pod.Recovery`).

  ## La chaîne de boot = un évènement interne `:proceed`

  `init/1` retourne `{:ok, <état de départ>, data, [{:next_event, :internal, :proceed}]}`.
  Chaque état de boot porte `handle_event(:internal, :proceed, <état>, data)` qui exécute
  le travail (en déléguant aux modules `Pod.*`) puis transitionne via
  `{:next_state, suivant, data, [{:next_event, :internal, :proceed}]}`. Les évènements
  internes ont PRIORITÉ sur la boîte aux lettres → toute la cascade de boot s'exécute
  AVANT qu'un appel externe (`:info`/`:kill`) ne soit traité — c'est exactement la
  sémantique de l'ancienne chaîne `handle_continue` (vérifié : un `:enter` ne peut PAS
  émettre `next_event` ni changer d'état sur cette OTP — `bad_state_enter_action` —, donc
  le travail vit dans `:proceed`, pas dans `:enter`).

  Le `:state_enter` n'est utilisé que pour `:monitoring` (souscription au Bus à la 1ʳᵉ
  entrée + armement des watchdogs) : il s'exécute uniformément que l'on entre depuis
  `:launching` (1ᵉʳ cycle) ou depuis `:extracting` (ré-armement d'un pod long-lived).

  ## Conditions

  `data.conditions` (MapSet) accumule les évènements observables franchis :
  `:home_projected`, `:context_injected`, `:process_launched`, `:stream_alive`,
  `:output_extracted`, `:home_released`, plus le FLAG `:publishing` (un pipe git_native
  entre son submit et la confirmation forge `deliverable.published`). `:publishing` reste
  un flag, PAS un état : un pod publishing est fonctionnellement en `:monitoring` (il peut
  recevoir une tâche) ; le flag ne fait que gater le reset/re-brief EXTERNE
  (`pipe_rebrief_state` lit `pod_info.conditions`).

  ## Timers NATIFS (plus de timer maison)

  - `:result_deadline` = **state_timeout de `:monitoring`** : annulé AUTOMATIQUEMENT en
    quittant `:monitoring` (la transition `:monitoring → :extracting` sur `work_item.completed`
    réalise nativement l'invariant « le deadline est annulé à l'arrivée du résultat »).
  - `:liveness` = **generic timeout** récurrent en `:monitoring` (ré-arme le deadline si le
    pod a bougé).
  - `:publish_deadline` = generic timeout (fail-safe du flag `:publishing`).
  - `:kick` = generic timeout (boucle de réveil ack-driven, bornée).

  ## Recovery state FS

  `<state_fs_root>/<scope>/<id>/state.json` écrit aux 4 sites de transition (launch, kill,
  release, fail). Au prochain `init/1`, `recover_or_init` lit le fichier → `Pod.Recovery`
  tranche : phase terminale → `:release` (rien à relancer), tout le reste → `:recreate`
  (from scratch, session neuve). On ne tente JAMAIS `--resume` sur une session morte.
  """

  # `@behaviour :gen_statem` (PAS `use GenServer`). Le `restart: :temporary` ne vient PAS
  # d'ici : `pod_child_spec/1` (spawner.ex) construit le child_spec explicite et fixe
  # `restart: :temporary` — c'est lui qui fait foi au spawn.
  @behaviour :gen_statem

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.Pod.Backend
  alias Fleet.Spawner.Pod.CompletedPayload
  alias Fleet.Spawner.Pod.Events
  alias Fleet.Spawner.Pod.Fs
  alias Fleet.Spawner.Pod.Kick
  alias Fleet.Spawner.Pod.LaunchEnv
  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Liveness
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Recovery
  alias Fleet.Spawner.Pod.Scaffold
  alias Fleet.Spawner.Pod.StateFs
  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.SPBuilder

  # Complétion event-driven : le résultat arrive via l'event Bus
  # `task_queue.work_item.completed` (%Fleet.Event{}, émis par le central sur submit_result), PAS via un fichier.

  @type state_name ::
          :allocating
          | :cleaning
          | :projecting
          | :injecting
          | :launching
          | :monitoring
          | :extracting
          | :releasing

  @type condition ::
          :home_projected
          | :context_injected
          | :process_launched
          | :stream_alive
          | :output_extracted
          | :home_released
          # SLOT-FREEZE : un pipe est :publishing entre son submit et la confirmation que son livrable est
          # sur la forge (event deliverable.published). Levee -> pret a reset/re-briefer (etape 4).
          | :publishing

  @type data :: %{
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          issue_id: String.t(),
          session_id: String.t() | nil,
          # `started_at` ISO8601 figé à la création du Pod, persisté tel quel dans `state.json`.
          started_at: DateTime.t(),
          resume: boolean(),
          cap_profile: Fleet.CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          last_error: term() | nil,
          opts: keyword(),
          # Port owné par le Pod (détection exit + kill en RELEASE).
          port: port() | nil,
          # Résultat reçu via l'event Bus task_queue.work_item.completed (%Fleet.Event{}, complétion).
          submitted_result: map() | nil,
          last_result: map() | nil,
          # Nom de la session tmux du pod (`lcars-pod-<id>` sur le sock PAR-POD, posé par
          # LauncherPortBackend). Sert au kick/wake (PodTmux) et au teardown sock-aware.
          tmux_session: String.t() | nil,
          # Dernier échantillon de liveness (taille jsonl, jiffies CPU) ; nil avant le 1er tick.
          liveness_sample: term()
        }

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Démarre un Pod `gen_statem` pour un nouveau pod éphémère.

  Invoqué par `Fleet.Spawner.spawn_pod/3` via le child_spec passé à
  `DynamicSupervisor.start_child/2`. L'`init/1` enchaîne ensuite la chaîne de boot
  via l'évènement interne `:proceed`.
  """
  @spec start_link(map()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(args) do
    :gen_statem.start_link(name(args.pod_id), __MODULE__, args, [])
  end

  @doc """
  Renvoie le nom registry-via du Pod pour un `pod_id`.

  Utilisé pour `GenServer.call`/`GenServer.cast` ciblés (compatibles `gen_statem`) +
  `kill_pod` lookup (`Fleet.Spawner.Registry`).
  """
  @spec name(String.t()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t()}}
  def name(pod_id) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id}}
  end

  # ============================================================
  # gen_statem callbacks
  # ============================================================

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(args) do
    # `recover_or_init` (via `deterministic_session_id`) RAISE pour un rôle project-bound sans
    # repo_id (forge non résolue) — on ne fabrique JAMAIS un UUID de complaisance. On rend alors
    # `{:stop, {exception, stacktrace}}` : `start_link` renvoie `{:error, {%ArgumentError{}, stack}}`
    # (forme identique à l'ancien GenServer dont l'init_it formatait la même paire — fail-loud, aucun launch).
    try do
      recovered = recover_or_init(args)

      # `continue_to_phase` = l'INVERSE de `Recovery.first_continue_for` : le `:continue` de reprise
      # → le NOM d'état gen_statem de départ. La bijection phase↔continue a sa source unique dans
      # `Pod.Recovery` (les deux sens y sont dérivés d'une seule table).
      start_state = Recovery.continue_to_phase(Recovery.first_continue_for(recovered))
      # `data` = le state map MOINS `phase` (= l'état gen_statem) et `recovery` (consommé ici).
      data = Map.drop(recovered, [:phase, :recovery])
      {:ok, start_state, data, [{:next_event, :internal, :proceed}]}
    rescue
      e -> {:stop, {e, __STACKTRACE__}}
    end
  end

  # ============================================================
  # state_enter — armement de :monitoring (le seul état qui en a besoin)
  # ============================================================

  # On souscrit au Bus à la 1ʳᵉ entrée (depuis :launching) UNIQUEMENT : une re-souscription au
  # retour depuis :extracting (pod long-lived) doublerait les messages. Puis on (ré)arme les
  # watchdogs de réponse (state_timeout :result_deadline + generic timeout :liveness).
  @impl :gen_statem
  def handle_event(:enter, old_state, :monitoring, data) do
    unless old_state == :extracting, do: Bus.subscribe()
    {:keep_state_and_data, arm_result_deadline_actions(data)}
  end

  # Tous les autres états : l'entrée ne fait rien (le travail vit dans `:proceed`).
  def handle_event(:enter, _old_state, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Chaîne de boot — évènement interne :proceed (priorité sur la mailbox)
  # ============================================================

  # ALLOCATE — I/O non-bang via safe_* (erreur → transition_failed clean, pas de crash brutal).
  # `with_resolved_disallowed_tools` peut raise sur baseline corrompue (fail-closed intangible)
  # → catch via safe_resolve_disallowed + transition_failed.
  def handle_event(:internal, :proceed, :allocating, data) do
    cap_profile_path = Path.join(data.pod_dir, ".cap-profile.json")

    with {:ok, resolved} <- safe_resolve_disallowed(data.cap_profile),
         :ok <- gate_cap_profile(resolved),
         :ok <- Fs.safe_mkdir_p(data.pod_dir),
         :ok <-
           Fs.safe_write(
             cap_profile_path,
             Jason.encode!(Map.from_struct(resolved), pretty: true)
           ) do
      {:next_state, :cleaning, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:allocate_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :cleaning, data) do
    # GC d'UUID : avec des session_id DÉTERMINISTES + pod_dir survivant (kill -9 / crash →
    # teardown raté → `safe_mkdir_p` PRÉSERVE le dir en :allocate), un re-spawn en `--session-id`
    # (resume=false) heurterait `Session ID already in use` si un `<uuid>.jsonl` traîne. On le supprime
    # → `--session-id` crée toujours frais. (resume=true → `SeedStore.restore` écrase le jsonl : pas de GC.)
    unless data.resume, do: Scaffold.gc_stale_session_jsonl(data)
    {:next_state, :projecting, data, [{:next_event, :internal, :proceed}]}
  end

  # PROJECT — toutes les I/O dans la chaîne `with` (non-bang) → erreur propagée → transition_failed
  # clean (state.json phase=failed écrit). Modèle issue-driven : le brief est écrit en
  # `issues/<issue_id>.md` (lu comme contenu projet, pas comme injection-prompt) ET pushé en
  # TaskQueue (le pod PULL via le tool MCP get_work_item, déclenché par le mot-clé `yop`).
  def handle_event(:internal, :proceed, :projecting, data) do
    skills_root = Application.get_env(:fleet_spawner, :skills_root, nil)
    repo_md = Path.join(data.pod_dir, "CLAUDE.md.repo-source")

    # `.claude/` est POD-OWNED. bwrap ne bind QUE `.credentials.json` dedans (pas le .claude
    # humain entier). Sinon fuite de hooks : cwd=HOME=POD_DIR, donc les tiers settings
    # `project`/`local` résoudraient dans `$POD_DIR/.claude/` = le `.claude` humain bindé → le
    # settings.json humain (et ses hooks) lu comme settings *projet*. D'où : `.claude/` pod-owned
    # + aucun settings.json dedans → tiers project/local vides → 0 hook humain. Fichiers pod
    # (settings/SP/protocole) en .lcars/ ; CLAUDE.md → racine pod.
    pod_claude_dir = Path.join(data.pod_dir, ".claude")
    lcars_dir = Path.join(data.pod_dir, ".lcars")
    issues_dir = Path.join(data.pod_dir, "issues")

    with {:ok, sp_compose} <-
           SPBuilder.compose(data.cap_profile, [], pod_id: data.pod_id, job_id: data.issue_id),
         {:ok, claude_md} <-
           SPBuilder.compose_claude_md(data.cap_profile, Scaffold.maybe_path(repo_md)),
         {:ok, _skills_paths} <- Scaffold.maybe_filter_skills(data.cap_profile, skills_root),
         {:ok, agent_draft} <- Scaffold.read_agent_draft(data.cap_profile),
         {:ok, protocole_user} <- Scaffold.read_protocole_user(),
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
         :ok <- Fs.safe_write(Path.join(data.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <-
           Fs.safe_write(Path.join(lcars_dir, "settings.json"), Scaffold.pod_settings_json()),
         :ok <- Fs.safe_mkdir_p(issues_dir),
         :ok <-
           Fs.safe_write(
             Path.join(issues_dir, "#{Scaffold.issue_id_to_filename(data.issue_id)}.md"),
             Scaffold.default_brief(data)
           ),
         # Le scaffold ci-dessus est le contexte LISIBLE ; le canal CANONIQUE du brief est la
         # TaskQueue (`get_work_item`). Idempotent (skip si déjà en file). Sans cet enqueue, un
         # `admin.spawn` (sans dispatcher) verrait `get_work_item` rendre `{done:true}` → pod idle.
         :ok <- Scaffold.maybe_enqueue_brief(data),
         # Provisionne la socket MCP per-pod AVANT le launch (le bind bwrap échoue si le fichier
         # socket n'existe pas encore). Échec → propagé au `with` → transition_failed.
         {:ok, mcp_socket_path} <- Backend.ensure_pod_socket(data.pod_id),
         :ok <-
           McpProvision.maybe_provision_mcp_config(
             data.pod_dir,
             LaunchSpec.sandbox_home(data.cap_profile, data.pod_dir),
             data.pod_id,
             mcp_socket_path,
             Backend.launch_backend()
           ),
         :ok <- Scaffold.provision_monitor_watch(data),
         :ok <- Scaffold.maybe_bootstrap_project_workspace(data),
         # Recall délibéré — restaure le seed AVANT le launch (après workspace = cwd réglé).
         :ok <- Scaffold.maybe_recall_restore(data) do
      # SP plus stocké en data (plus en argv) : la SOURCE = .lcars/system-prompt.md (écrit ci-dessus),
      # lu par claude_launch via --system-prompt-file.
      data = add_condition(data, :home_projected)
      {:next_state, :injecting, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:project_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :injecting, data) do
    # Plus de resolve_env OAuth (coffre/RT-env déprécié). Le pod s'authentifie via le claudeDir de
    # l'humain, bindé RW par bwrap_launch.sh (env CLAUDE_DIR → ~/.claude, refresh natif Anthropic).
    env_vars = %{"CLAUDE_DIR" => LaunchEnv.claude_dir()}

    data =
      data
      |> Map.put(:env_vars, env_vars)
      |> add_condition(:context_injected)

    {:next_state, :launching, data, [{:next_event, :internal, :proceed}]}
  end

  def handle_event(:internal, :proceed, :launching, data) do
    # Un crash du Pod ne tue PAS le bwrap/tmux/claude (`--die-with-parent` = BEAM, pas le process
    # gen_statem) → pod ORPHELIN vivant (OAuth+RAM). Avant tout (re)launch, on REAP un éventuel
    # orphelin du même pod_id : no-op pour un pod neuf ; sur recovery (:recreate) ça nettoie le
    # mort-vivant AVANT de relancer (sinon collision sock/process), ce qui rend la recovery viable.
    Backend.reap_orphan_pod(data.pod_id)
    role = cap_profile_name(data.cap_profile)
    containment = cap_profile_containment(data.cap_profile)

    # Le launcher N0 dépend du containment, lu ICI (sinon bwrap aveugle pour tous).
    # "none" (host_native : architect, starfleet) → host_launch.sh (host, sans sandbox) ;
    # sinon la chaîne bwrap.
    launcher_path =
      if containment == "none", do: Backend.host_launch_path(), else: Backend.bwrap_launch_path()

    args = %{
      role: role,
      pod_id: data.pod_id,
      pod_dir: data.pod_dir,
      # Launcher N0 sélectionné par containment (host_launch.sh | bwrap_launch.sh). L'argv reste
      # identique des deux côtés (même contrat <role> <pod_id> <pod_dir> <command...>). Le command
      # opaque (claude_launch.sh …) est claude_launch_path ci-dessous.
      launcher_path: launcher_path,
      claude_launch_path: Backend.claude_launch_path(),
      # SP plus dans l'argv (fuite /proc/cmdline + frôle ARG_MAX) : claude_launch lit
      # pod_dir/.lcars/system-prompt.md via --system-prompt-file (écrit en projecting). C'est la SOURCE.
      session_id: data.session_id
    }

    # Construction de l'env complet + résolution/validation des credentials dans `Pod.LaunchEnv.build/4`.
    # Rend `{:ok, env}` (auth bind posée + identité git de l'humain + porte scope/plan franchie) ou un
    # `{:error, reason}` DÉJÀ taggé (:launch_env_unresolved / :credentials_invalid / :auth_token_required)
    # → transition_failed (même cleanup que les autres échecs launch).
    case LaunchEnv.build(data, role, containment, Backend.claude_launch_path()) do
      {:ok, env} -> do_launch_backend(data, args, env)
      {:error, reason} -> transition_failed(data, reason)
    end
  end

  # EXTRACT — le résultat vient de l'event Bus (data.submitted_result), pas d'un fichier.
  # `pod.completed` est LIFECYCLE load-bearing (le StepRunConsumer en dépend pour finir le step_run).
  # Diffusion via `required_broadcast` : son échec n'est PAS avalé. Si elle échoue, on NE progresse
  # PAS vers release/kill (one-shot) ni vers le re-monitoring qui DROPPE `submitted_result`
  # (long-lived) : le pod RESTE en :monitoring avec son résultat RETENU + deadline ré-armée (par
  # l'enter de :monitoring) → un re-wake re-fire l'extract au lieu d'une complétion ORPHELINE.
  def handle_event(:internal, :proceed, :extracting, data) do
    result = data.submitted_result || %{}

    case Events.required_broadcast("pod.completed", CompletedPayload.build(data, result)) do
      :ok ->
        do_extract_proceed(data, result)

      {:error, _reason} ->
        # Fail-loud (déjà loggé ERROR par required_broadcast). Retour à :monitoring : son enter
        # ré-arme le deadline. submitted_result RETENU (pas de drop) → le re-wake re-déclenche.
        {:next_state, :monitoring, data}
    end
  end

  # RELEASE — tue le pod interactif (Port.close → claude/bwrap/script terminés) puis ARRÊT NORMAL
  # (sinon memory leak du DynamicSupervisor). Sous `:temporary` l'arrêt :normal n'est jamais
  # ressuscité. Pas de clear_for_pod ici — release = succès post-EXTRACT (task déjà complétée).
  # Checkpoint le seed AVANT de tuer le backend (JSONl encore intact).
  def handle_event(:internal, :proceed, :releasing, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :succeeded))
    {:stop, :normal, data}
  end

  # Défensif : un :proceed dans un état qui n'en attend pas (recovery directe en :monitoring, dead
  # path) ne crashe pas — le travail de :monitoring est dans son `:enter`, pas dans `:proceed`.
  def handle_event(:internal, :proceed, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Appels synchrones ({:call, from}) — compatibles GenServer.call
  # ============================================================

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      pod_id: data.pod_id,
      issue_id: data.issue_id,
      # Le RÔLE est gravé au SPAWN (= `metadata.name` du cap-profile), exposé via le Registry. C'est
      # l'identité de rôle AUTHENTIFIÉE (le pod ne peut pas la forger via le wire).
      role: cap_profile_name(data.cap_profile),
      # `phase` = le NOM d'état gen_statem reconstruit pour pod_info (les consommateurs en dépendent :
      # des tests lisent phase, et le dispatcher lit conditions+has_active_task ci-dessous).
      phase: state,
      conditions: MapSet.to_list(data.conditions),
      # SLOT-FREEZE : le gate du dispatcher distingue un pipe IDLE (re-briefable) d'un pipe qui
      # TRAVAILLE encore une tache. Combine a :publishing pour decider :ready.
      has_active_task: TaskProbe.pod_has_active_task?(data.pod_id),
      session_id: data.session_id,
      pod_dir: data.pod_dir,
      state_fs_path: data.state_fs_path,
      last_error: data.last_error,
      last_result: data.last_result,
      # tmux_session : nom de la session tmux du pod (posé par LauncherPortBackend, nil pour
      # StubBackend). Exposé pour Fleet.Spawner.wake_pod/1.
      tmux_session: data.tmux_session
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  # SLOT-FREEZE : reset COLD in-place du workspace d'un pipe RESIDENT pour le issue suivant. PAS de
  # rm_rf (bind mount vivant) — reset --hard base + clean + checkout -B feature/work via
  # ProjectBootstrap.reset_in_place, puis /clear du REPL. Appele quand le pod est :ready (livrable
  # du issue precedent confirme sur la forge -> le push a deja LU le workspace : reset sur).
  def handle_event({:call, from}, {:reprovision_pipe_workspace, project, opts}, _state, data) do
    eff_cap = %{data.cap_profile | spec: Map.put(data.cap_profile.spec, "project", project)}

    case Fleet.ProjectBootstrap.Phase.Clone.reset_in_place(data.pod_dir, eff_cap, opts) do
      {:ok, ws, branch} ->
        _ = Fleet.Spawner.PodTmux.send_keys(data.pod_id, "/clear")

        Logger.info(
          "pod #{data.pod_id} workspace reprovisionne COLD (#{ws} branch=#{branch}) + /clear"
        )

        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, reason} = err ->
        Logger.error("pod #{data.pod_id} reprovision workspace ECHOUE : #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  # kill = transition de release DÉLIBÉRÉE, pas un kill brutal du supervisor. Checkpoint le seed +
  # teardown backend + libère la task (abort, pas succès → clear) + grave phase :killed, puis arrêt
  # :normal en répondant :ok au caller. Le fallback brutal (terminate_child) ne sert que si ce call
  # timeout (cf. kill_pod/1).
  def handle_event({:call, from}, :kill, _state, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    clear_pod_task(data.pod_id)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :killed))
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  # ============================================================
  # Casts — compatibles GenServer.cast
  # ============================================================

  # Ré-armement de la deadline de réponse — déclenché par `wake_pod` quand une nouvelle tâche est
  # assignée à un pod long-lived. Seulement en :monitoring (hors = pas de fenêtre de réponse active).
  def handle_event(:cast, :rearm_deadline, :monitoring, data) do
    {:keep_state_and_data, arm_result_deadline_actions(data)}
  end

  def handle_event(:cast, :rearm_deadline, _state, _data), do: :keep_state_and_data

  # `wake_pod` arme la boucle ack-driven. Le porteur (flag) vient d'être touché ; la boucle est le
  # FALLBACK — elle ne send-keys `"wake"` QUE si le pull n'arrive pas, puis escalade au cap. Le
  # generic timeout :kick à le même nom → (re)l'armer RESTART le timer (un wake pendant le bootstrap
  # ne crée pas une 2e boucle). 1er tick après kick_first_delay_ms (on laisse le flag livrer d'abord).
  def handle_event(:cast, :arm_kick, _state, _data) do
    {:keep_state_and_data, [schedule_kick_action(0, Kick.kick_first_delay_ms())]}
  end

  # ============================================================
  # Timers natifs
  # ============================================================

  # Deadline (= state_timeout de :monitoring) : timeout de RÉPONSE. Au FIRE, on distingue :
  #   - task active (pending/assigned/in_progress) → le pod n'a PAS répondu à temps → échec.
  #   - aucune task active → le pod attendait juste sa prochaine task (idle) ; ce n'est PAS un
  #     timeout de réponse → on laisse lapser, PAS de kill (sinon idle-kill d'un pod sain). La vérif
  #     est à l'instant du fire (≠ à l'armement) → couvre la race d'enqueue worker ET l'inter-step.
  # Le state_timeout, une fois fired, n'est plus armé → pas de re-fire tant que le liveness ne ré-arme pas.
  def handle_event(:state_timeout, :result_deadline, :monitoring, data) do
    if TaskProbe.pod_has_active_task?(data.pod_id) do
      transition_failed(data, {:result_timeout, data.pod_id})
    else
      :keep_state_and_data
    end
  end

  # Watchdog de LIVENESS (generic timeout récurrent, workers seulement). Si le pod a BOUGÉ depuis le
  # tick précédent (taille jsonl ↑ OU jiffies CPU ↑) → ré-arme le deadline (repousse le kill) + le
  # tick ; sinon → re-planifie juste le tick (le deadline state_timeout continue de courir). Résultat :
  # un engineer qui bosse ne timeout JAMAIS ; le deadline ne tombe que sur silence total.
  def handle_event({:timeout, :liveness}, :tick, :monitoring, data) do
    sample = Liveness.liveness_sample(data)
    moved? = Liveness.liveness_moved?(Map.get(data, :liveness_sample), sample)
    data = Map.put(data, :liveness_sample, sample)

    actions =
      if moved?,
        do: arm_result_deadline_actions(data),
        else: [liveness_tick_action(data)]

    {:keep_state, data, actions}
  end

  # Tick résiduel hors :monitoring (generic timeout pas auto-annulé au changement d'état) → no-op.
  def handle_event({:timeout, :liveness}, :tick, _state, _data), do: :keep_state_and_data

  # SLOT-FREEZE fail-safe : la confirmation deliverable.published n'est pas arrivee dans le delai (role
  # sans livrable git, ou push KO). On leve :publishing quand meme — sinon le pod resterait jamais-:ready
  # donc jamais re-brief (wedge). Logge WARNING : une confirmation manquee doit etre visible.
  def handle_event({:timeout, :publish_deadline}, :fire, _state, data) do
    if MapSet.member?(data.conditions, :publishing) do
      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready par DEADLINE (deliverable.published non recu a temps)"
      )
    end

    {:keep_state, leave_publishing(data), [cancel_publish_deadline_action()]}
  end

  # Boucle KICK ack-driven UNIFIÉE (bootstrap + wake-fallback, paramétrée : cap/retry/mot-clé/ACK).
  # Tick borné. Le contrôle = l'ACK de l'agent (`acked?/3`), JAMAIS un proxy :
  #   - ACK (pull pour un wake / poll pour un bootstrap) → cancel le generic timeout :kick ;
  #   - cap sans ACK → broadcast `wake.failed` (escalade ring-propre) + cancel ;
  #   - tmux joignable → kick_send (mot-clé `yop` bootstrap / `wake` fallback) + reschedule ;
  #   - tmux pas encore up → reschedule sans consommer de send-keys.
  # Une erreur send-keys n'interrompt pas le pod (le monitor time-out couvre).
  def handle_event({:timeout, :kick}, {:attempt, n}, _state, %{tmux_session: session} = data)
      when is_binary(session) do
    # Un pod SANS brief en attente (interactif/forever, ou permanent booté à froid) n'a RIEN à
    # puller : ses briefs arrivent plus tard via `wake_pod`. On se contente d'un BOOTSTRAP — réveil
    # du REPL — borné et ESPACÉ. Un worker (brief enqueué au spawn) garde le kick fréquent jusqu'au pull.
    bootstrap? = TaskProbe.no_pending_brief?(data.pod_id)

    # polled? = l'agent a déjà appelé get_work_item (ACK in-band). Calculé 1× : sert au bootstrap-stop ET
    # au choix du mot-clé (pas encore pollé = bootstrap-arm "yop" ; déjà pollé = pod running → "wake").
    polled = TaskProbe.polled?(data)
    cap = if bootstrap?, do: Kick.kick_bootstrap_max(), else: Kick.kick_max_attempts()
    retry = if bootstrap?, do: Kick.kick_bootstrap_retry_ms(), else: Kick.kick_retry_ms()

    cond do
      # ACK = l'agent a tendu la main → on STOPPE la boucle (cancel le generic timeout :kick).
      Kick.acked?(TaskProbe.brief_pulled?(data.pod_id), bootstrap?, polled) ->
        Logger.debug(
          "pod #{data.pod_id} acké (pull/poll) → kick stoppé (porteur prend le relais)"
        )

        {:keep_state_and_data, [cancel_kick_action()]}

      n >= cap ->
        # Cap épuisé = l'agent n'a JAMAIS acké. Ring-propre : on BROADCAST (Ring 1) → un consumer
        # fleet_pilot (Ring 2) `record_or_escalate` → récurrent = `:sp_suspect`.
        phase = if bootstrap?, do: :bootstrap, else: :wake

        Logger.warning(
          "pod #{data.pod_id} kick (#{phase}) abandonné après #{n} tentatives — agent jamais acké → escalade #5.2"
        )

        Events.best_effort_broadcast("wake.failed", %{
          "pod_id" => data.pod_id,
          "reason" => {:no_ack, phase},
          "pane" => Fleet.Spawner.PodTmux.capture_pane(data.pod_id)
        })

        {:keep_state_and_data, [cancel_kick_action()]}

      Fleet.Spawner.PodTmux.alive?(data.pod_id) ->
        _ = Kick.kick_send(data, polled)
        {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}

      true ->
        {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}
    end
  end

  # Pas de tmux_session (StubBackend, ou session disparue/kill race) → pas de kick.
  def handle_event({:timeout, :kick}, {:attempt, _n}, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Évènements Port / Bus (event type :info) + catch-all
  # ============================================================
  #
  # Complétion event-driven : le broker fleet_task_queue broadcast %Fleet.Event{work_item.completed} sur
  # fleet.events. On ne réagit qu'au NÔTRE (pod_id) en :monitoring. Le résultat est arrivé → la
  # transition :monitoring → :extracting ANNULE NATIVEMENT le state_timeout :result_deadline (= l'invariant
  # result_deadline_cancelled) ; on annule en plus le generic timeout :liveness (lui ne s'annule pas
  # au changement d'état). SLOT-FREEZE : on ADOPTE le issue_id de la TACHE complétée (porté par
  # l'event) → le livrable est attribué à la BONNE brique (sinon le 2e livrable écrase la branche/PR du 1er).
  def handle_event(
        :info,
        %Fleet.Event{
          source: :task_queue,
          type: :"work_item.completed",
          pod_id: pid,
          payload: payload
        },
        :monitoring,
        %{pod_id: pid} = data
      ) do
    result = payload[:result] || payload["result"] || %{}

    data =
      data
      |> adopt_task_issue_id(payload)
      |> Map.put(:submitted_result, result)

    {:next_state, :extracting, data,
     [cancel_liveness_action(), {:next_event, :internal, :proceed}]}
  end

  # %Fleet.Event{work_item.completed} d'un autre pod, ou hors :monitoring → ignore.
  def handle_event(
        :info,
        %Fleet.Event{source: :task_queue, type: :"work_item.completed"},
        _state,
        _data
      ),
      do: :keep_state_and_data

  # SLOT-FREEZE : le livrable de CE pod est confirme sur la forge (push + PR OK -> le push a deja LU le
  # workspace). On leve :publishing -> le pod est :ready (reset/re-brief surs, etape 4) + on annule
  # le publish_deadline. Matche par pod_id ; les deliverable.published d'AUTRES pods -> ignores.
  def handle_event(
        :info,
        %Fleet.Event{type: :"deliverable.published", pod_id: pid},
        _state,
        %{pod_id: pid} = data
      ) do
    if MapSet.member?(data.conditions, :publishing) do
      Logger.info("pod #{data.pod_id} livrable confirme sur forge -> :ready")
    end

    {:keep_state, leave_publishing(data), [cancel_publish_deadline_action()]}
  end

  def handle_event(:info, %Fleet.Event{type: :"deliverable.published"}, _state, _data),
    do: :keep_state_and_data

  # Cycle de vie du Port : si le résultat a été extrait (event work_item.completed reçu → :output_extracted),
  # l'exit est l'arrêt normal post-release. Sinon le process est mort SANS soumettre de résultat → échec.
  def handle_event(:info, {port, {:exit_status, exit_code}}, _state, %{port: port} = data)
      when is_port(port) do
    if MapSet.member?(data.conditions, :output_extracted) do
      {:stop, :normal, data}
    else
      # Process mort SANS résultat soumis → task active orpheline. Libère.
      clear_pod_task(data.pod_id)

      Events.best_effort_broadcast("pod.failed", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{data.pod_id} exited before submitting result (exit=#{exit_code})")
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, data}
    end
  end

  # Catch-all silencieux : autres messages info (down, monitor, exit_status d'un port étranger, etc.).
  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  # ============================================================
  # terminate/3 — filet teardown GARANTI (anti-orphelin + anti-fuite socket)
  # ============================================================
  #
  # OTP appelle `terminate/3` sur TOUT `{:stop, _, _}` (succès, kill, échec de transition,
  # exit-avant-résultat) ET sur un crash de callback. Les chemins succès (releasing) et kill
  # appellent DÉJÀ `teardown_backend` explicitement AVANT leur arrêt — on les garde (l'ordre
  # « checkpoint le seed AVANT de tuer le backend » y est co-localisé). `terminate/3` est le FILET
  # pour les autres arrêts (échec de transition, exit-avant-résultat) qui sinon laisseraient le
  # backend ORPHELIN vivant (claude brûle l'OAuth+RAM). `teardown_backend/1` est idempotent (port
  # déjà fermé court-circuité, kill tmux no-op sur cible morte, File.rm_rf ne lève pas sur l'absent),
  # donc le double appel est inoffensif. Protégé par rescue/catch : `terminate` ne doit JAMAIS lever
  # (sinon il masque la vraie raison d'arrêt). Le `after` libère la socket MCP per-pod sur TOUT chemin
  # (même si teardown_backend lève) — sans elle, le fichier socket + son dir per-pod FUITERAIENT.
  @impl :gen_statem
  def terminate(reason, _state, data) do
    Backend.teardown_backend(data)
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown a levé (non-fatal ; arrêt=#{inspect(reason)}) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown #{kind} (non-fatal ; arrêt=#{inspect(reason)}) — #{inspect(value)}"
      )

      :ok
  after
    # Toujours exécuté → la socket est libérée même si teardown_backend lève. `release_pod_socket/1`
    # est self-protégé (ne lève jamais) : un raise ici se propagerait hors de `terminate`.
    Backend.release_pod_socket(data)
  end

  # ============================================================
  # Launch backend
  # ============================================================

  defp do_launch_backend(data, args, env) do
    case Backend.launch_backend().launch(args, env) do
      {:ok, launched} when is_map(launched) ->
        # Extrait le port (LauncherPortBackend l'inclut, StubBackend non). nil-able : un test stub
        # n'a pas de Port → les clauses exit_status ne matchent jamais → comportement legacy préservé.
        port = Map.get(launched, :port)

        # tmux_session posé par LauncherPortBackend (bwrap ET host) ; nil pour StubBackend.
        tmux_session = Map.get(launched, :tmux_session)

        data =
          data
          |> Map.put(:port, port)
          |> Map.put(:tmux_session, tmux_session)
          # session_id PRÉ-ALLOUÉ (data) — pas de capture init_msg (le modèle -p est mort).
          |> Map.put(:session_id, data.session_id)
          |> add_condition(:process_launched)
          |> add_condition(:stream_alive)

        StateFs.write_state_fs(put_phase(data, :monitoring))

        # Brief delivery au pod long-lived RC : PodTmux send-keys sur le sock par-pod (universel,
        # bwrap ET host). Path Stub (tests) : no-op (pas de tmux_session retourné → kick non armé).
        # On arme la boucle de kick ack-driven en ACTION de transition (1er tick = bootstrap "yop").
        {:next_state, :monitoring, data, brief_kick_actions(data)}

      {:error, reason} ->
        transition_failed(data, {:launch_failed, reason})
    end
  end

  # Le 1er send-keys sera `yop` (bootstrap) ; le SP `agent-worker-base.md` porte le workflow
  # get_work_item→submit_result. Pas de tmux_session (StubBackend/kill race) → aucune action.
  defp brief_kick_actions(%{tmux_session: nil}), do: []

  defp brief_kick_actions(%{tmux_session: session}) when is_binary(session),
    do: [schedule_kick_action(0, Kick.kick_first_delay_ms())]

  # ============================================================
  # Extract — progression / payload pod.completed
  # ============================================================

  # Progression normale APRÈS un `pod.completed` diffusé avec succès. Branche selon lifetime_scope :
  #   - `one-shot` : extract → release → arrêt (1 task = 1 vie pod).
  #   - autres (pipe/run/forever) : pod long-lived. Retour à :monitoring (son enter ré-arme le
  #     deadline), reset submitted_result + :output_extracted. Release uniquement sur kill_pod externe
  #     ou timeout deadline. (Extrait du chemin pour qu'un échec de broadcast n'avance JAMAIS ici.)
  defp do_extract_proceed(data, result) do
    data =
      data
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(data.cap_profile) do
      "one-shot" ->
        {:next_state, :releasing, data, [{:next_event, :internal, :proceed}]}

      _other ->
        # Reset :output_extracted au re-monitoring (sinon un crash REPL au cycle 2 est masqué en
        # {:stop, :normal} via la garde du handler exit_status → pod.failed/clear jamais émis).
        # Bus.subscribe pas re-appelé : l'enter de :monitoring ne souscrit que depuis :launching.
        data =
          data
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)

        # SLOT-FREEZE : enter_publishing -> le pipe est :publishing tant que son livrable n'est pas
        # confirme sur la forge (deliverable.published) ; il n'est pas re-briefable tant qu'il publie.
        # Conditionne au livrable git async : un pod payload n'a rien a proteger et n'arme donc pas
        # un deadline jamais leve.
        {data, pub_actions} = maybe_enter_publishing(data)

        # Retour à :monitoring : son `:enter` ré-arme result_deadline + liveness.
        {:next_state, :monitoring, data, pub_actions}
    end
  end

  # Délègue à la source unique `Fleet.CapProfile.lifetime_scope/1`.
  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  # À la mort d'un pod-PROJET (rc_name présent), checkpointe son JSONl de session ACTIF vers le
  # seed-store pour rappel ultérieur (`--resume`). Permanents (sans rc_name) → pas de seed-store.
  # Best-effort (SeedStore ne raise jamais ici).
  defp maybe_checkpoint_seed(data) do
    case LaunchSpec.rc_project(data.opts, data.cap_profile) do
      nil ->
        :ok

      projet ->
        _ =
          Fleet.Spawner.SeedStore.checkpoint(
            data.pod_dir,
            projet,
            cap_profile_name(data.cap_profile),
            data.session_id
          )

        :ok
    end
  end

  # ============================================================
  # Recovery / state FS
  # ============================================================

  defp recover_or_init(args) do
    base = initial_state(args)

    with {:ok, json} <- File.read(base.state_fs_path),
         {:ok, %{"session_id" => sid, "phase" => phase_str}} when is_binary(sid) <-
           Jason.decode(json) do
      phase = Recovery.phase_from_string(phase_str) || :launching
      Recovery.apply_recovery(base, Recovery.recovery_action(phase), sid, phase)
    else
      _ -> base
    end
  end

  # session_id DÉTERMINISTE hexspeak calculé au spawn pour un rôle catalogué. La SOURCE du QUOI
  # (index de rôle, tier protégé, fleet-level) est le cap-profile ; `Fleet.Spawner.SessionId.encode/4`
  # n'est qu'un encodeur pur. `opts[:session_id]` (seed explicite, ex. recall arch) PRIME.
  #
  #   * rôle NON catalogué — `UUID.uuid4()` est légitime.
  #   * fleet-level (arch, gatekeeper) — repo `0000`, pas de dimension projet.
  #   * project-bound (eng, juges) — l'identité hexspeak EXIGE le repo.
  #       - AVEC repo → on minte l'id déterministe.
  #       - SANS repo → on REFUSE (raise) : l'absence de repo signale une forge qui n'a pas résolu
  #         l'id (forge down). On ne fabrique JAMAIS un UUID random pour masquer ça (fausse identité,
  #         non reconstructible). Filet de dernier recours : le stop propre vit en amont (dispatch).
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
    pod_dir = Paths.pod_dir_for(args.pod_id, args.opts)

    %{
      # `phase: :pending` n'est lu que par `Pod.Recovery.first_continue_for/1` dans `init/1` (pour
      # choisir l'état de départ), puis DROPPÉ du data gen_statem (la phase EST l'état).
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      issue_id: args.issue_id,
      # Session UUID PRÉ-ALLOUÉ au spawn : `--session-id <uuid>` à la 1ʳᵉ création. La recovery
      # depuis state.json ne réutilise PAS ce sid (recreate = session neuve).
      session_id:
        Keyword.get(args.opts, :session_id) ||
          deterministic_session_id(args.cap_profile, args.opts),
      # Timestamp ISO8601 figé à la création, persisté tel quel dans state.json.
      started_at: DateTime.utc_now(),
      # défaut false ; SEUL le recall délibéré (`opts[:resume]`) le passe à true → claude
      # `--resume <session_id>`. La recovery sur state.json ne resume jamais.
      resume: Keyword.get(args.opts, :resume, false),
      cap_profile: args.cap_profile,
      env_vars: %{},
      pod_dir: pod_dir,
      state_fs_path: state_fs_path,
      last_error: nil,
      opts: args.opts,
      port: nil,
      submitted_result: nil,
      last_result: nil,
      tmux_session: nil,
      liveness_sample: nil
    }
  end

  # Accesseur UNIQUE du rôle (= metadata.name) pour TOUS les sites du pod. Délègue à la SOURCE
  # UNIQUE `Fleet.CapProfile.name/1`, qui RAISE si le name est absent/vide — PAS de défaut fabriqué.
  defp cap_profile_name(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.name(cap)

  # `metadata.containment` ∈ {"bwrap","none"} (défaut conservateur "bwrap"). "none" = host_native →
  # host_launch.sh (PAS de sandbox) ; sinon la chaîne bwrap. Délègue à la SOURCE UNIQUE
  # `Fleet.CapProfile.containment/1`.
  defp cap_profile_containment(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.containment(cap)

  # Fallback non-struct = le défaut conservateur, lu à l'AUTORITÉ UNIQUE (pas de littéral "bwrap"
  # retapé qui resterait stale si le défaut changeait).
  defp cap_profile_containment(_), do: Fleet.CapProfile.default_containment()

  # ============================================================
  # Helpers
  # ============================================================

  # Reconstruit un map avec `:phase` (l'état gen_statem) pour les modules Pod.* qui en dépendent —
  # `StateFs.write_state_fs/1` lit `state.phase` + `state.conditions`. La phase n'est plus dans
  # `data` (elle EST l'état) : on l'y réinjecte au moment d'écrire le snapshot recovery.
  defp put_phase(data, phase), do: Map.put(data, :phase, phase)

  # Échec de transition : le pod meurt sans relaunch → libérer sa task active (sinon orpheline),
  # graver state.json phase=failed, signaler sur le Bus, puis arrêt `{:shutdown, reason}` (terminate/3
  # est le filet teardown du backend). Jumeau du broadcast `pod.failed` du handler exit_status.
  defp transition_failed(data, reason) do
    Logger.warning("pod #{data.pod_id} failed: #{inspect(reason)}")

    clear_pod_task(data.pod_id)
    data = Map.put(data, :last_error, reason)
    StateFs.write_state_fs(put_phase(data, :failed))

    Events.best_effort_broadcast("pod.failed", %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "reason" => reason
    })

    {:stop, {:shutdown, reason}, data}
  end

  defp add_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.put(&1, condition))
  end

  # Retire une condition. `:output_extracted` DOIT être reset au re-monitoring d'un pod long-lived —
  # sinon un crash REPL au cycle 2 reste masqué en {:stop, :normal} (la garde du handler exit_status
  # reste vraie) → pod.failed/clear jamais émis.
  defp remove_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.delete(&1, condition))
  end

  # Libère la task active d'un pod qui meurt sans l'avoir complétée. Best-effort (non-fatal) : le Pod
  # est sinon découplé de TaskQueue (complétion event-driven) — on ne fait pas crasher la mort d'un
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

  # ============================================================
  # Actions de timer natif (state_timeout + generic timeouts)
  # ============================================================

  # Deadline de RÉPONSE (state_timeout de :monitoring) + watchdog liveness (generic timeout récurrent).
  # Politique préservée : pas d'armement pour un pod `forever` (un permanent n'a pas de fenêtre de
  # réponse bornée ; idle = normal, slow-task légitime, gouverné par kill_pod externe) → on émet les
  # ACTIONS d'annulation (time :infinity) pour garantir l'absence de deadline ET de liveness.
  # Sinon : le deadline N'EST PAS un budget « temps pour finir » — c'est un watchdog de SILENCE. Le
  # `:liveness` ré-arme ce deadline tant que le pod BOUGE → un agent qui bosse ne timeout JAMAIS.
  defp arm_result_deadline_actions(data) do
    if lifetime_scope(data.cap_profile) == "forever" do
      [{:state_timeout, :infinity, :result_deadline}, {{:timeout, :liveness}, :infinity, :tick}]
    else
      [
        {:state_timeout, Liveness.monitor_timeout_ms(data), :result_deadline},
        liveness_tick_action(data)
      ]
    end
  end

  defp liveness_tick_action(data),
    do: {{:timeout, :liveness}, Liveness.liveness_tick_ms(data), :tick}

  # Annule le generic timeout :liveness (un generic timeout NE s'annule PAS au changement d'état,
  # contrairement au state_timeout :result_deadline). Émis sur :monitoring → :extracting.
  defp cancel_liveness_action, do: {{:timeout, :liveness}, :infinity, :tick}

  # ============================================================
  # Publishing (FLAG dans data.conditions) + generic timeout :publish_deadline
  # ============================================================

  # SLOT-FREEZE : seul un pod à livrable git_native a un push async (confirmé par deliverable.published)
  # qu'il faut protéger du reset/re-brief → :publishing. Un pod payload (gatekeeper/architect : pas de
  # push) n'a rien à protéger ; le mettre :publishing armerait un deadline 120s jamais levé → WARNING
  # récurrent + sémantique fausse. Rend `{data, actions}` (la condition + l'armement du publish_deadline).
  defp maybe_enter_publishing(data) do
    if Fleet.CapProfile.deliverable_mode(data.cap_profile) == "git_native" do
      {add_condition(data, :publishing),
       [{{:timeout, :publish_deadline}, publish_deadline_ms(), :fire}]}
    else
      {data, []}
    end
  end

  # La levée (deliverable.published OU deadline) retire la condition ; l'annulation du timer est
  # émise en ACTION par les appelants (cancel_publish_deadline_action/0).
  defp leave_publishing(data), do: remove_condition(data, :publishing)

  defp cancel_publish_deadline_action, do: {{:timeout, :publish_deadline}, :infinity, :fire}

  defp publish_deadline_ms,
    do: Application.get_env(:fleet_spawner, :publish_deadline_ms, 120_000)

  # SLOT-FREEZE : adopte le issue_id de la tache complétée (de l'event work_item.completed) comme issue
  # courant du pod. Un pipe re-brief change de brique a chaque tache ; sans ca state.issue_id
  # resterait celui du spawn -> toutes les attributions pointeraient la 1ere brique. Absent/vide ->
  # on garde l'existant.
  defp adopt_task_issue_id(data, payload) do
    case payload[:issue_id] || payload["issue_id"] do
      t when is_binary(t) and t != "" -> %{data | issue_id: t}
      _ -> data
    end
  end

  # ============================================================
  # Kick (generic timeout :kick) — actions d'armement
  # ============================================================

  # Boucle de kick (generic timeout nommé `:kick`, 1 seul vivant par nom). (Re)l'armer RESTART le
  # timer (un wake_pod pendant le bootstrap ne crée pas une 2e boucle). Les bornes/cadences + la
  # décision/I-O vivent dans `Pod.Kick` ; ici on ne fabrique que l'ACTION de timer.
  defp schedule_kick_action(n, delay), do: {{:timeout, :kick}, delay, {:attempt, n}}

  # Cancel = poser le generic timeout :kick à :infinity (= pas de timer).
  defp cancel_kick_action, do: {{:timeout, :kick}, :infinity, {:attempt, 0}}

  defp safe_resolve_disallowed(cap_profile) do
    {:ok, Fleet.CapProfile.with_resolved_disallowed_tools(cap_profile)}
  rescue
    e -> {:error, {:baseline_corrupt, Exception.message(e)}}
  end

  # Porte de containment (dont le deny des server-tools natifs Anthropic) câblée au boundary spawn.
  # Si `validate/1` (toute la sémantique de containment) n'était appelée QUE par les tests, la porte
  # serait creuse : un profil neuf bypasserait silencieusement. Fail-loud : profil invalide → :failed,
  # le pod n'est JAMAIS lancé. Le JSON-schema ne couvre PAS toutes ces règles — d'où validate/1 ici.
  defp gate_cap_profile(resolved) do
    case Fleet.CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end
end
