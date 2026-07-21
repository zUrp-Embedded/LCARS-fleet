defmodule Fleet.Spawner.Pod do
  @moduledoc """
  `gen_statem` (native OTP) for a pod's lifecycle: the boot chain
  ALLOCATE → … → MONITORING, then EXTRACTING → RELEASING on the result.

  ## States (= the former `phase`s)

      :allocating → :cleaning → :projecting → :launching →
      :monitoring  ⇄  :extracting → :releasing  ──▶ (stop :normal, phase :succeeded)
                                                ↑
            (a long-lived pod returns to :monitoring from :extracting)

  Every error exit goes through `transition_failed/2` → `{:shutdown, reason}` stop
  (the `state.json` snapshot then records the `failed` phase). A deliberate `kill` records
  `killed`. Under `:temporary` (child_spec from `spawner.ex`) the supervisor never
  resurrects; recovery at the next `init/1` is explicit (cf. `Pod.Recovery`).

  ## The boot chain = an internal `:proceed` event

  `init/1` returns `{:ok, <start state>, data, [{:next_event, :internal, :proceed}]}`.
  Each boot state carries `handle_event(:internal, :proceed, <state>, data)` that runs
  the work (delegating to the `Pod.*` modules) then transitions via
  `{:next_state, next, data, [{:next_event, :internal, :proceed}]}`. Internal events
  have PRIORITY over the mailbox → the whole boot cascade runs
  BEFORE any external call (`:info`/`:kill`) is handled — this is exactly the
  semantics of the former `handle_continue` chain (verified: an `:enter` CANNOT
  emit `next_event` nor change state on this OTP — `bad_state_enter_action` —, so
  the work lives in `:proceed`, not in `:enter`).

  `:state_enter` is used only for `:monitoring` (Bus subscription on the 1st
  entry + arming the watchdogs): it runs uniformly whether we enter from
  `:launching` (1st cycle) or from `:extracting` (re-arming a long-lived pod).

  ## Conditions

  `data.conditions` (MapSet) accumulates the observable events crossed:
  `:home_projected`, `:process_launched`, `:stream_alive`,
  `:output_extracted`, `:home_released`, plus the `:publishing` FLAG (a git_native pipe
  between its submit and the forge confirmation `deliverable.published`). `:publishing` stays
  a flag, NOT a state: a publishing pod is functionally in `:monitoring` (it can
  receive a task); the flag only gates the EXTERNAL reset/re-brief
  (`pipe_rebrief_state` reads `pod_info.conditions`).

  ## NATIVE timers (no more home-grown timer)

  - `:result_deadline` = **state_timeout of `:monitoring`**: cancelled AUTOMATICALLY on
    leaving `:monitoring` (the `:monitoring → :extracting` transition on `work_item.completed`
    natively realizes the invariant "the deadline is cancelled when the result arrives").
  - `:liveness` = recurring **generic timeout** in `:monitoring` (re-arms the deadline if the
    pod has moved).
  - `:publish_deadline` = generic timeout (fail-safe for the `:publishing` flag).
  - `:kick` = generic timeout (ack-driven wake-up loop, bounded).

  ## FS recovery state

  `<state_fs_root>/<scope>/<id>/state.json` written at the 4 transition sites (launch, kill,
  release, fail). At the next `init/1`, `recover_or_init` reads the file → `Pod.Recovery`
  decides: terminal phase → `:release` (nothing to relaunch), everything else → `:recreate`
  (from scratch, fresh session). We NEVER attempt `--resume` on a dead session.

  **Last revised**: 2026-07-21
  """

  # `@behaviour :gen_statem` (NOT `use GenServer`). The `restart: :temporary` does NOT come
  # from here: `pod_child_spec/1` (spawner.ex) builds the explicit child_spec and sets
  # `restart: :temporary` — that is the authority at spawn.
  @behaviour :gen_statem

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.Pod.Assets
  alias Fleet.Spawner.Pod.Backend
  alias Fleet.Spawner.Pod.Brief
  alias Fleet.Spawner.Pod.CompletedPayload
  alias Fleet.Spawner.Pod.Events
  alias Fleet.Spawner.Pod.Fs
  alias Fleet.Spawner.Pod.Kick
  alias Fleet.Spawner.Pod.LaunchEnv
  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Liveness
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Publishing
  alias Fleet.Spawner.Pod.Recovery
  alias Fleet.Spawner.Pod.Scaffold
  alias Fleet.Spawner.Pod.SessionMint
  alias Fleet.Spawner.Pod.StateFs
  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.SPBuilder

  # Event-driven completion: the result arrives via the Bus event
  # `task_queue.work_item.completed` (%Fleet.Event{}, emitted by the broker on submit_result), NOT via a file.

  @type state_name ::
          :allocating
          | :cleaning
          | :projecting
          | :launching
          | :monitoring
          | :extracting
          | :releasing

  @type condition ::
          :home_projected
          | :process_launched
          | :stream_alive
          | :output_extracted
          | :home_released
          # SLOT-FREEZE: a pipe is :publishing between its submit and the confirmation that its deliverable is
          # on the forge (event deliverable.published). Cleared -> ready to reset/re-brief (step 4).
          | :publishing

  @type data :: %{
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          issue_id: String.t(),
          session_id: String.t() | nil,
          # `started_at` ISO8601 frozen at Pod creation, persisted as-is in `state.json`.
          started_at: DateTime.t(),
          resume: boolean(),
          cap_profile: Fleet.CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          last_error: term() | nil,
          opts: keyword(),
          # Port owned by the Pod (exit detection + kill in RELEASE).
          port: port() | nil,
          # Result received via the Bus event task_queue.work_item.completed (%Fleet.Event{}, completion).
          submitted_result: map() | nil,
          # Bounded retry counter for the pod.completed re-fire.
          extract_retries: non_neg_integer(),
          last_result: map() | nil,
          # Name of the pod's tmux session (`lcars-pod-<id>` on the PER-POD sock, set by
          # LauncherPortBackend). Used for kick/wake (PodTmux) and sock-aware teardown.
          tmux_session: String.t() | nil,
          # Last liveness sample (jsonl size, CPU jiffies); nil before the 1st tick.
          liveness_sample: term()
        }

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Starts a `gen_statem` Pod for a new ephemeral pod.

  Invoked by `Fleet.Spawner.spawn_pod/3` via the child_spec passed to
  `DynamicSupervisor.start_child/2`. `init/1` then chains the boot cascade
  via the internal `:proceed` event.
  """
  @spec start_link(map()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(args) do
    :gen_statem.start_link(name(args.pod_id), __MODULE__, args, [])
  end

  @doc """
  Returns the Pod's registry-via name for a `pod_id`.

  Used for targeted `GenServer.call`/`GenServer.cast` (compatible with `gen_statem`) +
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
    # trap_exit — WITHOUT it, terminate/3 is NOT invoked on an exit signal
    # (DynamicSupervisor.terminate_child fallback of kill_pod, supervisor shutdown): the "GUARANTEED
    # teardown net" documented on terminate/3 had a hole precisely on the supervisor-driven
    # shutdowns → orphan backend (claude burns OAuth+RAM) + leaked MCP socket.
    Process.flag(:trap_exit, true)

    # `recover_or_init` (via `SessionMint.mint`) RAISES for a project-bound role with no
    # repo_id (forge unresolved) — we NEVER fabricate a complacency UUID. We then return
    # `{:stop, {exception, stacktrace}}`: `start_link` returns `{:error, {%ArgumentError{}, stack}}`
    # (same shape as the former GenServer whose init_it formatted the same pair — fail-loud, no launch).
    try do
      recovered = recover_or_init(args)

      # `continue_to_phase` = the INVERSE of `Recovery.first_continue_for`: the resume `:continue`
      # → the start gen_statem state NAME. The phase↔continue bijection has its single source in
      # `Pod.Recovery` (both directions are derived there from a single table).
      start_state = Recovery.continue_to_phase(Recovery.first_continue_for(recovered))
      # `data` = state map MINUS `phase` (= gen_statem state) and `recovery` (consumed here).
      data = Map.drop(recovered, [:phase, :recovery])
      {:ok, start_state, data, [{:next_event, :internal, :proceed}]}
    rescue
      e -> {:stop, {e, __STACKTRACE__}}
    end
  end

  # ============================================================
  # state_enter — arming :monitoring (the only state that needs it)
  # ============================================================

  # We subscribe to the Bus on the 1st entry (from :launching) ONLY: a re-subscription on the
  # return from :extracting (long-lived pod) would double the messages. Then we (re-)arm the
  # response watchdogs (state_timeout :result_deadline + generic timeout :liveness).
  @impl :gen_statem
  def handle_event(:enter, old_state, :monitoring, data) do
    first_entry? = old_state != :extracting
    if first_entry?, do: :ok = Bus.subscribe()

    actions = arm_result_deadline_actions(data)

    # Desktop-slot capture: on the FIRST entry into :monitoring (post-launch), if this pod is
    # RC-visible, arm a bounded poll that persists its `bridge_status` once claude has registered
    # → the slot re-attaches next boot (SeedStore.capture_slot_bridge). A no-RC pod never registers
    # → never armed. Once per boot suffices (the slot is stable for the process lifetime).
    actions =
      if first_entry? and Fleet.CapProfile.remote_control?(data.cap_profile),
        do: [schedule_capture_action(0, capture_slot_first_delay_ms()) | actions],
        else: actions

    {:keep_state_and_data, actions}
  end

  # All other states: entry does nothing (the work lives in `:proceed`).
  def handle_event(:enter, _old_state, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Boot chain — internal :proceed event (priority over the mailbox)
  # ============================================================

  # ALLOCATE — non-bang I/O via safe_* (error → clean transition_failed, no brutal crash).
  # `with_resolved_disallowed_tools` may raise on a corrupt baseline (fail-closed, non-bypassable)
  # → caught via safe_resolve_disallowed + transition_failed.
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
    # UUID GC: with DETERMINISTIC session_ids + a surviving pod_dir (kill -9 / crash →
    # failed teardown → `safe_mkdir_p` PRESERVES the dir in :allocate), a re-spawn in `--session-id`
    # (resume=false) would hit `Session ID already in use` if a `<uuid>.jsonl` lingers. We delete it
    # → `--session-id` always creates fresh. (resume=true → `SeedStore.restore` overwrites the jsonl: no GC.)
    unless data.resume, do: Scaffold.gc_stale_session_jsonl(data)
    {:next_state, :projecting, data, [{:next_event, :internal, :proceed}]}
  end

  # PROJECT — all the I/O in the `with` chain (non-bang) → error propagated → clean
  # transition_failed (state.json phase=failed written). Issue-driven model: the brief is written to
  # `issues/<issue_id>.md` (read as project content, not as a prompt-injection) AND pushed to
  # TaskQueue (the pod PULLS via the MCP tool get_work_item, triggered by the `yop` keyword).
  def handle_event(:internal, :proceed, :projecting, data) do
    skills_root = Application.get_env(:fleet_spawner, :skills_root, nil)
    repo_md = Path.join(data.pod_dir, "CLAUDE.md.repo-source")

    # `.claude/` is POD-OWNED. bwrap binds ONLY `.credentials.json` inside it (not the whole
    # human `.claude`). Otherwise a hook leak: cwd=HOME=POD_DIR, so the `project`/`local`
    # settings tiers would resolve to `$POD_DIR/.claude/` = the bound human `.claude` → the
    # human settings.json (and its hooks) read as *project* settings. Hence: `.claude/` pod-owned
    # + no settings.json inside → project/local tiers empty → 0 human hook. Pod files
    # (settings/SP/protocole) go in .lcars/; CLAUDE.md → pod root.
    pod_claude_dir = Path.join(data.pod_dir, ".claude")
    lcars_dir = Path.join(data.pod_dir, ".lcars")
    issues_dir = Path.join(data.pod_dir, "issues")

    with {:ok, sp_compose} <-
           SPBuilder.compose(
             data.cap_profile,
             # The role's modop overlays (`spec.modop_set.default`) are composed into the pod's
             # system prompt (F-C146). A modop declared without a bundle →
             # `{:error, {:modop_bundle_missing, _}}` surfaces here (fail-loud: the pod does not launch).
             Fleet.CapProfile.default_modops(data.cap_profile),
             pod_id: data.pod_id,
             job_id: data.issue_id
           ),
         {:ok, claude_md} <-
           SPBuilder.compose_claude_md(data.cap_profile, Assets.maybe_path(repo_md)),
         {:ok, _skills_paths} <- Assets.maybe_filter_skills(data.cap_profile, skills_root),
         {:ok, agent_draft} <- Assets.read_agent_draft(data.cap_profile),
         {:ok, protocole_user} <- Assets.read_protocole_user(),
         :ok <- Fs.safe_mkdir_p(lcars_dir),
         # `.claude/` pod-owned = target of the creds-only bind (bwrap_launch). We create ONLY the dir,
         # no settings.json inside → 0 human hook. bwrap mounts `.credentials.json` there.
         :ok <- Fs.safe_mkdir_p(pod_claude_dir),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         # Custom CLAUDE.md at the pod ROOT (project/cwd, not hidden); the rest in .lcars/.
         :ok <- Fs.safe_write(Path.join(data.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <-
           Fs.safe_write(Path.join(lcars_dir, "settings.json"), Assets.pod_settings_json()),
         :ok <- Fs.safe_mkdir_p(issues_dir),
         :ok <-
           Fs.safe_write(
             Path.join(issues_dir, "#{Brief.issue_id_to_filename(data.issue_id)}.md"),
             Brief.default_brief(data)
           ),
         # The scaffold above is the READABLE context; the CANONICAL channel for the brief is the
         # TaskQueue (`get_work_item`). Idempotent (skip if already queued). Without this enqueue, an
         # `admin.spawn` (no dispatcher) would see `get_work_item` return `{done:true}` → idle pod.
         :ok <- Brief.maybe_enqueue_brief(data),
         # Provision the per-pod MCP socket BEFORE the launch (the bwrap bind fails if the socket
         # file does not exist yet). Failure → propagated to the `with` → transition_failed.
         {:ok, mcp_socket_path} <-
           McpProvision.ensure_pod_socket(
             data.pod_id,
             Fleet.CapProfile.mcp_fleet_tools(data.cap_profile)
           ),
         :ok <-
           McpProvision.maybe_provision_mcp_config(
             data.pod_dir,
             LaunchSpec.sandbox_home(data.cap_profile, data.pod_dir),
             data.pod_id,
             mcp_socket_path,
             Backend.launch_backend()
           ),
         :ok <- Assets.provision_monitor_watch(data),
         :ok <- Scaffold.maybe_bootstrap_project_workspace(data),
         # Deliberate recall — restores the seed BEFORE the launch (after workspace = cwd set).
         :ok <- Scaffold.maybe_recall_restore(data) do
      # SP no longer stored in data (no longer in argv): the SOURCE = .lcars/system-prompt.md (written above),
      # read by claude_launch via --system-prompt-file.
      data = add_condition(data, :home_projected)
      {:next_state, :launching, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:project_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :launching, data) do
    # A Pod crash does NOT kill the bwrap/tmux/claude (`--die-with-parent` = BEAM, not the
    # gen_statem process) → live ORPHAN pod (OAuth+RAM). Before any (re)launch, we REAP a possible
    # orphan of the same pod_id: no-op for a fresh pod; on recovery (:recreate) it cleans up the
    # undead BEFORE relaunching (otherwise sock/process collision), which makes recovery viable.
    Backend.reap_orphan_pod(data.pod_id)
    role = cap_profile_name(data.cap_profile)
    containment = cap_profile_containment(data.cap_profile)

    # The N0 launcher depends on the containment, read HERE (otherwise bwrap blind for everyone).
    # "none" (host-native, out-of-band interactive session) → host_launch.sh (host, no sandbox);
    # otherwise the bwrap chain. (No canon cap-profile is host-native post-2026-07-19 reorg.)
    launcher_path =
      if containment == "none", do: Backend.host_launch_path(), else: Backend.bwrap_launch_path()

    args = %{
      role: role,
      pod_id: data.pod_id,
      pod_dir: data.pod_dir,
      # N0 launcher selected by containment (host_launch.sh | bwrap_launch.sh). The argv stays
      # identical on both sides (same contract <role> <pod_id> <pod_dir> <command...>). The opaque
      # command (claude_launch.sh …) is claude_launch_path below.
      launcher_path: launcher_path,
      claude_launch_path: Backend.claude_launch_path(),
      # SP no longer in the argv (/proc/cmdline leak + brushes ARG_MAX): claude_launch reads
      # pod_dir/.lcars/system-prompt.md via --system-prompt-file (written in projecting). That is the SOURCE.
      session_id: data.session_id
    }

    # Build the full env + resolve/validate the credentials in `Pod.LaunchEnv.build/4`.
    # Returns `{:ok, env}` (auth bind placed + the human's git identity + login-validity gate passed) or an
    # ALREADY-tagged `{:error, reason}` (:launch_env_unresolved / :credentials_invalid / :git_identity_unresolved)
    # → transition_failed (same cleanup as the other launch failures).
    case LaunchEnv.build(data, role, containment, Backend.claude_launch_path()) do
      {:ok, env} -> do_launch_backend(data, args, env)
      {:error, reason} -> transition_failed(data, reason)
    end
  end

  # EXTRACT — the result comes from the Bus event (data.submitted_result), not from a file.
  # A TWO-HOP RELAY, NOT A REDUNDANCY: `work_item.completed` (broker→pod) is the end-of-MANDATE
  # signal — the event-driven wake of THIS pod out of :monitoring (the deliberate replacement of
  # file polling); `pod.completed` (pod→pilot) is the end-of-STEP, enriched HERE
  # (workspace/base_sha/repo via CompletedPayload — the pod is the ONLY one that knows them).
  # Unifying the two would require either the pod consuming its own event, or re-introducing
  # shared state: the two hops are irreducible. Do NOT "simplify" this relay.
  # Bounded re-fire of pod.completed after a failed broadcast. The 1000ms delay is NOT
  # cosmetic: it keeps the pod ALIVE in :monitoring between retries (never release/kill
  # on an orphan completion) and spaces them; @extract_retry_max caps them before transition_failed.
  @extract_retry_max 5
  @extract_retry_delay_ms 1_000

  # `pod.completed` is load-bearing LIFECYCLE (the StepRunConsumer depends on it to finish the step_run).
  # Broadcast via `required_broadcast`: its failure is NOT swallowed. If it fails, we do NOT progress
  # to release/kill (one-shot) nor to the re-monitoring that DROPS `submitted_result`
  # (long-lived): the pod STAYS in :monitoring with its result RETAINED → a bounded `:extract_retry`
  # timer re-fires the extract (capped at @extract_retry_max, then transition_failed) instead of an
  # ORPHAN completion — never a silent wedge.
  def handle_event(:internal, :proceed, :extracting, data) do
    result = data.submitted_result || %{}

    case Events.required_broadcast("pod.completed", CompletedPayload.build(data, result)) do
      :ok ->
        # Reset the retry counter on every SUCCESSFUL broadcast: a long-lived pod's cycle N must not
        # inherit cycle N-1's retries.
        do_extract_proceed(%{data | extract_retries: 0}, result)

      {:error, _reason} ->
        # Fail-loud (already logged ERROR by required_broadcast). submitted_result RETAINED (no drop).
        n = data.extract_retries

        if n >= @extract_retry_max do
          Logger.error(
            "pod #{data.pod_id} pod.completed UNDELIVERABLE after #{n} retries — result NOT delivered " <>
              "to the step_run → transition_failed (no silent wedge)"
          )

          transition_failed(data, {:pod_completed_undeliverable, n})
        else
          # BOUNDED retry rail: back to :monitoring + a dedicated :extract_retry timer re-fires the
          # extract (the ONLY re-fire path — the broker emits work_item.completed just once, so a
          # missed broadcast would otherwise wedge the pod FOREVER with its result in hand).
          {:next_state, :monitoring, %{data | extract_retries: n + 1},
           [schedule_extract_retry_action()]}
        end
    end
  end

  # RELEASE — kills the interactive pod (Port.close → claude/bwrap/script terminated) then NORMAL STOP
  # (otherwise DynamicSupervisor memory leak). Under `:temporary` the :normal stop is never
  # resurrected. No clear_for_pod here — release = post-EXTRACT success (task already completed).
  # Checkpoint the seed BEFORE killing the backend (JSONl still intact).
  def handle_event(:internal, :proceed, :releasing, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :succeeded))
    {:stop, :normal, data}
  end

  # Defensive: a :proceed in a state that does not expect one (direct recovery into :monitoring, dead
  # path) does not crash — :monitoring's work is in its `:enter`, not in `:proceed`.
  def handle_event(:internal, :proceed, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Synchronous calls ({:call, from}) — GenServer.call-compatible
  # ============================================================

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      pod_id: data.pod_id,
      issue_id: data.issue_id,
      # The ROLE is recorded at SPAWN (= the cap-profile's `metadata.name`), exposed via the Registry. It is
      # the AUTHENTICATED role identity (the pod cannot forge it over the wire).
      role: cap_profile_name(data.cap_profile),
      # The repo the pod is BOUND to (`opts[:repo]`, `owner/name`) — the channel-side identity the MCP
      # delegation tools resolve "the project" from (the pod never names its repo over the wire; it has
      # "the project", nothing else). nil for unbound pods (starfleet, admin).
      repo: Keyword.get(data.opts, :repo),
      # `phase` = the gen_statem state NAME reconstructed for pod_info (consumers depend on it:
      # tests read phase, and the dispatcher reads conditions+has_active_task below).
      phase: state,
      conditions: MapSet.to_list(data.conditions),
      # SLOT-FREEZE: the dispatcher's gate distinguishes an IDLE pipe (re-briefable) from a pipe still
      # WORKING a task. Combined with :publishing to decide :ready.
      has_active_task: TaskProbe.pod_has_active_task?(data.pod_id),
      session_id: data.session_id,
      pod_dir: data.pod_dir,
      state_fs_path: data.state_fs_path,
      last_error: data.last_error,
      last_result: data.last_result,
      # tmux_session: name of the pod's tmux session (set by LauncherPortBackend, nil for
      # StubBackend). Exposed for Fleet.Spawner.wake_pod/1.
      tmux_session: data.tmux_session
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  # SLOT-FREEZE: COLD in-place reset of a RESIDENT pipe's workspace for the next issue. NO
  # rm_rf (live bind mount) — reset --hard base + clean + checkout -B feature/work via
  # ProjectBootstrap.reset_in_place, then /clear the REPL. Called when the pod is :ready (the previous
  # issue's deliverable confirmed on the forge -> the push already READ the workspace: reset is safe).
  def handle_event({:call, from}, {:reprovision_pipe_workspace, project, opts}, _state, data) do
    # cap_profile carrying the EFFECTIVE project (the call's, not the static one) for reset_in_place.
    eff_cap = Fleet.CapProfile.with_project(data.cap_profile, project)

    # F-28: on SUCCESS the fresh project map must ALSO replace the pod's OWN copy
    # (`opts[:project]`) — `CompletedPayload` derives base_sha/gate_base_sha from it. A
    # `keep_state_and_data` here applied the fresh base to the WORKSPACE and threw the map
    # away: every payload of the reused pipe then reported the SPAWN-time base — a LYING
    # provenance input_sha (lived: issue built on 2d70d4a attested as built on b2707cd) and
    # a RECEDED base-ancestor gate (a HEAD rewriting the intermediate brick away would still
    # pass the mechanical wall). On FAILURE the old map stays — the workspace kept the old
    # base, updating the map anyway would be the INVERSE lie (fresh claim, stale disk).
    repinned = %{data | opts: Keyword.put(data.opts, :project, project)}

    case Fleet.ProjectBootstrap.Phase.Clone.reset_in_place(data.pod_dir, eff_cap, opts) do
      {:ok, ws, branch} ->
        # `/clear` is the OTHER load-bearing half of the cold reset (git workspace + REPL context). A failed
        # `/clear` leaves the REPL carrying the PREVIOUS issue's conversation → context BLEED into the next
        # issue — and the "+ /clear" log would lie. We surface it (the workspace IS reset; only the REPL clear
        # failed) rather than swallow + falsely report success. We still proceed (:ok) — the git isolation
        # holds and a tmux hiccup is transient; the bleed is now VISIBLE, not silent.
        case Fleet.Spawner.PodTmux.send_keys(data.pod_id, "/clear") do
          :ok ->
            Logger.info(
              "pod #{data.pod_id} workspace reprovisioned COLD (#{ws} branch=#{branch}) + /clear"
            )

          {:error, reason} ->
            Logger.error(
              "pod #{data.pod_id} workspace reset COLD (#{ws} branch=#{branch}) but REPL /clear FAILED " <>
                "(#{inspect(reason)}) — REPL keeps the previous issue's context (bleed) until re-cleared"
            )
        end

        {:keep_state, repinned, [{:reply, from, :ok}]}

      {:error, reason} = err ->
        Logger.error("pod #{data.pod_id} workspace reprovision FAILED: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  # kill = a DELIBERATE release transition, not a brutal supervisor kill. Checkpoint the seed +
  # teardown backend + release the task (abort, not success → clear) + record phase :killed, then stop
  # :normal replying :ok to the caller. The brutal fallback (terminate_child) is only used if this call
  # times out (cf. kill_pod/1).
  def handle_event({:call, from}, :kill, _state, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    clear_pod_task(data.pod_id)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :killed))
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  # ============================================================
  # Casts — GenServer.cast-compatible
  # ============================================================

  # Re-arming the response deadline — triggered by `wake_pod` when a new task is
  # assigned to a long-lived pod. Only in :monitoring (outside = no active response window).
  def handle_event(:cast, :rearm_deadline, :monitoring, data) do
    {:keep_state_and_data, arm_result_deadline_actions(data)}
  end

  def handle_event(:cast, :rearm_deadline, _state, _data), do: :keep_state_and_data

  # `wake_pod` arms the ack-driven loop. The carrier (flag) has just been poked; the loop is the
  # FALLBACK — it only send-keys `"wake"` IF the pull does not arrive, then escalates at the cap. The
  # :kick generic timeout has the same name → (re-)arming it RESTARTS the timer (a wake during bootstrap
  # does not create a 2nd loop). 1st tick after wake_first_delay_ms — NOT the 2s bootstrap delay:
  # the net must OUTWAIT the carrier's nominal delivery (flag→Monitor→turn→get_work_item takes
  # seconds; at 2s the fallback double-fired on a WORKING rail, live 2026-07-19).
  def handle_event(:cast, :arm_kick, _state, _data) do
    {:keep_state_and_data, [schedule_kick_action(0, Kick.wake_first_delay_ms())]}
  end

  # ============================================================
  # Native timers
  # ============================================================

  # Deadline (= state_timeout of :monitoring): RESPONSE timeout. On FIRE, we distinguish:
  #   - active task (pending/assigned/in_progress) → the pod did NOT respond in time → failure.
  #   - no active task → the pod was just waiting for its next task (idle); this is NOT a
  #     response timeout → we let it lapse, NO kill (otherwise idle-kill of a healthy pod). The check
  #     is at the moment of the fire (≠ at arming) → covers the worker-enqueue race AND the inter-step.
  # The state_timeout, once fired, is no longer armed → no re-fire until the liveness re-arms it.
  def handle_event(:state_timeout, :result_deadline, :monitoring, data) do
    result_deadline_fire(TaskProbe.active_task_state(data.pod_id), data)
  end

  # LIVENESS watchdog (recurring generic timeout, workers only). If the pod has MOVED since the
  # previous tick (jsonl size ↑ OR CPU jiffies ↑) → re-arm the deadline (pushes back the kill) + the
  # tick; otherwise → just reschedule the tick (the state_timeout deadline keeps running). Result:
  # an engineer at work NEVER times out; the deadline only fires on total silence.
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

  # Residual tick outside :monitoring (generic timeout not auto-cancelled on state change) → no-op.
  def handle_event({:timeout, :liveness}, :tick, _state, _data), do: :keep_state_and_data

  # SLOT-FREEZE fail-safe: deliverable.published did not arrive within the deadline. NOT "a role with no git
  # deliverable" — those never arm this deadline (Publishing.maybe_enter_publishing gates on git_native). The
  # real triggers are a LOST emission (the workspace read already happened → safe) or a crashed/stuck completion.
  # Either way the pilot's workspace-git ops are hard-bounded + SIGKILL'd under the deadline (cf. the invariant
  # on Publishing.publish_deadline_ms), so no live reader survives → clearing :publishing and re-enabling reset
  # is safe. We clear anyway — otherwise the pod stays never-:ready thus never re-briefed (wedge). Logs WARNING:
  # a missed confirmation must be visible.
  def handle_event({:timeout, :publish_deadline}, :fire, _state, data) do
    if Publishing.publishing?(data) do
      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready by DEADLINE (deliverable.published not received in time)"
      )
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  # UNIFIED ack-driven KICK loop (bootstrap + wake-fallback, parameterized: cap/retry/keyword/ACK).
  # Bounded tick. The control = the agent's ACK (`acked?/3`), NEVER a proxy:
  #   - ACK (pull for a wake / poll for a bootstrap) → cancel the :kick generic timeout;
  #   - cap without ACK → broadcast `wake.failed` (layer-clean escalation: Bus broadcast, no upward call) + cancel;
  #   - tmux reachable → kick_send (keyword `yop` bootstrap / `wake` fallback) + reschedule;
  #   - tmux not up yet → reschedule without consuming a send-keys.
  # A send-keys error does not interrupt the pod (the monitor time-out covers it).
  def handle_event({:timeout, :kick}, {:attempt, n}, _state, %{tmux_session: session} = data)
      when is_binary(session) do
    # A pod with NO pending brief (interactive/forever, or a permanent cold-booted) has NOTHING to
    # pull: its briefs arrive later via `wake_pod`. We settle for a BOOTSTRAP — waking the REPL —
    # bounded and SPACED OUT. A worker (brief enqueued at spawn) keeps the kick frequent until the pull.
    bootstrap? = TaskProbe.no_pending_brief?(data.pod_id)

    # polled? = the agent has already called get_work_item (in-band ACK). Computed once: used for bootstrap-stop AND
    # for the keyword choice (not polled yet = bootstrap-arm "yop"; already polled = running pod → "wake").
    polled = TaskProbe.polled?(data)
    cap = if bootstrap?, do: Kick.kick_bootstrap_max(), else: Kick.kick_max_attempts()

    # Three cadences, one per situation: bootstrap probe (spaced), worker startup yop-until-pull
    # (frequent — nobody types in a fresh worker tmux), wake FALLBACK on a RUNNING pod (slow —
    # it paces itself BEHIND the carrier, cf. Kick.wake_retry_ms/0).
    retry =
      cond do
        bootstrap? -> Kick.kick_bootstrap_retry_ms()
        polled -> Kick.wake_retry_ms()
        true -> Kick.kick_retry_ms()
      end

    cond do
      # ACK = the agent reached out → we STOP the loop (cancel the :kick generic timeout).
      Kick.acked?(TaskProbe.brief_pulled?(data.pod_id), bootstrap?, polled) ->
        Logger.debug(
          "pod #{data.pod_id} acked (pull/poll) → kick stopped (carrier rail takes over)"
        )

        {:keep_state_and_data, [cancel_kick_action()]}

      # Human-terminal pod (cap-profile `wake_send_keys: false`) with NOTHING pending: a
      # flag-only bootstrap loop has NO action left (every send-keys gated, yop included) and
      # would only burn its cap into a FALSE `wake.failed` escalation — the human/bridge side
      # is the armer of this class (live 2026-07-19: resumed starfleet, `polled?` wiped by the
      # fleet restart). A pod WITH a pending brief keeps the loop: `wake.failed` stays the
      # terminal net of an unpulled mandate.
      bootstrap? and not Kick.profile_send_keys?(data) ->
        Logger.debug(
          "pod #{data.pod_id} bootstrap kick canceled (profile is flag-only, nothing pending)"
        )

        {:keep_state_and_data, [cancel_kick_action()]}

      n >= cap ->
        # Cap exhausted = the agent NEVER acked. Layer-clean: we BROADCAST → a fleet_pilot
        # consumer `record_or_escalate` → recurring = `:sp_suspect`.
        phase = if bootstrap?, do: :bootstrap, else: :wake

        Logger.warning(
          "pod #{data.pod_id} kick (#{phase}) abandoned after #{n} attempts — agent never acked → escalating"
        )

        # JSON-safe payload (the WS edge encodes it raw) WITHOUT losing the dedup bucket:
        # "reason" = stable category ("no_ack" — same IncidentRegistry signature as the raw
        # tuple), "reason_detail" = full term for the human diag.
        {reason, reason_detail} = Fleet.Event.reason_fields({:no_ack, phase})

        Events.lossy_broadcast("wake.failed", %{
          "pod_id" => data.pod_id,
          # issue_id feeds correlation_id (Events.lossy_broadcast derives it from the payload):
          # without it every wake.failed leaves with correlation_id=nil and the :sp_suspect
          # escalation issue comes out without its linked-mandate block.
          "issue_id" => data.issue_id,
          "reason" => reason,
          "reason_detail" => reason_detail,
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

  # No tmux_session (StubBackend, or vanished session/kill race) → no kick.
  def handle_event({:timeout, :kick}, {:attempt, _n}, _state, _data), do: :keep_state_and_data

  # Desktop-slot capture loop (generic timeout `:capture_slot`, RC-visible pods only). Bounded poll
  # of the live jsonl until claude has written its `bridge_status` (RC registration), then persist it
  # to the per-identity sidecar and STOP. Best-effort: a cap without capture gives up quietly (the
  # slot is re-minted + re-captured next boot). Isolated from kick/liveness/deadline — a failure here
  # never touches the pod's core loop.
  def handle_event({:timeout, :capture_slot}, {:attempt, n}, :monitoring, data) do
    case Fleet.Spawner.SeedStore.capture_slot_bridge(data.pod_dir, data.session_id) do
      :ok ->
        Logger.debug(
          "pod #{data.pod_id} Desktop slot captured (bridge_status → sidecar) — stable on next boot"
        )

        {:keep_state_and_data, [cancel_capture_action()]}

      _not_yet ->
        if n + 1 < capture_slot_max() do
          {:keep_state_and_data, [schedule_capture_action(n + 1, capture_slot_retry_ms())]}
        else
          Logger.debug(
            "pod #{data.pod_id} Desktop slot NOT captured after #{n + 1} tries (best-effort; " <>
              "re-mint + re-capture next boot)"
          )

          {:keep_state_and_data, [cancel_capture_action()]}
        end
    end
  end

  # Residual capture tick outside :monitoring (generic timeout not auto-cancelled on state change) → no-op.
  def handle_event({:timeout, :capture_slot}, {:attempt, _n}, _state, _data),
    do: :keep_state_and_data

  # BOUNDED extract-retry timer — the ONLY re-fire of pod.completed after a failed
  # broadcast. Guarded on :monitoring + a non-nil submitted_result: a no-op if a long-lived cycle has
  # meanwhile reset the result (the extract already succeeded or the pod moved on).
  def handle_event({:timeout, :extract_retry}, :fire, :monitoring, %{submitted_result: r} = data)
      when not is_nil(r),
      do: {:next_state, :extracting, data, [{:next_event, :internal, :proceed}]}

  def handle_event({:timeout, :extract_retry}, :fire, _state, _data), do: :keep_state_and_data

  # ============================================================
  # Port / Bus events (event type :info) + catch-all
  # ============================================================
  #
  # Event-driven completion: the fleet_task_queue broker broadcasts %Fleet.Event{work_item.completed} on
  # fleet.events. We only react to OURS (pod_id) in :monitoring. The result has arrived → the
  # :monitoring → :extracting transition NATIVELY CANCELS the :result_deadline state_timeout (= the
  # result_deadline_cancelled invariant); we additionally cancel the :liveness generic timeout (which does not
  # cancel itself on state change). SLOT-FREEZE: we ADOPT the issue_id of the completed TASK (carried by
  # the event) → the deliverable is attributed to the RIGHT brick (otherwise the 2nd deliverable overwrites the branch/PR of the 1st).
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

  # %Fleet.Event{work_item.completed} from another pod, or outside :monitoring → ignore.
  def handle_event(
        :info,
        %Fleet.Event{source: :task_queue, type: :"work_item.completed"},
        _state,
        _data
      ),
      do: :keep_state_and_data

  # SLOT-FREEZE: THIS pod's deliverable is confirmed on the forge (push + PR OK -> the push already READ the
  # workspace). We clear :publishing -> the pod is :ready (reset/re-brief safe, step 4) + we cancel
  # the publish_deadline. Matched by pod_id; deliverable.published from OTHER pods -> ignored.
  def handle_event(
        :info,
        %Fleet.Event{type: :"deliverable.published", pod_id: pid},
        _state,
        %{pod_id: pid} = data
      ) do
    if Publishing.publishing?(data) do
      Logger.info("pod #{data.pod_id} deliverable confirmed on forge -> :ready")
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  def handle_event(:info, %Fleet.Event{type: :"deliverable.published"}, _state, _data),
    do: :keep_state_and_data

  # Port lifecycle: if the result was extracted (work_item.completed event received → :output_extracted),
  # the exit is the normal post-release stop. Otherwise the process died WITHOUT submitting a result → failure.
  def handle_event(:info, {port, {:exit_status, exit_code}}, _state, %{port: port} = data)
      when is_port(port) do
    if MapSet.member?(data.conditions, :output_extracted) do
      {:stop, :normal, data}
    else
      # Process died WITHOUT a submitted result → orphan active task. Release it.
      clear_pod_task(data.pod_id)

      Events.lossy_broadcast("pod.failed", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{data.pod_id} exited before submitting result (exit=#{exit_code})")

      # TOMBSTONE: record state.json phase=:failed BEFORE the stop. Without it the state.json
      # stays at :monitoring (set at launch) → neither clear_terminal_snapshot nor the
      # PodWarden (which only GCs the @terminal_phases) ever reclaims the pod_dir (a full git
      # clone) = a monotonic leak, exactly what the warden exists to kill. Parity with
      # transition_failed (its twin), pod.failed payload unchanged (exit_code kept).
      data = Map.put(data, :last_error, {:exited_before_result, exit_code})
      StateFs.write_state_fs(put_phase(data, :failed))
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, data}
    end
  end

  # Silent catch-all: other info messages (down, monitor, exit_status of a foreign port, etc.).
  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  # 3-STATE decision at the :result_deadline fire, split out (grouped OUTSIDE the handle_event/4
  # clauses) to be testable without a live-vs-unreachable TaskQueue. `:active` = real response timeout →
  # kill; `:idle` = between tasks → lapse (no idle-kill); `:unknown` = broker unverifiable → no-kill
  # (preserved) BUT re-arm, never lapse (a bare lapse orphans a hung pod whose broker blipped at the fire —
  # the liveness only re-arms on movement).
  @doc false
  def result_deadline_fire(:active, data),
    do: transition_failed(data, {:result_timeout, data.pod_id})

  def result_deadline_fire(:idle, _data), do: :keep_state_and_data

  def result_deadline_fire(:unknown, data),
    do: {:keep_state_and_data, arm_result_deadline_actions(data)}

  # ============================================================
  # terminate/3 — GUARANTEED teardown net (anti-orphan + anti-socket-leak)
  # ============================================================
  #
  # OTP calls `terminate/3` on EVERY `{:stop, _, _}` (success, kill, transition failure,
  # exit-before-result) AND on a callback crash. The success (releasing) and kill paths
  # ALREADY call `teardown_backend` explicitly BEFORE their stop — we keep them (the order
  # "checkpoint the seed BEFORE killing the backend" is co-located there). `terminate/3` is the NET
  # for the other stops (transition failure, exit-before-result) that would otherwise leave the
  # backend a live ORPHAN (claude burns OAuth+RAM). `teardown_backend/1` is idempotent (already-closed
  # port short-circuited, kill tmux no-op on a dead target, File.rm_rf does not raise on the absent),
  # so the double call is harmless. Guarded by rescue/catch: `terminate` must NEVER raise
  # (otherwise it masks the real stop reason). The `after` releases the per-pod MCP socket on every
  # path that runs `terminate/3` to completion (even if teardown_backend raises). If the supervisor
  # brutal-kills a wedged teardown (15s shutdown bound exceeded), the `after` never runs — the
  # acceptor, AF_UNIX listener, Registry entry and socket file survive their pod; `Fleet.MCP.SocketWarden`
  # reconciles them against the live pods and releases them (2-tick grace), so the leak is bounded by
  # its tick, not by the next BEAM boot.
  @impl :gen_statem
  def terminate(reason, _state, data) do
    Backend.teardown_backend(data)
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown raised (non-fatal; stop=#{inspect(reason)}) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown #{kind} (non-fatal; stop=#{inspect(reason)}) — #{inspect(value)}"
      )

      :ok
  after
    # Always executed → the socket is released even if teardown_backend raises. `release_pod_socket/1`
    # (Pod.McpProvision — the whole MCP channel lives over there) is self-protected (never raises):
    # a raise here would propagate out of `terminate`.
    McpProvision.release_pod_socket(data)
  end

  # ============================================================
  # Launch backend
  # ============================================================

  defp do_launch_backend(data, args, env) do
    # F-C041 — conformity guard BEFORE dispatch: a misconfigured `:launch_backend` (typo/absent → no
    # `launch/2`) would raise `UndefinedFunctionError` HERE and crash the gen_statem WITH NO
    # transition_failed (orphan task + stale state.json). `launch_backend_conforming/0` folds it to a
    # typed error → clean pod failure (mirror of the MCP provisioner conformity guard).
    with {:ok, backend} <- Backend.launch_backend_conforming(),
         {:ok, launched} when is_map(launched) <- backend.launch(args, env) do
      # Extract the port (LauncherPortBackend includes it, StubBackend does not). nil-able: a stub test
      # has no Port → the exit_status clauses never match → legacy behavior preserved.
      port = Map.get(launched, :port)

      # tmux_session set by LauncherPortBackend (bwrap AND host); nil for StubBackend.
      tmux_session = Map.get(launched, :tmux_session)

      data =
        data
        |> Map.put(:port, port)
        |> Map.put(:tmux_session, tmux_session)
        # PRE-ALLOCATED session_id (data) — no init_msg capture (the -p model is dead).
        |> Map.put(:session_id, data.session_id)
        |> add_condition(:process_launched)
        |> add_condition(:stream_alive)

      StateFs.write_state_fs(put_phase(data, :monitoring))

      # Brief delivery to the long-lived RC pod: PodTmux send-keys on the per-pod sock (universal,
      # bwrap AND host). Stub path (tests): no-op (no tmux_session returned → kick not armed).
      # We arm the ack-driven kick loop as a transition ACTION (1st tick = bootstrap "yop").
      {:next_state, :monitoring, data, brief_kick_actions(data)}
    else
      # Guard misconfig `{:launch_backend_misconfigured, _}` OR launch `{:error, _}` → both fail the pod
      # cleanly via transition_failed (no UndefinedFunctionError crash, no orphaned task).
      {:error, reason} -> transition_failed(data, {:launch_failed, reason})
    end
  end

  # The 1st send-keys will be `yop` (bootstrap); the role's SP (`core/runtime-contract` block) carries the
  # get_work_item→submit_result workflow. No tmux_session (StubBackend/kill race) → no action.
  defp brief_kick_actions(%{tmux_session: nil}), do: []

  defp brief_kick_actions(%{tmux_session: session}) when is_binary(session),
    do: [schedule_kick_action(0, Kick.kick_first_delay_ms())]

  # ============================================================
  # Extract — progression / payload pod.completed
  # ============================================================

  # Normal progression AFTER a `pod.completed` broadcast successfully. Branches by lifetime_scope:
  #   - `one-shot`: extract → release → stop (1 task = 1 pod life).
  #   - others (pipe/run/forever): long-lived pod. Back to :monitoring (its enter re-arms the
  #     deadline), reset submitted_result + :output_extracted. Release only on external kill_pod
  #     or deadline timeout. (Pulled out of the path so a broadcast failure NEVER advances here.)
  defp do_extract_proceed(data, result) do
    data =
      data
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(data.cap_profile) do
      "one-shot" ->
        {:next_state, :releasing, data, [{:next_event, :internal, :proceed}]}

      _other ->
        # Reset :output_extracted on re-monitoring (otherwise a REPL crash on cycle 2 is masked as
        # {:stop, :normal} via the exit_status handler's guard → pod.failed/clear never emitted).
        # Bus.subscribe not re-called: :monitoring's enter only subscribes from :launching.
        data =
          data
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)

        # SLOT-FREEZE: enter_publishing -> the pipe is :publishing as long as its deliverable is not
        # confirmed on the forge (deliverable.published); it is not re-briefable while it publishes.
        # Decision + flag + arming of :publish_deadline in `Pod.Publishing` (git_native gate included).
        {data, pub_actions} = Publishing.maybe_enter_publishing(data)

        # Back to :monitoring: its `:enter` re-arms result_deadline + liveness.
        {:next_state, :monitoring, data, pub_actions}
    end
  end

  # Delegates to the single source `Fleet.CapProfile.lifetime_scope/1`.
  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  # At the death of a PROJECT pod (rc_name present), checkpoints its ACTIVE session JSONl to the
  # seed-store for later recall (`--resume`). Permanents (no rc_name) → no seed-store.
  # Non-fatal by contract: SeedStore.checkpoint never raises (it rescues internally, logs warning,
  # returns `{:error, _}` — discarded here); a failed checkpoint loses only the session-memory
  # bonus, the death path proceeds (the work truth lives on the forge).
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

    case File.read(base.state_fs_path) do
      # No prior state.json = a FRESH pod (first boot for this pod_id) → the UNIFIED seed decision
      # (maybe_slot_resume): an RC identity with a live jsonl or a captured graine RESUMES it; else
      # fresh create. ONLY on this branch — a crash-recovery (snapshot below) keeps the fresh-reroll
      # doctrine (never resume a dead pod's accumulated session).
      {:error, :enoent} ->
        maybe_slot_resume(base)

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"session_id" => sid, "phase" => phase_str} = snap} when is_binary(sid) ->
            if Map.get(snap, "boot_id") == Fleet.Spawner.BootEpoch.id() do
              # SAME fleet life: the pod died while this fleet was alive (crash/wedge) →
              # the fresh-reroll recovery doctrine (never resume a dead pod's accumulated session).
              phase = Recovery.phase_from_string(phase_str) || :launching
              Recovery.apply_recovery(base, Recovery.recovery_action(phase), sid, phase)
            else
              # PREVIOUS fleet life (clean stop / fleet crash — the whole BEAM was down): the
              # snapshot is STALE, nothing was mid-flight in THIS life → the unified seed decision
              # applies exactly as on a first boot (live jsonl → resume in place; graine → resume;
              # else fresh). Live scar 2026-07-19: without this, every clean reboot fell into
              # :recreate and the slot/context never came back.
              Logger.info(
                "pod #{base.pod_id} recover: state.json from a PREVIOUS fleet life " <>
                  "(stale epoch) → unified seed decision (not a crash recovery)"
              )

              maybe_slot_resume(base)
            end

          # state.json PRESENT but CORRUPT/incomplete (bad JSON, missing session_id/phase) = a broken
          # recovery point. We fresh-init (cannot recover), but LOUD (error = real loss: the durable
          # recovery point is gone), like the TaskQueue emits `state.corrupt` — a silent fresh init would
          # masquerade the data loss as a normal boot.
          _ ->
            Logger.error(
              "pod #{base.pod_id} recover: state.json PRESENT but CORRUPT at #{base.state_fs_path} " <>
                "— fresh init (durable recovery point lost)"
            )

            base
        end

      # File present but UNREADABLE (perms/IO) = also a broken recovery point → LOUD, fresh init.
      {:error, reason} ->
        Logger.error(
          "pod #{base.pod_id} recover: state.json UNREADABLE (#{inspect(reason)}) at " <>
            "#{base.state_fs_path} — fresh init"
        )

        base
    end
  end

  defp initial_state(args) do
    state_fs_path = Paths.state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = Paths.pod_dir_for(args.pod_id, args.opts)

    %{
      # `phase: :pending` = the fresh-boot marker; `Pod.Recovery.first_continue_for/1` matches on
      # `:recovery` ALONE (its fallback clause covers this fresh/no-snapshot shape → :allocate).
      # The field is then DROPPED from the gen_statem data (the phase IS the state).
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      issue_id: args.issue_id,
      # Session UUID PRE-ALLOCATED at spawn: `--session-id <uuid>` on the 1st creation. Recovery
      # from state.json does NOT reuse this sid (recreate = fresh session). The explicit seed
      # (`opts[:session_id]`, e.g. arch recall) TAKES PRECEDENCE over the
      # mint (`Pod.SessionMint`) — but is CAST as a valid UUID first (see resolve_session_id/1).
      session_id: resolve_session_id(args),
      # ISO8601 timestamp frozen at creation, persisted as-is in state.json.
      started_at: DateTime.utc_now(),
      # default false; ONLY a deliberate recall (`opts[:resume]`) sets it to true → claude
      # `--resume <session_id>`. Recovery from state.json never resumes.
      resume: Keyword.get(args.opts, :resume, false),
      cap_profile: args.cap_profile,
      env_vars: %{},
      pod_dir: pod_dir,
      state_fs_path: state_fs_path,
      last_error: nil,
      opts: args.opts,
      port: nil,
      submitted_result: nil,
      extract_retries: 0,
      last_result: nil,
      tmux_session: nil,
      liveness_sample: nil
    }
  end

  # UNIFIED seed decision (socle Décision 1, reorg 2026-07-19) — FRESH first-boot only (the caller
  # gates on :enoent). Precedence:
  #   1. explicit recall/resume (opts) → untouched (the deliberate paths stay authoritative);
  #   2. non-RC pod → fresh create (it never captured, nothing to resume);
  #   3. its LIVE jsonl exists in the pod_dir (clean fleet reboot, pod_dir persisted) →
  #      resume IN PLACE: full context back + slot re-attached (the jsonl carries its own RC
  #      identity) — THE per-project arch continuity story, zero restore needed;
  #   4. a captured GRAINE exists for the identity → resume FROM it via the recall machinery
  #      (restore copies it under the uuid): slot back, context empty (F5) — judges/one-shots;
  #   5. nothing → fresh create (first boot ever; the capture seeds the graine for next time).
  defp maybe_slot_resume(base) do
    cond do
      base.resume or Keyword.has_key?(base.opts, :recall_seed_jsonl) ->
        base

      not Fleet.CapProfile.remote_control?(base.cap_profile) ->
        base

      live_jsonl_exists?(base) ->
        %{base | resume: true}

      true ->
        case Fleet.Spawner.SeedStore.slot_graine(base.session_id) do
          {:ok, graine} ->
            %{base | resume: true, opts: Keyword.put(base.opts, :recall_seed_jsonl, graine)}

          :none ->
            base
        end
    end
  end

  # Is the identity's live jsonl already in the pod_dir? (Same path shape as `SeedStore.restore`
  # writes and `--resume <uuid>` reads: `.claude/projects/<slugify(cwd)>/<uuid>.jsonl`.)
  defp live_jsonl_exists?(base) do
    cwd = LaunchSpec.pod_cwd(base.opts, base.cap_profile, base.pod_dir)

    [base.pod_dir, ".claude", "projects", Fleet.Spawner.SeedStore.slugify(cwd), "#{base.session_id}.jsonl"]
    |> Path.join()
    |> File.exists?()
  end

  # The explicit seed (`opts[:session_id]`) PRECEDES the mint but must be a VALID session UUID —
  # an arch recall resumes a real vendor session, and the value is exported to the
  # launcher + persisted for recovery. A present-but-non-UUID seed is a caller/seed corruption: we REFUSE
  # it loud (raise → `init/1` rescue → `{:error, _}` at start_link, no launch), never accept an arbitrary
  # binary as identity nor silently fall back to the mint (that would MASK the corrupt seed with a mint id
  # under a wrong recall/resume intent). Absent seed → the mint (a valid UUID by construction).
  defp resolve_session_id(args) do
    case Keyword.get(args.opts, :session_id) do
      nil ->
        SessionMint.mint(args.cap_profile, args.opts)

      seed ->
        case Fleet.Spawner.SessionId.cast(seed) do
          {:ok, uuid} ->
            uuid

          {:error, :not_uuid_shaped} ->
            raise ArgumentError,
                  "Pod: explicit session_id #{inspect(seed)} is not a valid UUID — a recall/" <>
                    "boot seed must resume a real vendor session; refusing rather than posing a " <>
                    "non-reconstructible identity."
        end
    end
  end

  # SINGLE accessor of the role (= metadata.name) for ALL pod sites. Delegates to the SINGLE
  # SOURCE `Fleet.CapProfile.name/1`, which RAISES if the name is absent/empty — NO fabricated default.
  defp cap_profile_name(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.name(cap)

  # `metadata.containment` ∈ {"bwrap","none"} (conservative default "bwrap"). "none" = host_native →
  # host_launch.sh (NO sandbox); otherwise the bwrap chain. Delegates to the SINGLE SOURCE
  # `Fleet.CapProfile.containment/1`.
  defp cap_profile_containment(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.containment(cap)

  # Non-struct fallback = the conservative default, read from the SINGLE AUTHORITY (no re-typed "bwrap"
  # literal that would go stale if the default changed).
  defp cap_profile_containment(_), do: Fleet.CapProfile.default_containment()

  # ============================================================
  # Helpers
  # ============================================================

  # Rebuilds a map with `:phase` (the gen_statem state) for the Pod.* modules that depend on it —
  # `StateFs.write_state_fs/1` reads `state.phase` + `state.conditions`. The phase is no longer in
  # `data` (it IS the state): we re-inject it when writing the recovery snapshot.
  defp put_phase(data, phase), do: Map.put(data, :phase, phase)

  # Transition failure: the pod dies without relaunch → release its active task (otherwise orphaned),
  # record state.json phase=failed, signal on the Bus, then `{:shutdown, reason}` stop (terminate/3
  # is the backend teardown net). Twin of the `pod.failed` broadcast in the exit_status handler.
  defp transition_failed(data, reason) do
    Logger.warning("pod #{data.pod_id} failed: #{inspect(reason)}")

    clear_pod_task(data.pod_id)
    data = Map.put(data, :last_error, reason)
    StateFs.write_state_fs(put_phase(data, :failed))

    # All callers pass tuple reasons ({:allocate_failed,_}, {:launch_failed,_}, …) — non-JSON
    # terms crash the WS edge. Normalize to the stable category (same IncidentRegistry dedup
    # signature as the tuple: both bucket to elem(0)) + full detail aside.
    {category, reason_detail} = Fleet.Event.reason_fields(reason)

    Events.lossy_broadcast("pod.failed", %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "reason" => category,
      "reason_detail" => reason_detail
    })

    {:stop, {:shutdown, reason}, data}
  end

  defp add_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.put(&1, condition))
  end

  # Removes a condition. `:output_extracted` MUST be reset on re-monitoring of a long-lived pod —
  # otherwise a REPL crash on cycle 2 stays masked as {:stop, :normal} (the exit_status handler's guard
  # stays true) → pod.failed/clear never emitted.
  defp remove_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.delete(&1, condition))
  end

  # Releases the active task of a pod that dies without completing it. Non-fatal for the death path:
  # the Pod is otherwise decoupled from TaskQueue (event-driven completion) — we do not crash a pod's
  # death if TaskQueue is unavailable (e.g. a test context with no broker). A failed release is logged
  # warning below; the stale ACTIVE item does not outlive it silently: the broker holds no persisted
  # state (a down broker restarts EMPTY) and a later enqueue for the same pod supersedes any stale
  # active item — cf. `Spawner.safe_clear_for_pod` (kill path twin, logged ERROR there because the
  # staleness feeds the poller-reclaim/re-dispatch loop).
  defp clear_pod_task(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} clear_for_pod failed (non-fatal): #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("pod #{pod_id} clear_for_pod unavailable (non-fatal): #{inspect(reason)}")
      :ok
  end

  # ============================================================
  # Native timer actions (state_timeout + generic timeouts)
  # ============================================================

  # RESPONSE deadline (state_timeout of :monitoring) + liveness watchdog (recurring generic timeout).
  # Preserved policy: no arming for a `forever` pod (a permanent has no bounded response
  # window; idle = normal, legitimate slow-task, governed by external kill_pod) → we emit the
  # cancellation ACTIONS (time :infinity) to guarantee the absence of both a deadline AND liveness.
  # Otherwise: the deadline is NOT a "time to finish" budget — it is a SILENCE watchdog. The
  # `:liveness` re-arms this deadline as long as the pod MOVES → an agent at work NEVER times out.
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

  # Cancels the :liveness generic timeout (a generic timeout does NOT cancel itself on state change,
  # unlike the :result_deadline state_timeout). Emitted on :monitoring → :extracting.
  defp cancel_liveness_action, do: {{:timeout, :liveness}, :infinity, :tick}

  # SLOT-FREEZE: adopts the issue_id of the completed task (from the work_item.completed event) as the pod's
  # current issue. A re-briefed pipe changes brick on every task; without this state.issue_id
  # would stay the spawn one -> all attributions would point at the 1st brick. Absent/empty ->
  # we keep the existing one.
  defp adopt_task_issue_id(data, payload) do
    case payload[:issue_id] || payload["issue_id"] do
      t when is_binary(t) and t != "" -> %{data | issue_id: t}
      _ -> data
    end
  end

  # ============================================================
  # Kick (generic timeout :kick) — arming actions
  # ============================================================

  # Kick loop (generic timeout named `:kick`, only 1 alive per name). (Re-)arming it RESTARTS the
  # timer (a wake_pod during bootstrap does not create a 2nd loop). The bounds/cadences + the
  # decision/I-O live in `Pod.Kick`; here we only build the timer ACTION.
  defp schedule_kick_action(n, delay), do: {{:timeout, :kick}, delay, {:attempt, n}}

  defp schedule_extract_retry_action,
    do: {{:timeout, :extract_retry}, @extract_retry_delay_ms, :fire}

  # Cancel = set the :kick generic timeout to :infinity (= no timer).
  defp cancel_kick_action, do: {{:timeout, :kick}, :infinity, {:attempt, 0}}

  # Desktop-slot capture (generic timeout `:capture_slot`) — arming/cancel + cadence. Wider window
  # than the kick: claude's RC registration lands after the cold-start (~15s under bwrap), so the
  # default 5s + 20×5s ≈ 105s comfortably covers it. Best-effort, no escalation on cap.
  defp schedule_capture_action(n, delay), do: {{:timeout, :capture_slot}, delay, {:attempt, n}}
  defp cancel_capture_action, do: {{:timeout, :capture_slot}, :infinity, {:attempt, 0}}

  defp capture_slot_first_delay_ms,
    do: Application.get_env(:fleet_spawner, :capture_slot_first_delay_ms, 5_000)

  defp capture_slot_retry_ms,
    do: Application.get_env(:fleet_spawner, :capture_slot_retry_ms, 5_000)

  defp capture_slot_max, do: Application.get_env(:fleet_spawner, :capture_slot_max, 20)

  defp safe_resolve_disallowed(cap_profile) do
    {:ok, Fleet.CapProfile.with_resolved_disallowed_tools(cap_profile)}
  rescue
    e -> {:error, {:baseline_corrupt, Exception.message(e)}}
  end

  # Containment gate (including the deny of Anthropic native server-tools) wired at the spawn boundary.
  # If `validate/1` (all the containment semantics) were called ONLY by the tests, the gate
  # would be hollow: a fresh profile would silently bypass. Fail-loud: invalid profile → :failed,
  # the pod is NEVER launched. The JSON-schema does NOT cover all these rules — hence validate/1 here.
  defp gate_cap_profile(resolved) do
    case Fleet.CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end
end
