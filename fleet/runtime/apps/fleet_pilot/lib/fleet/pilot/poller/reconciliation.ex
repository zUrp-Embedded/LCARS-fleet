defmodule Fleet.Pilot.Poller.Reconciliation do
  @moduledoc """
  IMPURE "orphaned lock reconciliation" cluster extracted from `Fleet.Pilot.Poller`.

  A `lcars-in-flight` lock is ORPHANED if the brick carries it but no live pod is
  working it. Cause: a dead pod (`:result_timeout` deadline, crash, BEAM restart) reaped by the
  PodWarden — which removes the PROCESS but NOT the forge label. Broken symmetry → without repair the
  `dispatch_*` skips the `:in_flight` brick FOREVER (a single pod stall wedges the pipe). This
  module REPAIRS: at each tick, it compares the locks seen on the forge to the refs that a LIVE pod
  actually owns, and reclaims (removes the label) the CONFIRMED orphans → the next tick
  re-dispatches.

  ## What this module does / does NOT do

  It READS 5 seams (`%Seams{}`) and yields the NEW set of suspects (`MapSet.t()`) — it WRITES no
  poller state. The **2-tick grace** (only accumulate a suspect over two consecutive ticks) and
  the **cross-repo aggregation** (`MapSet.union` of the suspects of all the repos of a tick) are
  CROSS-TICK state: they STAY at the core (`Fleet.Pilot.Poller` — `do_poll`/`step_do_poll` passes
  the suspects of the previous tick as `prior_suspects` and re-writes the yielded set into the state).

  ## 2-tick grace + REPO-QUALIFIED refs (load-bearing semantics, verbatim)

  We only reclaim a CONFIRMED orphan: `reconcile/5` intersects the orphans seen THIS tick with
  `prior_suspects` (the orphans seen at the PREVIOUS tick) — never a freshly dispatched pod (not
  yet registered) or one in the process of dying. The lock refs are REPO-QUALIFIED
  (`{repo, :issue|:pr, n}`): the key carries the repo, so the refs of the live pods (`owned`, scoped
  to the current repo) and the cross-tick suspects (all repos) no longer collide on the number alone.
  An orphan #N/repoA is no longer masked by a live pod #N/repoB, and the grace no longer contaminates
  across repos.

  ## Fail-safe (verbatim)

  If the enumeration of live pods fails (`live_owned_refs/1 → :error`), we reclaim NOTHING and
  keep `prior_suspects` as is — NEVER unlock blindly.

  ## Boundary: explicit seams struct (not the whole `state`)

  The cluster reads only 5 seams of the poller (`forge`/`spawner`/`task_queue`/`repo`/`forge_opts`). We
  do NOT pass the whole `state` — that would be a boundary leak. The caller builds a
  `%Seams{}` (narrow, TYPED contract): `@enforce_keys` forces the 5 fields at the call, and an access
  `seams.<other_field>` does not compile (static KeyError) — a bare map would let
  `Map.get(seams, :orphan_lock_suspects)` pass silently. The caller resolves the prod defaults
  (`state.spawner || Fleet.Spawner`, `state.task_queue || Fleet.TaskQueue`) at ITS site: the cluster
  receives already-resolved modules.

  Dependencies (never `Fleet.Pilot.Poller` → no cycle): `Fleet.Pilot.Labels` (single source of the
  lock), `Fleet.Pilot.PodId` (format of the pod_ids), `Fleet.Pilot.IssueId` (parse issue_id) + the
  injected seams (spawner/task_queue/forge).
  """

  require Logger

  # workflow_run lock: single source `Fleet.Pilot.Labels` (compile-time constant). SAME source as
  # the `@in_flight` of the core `Poller` (which keeps its own for the fast-path `classify_issue`) — not a
  # fork of a literal, the authority stays `Labels.in_flight/0`.
  @in_flight Fleet.Pilot.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Reconciliation boundary contract: the 5 seams (and NOTHING else) that `reconcile/5` reads.
    `@enforce_keys` forces the 5 fields at construction; an access `seams.<other_field>` does not compile
    — the cluster never receives the poller's whole `state`. `spawner`/`task_queue` are already
    RESOLVED by the caller (prod defaults `Fleet.Spawner`/`Fleet.TaskQueue` applied at its site).
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Injected spawner, ALREADY resolved by the caller (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected broker, ALREADY resolved by the caller (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # `owner/name` of the current repo (the lock refs are repo-qualified there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient (`remove_label`).
            forge_opts: keyword()
          }
  end

  @doc """
  Reconciles the orphaned `lcars-in-flight` locks of the repo `seams.repo` and yields the NEW set of
  suspects (`MapSet.t()` of repo-qualified refs `{repo, :issue|:pr, n}`).

  `prior_suspects` = the orphans seen at the PREVIOUS tick (2-tick grace, carried by the core). Side
  effect: removes the forge label (`reclaim_lock/2`) of the CONFIRMED orphans (seen at both ticks). The
  yielded set = the orphans of THIS tick not yet reclaimed (those awaiting their 2nd confirmation).

  Fail-safe: if the enumeration of the pods fails (`:error`), yields `prior_suspects` unchanged (reclaims
  nothing blindly).
  """
  @spec reconcile(list(map()), list(map()), MapSet.t(), MapSet.t(), Seams.t()) :: MapSet.t()
  def reconcile(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams) do
    case live_owned_refs(seams) do
      # Pod enumeration unavailable → fail-safe: we reclaim NOTHING (never unlock
      # blindly), we keep the suspects as is.
      :error ->
        prior_suspects

      owned ->
        repo = seams.repo

        # NB (lesson 2026-07-07): we do NOT derive the PR lock from the ownership of the ISSUE. Naive
        # temptation: "a PR whose parent issue is owned is owned too" (to cover a
        # project-scoped producer in rework that holds the PR lock but whose pod only derives
        # the issue). BUT `pod_status` yields `:completed` (publication window → `pod_has_active_task?`
        # counts `:completed` as active, correct for the ISSUE-lock): a DELIVERED engineer (`:completed`,
        # in review) still "owns" its issue → it would then protect the PR lock of a DEAD JUDGE
        # (the PR lock in review belongs to the judge, not the producer) → judge never re-dispatched = WALL
        # (seen live martine-o-matic PR#2). The churn of the PR lock during a REAL producer rework is
        # minor and self-heals (serialize `:role_busy` prevents the double-spawn) — we accept it rather
        # than masking the judge orphans. A clean fix (strict `@active_states` set, excluding
        # `:completed`) requires a rework repro — deferred, no trick under pressure.

        # REPO-QUALIFIED orphans (`{repo, :issue|:pr, n}`): the lock key carries the repo, so
        # `owned` (repo-scoped refs of the live pods of THIS repo) and `prior_suspects` (cross-tick, all
        # repos) no longer collide on the number alone. An orphan #N/repoA is no longer masked by a
        # live pod #N/repoB, and the 2-tick grace no longer contaminates across repos.
        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # an issue with an open PR is in JUDGE phase (lock on the PR side) → not an issue orphan
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {repo, :issue, n}),
              into: MapSet.new(),
              do: {repo, :issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {repo, :pr, n}),
              into: MapSet.new(),
              do: {repo, :pr, n}

        orphaned_now = MapSet.union(issue_orphans, pr_orphans)
        to_reclaim = MapSet.intersection(orphaned_now, prior_suspects)
        Enum.each(to_reclaim, fn {_repo, _type, n} -> reclaim_lock(seams, n) end)
        MapSet.difference(orphaned_now, to_reclaim)
    end
  end

  # Refs `{repo, :issue|:pr, n}` that a pod is REALLY working, derived from the deterministic STABLE pod_ids
  # (`<repo-slug>-issue-<n>-<role>` / `<repo-slug>-pr-<n>-<role>`; no timestamp suffix).
  # Filters by **active task** (TaskQueue): a lock is legitimately held ONLY while a pod has an active
  # task on it. A LIVE but IDLE pod (long-lived between two reworks, e.g. the engineer) does NOT "own"
  # the lock — otherwise it would mask a DEAD judge and the reconciliation would never reclaim (wedge).
  # `:error` if the enumeration fails (fail-safe: we reclaim nothing blindly).
  #
  # REPO SCOPE: we keep ONLY the pods of `seams.repo` (prefix `PodId.scope_prefix/1`), and the ref
  # yielded CARRIES the repo (`{repo, :issue|:pr, n}`). Without this, a live pod #N/repoB would "own" the global
  # ref `{:issue, N}` → it would MASK the orphan #N/repoA (lock never reclaimed = wedge) AND the 2-tick
  # grace would contaminate cross-repo (double-spawn). The REPO-QUALIFIED lock key = the real identity.
  #
  # G1 — a brick under GATEKEEPER EVAL is owned TOO: during the eval (a claude turn = minutes),
  # the PRODUCER pod is done (dead one-shot or idle) and the GATEKEEPER carries the eval task under a
  # pod_id `permanent-*` (no repo slug) → without `gate_eval_owned_refs`, the ref looked orphaned and
  # the 2-tick grace (~60s) RECLAIMED it in the middle of the eval → re-dispatch of the concurrent step (double
  # workflow_run + ghost verdict on return). The union is done INSIDE the try: a failure to enumerate the
  # evals makes `:error` → the fail-safe "reclaim nothing" covers both sources.
  defp live_owned_refs(%Seams{spawner: spawner, task_queue: tq, repo: repo}) do
    pod_refs =
      spawner.list_pods()
      |> Enum.filter(&pod_has_active_task?(tq, &1[:pod_id]))
      |> Enum.flat_map(&owned_refs_for_pod(&1[:pod_id], repo, tq))
      |> MapSet.new()

    MapSet.union(pod_refs, gate_eval_owned_refs(tq, repo))
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # G1 — refs owned by the ACTIVE GATEKEEPER EVALS of the broker. The source of truth already exists:
  # the eval task (MA-03, self-describing metadata) carries `gate_eval: true` + `resume_n` (issue number)
  # + `resume_payload.repository.full_name` (repo — multi-project: an eval of repoB does NOT own a
  # ref of repoA). ACTIVE states only (`TaskQueue.list_active`): an eval `:cleared` (clobbered by
  # a supersede at enqueue — MA-27 bounds to 1 active work item/pod) or `:completed` (verdict rendered,
  # resume in flight — window covered by the 2-tick grace) no longer owns its ref → the reclaim takes
  # back control and the re-dispatch re-escalates (self-heal bounded by the rework budget). The evals are on
  # ISSUES (the PR judges go through dispatch_review, without a gate) → refs `{repo, :issue, n}`.
  # `function_exported?`: a task_queue stub without `list_active` → empty MapSet (conservative, same
  # pattern as `pod_active_issue_id` — masks nothing it does not know).
  defp gate_eval_owned_refs(tq, repo) do
    if function_exported?(tq, :list_active, 0) do
      for %{metadata: meta} <- tq.list_active(),
          meta["gate_eval"] == true,
          get_in(meta, ["resume_payload", "repository", "full_name"]) == repo,
          n = meta["resume_n"],
          is_integer(n),
          into: MapSet.new(),
          do: {repo, :issue, n}
    else
      MapSet.new()
    end
  end

  # Refs that an ACTIVE pod owns. Per-issue (instance): derived from the pod_id (`-issue-N-` / `-pr-N-`).
  # SLOT-FREEZE — project pipe (pod_id `<repo>-engineer`, NO `-issue-N-`): parse_pod_ref yields [] (its
  # id does not encode the brick), so we derive the brick from its ACTIVE TASK (`issue_id` = `issue-N`).
  # Otherwise the poller thinks the resident eng owns NO lock -> reclaims its own -> loops.
  defp owned_refs_for_pod(pod_id, repo, tq) do
    case parse_pod_ref(pod_id, repo) do
      [] -> project_pod_owned_refs(pod_id, repo, tq)
      refs -> refs
    end
  end

  # A project-scoped pod of THIS repo (scope prefix) owns the ref of its active task (`issue-N` ->
  # {repo, :issue, N}). Keeps the repo SCOPE: an eng of another repo does not own a ref of seams.repo.
  # function_exported?: a task_queue stub without the fn -> [] (conservative, masks nothing).
  defp project_pod_owned_refs(pod_id, repo, tq) do
    with true <- String.starts_with?(pod_id, Fleet.Pilot.PodId.scope_prefix(repo)),
         true <- function_exported?(tq, :pod_active_issue_id, 1),
         {:ok, issue_id} when is_binary(issue_id) <- tq.pod_active_issue_id(pod_id),
         {:ok, n} <- Fleet.Pilot.IssueId.parse(issue_id) do
      [{repo, :issue, n}]
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Does a pod have an ACTIVE task (assigned, not closed)? `{:ok, nil}` = idle. Tolerant (any
  # anomaly → `false`: a pod whose activity cannot be established does not mask an orphan).
  defp pod_has_active_task?(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, nil} -> false
      {:ok, _status} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp pod_has_active_task?(_tq, _), do: false

  # Lock refs that an INSTANCE pod owns, deduced from its pod_id. The FORMAT (`issue|pr` + number)
  # lives in `Fleet.Pilot.PodId.parse_ref/2` (the authority that builds it); here we only SCOPE to the
  # current repo and dress the ref. Effect of the scope: a pod of ANOTHER repo yields `:error` (its slug
  # differs) -> it does not "own" a ref of `seams.repo` -> end of the cross-repo masking (#N/repoB
  # masking the orphan #N/repoA). The ref yielded CARRIES the repo (`{repo, :issue|:pr, n}`) = the complete key
  # (the real identity of the lock).
  defp parse_pod_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    case Fleet.Pilot.PodId.parse_ref(pod_id, repo) do
      {:ok, {phase, n}} -> [{repo, phase, n}]
      :error -> []
    end
  end

  defp parse_pod_ref(_, _), do: []

  defp locked?(item) do
    @in_flight in Enum.map(Map.get(item, "labels") || [], & &1["name"])
  end

  defp reclaim_lock(%Seams{forge: forge, repo: repo, forge_opts: forge_opts}, number) do
    # "reclaiming", NOT "reclaimed": the announce precedes the WRITE (remove_label). A premature "reclaimed"
    # would over-report — on a forge-down the label survives and the lock is NOT actually released.
    Logger.warning(
      "Poller: reconciliation : lock #{@in_flight} ORPHAN on " <>
        "#{repo}##{number} (pod dead without completion) → reclaiming (re-dispatch on next tick)"
    )

    # Stopwatch: stopped ALSO here (dead pod = never went through `unlock`) — otherwise it would run until
    # the next real unlock, counting the dead time as work. Best-effort, symmetric to the spawn —
    # BUT signed with RAW forge_opts (system), NOT `as_role`: the dead pod TOOK its role identity with it
    # (no usable trace at this point, orphan = no live pod left to query). Gitea requires
    # the SAME identity to stop as to start (per-user) → THIS stop will NOT match the stopwatch
    # started `as_role` by the dead pod (known limit, assumed: pod failure case, not the nominal path
    # — cf. `Fleet.Pilot.StepDispatcher.Spawn`/`StepRunCompleter.unlock` for the nominal attribution).
    _ = forge.stop_stopwatch(repo, number, forge_opts)

    # The label removal IS the reclaim: a failed remove_label means the lock is NOT released (the announced
    # reclaim did not take). Self-heals on the next tick (2-tick grace), but it must be VISIBLE, not swallowed.
    case forge.remove_label(repo, number, @in_flight, forge_opts) do
      {:error, reason} ->
        Logger.error(
          "Poller: reconciliation : reclaim of #{repo}##{number} FAILED — #{@in_flight} NOT removed " <>
            "(#{inspect(reason)}) — lock persists, retry next tick"
        )

      _ ->
        :ok
    end
  end
end
