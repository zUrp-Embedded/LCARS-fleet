defmodule Fleet.Spawner do
  # COMPILED domain boundary: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface. The compiler refuses any violation — widening an
  # export or adding a dep is an API decision, visible in review.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      # Foundation (deps: []) — the skills-root default resolves at SPAWN time (BL-6-22, the
      # `:catalogue` sentinel in Pod :projecting): the one Catalogue read this domain makes.
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      Fleet.SPBuilder,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.ProjectBootstrap,
      Fleet.TaskQueue,
      # Foundation primitive (:persistent_term flag, deps: []) — readable from any
      # domain. The PermanentWarden consults it so as not to respawn during a drain (A-13).
      Fleet.Shutdown.Quiesce,
      # Foundation primitive (:persistent_term per-pod publish-in-flight fact, deps: []) — the pod's
      # :publish_deadline reads it to defer its reset while the Pilot completion is still publishing.
      Fleet.Publish.InFlight
    ],
    exports: [Application, PermanentBoot, PodTmux, Pod.McpProvision, LaunchBackend]

  @moduledoc """
  Drives the LCARS v2 pod lifecycle (pod-composition layer).

  Spawns, watches and terminates ephemeral agent pods. Each pod is a
  `Fleet.Spawner.Pod` (`gen_statem`) supervised by `Fleet.Spawner.Supervisor`:
  its STATES are the 7 phases of the canonical cycle (`:allocating → :cleaning →
  :projecting → :launching → :monitoring → :extracting → :releasing`).

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
  `:recreate` (from scratch, FRESH session). Resurrection is a **deliberate** act from the desired
  state — by the boot-orchestrator (initial boot) OR the `PermanentWarden` (recovery respawn of a dead
  permanent), never the supervisor; recovery NEVER attempts `--resume` on a session dead
  server-side (claude exits → zombie pod) — the task left in the queue
  re-drives a fresh REPL. Only a deliberate RECALL (`recall/2`) resumes a session.

  ## pod_id generation

  `UUID.uuid4()` caller-side is only the FALLBACK, used when no `:pod_id` is supplied (statistically
  collision-free without a central coordinator). Every real rail passes a DETERMINISTIC, meaningful id
  instead — `<repo-slug>-issue-N-role` (step dispatch), `permanent-<role>` (permanent boot), and
  `recall-<project>-<role>` — because determinism is what makes a re-boot or a respawn land back on the
  SAME pod instead of forking a twin. Reading this section as "pod_ids are uuids" would invert that.

  ## Exit codes

    * `{:ok, pid}` — pod started
    * `{:error, {:cap_profile_invalid, violations}}` — profile rejected by `CapProfile.validate/1`
      (the tag is NESTED in the reason: matching a flat `{:error, :cap_profile_invalid, _}` never fires)
    * `{:error, {:already_started, pid}}` — pod_id collision
    * `{:error, :invalid_pod_id}` — pod_id not path-safe (outside `[A-Za-z0-9._-]` or contains `..`)
    * `{:error, :brief_required}` — one-shot pod without a brief

  **Last revised**: 2026-08-02
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
  A one-shot cap-profile requires a brief. Shared authority (brief_guard +
  the boundaries that validate at admission, e.g. the API). Reads only the EXPLICIT
  `"one-shot"`; a missing lifetime_scope → false, but that is now a dead-safe default —
  the spawn choke point (`spawn_pod`) refuses a no-scope profile via `fetch_lifetime_scope/1`
  BEFORE this predicate is consulted (DR-019), and admission only ever schema-loads.
  """
  @spec brief_required?(Fleet.CapProfile.t()) :: boolean()
  def brief_required?(%Fleet.CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot"
  end

  @doc """
  Does the `role`'s cap-profile declare the business capability `cap`? (catalogue chantier L3,
  B-03 — the cross-boundary capability resolver). `Fleet.MCP`'s delegation gates cannot reference
  `Fleet.CapProfile` (forbidden boundary edge) but CAN reference `Fleet.Spawner` — this is the
  bridge: load the role's profile, read its `capabilities`. Fail-closed: a role that does not load
  has NO capability (an unknown identity is never admitted by a gate).
  """
  @spec role_has_capability?(String.t(), atom() | String.t()) :: boolean()
  def role_has_capability?(role, cap) when is_binary(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, profile} -> Fleet.CapProfile.has_capability?(profile, cap)
      _ -> false
    end
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
    # DR-019 — the STRUCTURAL guard: `lifetime_scope` is schema-REQUIRED — it decides brief-required, slot
    # scope, state-fs scope AND release. A %CapProfile{} without it is an INVALID state the struct type
    # still allows (an unvalidated/hand-forged struct); letting it spawn gave it DIVERGENT downstream
    # reads (brief-exempt at the guard, yet "one-shot" at extraction → releases). We refuse it at THE
    # choke point (every spawn — publish_consumer, step_dispatcher, recall — funnels here), so no
    # unvalidated profile ever reaches the divergent readers.
    # Same structural guard, same choke point, for `interlocutor`: it decides WHICH protocol
    # contract the pod is provisioned with. Absent, the provisioning would fall back to the
    # machine contract — the exact silence the field exists to end, and one that reads as correct
    # from the outside (the pod boots, the human just gets an agent holding a worker's contract).
    with {:ok, _scope} <- Fleet.CapProfile.fetch_lifetime_scope(cap_profile),
         {:ok, _who} <- Fleet.CapProfile.fetch_interlocutor(cap_profile),
         :ok <- brief_guard(cap_profile, opts) do
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
    else
      {:error, :no_lifetime_scope} ->
        # Invalid state refused at the boundary (DR-019), not silently defaulted: the profile never
        # came from the schema → do not spawn it. LOUD (error): a caller forged/mutated a struct.
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no lifetime_scope (schema-required; " <>
            "an unvalidated/hand-forged struct is not a spawnable state)."
        )

        {:error, :cap_profile_no_lifetime_scope}

      {:error, :no_interlocutor} ->
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no interlocutor (schema-required; " <>
            "the protocol contract a pod is provisioned with is never inferred)."
        )

        {:error, :cap_profile_no_interlocutor}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deliberate RECALL: brings the `(project, role)` agent back alive from its checkpointed seed
  (`<seed_root>/<project>/pods/`, cf. `SeedStore`). Reads the SEED descriptor `<role>.json` (uuid + jsonl) —
  NOT a `workflow_map`, which is the step-pipeline map the dispatcher reads and has nothing to do with
  recall. Spawns a pod in resume mode:
  `session_id` = the seed's uuid, `resume: true`, the seed is restored into the pod BEFORE the launch
  (state :projecting → maybe_recall_restore) → claude `--resume <uuid>` picks up the context. Desktop name
  `<project>_<role>`. `allow_no_brief` (the pod resumes its context, not idle; no fresh brief).

  `{:ok, pid}` | `{:error, :no_seed}` (no seed) | `{:error, term}`.
  """
  @spec recall(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def recall(project, role) when is_binary(project) and is_binary(role) do
    case Fleet.Spawner.SeedStore.read_map(project, role) do
      :none ->
        {:error, :no_seed}

      {:ok, %{uuid: uuid, jsonl: jsonl}} ->
        # `resolve` (base + default modops), NOT bare `load` — a
        # recalled pod must come back with the SAME effective profile a fresh spawn composes, else a
        # structural modop overlay would be silently dropped on recall.
        with {:ok, cap_profile} <- Fleet.CapProfile.resolve(Fleet.CapProfile, role) do
          spawn_pod(cap_profile, "recall-#{project}-#{role}",
            pod_id: "recall-#{project}-#{role}",
            session_id: uuid,
            resume: true,
            recall_seed_jsonl: jsonl,
            rc_name: "#{project}_#{role}",
            allow_no_brief: true
          )
        end
    end
  end

  # Invariant made structurally impossible to violate: a `one-shot` pod (1 task
  # then dies) MUST carry a brief — otherwise it leaves with no work (generic brief →
  # claude waits → timeout). Long-lived pods (`forever`/`run`/`pipe`) pull their
  # tasks via MCP (`engage` → get_work_item) → exempted (spares the permanent/gatekeeper pods).
  # Explicit admin/diagnostic escape hatch: `opts[:allow_no_brief]`.
  # PRECONDITION: `cap_profile` already passed `fetch_lifetime_scope/1` in `spawn_pod` (a no-scope
  # profile never reaches here — it is refused upstream, DR-019). So scope is guaranteed present:
  # the guard only decides one-shot→brief, no nil-scope exemption to make.
  defp brief_guard(%Fleet.CapProfile{} = cap_profile, opts) do
    brief = Keyword.get(opts, :brief)
    # `nil` AND `""` (empty brief — e.g. a `build_brief` over an empty/malformed
    # step context) both count as "no brief".
    has_brief? = is_binary(brief) and brief != ""

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
          "Spawner: spawn_pod refused: one-shot pod without brief — " <>
            "provide :brief (the work) or :allow_no_brief (admin/diagnostic)."
        )

        {:error, :brief_required}

      # Long-lived (forever/run/pipe): pulls its work via MCP → exempted.
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
            # Fail-safe toward the caller only: a TaskQueue that is itself down must never make
            # `kill_pod` crash — a failed release is logged ERROR by `safe_clear_for_pod` (the
            # reclaim-loop stake is spelled out there).
            _ = safe_clear_for_pod(pod_id)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Release a pod's active mandate (used by the brutal `kill_pod` fallback): a TaskQueue that is
  # itself down/absent must never propagate an exit into `kill_pod` — but the failure is NOT silent:
  # logged ERROR below (the stake: stale active item → poller reclaim → kill/re-dispatch loop).
  defp safe_clear_for_pod(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      # The rescue/catch is legitimately fail-safe (must NEVER make kill_pod crash). But it must not be
      # SILENT: this is the load-bearing mandate release — if it fails, the work item stays active → the
      # poller reclaims it → kill/re-dispatch LOOP (exactly what the release exists to prevent). Log LOUD.
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (#{inspect(e)}) — the work item may " <>
          "stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (TaskQueue exit: #{inspect(reason)}) " <>
          "— the work item may stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
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
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)

  @doc """
  Returns a pod's current state (`%{phase, conditions, ...}`).

  THREE outcomes, kept distinct up to every destructive decision: `{:ok, info}` (alive),
  `{:error, :not_found}` (genuinely absent), `{:error, :unreachable}` (info call TIMED
  OUT or exited oddly — the pod may be ALIVE and slow). Flattening `:unreachable` into
  `:not_found` let compensations kill a living pod and reset a workspace mid-write;
  destructive consumers must DEFER on `:unreachable`, never treat it as death.
  (`timeout` is a test seam — prod callers use the default.)
  """
  @spec pod_info(String.t(), timeout()) :: {:ok, map()} | {:error, :not_found | :unreachable}
  def pod_info(pod_id, timeout \\ 5_000) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # The pid may be dead but still briefly in the Registry (async cleanup via
        # monitor) — a `GenServer.call` exits there. A DEAD pid (noproc/normal/shutdown)
        # is genuinely absent; a TIMEOUT (or any other exit) is NOT a death proof.
        try do
          {:ok, GenServer.call(pid, :info, timeout)}
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
          :exit, {:normal, _} -> {:error, :not_found}
          :exit, {:shutdown, _} -> {:error, :not_found}
          :exit, {{:shutdown, _}, _} -> {:error, :not_found}
          :exit, _other -> {:error, :unreachable}
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
  state. This is the only exposed enumeration seam: readers (the surface
  observability deck) go through here, **never** through the Registry directly.
  """
  @spec list_pods() :: [map()]
  def list_pods do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pod_id ->
      case pod_info(pod_id) do
        {:ok, info} -> [info]
        # Absent AND unreachable both drop from the listing (display seam, read-only —
        # the destructive paths read the TYPED error, never this enumeration).
        {:error, _} -> []
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
  Global live-pod cap — SINGLE authority for the `:fleet_spawner, :max_pods` default (24).
  Read by the DynamicSupervisor (`max_children`, the enforcing side) AND `has_capacity?/0`
  (the pre-flight side): one default, no drift between the two readers.
  """
  @spec max_pods() :: pos_integer()
  def max_pods, do: Application.get_env(:fleet_spawner, :max_pods, 24)

  @doc """
  Is there room to START a new pod? Same count/cap pair the DynamicSupervisor enforces
  (`count_children` vs `max_pods/0`) — the pre-flight twin of its `max_children` refusal,
  for callers that must gate BEFORE side effects. Raison d'être: the dispatcher LOCKS the
  issue on the forge before spawning; discovering saturation only at `spawn_pod`
  (`{:error, :max_children}`) forced a lock→unlock compensation on EVERY tick at saturation
  (~4 forge writes/issue/30s polluting the issue timeline, and the tally counted "full" as
  an ERROR → poller backoff as if the forge were down). Pre-flight = defer without a write.
  The residual TOCTOU (last slot stolen between check and spawn) still lands on
  `max_children` + the caller's compensation — this gate makes that the rare exception,
  not the steady-state mechanism.
  """
  @spec has_capacity?() :: boolean()
  def has_capacity?, do: count_pods() < max_pods()

  @doc """
  Wakes a long-lived pod (lifetime_scope != one-shot) for a new cycle.

  **Load-bearing rail = wake-by-flag** (`turn.flag` + in-pod Monitor tool), touched HERE. Triggers the
  common workflow (`core/runtime-contract` block of the per-role SP):

      (flag touched → Monitor "your turn") → mcp__fleet__get_work_item → processes → mcp__fleet__submit_result

  `wake_pod` is ONLY *trigger + arming of the net*: it touches the flag (load-bearing), then ARMS (cast)
  the Pod's ack-driven loop (`:arm_kick` — the FALLBACK: send-keys `"wake"` ONLY if the pull does not
  arrive) + re-arms the RESPONSE deadline (`:rearm_deadline`). It does **not** send-keys itself.

  Precondition: the caller has already enqueued the brief in `Fleet.TaskQueue` (targeted at `pod_id`; the
  central resolves the target pod from its per-pod MCP socket, not from any wire field) BEFORE the call.
  The CONTENT ALWAYS goes through MCP
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
  @spec wake_pod(String.t()) :: :ok | {:error, :not_found | :not_a_tmux_pod | :unreachable}
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
  INFORMATIONAL wake — flag ONLY, typed message. Writes `"<token> <message>"` into the
  pod's `turn.flag`: the in-pod monitor emits the message verbatim (vs the fixed
  "ton tour" of a mandate wake). Deliberately does NOT arm the ack-driven kick net nor
  the response deadline: an info wake expects NO pull (`get_work_item`), so the send-keys
  fallback would eventually type into the human's terminal for nothing — the exact
  interference the info channel must never cause. Best-effort: unknown/flagless pod →
  `:ok` (the durable trail is the arch feed file; a lost info wake costs nothing).
  """
  @spec notify_pod(String.t(), String.t()) :: :ok
  def notify_pod(pod_id, message) when is_binary(pod_id) and is_binary(message) do
    case pod_info(pod_id) do
      {:ok, info} -> Fleet.Spawner.Pod.TurnFlag.touch(info, message)
      {:error, _} -> :ok
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

  @doc """
  Proves every canon role spawn-ready against the currently-resolved catalogue — the boot check
  (`Spawner.Application`) reachable off the supervision path, for the standalone catalogue
  verifier. Delegates to `Fleet.Spawner.CanonProof`: the SAME function the boot calls, never a
  copy — a divergent proof would be one more dialect of "spawnable".
  """
  defdelegate prove_canon!(), to: Fleet.Spawner.CanonProof, as: :prove_all!

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = Fleet.CapProfile.lifetime_scope(cap_profile)

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      # Supervisor SHUTDOWN bound = the TEARDOWN time (kill tmux + rm + seed checkpoint,
      # seconds), NOT the pod's lifetime (an ex-attempt tied it to the pod lifetime = 600s waited
      # 10 min on a pod stubborn to stop — dead config without trap_exit, a real wall with it). 15s then
      # OTP brutal-kill — which cuts `terminate/3` short. Both footprints have a RUNTIME reaper on
      # that path: the PodWarden reconciles the tmux sessions/pod_dirs, and `Fleet.MCP.SocketWarden`
      # reconciles the per-pod MCP socket (acceptor, AF_UNIX listener, Registry entry, socket file)
      # against the live pods — same 2-tick grace. Cold boot keeps its own sweep
      # (`PodSocketSupervisor.sweep_stale_sockets/0`) for what a BEAM crash left behind.
      shutdown: 15_000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()
end
