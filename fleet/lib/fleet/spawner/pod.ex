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
          # Gates pipe reset until publication is confirmed or explicitly lifted.
          | :publishing

  @type data :: %{
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          issue_id: String.t(),
          session_id: String.t() | nil,
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
          liveness_sample: term(),
          # Filtered skill dirs to bind into the pod (BL-6-22) — set by :projecting, read by
          # :launching (LaunchEnv → skills_paths_env). [] until projection, and for skill-less pods.
          skills_paths: [Path.t()]
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
    # POOL SLOT allocated HERE, and not at the spawn site. This function runs in the child process
    # that `DynamicSupervisor.start_child/2` starts, and that call is synchronous: allocation and
    # the registration that publishes it happen inside one window no other pod start can enter. The
    # atomicity is INHERITED, not built — no lock, no extra process, and the Registry stays the
    # single truth (`name/2` carries the value `PoolSlot` reads back).
    #
    # `{:error, :role_at_capacity}` is returned as the child's start result: the supervisor
    # propagates it verbatim, so `spawn_pod/3` hands the caller a DEFERRAL rather than a crash.
    #
    # No `:slot_key` (recall built by hand, tests that do not go through `spawn_pod/3`) → plain
    # registration: that pod holds no slot and is invisible to the allocation, which is the correct
    # reading of "outside the managed fan-out".
    case Map.get(args, :slot_key) do
      %{role: role, repo: repo} ->
        scope = Fleet.CapProfile.slot_scope(args.cap_profile)

        case Fleet.Spawner.PoolSlot.allocate(role, repo, scope) do
          {:error, :role_at_capacity} = err ->
            err

          {:ok, pool} ->
            slot = %{role: role, repo: repo, pool: pool}
            args = %{args | opts: Keyword.put(args.opts, :pool, pool)}
            :gen_statem.start_link(name(args.pod_id, slot), __MODULE__, args, [])
        end

      _ ->
        :gen_statem.start_link(name(args.pod_id), __MODULE__, args, [])
    end
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

  @doc """
  Registry-via name CARRYING the pod's slot identity `%{role, repo, pool}`.

  The value is what makes `Fleet.Spawner.PoolSlot` able to read live allocations WITHOUT calling
  a single pod — a hung pod must never block another's spawn. It is set at registration, so the
  pool has to be decided at the SPAWN site (before the process exists), which is also where the
  capacity ceiling belongs.
  """
  @spec name(String.t(), map()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t(), map()}}
  def name(pod_id, %{} = slot) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id, slot}}
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

  # Monitoring re-entry re-arms watchdogs but never duplicates the Bus subscription.
  @impl :gen_statem
  def handle_event(:enter, old_state, :monitoring, data) do
    first_entry? = old_state != :extracting

    if first_entry? do
      :ok = Bus.subscribe()

      # BL-6-06
      Events.lossy_broadcast("pod.spawned", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        "issue" => issue_number_of(data.issue_id),
        "role" => Fleet.CapProfile.name(data.cap_profile),
        "repo" => LaunchSpec.effective_project(data.opts, data.cap_profile)["repo"]
      })
    end

    actions = arm_result_deadline_actions(data)

    # Desktop-slot capture: on the FIRST entry into :monitoring (post-launch), if this pod is
    # RC-visible, arm a bounded poll that persists its `bridge_status` once claude has registered
    # → the slot re-attaches next boot (SeedStore.capture_slot_bridge). A no-RC pod never registers
    # → never armed. Once per boot suffices (the slot is stable for the process lifetime).
    actions =
      if first_entry? and LaunchSpec.remote_control?(data.cap_profile),
        do: [schedule_capture_action(0, capture_slot_first_delay_ms()) | actions],
        else: actions

    {:keep_state_and_data, actions}
  end

  def handle_event(:enter, _old_state, _state, _data), do: :keep_state_and_data

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
  # transition_failed (state.json phase=failed written). Issue-driven model: the pod PULLS its order
  # from the TaskQueue (MCP `get_work_item`, triggered by `engage`); `issues/<issue_id>.md` is a
  # scaffold file written BESIDE it.
  #
  # What that file actually holds — it is not one thing:
  #   * PRODUCERS, nominal rail: the dispatcher DOES put the order text under `:brief`, and
  #     `Spawn` DROPS that copy as soon as the order has been materialized into a committed doc —
  #     an address replaces it. So the file names the pinned doc (`brief_ref` @ `brief_sha`) and
  #     holds no text. That covers the rework rounds too: `RoleDispatch` re-briefs the producer on
  #     ITS OWN pod identity (`pod_id_for_scope`, the same one `dispatch_issue` uses), and that pod
  #     was spawned from the step rail.
  #   * PRODUCERS, degraded rail (no work dir, so no committed doc): the copy STAYS, because there
  #     is no address to name in its place — and nothing moves beside the file there, so it cannot
  #     go stale.
  #
  #   ⚠ Two claims of an earlier revision of this comment were false and cost a chantier: it said
  #   the dispatcher put no `:brief` at all (it did, and the copy survived into `issues/<id>.md`,
  #   never rewritten while the pointer advanced), and it said the file held a
  #   "(No brief provided)" placeholder (`Pod.Brief` stopped writing that: with no `:brief` it
  #   names the order's ADDRESS, precisely so an agent never reads that it was asked nothing).
  #   * JUDGES: `RoleDispatch` MUST pass `brief:` in the spawn opts — a judge is `one-shot` and
  #     `brief_guard` refuses a one-shot spawn without one — so the file holds the gate brief. Its
  #     pod is keyed on the PR (`PodId.for_pr`) and dies with its verdict, so each review writes it
  #     FRESH, and a re-dispatch while the previous one is alive is refused upstream by the
  #     `lcars-in-flight` lock (`dispatch_review`).
  #
  # So it is a SECOND COPY of the gate brief on a judge's disk, not a stale one: no reachable path
  # leaves an order here describing a round that has passed. (An earlier revision of this comment
  # claimed it did — deduced from "written at spawn only" without measuring which pod identity a
  # rework lands on.)
  #
  # No SP block or draft reads it either (measured across `priv/sp_builder` and the committed
  # drafts), but an agent exploring its own workspace does not need a wire to read a file named
  # after its issue. Whether the copy should exist at all is open (chantier monde-du-pod,
  # `## À trancher`): the answer depends on a DEPLOYED catalogue this repo does not carry.
  def handle_event(:internal, :proceed, :projecting, data) do
    # Skills root — THREE-way resolution (BL-6-22), and the `:catalogue` sentinel is deliberate
    # (get_env/3 returns the default ONLY when the key is ABSENT, never when it is present-nil):
    #   * key ABSENT → `:catalogue` → `Fleet.Catalogue.skills_root()` — resolved HERE at spawn,
    #     AFTER Config.Reader's batch-apply, so LCARS_CATALOGUE_ROOT is honored (a Catalogue call
    #     from runtime.exs would read the pre-runtime ETS and silently serve the bundled tree);
    #   * key = nil EXPLICIT (config/test.exs) → skills OFF (hermeticity — tests never filter or
    #     mount against the real tree);
    #   * key = a binary (LCARS_SKILLS_ROOT fine override) → that path.
    # Do not "simplify" the sentinel to nil: the two nil meanings would collapse.
    skills_root =
      case Application.get_env(:fleet_spawner, :skills_root, :catalogue) do
        :catalogue -> Fleet.Catalogue.skills_root()
        other -> other
      end

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

    # Is the disk still what the epoch validated? Asked HERE because this is the moment the question
    # means something: a pod is about to be built from that material. The pod is built ANYWAY, from
    # the image — serving proven-good is the whole point, and bytes that appeared after boot must not
    # reach an agent. What was missing is saying it: an edit to the deployed program's prompt material
    # used to be a NON-EVENT, absorbed in silence by the very mechanism protecting against it.
    warn_on_image_drift()

    with {:ok, sp_compose} <-
           SPBuilder.compose(
             data.cap_profile,
             # The ACTIVE modops of this composition — the role's defaults PLUS any optional modop the
             # step activated (`CapProfile.resolve/3` stamps them; `active_modops/1` falls back to the
             # defaults for a profile built outside it). Their `sp.md` fragments are composed into the
             # pod's system prompt (F-C146). A modop declared without a bundle →
             # `{:error, {:modop_bundle_missing, _}}` surfaces here (fail-loud: the pod does not launch).
             Fleet.CapProfile.active_modops(data.cap_profile),
             pod_id: data.pod_id,
             job_id: data.issue_id
           ),
         {:ok, claude_md} <-
           SPBuilder.compose_claude_md(data.cap_profile, Assets.maybe_path(repo_md)),
         {:ok, skills_paths} <- Assets.maybe_filter_skills(data.cap_profile, skills_root),
         {:ok, agent_draft} <- Assets.read_agent_draft(data.cap_profile),
         {:ok, protocole_user} <- Assets.read_protocole_user(data.cap_profile),
         :ok <- Fs.safe_mkdir_p(lcars_dir),
         :ok <- Fs.safe_mkdir_p(pod_claude_dir),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         :ok <- Fs.safe_write(Path.join(data.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "settings.json"),
             Assets.pod_settings_json(data.cap_profile)
           ),
         :ok <- Fs.safe_mkdir_p(issues_dir),
         :ok <-
           Fs.safe_write(
             Path.join(issues_dir, "#{Brief.issue_id_to_filename(data.issue_id)}.md"),
             Brief.default_brief(data)
           ),
         :ok <- Brief.maybe_enqueue_brief(data),
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
      # read by claude_launch via --system-prompt-file. The FILTERED skill paths ride the data to
      # :launching (BL-6-22 — they used to be validated then thrown away; the delivery half is
      # `LaunchSpec.skills_paths_env/1` consuming them from here).
      # The socket path is RETAINED, not just used: `Pod.Liveness` derives the MCP activity marker
      # from it (Fleet.Layout.pod_mcp_activity_marker/1). The spawner cannot ask the MCP domain for
      # this path — the seam exists because a literal would close a cycle — so the one moment it
      # legitimately holds it is here, on the way back from the provisioner.
      data =
        %{add_condition(data, :home_projected) | skills_paths: skills_paths}
        |> Map.put(:mcp_socket_path, mcp_socket_path)

      {:next_state, :launching, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:project_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :launching, data) do
    # A crashed Pod can leave its launcher alive; reap the same pod ID before every launch.
    Backend.reap_orphan_pod(data.pod_id)
    role = cap_profile_name(data.cap_profile)
    containment = cap_profile_containment(data.cap_profile)

    launcher_path =
      if containment == "none", do: Backend.host_launch_path(), else: Backend.bwrap_launch_path()

    args = %{
      role: role,
      pod_id: data.pod_id,
      pod_dir: data.pod_dir,
      launcher_path: launcher_path,
      claude_launch_path: Backend.claude_launch_path(),
      session_id: data.session_id
    }

    case LaunchEnv.build(data, role, containment, Backend.claude_launch_path()) do
      {:ok, env} -> do_launch_backend(data, args, env)
      {:error, reason} -> transition_failed(data, reason)
    end
  end

  # Broker completion wakes the Pod; the enriched pod.completed event finishes the Pilot step.
  @extract_retry_max 5
  @extract_retry_delay_ms 1_000

  # A failed required broadcast retains the result and retries before any release or reset.
  def handle_event(:internal, :proceed, :extracting, data) do
    result = data.submitted_result || %{}

    case Events.required_broadcast("pod.completed", CompletedPayload.build(data, result)) do
      :ok ->
        do_extract_proceed(%{data | extract_retries: 0}, result)

      {:error, _reason} ->
        n = data.extract_retries

        if n >= @extract_retry_max do
          Logger.error(
            "pod #{data.pod_id} pod.completed UNDELIVERABLE after #{n} retries — result NOT delivered " <>
              "to the step_run → transition_failed (no silent wedge)"
          )

          transition_failed(data, {:pod_completed_undeliverable, n})
        else
          {:next_state, :monitoring, %{data | extract_retries: n + 1},
           [schedule_extract_retry_action()]}
        end
    end
  end

  # LE SEED EST PRIS AVANT LE TEARDOWN — et la raison ecrite ici jusqu'au 2026-08-08 etait FAUSSE.
  # Elle disait « avant que le teardown retire l'acces au JSONL ». Mesure : `teardown_backend/1` tue
  # le holder (port/tmux) et retire le sock-dir, RIEN D'AUTRE ; et `bwrap_launch.sh` monte le pod_dir
  # en BIND hote (`--bind "$POD_DIR" "$SANDBOX_HOME"`), donc le transcript est cote hote et survit.
  # L'acces n'est pas retire.
  #
  # L'ordre est CONSERVE, et ce qu'il garantit reellement est plus etroit : le checkpoint est le seul
  # geste de cette clause qui peut echouer sans consequence, alors que tuer le holder et retirer le
  # sock-dir sont irreversibles. Le faire d'abord, c'est ne pas dependre de leur reussite.
  #
  # ⚠ Ce que PERSONNE ne tient encore : l'ordre lui-meme. Intervertir ces deux lignes laisse la suite
  # verte (mesure 2026-08-08), parce que le stub de teardown ne touche pas au transcript et que
  # l'ordre est donc inobservable en test. Ne pas lire ce commentaire comme une garantie.
  def handle_event(:internal, :proceed, :releasing, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :succeeded))
    {:stop, :normal, data}
  end

  def handle_event(:internal, :proceed, _state, _data), do: :keep_state_and_data

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      pod_id: data.pod_id,
      issue_id: data.issue_id,
      role: cap_profile_name(data.cap_profile),
      repo: Keyword.get(data.opts, :repo),
      phase: state,
      conditions: MapSet.to_list(data.conditions),
      has_active_task: TaskProbe.pod_has_active_task?(data.pod_id),
      session_id: data.session_id,
      pod_dir: data.pod_dir,
      state_fs_path: data.state_fs_path,
      last_error: data.last_error,
      last_result: data.last_result,
      tmux_session: data.tmux_session
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  # Cold pipe reset is destructive and relies on the caller's :ready/:publishing gate.
  def handle_event({:call, from}, {:reprovision_pipe_workspace, project, opts}, _state, data) do
    eff_cap = Fleet.CapProfile.with_project(data.cap_profile, project)

    # F-28: only a successful disk reset may advance the payload's project provenance.
    repinned = %{data | opts: Keyword.put(data.opts, :project, project)}

    case Fleet.ProjectBootstrap.Phase.Clone.reset_in_place(data.pod_dir, eff_cap, opts) do
      {:ok, ws, branch} ->
        # Git isolation succeeded; a failed /clear is visible but does not undo the disk reset.
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
  #   - active task (pending/assigned) → the pod did NOT respond in time → failure.
  #   - no active task → the pod was just waiting for its next task (idle); this is NOT a
  #     response timeout → we let it lapse, NO kill (otherwise idle-kill of a healthy pod). The check
  #     is at the moment of the fire (≠ at arming) → covers the worker-enqueue race AND the inter-step.
  # The state_timeout, once fired, is no longer armed → no re-fire until the liveness re-arms it.
  def handle_event(:state_timeout, :result_deadline, :monitoring, data) do
    result_deadline_fire(TaskProbe.active_task_state(data.pod_id), data)
  end

  # LIVENESS watchdog (recurring generic timeout, workers only). If the pod has MOVED since the
  # previous tick (ANY of the four signals of `Liveness` moved) → re-arm the deadline (pushes back
  # the kill) + the
  # tick; otherwise → just reschedule the tick (the state_timeout deadline keeps running). Result:
  # an engineer at work NEVER times out; the deadline only fires on total silence.
  def handle_event({:timeout, :liveness}, :tick, :monitoring, data) do
    sample = Liveness.liveness_sample(data)
    moved? = Liveness.liveness_moved?(Map.get(data, :liveness_sample), sample)

    # An UNOBSERVABLE sample re-arms the deadline (moved? = true) but is NOT silence proven
    # alive — it is a measurement gap. Logged so a pod that is repeatedly unmeasurable is
    # visible (a persistent gap is a probe/mount problem, not a healthy pod), never a silent
    # benefit-of-the-doubt that masks it.
    if Liveness.unobservable?(sample) do
      Logger.warning(
        "pod #{data.pod_id} liveness UNOBSERVABLE this tick (every signal nil) — " <>
          "deadline re-armed (re-probe), not counted as silence"
      )
    end

    data = Map.put(data, :liveness_sample, sample)

    actions =
      if moved?,
        do: arm_result_deadline_actions(data),
        else: [liveness_tick_action(data)]

    {:keep_state, data, actions}
  end

  def handle_event({:timeout, :liveness}, :tick, _state, _data), do: :keep_state_and_data

  # Publication deadlines lift a stuck flag unless a live publish observation says to re-arm.
  def handle_event({:timeout, :publish_deadline}, :fire, _state, data) do
    cond do
      # Live observation outranks the arithmetic backstop; the mark clears in an `after` block.
      Publishing.publishing?(data) and Fleet.Publish.InFlight.in_flight?(data.pod_id) ->
        Logger.warning(
          "pod #{data.pod_id} :publish_deadline fired but a publish is IN FLIGHT — re-arming " <>
            "(observed live, not reset; observation over arithmetic)"
        )

        {:keep_state_and_data, [Publishing.arm_publish_deadline_action(data)]}

      true ->
        do_publish_deadline_lift(data)
    end
  end

  # One bounded ACK-driven loop handles bootstrap engage and wake fallback.
  def handle_event({:timeout, :kick}, {:attempt, n}, _state, %{tmux_session: session} = data)
      when is_binary(session) do
    bootstrap? = TaskProbe.no_pending_brief?(data.pod_id)

    polled = TaskProbe.polled?(data)
    cap = if bootstrap?, do: Kick.kick_bootstrap_max(), else: Kick.kick_max_attempts()

    retry =
      cond do
        bootstrap? -> Kick.kick_bootstrap_retry_ms()
        polled -> Kick.wake_retry_ms()
        true -> Kick.kick_retry_ms()
      end

    cond do
      Kick.acked?(TaskProbe.brief_pulled?(data.pod_id), bootstrap?, polled) ->
        Logger.debug(
          "pod #{data.pod_id} acked (pull/poll) → kick stopped (carrier rail takes over)"
        )

        {:keep_state_and_data, [cancel_kick_action()]}

      # Flag-only human terminals with no brief have no meaningful bootstrap action.
      bootstrap? and not Kick.profile_send_keys?(data) ->
        Logger.debug(
          "pod #{data.pod_id} bootstrap kick canceled (profile is flag-only, nothing pending)"
        )

        {:keep_state_and_data, [cancel_kick_action()]}

      n >= cap ->
        phase = if bootstrap?, do: :bootstrap, else: :wake

        Logger.warning(
          "pod #{data.pod_id} kick (#{phase}) abandoned after #{n} attempts — agent never acked → escalating"
        )

        {reason, reason_detail} = Fleet.Event.reason_fields({:no_ack, phase})

        Events.lossy_broadcast("wake.failed", %{
          "pod_id" => data.pod_id,
          "issue_id" => data.issue_id,
          "reason" => reason,
          "reason_detail" => reason_detail,
          "pane" => Fleet.Spawner.PodTmux.capture_pane(data.pod_id)
        })

        {:keep_state_and_data, [cancel_kick_action()]}

      # THE REPL IS NOT UP YET — AND TYPING INTO IT IS NOT A NO-OP. tmux buffers what is sent to a
      # session whose TUI has not started, and the TUI then replays each buffered line as its own
      # submission. The loop's stop condition cannot fire during that window either: every ACK it
      # knows (`pulled`/`polled`) requires a turn, which requires the REPL. So every kick fired
      # during a cold start is a guaranteed duplicate — measured 2026-08-04: 15 s + 6 x 2.5 s of
      # cadence against a 20-40 s bwrap cold start = a scribe with SEVEN `engage` in its REPL,
      # seven spurious turns on one dispatch.
      # `repl_up?` is the in-band proof that exists in that window: the pod's MCP client speaks on
      # its socket at TUI init, before any turn. We keep counting attempts — a REPL that never
      # comes up must still end in the `wake.failed` escalation, and it now says the truth (the
      # agent never showed up) instead of "it never answered our seven kicks".
      not TaskProbe.repl_up?(data.pod_id) ->
        {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}

      Fleet.Spawner.PodTmux.alive?(data.pod_id) ->
        _ = Kick.kick_send(data, polled)
        {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}

      true ->
        {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}
    end
  end

  def handle_event({:timeout, :kick}, {:attempt, _n}, _state, _data), do: :keep_state_and_data

  # RC-visible pods poll boundedly for a slot record; failure never touches the core loop.
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

  def handle_event({:timeout, :capture_slot}, {:attempt, _n}, _state, _data),
    do: :keep_state_and_data

  # Only retained results may re-fire a failed pod.completed broadcast.
  def handle_event({:timeout, :extract_retry}, :fire, :monitoring, %{submitted_result: r} = data)
      when not is_nil(r),
      do: {:next_state, :extracting, data, [{:next_event, :internal, :proceed}]}

  def handle_event({:timeout, :extract_retry}, :fire, _state, _data), do: :keep_state_and_data

  # Only this pod's completion advances it; leaving monitoring cancels the state timeout natively.
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

  def handle_event(
        :info,
        %Fleet.Event{source: :task_queue, type: :"work_item.completed"},
        _state,
        _data
      ),
      do: :keep_state_and_data

  # Forge confirmation makes this pipe re-briefable and cancels its publication deadline.
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

  # BL-6-03: a witnessed publication-task death lifts the flag with a named cause.
  def handle_event(
        :info,
        %Fleet.Event{type: :"deliverable.publish_lost", pod_id: pid} = ev,
        _state,
        %{pod_id: pid} = data
      ) do
    if Publishing.publishing?(data) do
      reason = (ev.payload || %{})["reason"] || "unknown"

      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready — completion task DIED (#{reason}); " <>
          "named-cause lift, :publish_deadline spared"
      )
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  def handle_event(:info, %Fleet.Event{type: :"deliverable.publish_lost"}, _state, _data),
    do: :keep_state_and_data

  # A Port exit is normal only after extraction; otherwise it fails and releases the active task.
  def handle_event(:info, {port, {:exit_status, exit_code}}, _state, %{port: port} = data)
      when is_port(port) do
    if MapSet.member?(data.conditions, :output_extracted) do
      {:stop, :normal, data}
    else
      # LA MEMOIRE SE SAUVE SURTOUT QUAND LA MORT N'ETAIT PAS VOULUE. Le checkpoint ne vivait que
      # sur `:releasing` et `:kill`. Les DEUX morts subies tardives — cet exit du Port avant
      # resultat, et le `:result_timeout` via `transition_failed/2` — n'y passaient pas : un agent
      # qui meurt seul, ou qui se tait, perdait sa graine alors que c'est exactement de la qu'on
      # veut reprendre le fil. Ici comme la-bas, avant tout demontage, tant que le JSONL est lisible.
      #
      # NON concerne, et il faut le dire pour que personne ne le "corrige" en double : le kill du
      # watchdog de vivacite passe par `Spawner.kill_pod/1` -> `:kill`, qui checkpointait deja.
      maybe_checkpoint_seed(data)
      clear_pod_task(data.pod_id)

      Events.lossy_broadcast("pod.failed", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        # The REPO, without which `issue_id` (`issue-<n>`) designates nothing writable: a consumer
        # that wants to put a label on the ticket needs `owner/name` + n, and deriving the repo from
        # the dashed `pod_id` would be a guess (a repo name can contain dashes).
        "repo" => Keyword.get(data.opts, :repo),
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{data.pod_id} exited before submitting result (exit=#{exit_code})")

      # The failed tombstone lets recovery and the warden reclaim this pod directory.
      data = Map.put(data, :last_error, {:exited_before_result, exit_code})
      StateFs.write_state_fs(put_phase(data, :failed))
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, data}
    end
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  @doc false
  def result_deadline_fire(:active, data),
    do: transition_failed(data, {:result_timeout, data.pod_id})

  def result_deadline_fire(:idle, _data), do: :keep_state_and_data

  def result_deadline_fire(:unknown, data),
    do: {:keep_state_and_data, arm_result_deadline_actions(data)}

  # Idempotent teardown is the net for every stop and callback crash; it must not mask the reason.
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
    McpProvision.release_pod_socket(data)
  end

  defp issue_number_of("issue-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp issue_number_of(_), do: nil

  defp do_publish_deadline_lift(data) do
    if Publishing.publishing?(data) do
      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready by DEADLINE (deliverable.published not received in time)"
      )
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  defp do_launch_backend(data, args, env) do
    # F-C041
    with {:ok, backend} <- Backend.launch_backend_conforming(),
         {:ok, launched} when is_map(launched) <- backend.launch(args, env) do
      port = Map.get(launched, :port)
      tmux_session = Map.get(launched, :tmux_session)

      data =
        data
        |> Map.put(:port, port)
        |> Map.put(:tmux_session, tmux_session)
        |> Map.put(:session_id, data.session_id)
        |> add_condition(:process_launched)
        |> add_condition(:stream_alive)

      StateFs.write_state_fs(put_phase(data, :monitoring))

      {:next_state, :monitoring, data, brief_kick_actions(data)}
    else
      {:error, reason} -> transition_failed(data, {:launch_failed, reason})
    end
  end

  defp brief_kick_actions(%{tmux_session: nil}), do: []

  defp brief_kick_actions(%{tmux_session: session}) when is_binary(session),
    do: [schedule_kick_action(0, Kick.kick_first_delay_ms())]

  # Successful extraction releases one-shots and resets long-lived pods for another cycle.
  defp do_extract_proceed(data, result) do
    data =
      data
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(data.cap_profile) do
      "one-shot" ->
        {:next_state, :releasing, data, [{:next_event, :internal, :proceed}]}

      _other ->
        data =
          data
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)

        {data, pub_actions} = Publishing.maybe_enter_publishing(data)
        {:next_state, :monitoring, data, pub_actions}
    end
  end

  defp lifetime_scope(%Fleet.CapProfile{} = cp), do: Fleet.CapProfile.lifetime_scope(cp)

  defp maybe_checkpoint_seed(data) do
    case LaunchSpec.rc_project(data.opts, data.cap_profile) do
      nil ->
        :ok

      project ->
        _ =
          Fleet.Spawner.SeedStore.checkpoint(
            data.pod_dir,
            project,
            cap_profile_name(data.cap_profile),
            data.session_id,
            checkpoint_issue(data)
          )

        :ok
    end
  end

  # How the seed is KEYED, derived from the same axis as everything else: a pod keyed on its TICKET
  # gets a per-ticket seed, a pod keyed on its PROJECT keeps the historical per-role one (it is the
  # project's only pod of that role, so the role alone identifies it). No new declaration — the
  # `slot_scope` already answers the question.
  #
  # A ticket-keyed pod whose issue_id is not a step issue (admin spawn, diagnostic) yields nil and
  # lands on the per-role name: that is the honest fallback, since there is no ticket to name.
  #
  # Reads the number through `issue_number_of/1`, the shape-parser this module already owns, and
  # NOT through `Fleet.Pilot.IssueId` — the boundary refuses `Spawner → Pilot` and it is right to:
  # an issue_id crosses into this domain as an opaque string, and the day it stops being
  # `issue-<n>` the one parser here is what needs revisiting, not a dependency edge.
  defp checkpoint_issue(data) do
    if Fleet.CapProfile.slot_scope(data.cap_profile) == "instance",
      do: issue_number_of(data.issue_id)
  end

  # ============================================================
  # Recovery / state FS
  # ============================================================

  defp recover_or_init(args) do
    base = initial_state(args)

    case File.read(base.state_fs_path) do
      # No prior state.json = a FRESH pod (first boot for this pod_id) → the UNIFIED seed decision
      # (maybe_slot_resume): an RC identity with a live jsonl or a captured seed RESUMES it; else
      # fresh create. ONLY on this branch — a crash-recovery (snapshot below) keeps the fresh-reroll
      # doctrine (never resume a dead pod's accumulated session).
      {:error, :enoent} ->
        maybe_slot_resume(base)

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"session_id" => sid, "phase" => phase_str} = snap} when is_binary(sid) ->
            if Map.get(snap, "boot_id") == Fleet.Spawner.BootEpoch.id() do
              # Same-epoch crash recovery creates a fresh session.
              phase = Recovery.phase_from_string(phase_str) || :launching
              Recovery.apply_recovery(base, Recovery.recovery_action(phase), sid, phase)
            else
              # Previous-epoch snapshots use the normal live/seed/fresh decision.
              Logger.info(
                "pod #{base.pod_id} recover: state.json from a PREVIOUS fleet life " <>
                  "(stale epoch) → unified seed decision (not a crash recovery)"
              )

              maybe_slot_resume(base)
            end

          _ ->
            Logger.error(
              "pod #{base.pod_id} recover: state.json PRESENT but CORRUPT at #{base.state_fs_path} " <>
                "— fresh init (durable recovery point lost)"
            )

            base
        end

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
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      issue_id: args.issue_id,
      session_id: resolve_session_id(args),
      started_at: DateTime.utc_now(),
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
      liveness_sample: nil,
      skills_paths: []
    }
  end

  # UNIFIED seed decision (core Decision 1, reorg 2026-07-19) — FRESH first-boot only (the caller
  # gates on :enoent). Precedence:
  #   1. explicit recall/resume (opts) → untouched (the deliberate paths stay authoritative);
  #   2. non-RC pod → fresh create (it never captured, nothing to resume);
  #   3. its LIVE jsonl exists in the pod_dir (clean fleet reboot, pod_dir persisted) →
  #      resume IN PLACE: full context back + slot re-attached (the jsonl carries its own RC
  #      identity) — THE per-project arch continuity story, zero restore needed;
  #   4. a captured SEED exists for the identity → resume FROM it via the recall machinery
  #      (restore copies it under the uuid): slot back, context empty (F5);
  #   5. nothing → fresh create (first boot ever; the capture seeds the seed for next time).
  #
  # Cases 3-5 are for SLOT-BEARING pods only, which since the RC derivation means project-keyed
  # ones, or an instance-keyed role that DECLARES `remote_control: true`. An undeclared
  # instance-keyed pod stops at case 2 — it holds no Desktop slot, so there is no slot to give back.
  defp maybe_slot_resume(base) do
    cond do
      base.resume or Keyword.has_key?(base.opts, :recall_seed_jsonl) ->
        base

      not LaunchSpec.remote_control?(base.cap_profile) ->
        base

      live_jsonl_exists?(base) ->
        %{base | resume: true}

      true ->
        case Fleet.Spawner.SeedStore.slot_seed(base.session_id) do
          {:ok, seed} ->
            %{base | resume: true, opts: Keyword.put(base.opts, :recall_seed_jsonl, seed)}

          :none ->
            base
        end
    end
  end

  defp live_jsonl_exists?(base) do
    cwd = LaunchSpec.pod_cwd(base.opts, base.cap_profile, base.pod_dir)

    [
      base.pod_dir,
      ".claude",
      "projects",
      Fleet.Spawner.SeedStore.slugify(cwd),
      "#{base.session_id}.jsonl"
    ]
    |> Path.join()
    |> File.exists?()
  end

  # Explicit recall identity precedes minting but must retain the vendor UUID shape.
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

  defp cap_profile_name(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.name(cap)

  defp cap_profile_containment(%Fleet.CapProfile{} = cap), do: Fleet.CapProfile.containment(cap)

  defp cap_profile_containment(_), do: Fleet.CapProfile.default_containment()

  # Recovery snapshots need the state name reattached to the callback data.
  defp put_phase(data, phase), do: Map.put(data, :phase, phase)

  defp transition_failed(data, reason) do
    Logger.warning("pod #{data.pod_id} failed: #{inspect(reason)}")

    # Jumeau du site d'exit du Port. Compte surtout pour `:result_timeout` (l'agent a travaille
    # puis s'est tu, il y a donc un transcript) ; sur les echecs PRECOCES — allocate, project,
    # lancement — il n'y a aucun JSONL et le store rend `:none` sans rien ecrire, ce qui est le
    # comportement voulu et non un oubli.
    maybe_checkpoint_seed(data)
    clear_pod_task(data.pod_id)
    data = Map.put(data, :last_error, reason)
    StateFs.write_state_fs(put_phase(data, :failed))

    # Normalize terms before the raw JSON websocket edge while retaining diagnostic detail.
    {category, reason_detail} = Fleet.Event.reason_fields(reason)

    Events.lossy_broadcast("pod.failed", %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      # Twin of the site above: same reason, same key. Both `pod.failed` emissions must carry the
      # SAME shape, or a consumer works on one and not the other.
      "repo" => Keyword.get(data.opts, :repo),
      "reason" => category,
      "reason_detail" => reason_detail
    })

    {:stop, {:shutdown, reason}, data}
  end

  defp add_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.put(&1, condition))
  end

  defp remove_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.delete(&1, condition))
  end

  # Task release is non-fatal on a Pod death but never silent.
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

  # Forever pods cancel both watchdogs; other deadlines measure silence, not work duration.
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

  defp cancel_liveness_action, do: {{:timeout, :liveness}, :infinity, :tick}

  # Re-briefed pipes attribute completion to the current task rather than their spawn issue.
  defp adopt_task_issue_id(data, payload) do
    case payload[:issue_id] || payload["issue_id"] do
      t when is_binary(t) and t != "" -> %{data | issue_id: t}
      _ -> data
    end
  end

  defp schedule_kick_action(n, delay), do: {{:timeout, :kick}, delay, {:attempt, n}}

  defp schedule_extract_retry_action,
    do: {{:timeout, :extract_retry}, @extract_retry_delay_ms, :fire}

  defp cancel_kick_action, do: {{:timeout, :kick}, :infinity, {:attempt, 0}}

  # Slot capture gets a wider best-effort window than the boot kick.
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

  # Runtime containment validation covers rules beyond the JSON schema.
  defp gate_cap_profile(resolved) do
    case Fleet.CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end

  # Pods keep using the proven image; disk divergence remains operator-visible.
  defp warn_on_image_drift do
    case SPBuilder.image_drift() do
      {:ok, []} ->
        :ok

      {:ok, drifted} ->
        Logger.warning(
          "SPBuilder.Image: #{length(drifted)} prompt source(s) DIVERGE from the published epoch — " <>
            "pods keep receiving the proven-good image, the disk no longer matches it " <>
            "(restart to open a new epoch): " <>
            Enum.map_join(drifted, ", ", fn {path, how} -> "#{path} (#{how})" end)
        )

      :unpublished ->
        :ok
    end
  end
end
