defmodule Fleet.Pilot.StepDispatcher.Spawn do
  @moduledoc """
  SINGLE-AUTHORITY spawn leaf extracted from `Fleet.Pilot.StepDispatcher`.

  The dispatcher's TWO flows — issue (`dispatch_issue`, producer) AND PR (`do_dispatch_review`,
  judge/rework/resolution) — CONVERGE here: a single spawn point (`spawn_step/9`), a single
  pod identity (`pod_id_for_scope/4`), a single scope serialization (`serialize_project_scope/6`).
  This module DECIDES nothing (route, role, verdict, budget stay in the `StepDispatcher` core): it
  EXECUTES the spawn sequence. There is only ONE copy of each — never an issue/review fork.
  (The opts builders / naming — `rc_name`/`feature_slug`/`maybe_put_route`/`resolve_repo_id` —
  live in the `Spawn.Naming` submodule, quasi-pure, called by both flows.)

  ## LOAD-BEARING semantics (preserved word-for-word from the core)

  - **Canonical order** `lock → pod → enqueue → wake` (wake LAST). The label-lock
    `lcars-in-flight` is set BEFORE the pod, else double-spawn.
  - **Compensation**: if a POST-lock step fails, we remove the lock AND kill the pod
    ONLY if it was just spawned fresh (`alive_before? == false`) — a re-brief on a living pod
    NEVER kills the eng or its context.
  - **Return `{:error, {:wake_unreached, pod_id, role, reason}}`**: the pod IS started (lock +
    brief + pod in place), only the tmux wake failed. The POLLER reads this return to TAKE the lease
    (the object is in-flight) and count it in `errors` (honest tally, not a silent success). This
    return contract does NOT change.

  ## Boundary: explicit seams struct (not the whole `ctx`/`opts`)

  `spawn_step/9` reads only 6 seams of the dispatch. We do NOT pass the whole `ctx`/`opts` — that would be
  a boundary leak. Each caller (issue via `opts`, review via `ctx`) builds a `%Seams{}`
  (narrow, TYPED contract): `@enforce_keys` forces the 6 fields at the call, and an access
  `seams.<other_field>` does not compile (static KeyError) — a bare map would let
  `Map.get(seams, :loader)` pass silently.

  The helpers SHARED with the core stay PUBLIC here and are called by `StepDispatcher`:
  `safe_kill/2` (compensation in `spawn_step` AND die-on-promote in `promote_pr`).
  """

  require Logger

  # Protocol vocabulary = single source Fleet.Pilot.Labels (compile-time constant, as in
  # StepDispatcher which keeps ITS @in_flight_label for `decide/1`/`dispatch_review` — same source,
  # not a fork).
  @in_flight_label Fleet.Pilot.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Boundary contract of the spawn leaf: the 6 seams (and NOTHING else) that `spawn_step/9`
    reads. `@enforce_keys` forces the 6 fields at construction; an access `seams.<other_field>` does
    not compile — the cluster never receives the whole `ctx`/`opts` of the dispatch.
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Injected spawner (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected brief broker (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # The repo's `owner/name` (the locked object lives there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient.
            forge_opts: keyword(),
            # Injected wake recovery (seam `:wake_recovery`, default `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()})
          }
  end

  # ============================================================
  # Cluster H — spawn leaf (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  Spawn LEAF shared by dispatch_issue (producer) AND do_dispatch_review (judge/rework).
  CANONICAL ORDER: label-lock `lcars-in-flight` BEFORE pod (else double-spawn) → pod
  (`maybe_spawn`: RE-BRIEFS if alive) → enqueue of the brief (that the pod pulls via get_work_item) →
  wake+recovery. POST-lock failure → compensation: removal of the lock (+ kill IF fresh spawn,
  NEVER a living re-brief). `lock_target` = the locked object (issue number | PR number);
  `issue_number` = the issue number for the `issue_id` AND the enqueue; `log_ctx` = caller log context.
  """
  @spec spawn_step(
          Seams.t(),
          String.t(),
          String.t(),
          Fleet.CapProfile.t(),
          String.t(),
          keyword(),
          integer(),
          integer(),
          String.t()
        ) :: {:ok, {:spawned, String.t(), String.t()}} | {:error, term()}
  def spawn_step(
        %Seams{} = seams,
        pod_id,
        role,
        profile,
        brief,
        spawn_opts,
        lock_target,
        issue_number,
        log_ctx
      ) do
    %Seams{
      forge: forge,
      spawner: spawner,
      task_queue: task_queue,
      repo: repo,
      forge_opts: forge_opts,
      wake_recovery: wake_recovery
    } = seams

    issue_id = Fleet.Pilot.IssueId.compose(issue_number)
    alive_before? = pod_alive?(spawner, pod_id)

    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         # Native time-tracking (best-effort, discard): STARTS the stopwatch on the SAME object as the
         # lock (issue or PR) — global mechanic, role-agnostic (cf. § Time-tracking, ForgeClient).
         # Signed IN THE WORKER'S NAME (`as_role`) — NOT the label (protocol = system): Gitea attributes the
         # tracked time to the AUTHENTICATED user, so a system stopwatch would count all the time
         # under `lcars-system`, never the real worker. Gitea requires the SAME identity for start AND stop
         # (per-user stopwatch) — the symmetric stop lives in `unlock` (same role, except the
         # ISSUE-lock case at the final `:promote`, cf. StepRunCompleter).
         _ =
           with(
             {:ok, ro} <- Fleet.Pilot.ForgeClient.as_role(forge_opts, role),
             do: forge.start_stopwatch(repo, lock_target, ro)
           ),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, issue_id, spawn_opts),
         :ok <- enqueue_brief(task_queue, pod_id, role, issue_number, brief) do
      # The return of `WakeRecovery.wake` is LOAD-BEARING: `{:error, {:escalated, _}}`
      # (pod unreachable, escalated to starfleet) or `{:error, _}` (re-wake failed) means the pod is
      # NOT woken. Discarding this return (`_ = wake(...)`) would always make `spawn_step` return
      # `{:ok, {:spawned}}` → the poller would count `dispatched +1 / errors 0` LYING (pod never woken,
      # but a clean tally). So we MATCH it: the lock + the brief + the pod STAY in place (the
      # brief is enqueued, the system escalation exists → not a dead-end, re-wake at the next tick), but
      # the dispatch is NOT a silent success — it surfaces `{:error, {:wake_unreached, …}}` → the poller
      # counts it in `errors` (honest tally + err_streak/telemetry reflect the real unreachability).
      case wake_recovery.(
             pod_id,
             fn -> maybe_spawn(spawner, false, profile, issue_id, spawn_opts) end,
             wake_fun: fn p -> safe_wake(spawner, p) end
           ) do
        :ok ->
          Logger.info(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx}"
          )

          {:ok, {:spawned, pod_id, role}}

        {:error, reason} ->
          # NO compensation: lock kept (the pod is dispatched, the object IS in-flight),
          # brief kept, pod kept. Only the wake-up failed → honest tally + re-wake at the next tick
          # (idempotent: alive_before? will be true, maybe_spawn no-op, re-wake retried).
          Logger.warning(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx} " <>
              "BUT wake UNREACHABLE → #{inspect(reason)} (lock+brief kept, re-wake on next tick ; " <>
              "tally = error, not silently dispatched)"
          )

          {:error, {:wake_unreached, pod_id, role, reason}}
      end
    else
      {:error, _} = err ->
        # A POST-lock step failed → compensation (removal of the lock, else stuck forever).
        # Kill ONLY if fresh spawn (a re-brief NEVER kills the living eng + its context).
        if not alive_before?, do: safe_kill(spawner, pod_id)
        _ = forge.remove_label(repo, lock_target, @in_flight_label, forge_opts)

        # Stopwatch started with the lock → stopped with it (the dispatch never succeeded, the elapsed
        # time would be noise, not real work). SAME identity as at the start (`as_role`, that
        # same role) — Gitea accepts the stop ONLY from the user who started it.
        _ =
          with {:ok, ro} <- Fleet.Pilot.ForgeClient.as_role(forge_opts, role) do
            forge.stop_stopwatch(repo, lock_target, ro)
          end

        Logger.warning(
          "StepDispatcher: dispatch role=#{role} pod=#{pod_id} #{log_ctx} → #{inspect(err)} " <>
            "(lock removed#{if(not alive_before?, do: ", pod killed", else: "")} — re-dispatch on next tick)"
        )

        err
    end
  end

  defp maybe_spawn(_spawner, true = _alive?, _profile, _issue_id, _spawn_opts),
    do: {:ok, :rebriefed}

  defp maybe_spawn(spawner, false = _alive?, profile, issue_id, spawn_opts) do
    case spawner.spawn_pod(profile, issue_id, spawn_opts) do
      {:ok, _pid} -> {:ok, :spawned}
      {:error, _} = err -> err
    end
  end

  defp disposition(true = _alive_before?), do: "re-briefed (pod vivant, contexte gardé)"
  defp disposition(false = _alive_before?), do: "spawned"

  # Enqueues the brief in the `Fleet.TaskQueue` broker targeted at pod_id — the claude REPL pulls it via
  # `mcp__fleet__get_work_item` → `PodTools.get_work_item` → `TaskQueue.get_for_pod` (NOT a file Read).
  # Without this enqueue, `TaskQueue.pod_status(pod_id) == nil` → the pod thinks it is bootstrap
  # (nothing to pull) → idle.
  # The `brief` = the role-aware BRIEF already built (build_brief): disarmed GateBrief for the
  # gatekeeper, issue body for a worker. A raw `issue["body"]` would make
  # the judge pull the executable BUILD brief. `metadata.issue` correlates to the issue.
  defp enqueue_brief(task_queue, pod_id, role, number, brief) do
    attrs = %{
      issue_id: Fleet.Pilot.IssueId.compose(number),
      role: role,
      brief: brief,
      metadata: %{"issue" => number}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp safe_wake(spawner, pod_id) do
    if function_exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    e ->
      # A RAISE from wake_pod is NOT a successful wake — returning `:ok` would report a woken pod that never
      # woke (false `dispatched` tally, silent). Surface it as `{:error}` so WakeRecovery re-rolls/escalates.
      Logger.warning(
        "Spawn.safe_wake: wake_pod RAISED for #{inspect(pod_id)} (#{inspect(e)}) → {:error}"
      )

      {:error, {:wake_raised, pod_id}}
  end

  @doc """
  Best-effort compensation: kills the pod (if it spawned) before removing the lock.
  Silent no-op if the spawner does not expose `kill_pod/1` or if the pod does not exist.

  PUBLIC because shared with the core: `spawn_step/9` (compensation) AND `ReviewLifecycle.promote_pr`
  (die-on-promote of the eng). One copy, no fork.
  """
  @spec safe_kill(module(), String.t()) :: any()
  def safe_kill(spawner, pod_id) do
    if function_exported?(spawner, :kill_pod, 1), do: spawner.kill_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # Idempotent dispatch. An already-ALIVE pod (stable deterministic id) = the long-lived pipe eng
  # → we RE-BRIEF it (enqueue + wake, keeps its context), no re-spawn (no more leak/orphan).
  # `pod_alive?` defaults to `false` if the spawner does not expose `pod_info/1` (test stubs) → spawn
  # path unchanged.
  defp pod_alive?(spawner, pod_id) do
    function_exported?(spawner, :pod_info, 1) and match?({:ok, _}, spawner.pod_info(pod_id))
  rescue
    e ->
      # A RAISE from pod_info leaves aliveness UNKNOWN. Defaulting to `false` (dead) is UNSAFE: a live pod
      # classed dead → double-spawn on the deterministic pod_id AND `safe_kill` of the LIVING eng + its
      # context. Fail-CLOSED → assume ALIVE (no destructive action; a wrong "alive" at worst wastes a rebrief).
      Logger.warning(
        "Spawn.pod_alive?: pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → assume ALIVE (fail-closed)"
      )

      true
  end

  # ============================================================
  # Cluster I — pod identity + scope serialization (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  Pod identity granularity, derived from the catalogue (`slot_scope` of the cap-profile, single source):
    "instance" → keyed on ISSUE (`for_issue`): fan-out, a distinct id per issue/PR (ephemeral judges).
    "project"  → keyed on REPO alone (`for_repo`): ONE identity per (repo, role) → a stable Desktop slot.
  Total over the slot_scope enum (the `Fleet.CapProfile.slot_scope/1` accessor guarantees project|instance).
  """
  @spec pod_id_for_scope(String.t(), String.t(), integer(), String.t()) :: String.t()
  def pod_id_for_scope("project", repo, _number, role),
    do: Fleet.Pilot.PodId.for_repo(repo, role)

  def pod_id_for_scope("instance", repo, number, role),
    do: Fleet.Pilot.PodId.for_issue(repo, number, role)

  @doc """
  Serialization of project-scoped roles: ONE identity (repo, role) alive at a time (1 Desktop slot).
  Modulated by the lifetime:
    instance         -> never gated (distinct ids per issue, fan-out assumed).
    project one-shot  -> alive = occupied by another issue -> DEFERRED; it dies at the end of the task +
                         fresh spawn at the next issue (baseline behavior, UNCHANGED).
    project pipe      -> RESIDENT process, per its state (pipe_rebrief_state):
                           dead  -> :ok (fresh spawn, 1st issue);
                           busy  -> DEFERRED (still working a task OR publishing its last deliverable:
                                    resetting its workspace now would corrupt it / race the push);
                           ready -> COLD in-place reset of the workspace for the new brief + /clear, THEN
                                    :ok (spawn_step re-briefs on a clean workspace, right branch).
  All BEFORE the lock/enqueue (else we would lock an issue we are not processing). `{:skipped,
  :role_busy}` surfaces to the poller (retry at the next tick). The reset base = `project["base_sha"]`:
  new issue -> main tip (fresh); rework -> tip of the PR (continues the eng's work). 1 single fn.
  """
  @spec serialize_project_scope(
          String.t(),
          String.t(),
          module(),
          String.t(),
          map() | nil,
          String.t()
        ) :: :ok | {:skipped, :role_busy}
  def serialize_project_scope("instance", _lifetime, _spawner, _pod_id, _project, _slug), do: :ok

  def serialize_project_scope("project", "one-shot", spawner, pod_id, _project, _slug) do
    if pod_alive?(spawner, pod_id), do: {:skipped, :role_busy}, else: :ok
  end

  def serialize_project_scope("project", _pipe, spawner, pod_id, project, slug) do
    case pipe_rebrief_state(spawner, pod_id) do
      :dead -> :ok
      :busy -> {:skipped, :role_busy}
      :ready -> reprovision_then_proceed(spawner, pod_id, project, slug)
    end
  end

  # State of a project-scoped pipe facing a NEW brief. :ready = idle AND last deliverable confirmed (neither
  # active task nor :publishing) — the ONLY situation where resetting the workspace is safe (the push already read
  # the commit, the agent writes no more). pod_info exposes conditions + has_active_task (the pod knows both).
  defp pipe_rebrief_state(spawner, pod_id) do
    case safe_pod_info(spawner, pod_id) do
      {:ok, %{conditions: conds, has_active_task: active}} ->
        cond do
          active -> :busy
          :publishing in conds -> :busy
          true -> :ready
        end

      # pod_info without has_active_task (partial stub): conservative -> :busy (a living pipe of unknown
      # state is NOT reset, just deferred).
      {:ok, _partial} ->
        :busy

      # F-C059 — aliveness UNKNOWN (pod_info RAISED): fail-CLOSED -> :busy (DEFER), NEVER :dead. Classing an
      # uncertain pod dead -> serialize `:ok` -> fresh spawn on the deterministic id -> reap/`safe_kill` of a
      # maybe-LIVING pipe eng + its context (the exact destructive path `pod_alive?` guards with "assume ALIVE").
      # A transient raise self-corrects next tick; a persistent one defers visibly (Logger.warning) rather than
      # acting destructively. This is the "grow a variant" the old `safe_pod_info` comment flagged as needed.
      # NB: only the RAISE case is closed here — the deeper `pod_info` conflation (a live-but-slow pod whose
      # GenServer.call times out into `{:error, :not_found}`, indistinguishable from a genuinely-absent pod at
      # THIS layer) needs a pod_info contract split at the spawner and is a separate doctrine item.
      :unknown ->
        :busy

      # Genuinely absent / a reachable `{:error}` from pod_info -> dead -> fresh spawn (1st issue).
      :error ->
        :dead
    end
  end

  defp safe_pod_info(spawner, pod_id) do
    if function_exported?(spawner, :pod_info, 1) do
      case spawner.pod_info(pod_id) do
        {:ok, info} -> {:ok, info}
        _ -> :error
      end
    else
      :error
    end
  rescue
    e ->
      # A RAISE from pod_info leaves the pod state UNKNOWN — distinct from a reachable `{:error}` (absent).
      # We return `:unknown` (NOT `:error`): `pipe_rebrief_state` DEFERS on unknown (fail-closed), never
      # cold-resets/kills a maybe-LIVING pipe. Surfaced. (Mirror of `pod_alive?`'s "assume ALIVE" on raise.)
      Logger.warning(
        "Spawn.safe_pod_info: pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → :unknown (fail-closed defer)"
      )

      :unknown
  end

  # COLD in-place reset of the workspace + /clear BEFORE the rebrief, then :ok (proceed). Reset failed -> DEFERRED
  # (retry at the next tick). No project (legacy) or spawner without the fn (stub) -> :ok without reset
  # (honest degrade: we do not block, but without the cold guarantee of this round).
  defp reprovision_then_proceed(spawner, pod_id, project, slug) do
    if is_map(project) and function_exported?(spawner, :reprovision_pipe_workspace, 3) do
      case spawner.reprovision_pipe_workspace(pod_id, project, slug: slug) do
        :ok -> :ok
        {:error, _} -> {:skipped, :role_busy}
      end
    else
      :ok
    end
  end

  # (Ex-cluster J — opts builders / naming: MOVED to `Spawn.Naming` (rc_name /
  # feature_slug / maybe_put_route / resolve_repo_id). Quasi-pure, shared by the two
  # dispatcher flows — the leaf keeps the spawn MECHANIC, Naming keeps the NAMES.)
end
