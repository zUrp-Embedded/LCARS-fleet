defmodule Fleet.Spawner do
  @moduledoc """
  Drives the LCARS v2 pod lifecycle (Ring 1 pod primitive).

  Spawns, watches and terminates ephemeral agent pods. Each pod is a
  `Fleet.Spawner.Pod` (`gen_statem`) supervised by `Fleet.Spawner.Supervisor`:
  its STATES are the 8 phases of the canonical cycle (`:allocating → :cleaning →
  :projecting → :injecting → :launching → :monitoring → :extracting →
  :releasing`).

  ## API

    * `spawn_pod/3` — starts a new pod
    * `kill_pod/1` — terminates a pod by its ID
    * `pod_info/1` — returns a pod's current state
    * `count_pods/0` — number of active pods

  ## Restart strategy

  All pods are `:temporary` (cf. `restart_strategy_for/1`). The
  `DynamicSupervisor` NEVER resurrects a pod —
  a dead pod (normal OR crash) is removed, full stop. `lifetime_scope` drives
  RECOVERY (`release|recreate`), not restart.

  ## Recovery

  Minimal FS state `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` =
  **observation snapshot** (where the pod was), not a reconstruction state.
  On (re)spawn, `recover_or_init` reads the snapshot and applies `recovery_action(phase)`
  (`Pod.Recovery`): terminal phase → `:release` (nothing to relaunch), everything else →
  `:recreate` (from scratch, FRESH session). Resurrection is a **deliberate** act
  of the boot-orchestrator; recovery NEVER attempts `--resume` on a session dead
  server-side (claude exit → zombie pod, proven live) — the task left in the queue
  re-drives a fresh REPL. Only a deliberate RECALL (`recall/2`) resumes a session.

  ## pod_id generation

  `UUID.uuid4()` generation caller-side (statistically collision-free
  without a central coordinator).

  ## Exit codes

    * `{:ok, pid}` — pod started
    * `{:error, :cap_profile_invalid, reason}` — invalid struct
    * `{:error, {:already_started, pid}}` — pod_id collision
    * `{:error, :invalid_pod_id}` — pod_id not path-safe (outside `[A-Za-z0-9._-]` or contains `..`)
    * `{:error, :brief_required}` — one-shot pod without a brief
  """

  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Validates that a `pod_id` is safe as a component of paths and socket/session names.

  The `pod_id` is interpolated into the pod dir (`~/pods/pod_<id>`), the FS state,
  the tmux/MCP sockets and the session names. This function is therefore the public
  authority for the boundaries that accept a `pod_id` supplied by an external or
  inter-app caller.
  """
  @spec valid_pod_id?(term()) :: boolean()
  # Single authority for the pod_id shape, satisfying ALL consumers by construction: head ALPHANUM
  # (a leading `.`/`_`/`-` would make a degenerate pkill pattern / a hidden path component), charset
  # `[A-Za-z0-9._-]`, no `..`, length 1..100 (anti-DoS sanity — the exact `sun_path` ≤ 108 bound is
  # enforced where the base dir is known, at the socket boundary). `\A…\z`, NOT `^…$` (line anchors in
  # PCRE → a trailing `\n` would sneak through).
  def valid_pod_id?(id) when is_binary(id),
    do:
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/, id) and
        not String.contains?(id, "..")

  def valid_pod_id?(_), do: false

  @doc """
  Rule R18: a one-shot cap-profile requires a brief. Shared authority (brief_guard +
  the boundaries that validate at admission, e.g. the API). nil/absent → false (exempted),
  like brief_guard.
  """
  @spec brief_required?(Fleet.CapProfile.t()) :: boolean()
  def brief_required?(%Fleet.CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot"
  end

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — `%Fleet.CapProfile{}` struct from `Fleet.CapProfile.compose/2`
    * `issue_id` — source event (Gitea issue, OS signal, etc.)
    * `opts`:
      * `:pod_id` (default `UUID.uuid4()`) — must be **path-safe** (`[A-Za-z0-9._-]`, no `..`),
        since interpolated into FS paths (`~/pods/pod_<id>`, sock, state recovery);
        otherwise `{:error, :invalid_pod_id}`.
      * `:state_fs_root` (override, default config `:fleet_spawner, :state_fs_root`)
      * `:brief` — the pod's work (string). **Mandatory** for a
        `one-shot` pod (otherwise `{:error, :brief_required}`).
      * `:allow_no_brief` — admin/diagnostic escape hatch (bool, default false).
  """
  @spec spawn_pod(Fleet.CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%Fleet.CapProfile{} = cap_profile, issue_id, opts \\ [])
      when is_binary(issue_id) and is_list(opts) do
    case brief_guard(cap_profile, opts) do
      :ok ->
        pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

        # pod_id threads into FS paths (pod_dir `~/pods/pod_<id>`, sock_path, state recovery)
        # by interpolation. The UUID default = safe, but the `:pod_id` override (step `issue-N-role-ts`, role
        # resolved forge-side; permanent `permanent-<name>-ts`; admin) is NOT necessarily controlled → a `/` or `..`
        # would traverse out of `~/pods`. Path-safe charset guard + `..` rejection → a CLEAR refusal, never a
        # traversed path (all legitimate pod_ids — UUID / catalogue / step — pass).
        if valid_pod_id?(pod_id) do
          # DETERMINISTIC pod id (stable, no timestamp suffix): a re-dispatch falls back on the same
          # `pod_id`. If a terminal TOMBSTONE (`state.json` :succeeded/:released/:killed) from a previous
          # cycle survives, `recover_or_init` would read it → `:release` → SILENT stop without launch → orphan
          # loop poller-side. We clear the tombstone (state + pod_dir) BEFORE spawn → FRESH init.
          # No-op if no snapshot / snapshot in flight (recovery :resume/:recreate left intact).
          _ = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, cap_profile, opts)

          args = %{
            cap_profile: cap_profile,
            issue_id: issue_id,
            pod_id: pod_id,
            opts: opts
          }

          spec = pod_child_spec(args)

          # NORMALIZED return — start_child's raw type includes `:ignore`/`{:ok, pid, info}`
          # (never produced by our gen_statem, but callers should not have to carry that contract).
          case DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec) do
            {:ok, pid} -> {:ok, pid}
            {:ok, pid, _info} -> {:ok, pid}
            :ignore -> {:error, :pod_init_ignored}
            {:error, _} = err -> err
          end
        else
          {:error, :invalid_pod_id}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deliberate RECALL: brings the `(projet, role)` agent back alive from its checkpointed seed
  (`projects.work/<projet>/pods/`). Reads the workflow_map (uuid+jsonl), spawns a pod in resume mode:
  `session_id` = the seed's uuid, `resume: true`, the seed is restored into the pod BEFORE the launch
  (state :projecting → maybe_recall_restore) → claude `--resume <uuid>` picks up the context. Desktop name
  `<projet>_<role>`. `allow_no_brief` (the pod resumes its context, not idle; no fresh brief).

  `{:ok, pid}` | `{:error, :no_seed}` (no seed) | `{:error, term}`.
  """
  @spec recall(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def recall(projet, role) when is_binary(projet) and is_binary(role) do
    case Fleet.Spawner.SeedStore.read_map(projet, role) do
      :none ->
        {:error, :no_seed}

      {:ok, %{uuid: uuid, jsonl: jsonl}} ->
        with {:ok, cap_profile} <- Fleet.CapProfile.load(role) do
          spawn_pod(cap_profile, "recall-#{projet}-#{role}",
            pod_id: "recall-#{projet}-#{role}",
            session_id: uuid,
            resume: true,
            recall_seed_jsonl: jsonl,
            rc_name: "#{projet}_#{role}",
            allow_no_brief: true
          )
        end
    end
  end

  # Invariant made structurally impossible to violate: a `one-shot` pod (1 task
  # then dies) MUST carry a brief — otherwise it leaves with no work (generic brief →
  # claude waits → timeout). Long-lived pods (`forever`/`run`/`pipe`) pull their
  # tasks via MCP (`yop` → get_work_item) → exempted (spares the permanent/gatekeeper pods).
  # Explicit admin/diagnostic escape hatch: `opts[:allow_no_brief]`.
  defp brief_guard(%Fleet.CapProfile{spec: spec} = cap_profile, opts) do
    brief = Keyword.get(opts, :brief)
    # `nil` AND `""` (empty brief — e.g. a `build_brief` over an empty/malformed
    # step context) both count as "no brief".
    has_brief? = is_binary(brief) and brief != ""
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    cond do
      has_brief? ->
        :ok

      Keyword.get(opts, :allow_no_brief, false) ->
        :ok

      # Same verdict as `scope == "one-shot"`, but via the shared PUBLIC predicate
      # `brief_required?/1` (single authority for the one-shot→brief rule, also called
      # at admission by the API) → no duplicated rule that could diverge.
      brief_required?(cap_profile) ->
        # Diagnosable (not a silent refusal): clearly distinguishes the case.
        Logger.warning(
          "Spawner: spawn_pod refused (R18): one-shot pod without brief — " <>
            "provide :brief (the work) or :allow_no_brief (admin/diagnostic)."
        )

        {:error, :brief_required}

      is_nil(scope) ->
        # Profile with no declared lifetime_scope (unvalidated?): exemption by default
        # (we only refuse the EXPLICIT one-shot), but we make the gap visible.
        Logger.warning(
          "Spawner: spawn_pod (R18): lifetime_scope missing from cap-profile — " <>
            "spawn allowed without brief (default exemption, profile to verify)."
        )

        :ok

      true ->
        :ok
    end
  end

  @doc """
  Terminates a pod by its ID. Returns `:ok` if found, `{:error, :not_found}` otherwise.
  """
  @spec kill_pod(String.t()) :: :ok | {:error, :not_found}
  def kill_pod(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # DELIBERATE release first — the Pod's `:kill` handler
        # (`handle_event({:call, from}, :kill, ...)`, `GenServer.call` gen_statem-compatible) does
        # backend teardown + clear_for_pod + terminal state :killed, then stop. Brutal terminate_child
        # fallback ONLY if the pod does not respond (timeout / already dead).
        # Never a bypass of the release transition.
        try do
          :ok = GenServer.call(pid, :kill, 5_000)
          :ok
        catch
          :exit, _reason ->
            _ = DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)

            # The pod did NOT answer :kill (timeout / already dead) → brutal terminate, so it could not
            # run its OWN clear_for_pod. Without releasing the mandate here, the work item stays ACTIVE →
            # the poller reclaims it → re-dispatch → a kill/timeout LOOP. So we release it (the
            # load-bearing part; the `:killed` tombstone is secondary and lost with the dead pod).
            # Best-effort: a TaskQueue that is itself down must never make `kill_pod` crash.
            _ = safe_clear_for_pod(pod_id)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Release a pod's active mandate, best-effort (used by the brutal `kill_pod` fallback): a TaskQueue
  # that is itself down/absent must never propagate an exit into `kill_pod`.
  defp safe_clear_for_pod(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Reprovisions a RESIDENT pipe pod's workspace for its next issue (slot-freeze): git reset
  IN-PLACE (NO rm_rf — the ws is bind-mounted in the live sandbox) on the basis of the new `project`
  + `/clear` of the REPL context. Called by the dispatcher when re-briefing a `:ready` pipe. Returns
  `:ok` | `{:error, _}` (incl. `:not_found` if the pod does not exist, `{:reset_failed, _}` if the git fails).
  """
  @spec reprovision_pipe_workspace(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def reprovision_pipe_workspace(pod_id, project, opts \\ [])
      when is_binary(pod_id) and is_map(project) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # Bounded git ops (Shell.git 30s each) but reset+clean+checkout can add up → generous
        # call (60s). An :exit (pod dead during the call) → typed error, no caller crash.
        try do
          GenServer.call(pid, {:reprovision_pipe_workspace, project, opts}, 60_000)
        catch
          :exit, reason -> {:error, {:reprovision_call_failed, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deliverable workspace from an ALREADY-known `pod_dir` (`<pod_dir>/workspace`). PUBLIC entry
  point (app boundary: external consumers do not depend on the internal `pod/*` tree); the
  AUTHORITY of the computation (the `"workspace"` literal) lives in `Pod.Paths.pod_workspace_path/1`
  — the `Pod.*` islands (LaunchSpec, CompletedPayload) call it directly, without going back up to the facade.
  `pod_workspace_dir/1` remains the registry path: the world reads where IT placed the pod, never where the pod
  claims to be.
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)

  @doc """
  Resolves a pod's deliverable workspace (`<pod_dir>/workspace`) from the REGISTERED pod_dir.
  The world reads where IT placed the pod (spawner record via `pod_info`), not a pod assertion:
  the pod never names the path of its own audit. Serves the forge-driven rail
  (`Pilot.StepRunCompleter` → `Deliverable`) to gate the workspace in `git_native` mode.
  """
  @spec pod_workspace_dir(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def pod_workspace_dir(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{pod_dir: dir}} when is_binary(dir) -> {:ok, pod_workspace_path(dir)}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns a pod's current state (`%{phase, conditions, ...}`).
  """
  @spec pod_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def pod_info(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # The pid may be dead but still briefly in the Registry (async cleanup
        # via monitor) — a `GenServer.call` would raise `EXIT` there. A dead pod =
        # absent → `{:error, :not_found}` (consistent with the try/catch pattern of
        # `kill_pod/1`; removes a race exposed by the release's fast stop).
        try do
          {:ok, GenServer.call(pid, :info)}
        catch
          :exit, _reason -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Enumerates the `:info` of live pods — **observability read seam** (read-only).

  Lists the keys of `Fleet.Spawner.Registry` and collects each one's `:info`
  via `pod_info/1`; pods that are dead but still briefly registered (async monitor
  cleanup race, cf. `pod_info/1`) are discarded. Read-only — alters no
  state. This is the only exposed enumeration seam: readers (the Ring 4
  observability deck) go through here, **never** through the Registry directly.
  """
  @spec list_pods() :: [map()]
  def list_pods do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pod_id ->
      case pod_info(pod_id) do
        {:ok, info} -> [info]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc """
  Number of active pods.
  """
  @spec count_pods() :: non_neg_integer()
  def count_pods do
    %{active: active} = DynamicSupervisor.count_children(Fleet.Spawner.Supervisor)
    active
  end

  @doc """
  Wakes a long-lived pod (lifetime_scope != one-shot) for a new cycle.

  **Load-bearing rail = wake-by-flag** (`turn.flag` + in-pod Monitor tool), touched HERE. Triggers the
  agent-worker-base workflow:

      (flag touched → Monitor "your turn") → mcp__fleet__get_work_item → processes → mcp__fleet__submit_result

  `wake_pod` is ONLY *trigger + arming of the net*: it touches the flag (load-bearing), then ARMS (cast)
  the Pod's ack-driven loop (`:arm_kick` — the FALLBACK: send-keys `"wake"` ONLY if the pull does not
  arrive) + re-arms the RESPONSE deadline (`:rearm_deadline`). It does **not** send-keys itself.

  Precondition: the caller has already enqueued the brief in `Fleet.TaskQueue` (targeted at `pod_id`; the pod
  identifies itself by `_lcars_pod_id` on the thread) BEFORE the call. The CONTENT ALWAYS goes through MCP
  (`get_work_item`), never through the injected text.

  Use-cases:
    - the `standard-qa` workflow-map: after reviewer/gatekeeper findings, push a corrective task + wake_pod(eng);
    - starfleet/fleet_pilot: new issue assigned to the same long-lived pod → push + wake.

  Returns — signals ONLY whether the trigger could LEAVE; the REAL wake is ASYNC:
    - `:ok` — flag touched + loop & deadline armed. **Does NOT assert the agent woke up**: the
      real success = the ACK (pull) observed by the loop; a wake that never takes → the loop escalates at the
      cap (`wake.failed` → `:sp_suspect`).
    - `{:error, :not_found}` — pod_id unknown/dead (never spawned, already killed, or dying pid).
    - `{:error, :not_a_tmux_pod}` — pod without a tmux session (the tests' StubBackend; in prod the backend
      always sets a tmux_session, bwrap as well as host).

  Both `{:error, _}` = STRUCTURAL failure (we could not even trigger) → the caller (cf. `WakeRecovery`)
  re-rolls/escalates. A 2nd path, complementary to the loop's async escalation (no-ACK).
  """
  @spec wake_pod(String.t()) :: :ok | {:error, :not_found | :not_a_tmux_pod}
  def wake_pod(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{tmux_session: session} = info} when is_binary(session) ->
        # Wake-by-flag (LOAD-BEARING rail): touches `turn.flag` (`Pod.TurnFlag.touch/1` — the flag's
        # FS I/O lives over there) → the Monitor-armed agent wakes up WITHOUT send-keys. No IMMEDIATE
        # send-keys here → we ARM the Pod's ack-driven loop (`:arm_kick`), which is the FALLBACK:
        # it send-keys `"wake"` ONLY if the pull does not arrive (the flag did not deliver), then
        # escalates at the cap. + re-arms the RESPONSE deadline. `wake_pod` is only a load-bearing
        # trigger + the arming of the net; the control (ACK = pull) lives in the loop
        # (`kick_attempt`). The `:wake_send_keys` knob (flag-only) is read by the loop.
        _ = Fleet.Spawner.Pod.TurnFlag.touch(info)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :rearm_deadline)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :arm_kick)
        :ok

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  A pod's restart strategy: `:temporary` for ALL scopes. The
  `DynamicSupervisor` NEVER resurrects a pod — a
  dead pod (normal exit OR crash) is removed, full stop. Resurrection
  is a deliberate act of the boot-orchestrator (recovery `release|recreate`).

  `:temporary` children do not count toward the supervisor's global
  `max_restarts` intensity → no more fleet-wide cascade possible.
  `lifetime_scope` drives RECOVERY, not restart (scope-typo
  detection therefore lives with `lifetime_scope`, no longer here).
  """
  @spec restart_strategy_for(String.t() | nil) :: :temporary
  def restart_strategy_for(_scope), do: :temporary

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = Fleet.CapProfile.lifetime_scope(cap_profile)

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      # Supervisor SHUTDOWN bound = the TEARDOWN time (kill tmux + rm + seed checkpoint,
      # seconds), NOT the pod's lifetime (the old `max_alive_sec * 1000` = 600s waited
      # 10 min on a pod stubborn to stop — dead config without trap_exit, a real wall with it). 15s then
      # OTP brutal-kill; the PodWarden reaps whatever would remain.
      shutdown: 15_000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()
end
