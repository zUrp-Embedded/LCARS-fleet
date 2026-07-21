defmodule Fleet.Pilot.Poller.Reconciliation do
  @moduledoc """
  IMPURE "orphan reconciliation" cluster of `Fleet.Pilot.Poller` — TWO symmetric duties on the
  same tick, the same suspect set and the same 2-tick grace:

  **(1) Orphaned lock** (label without pod). A `lcars-in-flight` lock is ORPHANED if the brick
  carries it but no live pod is working it. Cause: a dead pod (`:result_timeout` deadline, crash,
  BEAM restart) reaped by the PodWarden — which removes the PROCESS but NOT the forge label.
  Broken symmetry → without repair the `dispatch_*` skips the `:in_flight` brick FOREVER (a single
  pod stall wedges the pipe). Repair: reclaim (remove the label) the CONFIRMED orphans → the next
  tick re-dispatches.

  **(2) Quiesced pod** (pod without lock — the inverse). A live PER-BRICK pod (judge, one-shot
  gatekeeper) whose brick no longer holds the lock and which has no active task has no reason to
  live: a one-shot never "ends itself" (the pod model is a persistent interactive PTY) — without
  this reap it idles at the prompt INDEFINITELY (the `max_alive_sec` cap was nuked 2026-07-20 —
  this reap IS the lifetime mechanism, not a belt) and gets re-briefed by the next dispatch
  (live 2026-07-19: the #5 zombie loop). Repair: `Spawn.safe_kill` the CONFIRMED quiesced pods
  (cf. `quiesced_brick_pods`). This is the NOMINAL end-of-life of per-brick pods.

  ## What this module does / does NOT do

  It READS 5 seams (`%Seams{}`) and yields the NEW set of suspects (`MapSet.t()`) — it WRITES no
  poller state. The **2-tick grace** (only accumulate a suspect over two consecutive ticks) and
  the **cross-repo aggregation** (`MapSet.union` of the suspects of all the repos of a tick) are
  CROSS-TICK state: they STAY at the core (`Fleet.Pilot.Poller` — `do_poll`/`step_do_poll` passes
  THIS repo's subset of the previous tick's suspects as `prior_suspects` and re-writes the yielded
  set into the state).

  ## 2-REGULAR-tick grace + REPO-QUALIFIED refs (load-bearing semantics)

  We only reclaim a CONFIRMED orphan: `reconcile/5` intersects the orphans seen THIS tick with
  `prior_suspects` (the orphans seen at the PREVIOUS tick) — never a freshly dispatched pod (not
  yet registered) or one in the process of dying. The grace unit is the REGULAR tick (~30s):
  webhook kick-polls are dispatch-only and NEVER call `reconcile/5` (counting them would compress
  the ~60s grace to the webhook rate — reclaim mid-publication, double dispatch).
  The lock refs are REPO-QUALIFIED (`{repo, :issue|:pr, n}`): the key carries the repo, so the
  refs of the live pods (`owned`, scoped to the current repo) and the suspects (repo-scoped by
  the caller) cannot collide on the number alone. An orphan #N/repoA is not masked by
  a live pod #N/repoB, and the grace does not contaminate across repos.

  ## Fail-safe

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

  Dependencies (never `Fleet.Pilot.Poller` → no cycle): `Fleet.Labels` (single source of the
  lock), `Fleet.Pilot.PodId` (format of the pod_ids), `Fleet.Pilot.IssueId` (parse issue_id),
  `Fleet.Pilot.StepDispatcher.Spawn.safe_kill/2` (SINGLE kill authority — never forked) + the
  injected seams (spawner/task_queue/forge).

  **Last revised**: 2026-07-21
  """

  require Logger

  # workflow_run lock: single source `Fleet.Labels` (compile-time constant). SAME source as
  # the `@in_flight` of the core `Poller` (which keeps its own for the fast-path `classify_issue`) — not a
  # fork of a literal, the authority stays `Labels.in_flight/0`.
  @in_flight Fleet.Labels.in_flight()

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

  `prior_suspects` = THIS repo's orphans seen at the PREVIOUS regular tick (2-tick grace, carried
  by the core — the caller passes the repo-scoped subset, never the whole cross-repo union: the
  union let an error branch resurrect suspects resolved on other repos). Side effect: removes the
  forge label (`reclaim_lock/2`) of the CONFIRMED orphans (seen at both ticks). The yielded set =
  the orphans of THIS tick not yet reclaimed (those awaiting their 2nd confirmation).

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

        # NB: we do NOT derive the PR lock from the ownership of the ISSUE.
        # Naive temptation: "a PR whose parent issue is owned is owned too". TWO reasons it stays wrong:
        #  (1) a DELIVERED engineer would protect the PR lock of a DEAD JUDGE (the PR lock in review belongs
        #      to the judge, not the producer) → judge never re-dispatched = WALL. The PR-lock churn
        #      during a REAL producer rework is minor and
        #      self-heals (serialize `:role_busy` prevents the double-spawn).
        #  (2) `pod_has_active_task?` does not count `:completed` as owning: `:completed` is
        #      TERMINAL (`WorkItem.active?/1`) — a delivered engineer's completion (push → open PR →
        #      unlock) is running-or-done, its lock is released at the END. Counting it as active would
        #      mask an orphaned ISSUE lock FOREVER when the completion is LOST before open_pr (permanent
        #      silent wedge). The legitimate publication window (push ≤30s) is covered by the 2-REGULAR-tick
        #      grace (~60s at the 30s interval — webhook kick-polls never enter reconcile, so the forge
        #      traffic of the completion sequence itself cannot compress this window)
        #      + the idempotent completion sequence (a late reclaim = a harmless replay), so excluding
        #      `:completed` reclaims the lost-completion orphan WITHOUT churning the nominal window.

        # REPO-QUALIFIED orphans (`{repo, :issue|:pr, n}`): the lock key carries the repo, so
        # `owned` (repo-scoped refs of the live pods of THIS repo) and `prior_suspects` (cross-tick,
        # repo-scoped by the caller) cannot collide on the number alone. An orphan #N/repoA is not
        # masked by a live pod #N/repoB, and the 2-tick grace does not contaminate across repos.
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

        # SYMMETRIC duty — the INVERSE orphan (pod without lock): a live per-brick pod whose
        # brick is quiesced. Same suspect set, same 2-tick grace: the entries are tagged
        # `{repo, :pod, pod_id}` — the same 3-tuple shape as the lock refs, so the core's
        # repo-filter (`fn {r, _type, _n} -> r == repo end`) threads them with ZERO plumbing.
        zombie_pods = quiesced_brick_pods(issues, pulls, seams)

        orphaned_now = issue_orphans |> MapSet.union(pr_orphans) |> MapSet.union(zombie_pods)
        to_act = MapSet.intersection(orphaned_now, prior_suspects)

        Enum.each(to_act, fn
          {_repo, :pod, pod_id} -> reap_pod(seams, pod_id)
          {_repo, _type, n} -> reclaim_lock(seams, n)
        end)

        MapSet.difference(orphaned_now, to_act)
    end
  end

  # SYMMETRIC duty — the inverse orphan: a LIVE per-brick pod (pod_id encodes `-issue-N-`/`-pr-N-`
  # — judges, one-shot gatekeepers; resident/permanent pods carry no brick ref → structurally
  # exempt, their lifecycle is elsewhere: slot-freeze for the resident eng, forever for the
  # permanents) whose brick no longer holds the `lcars-in-flight` lock (verdict consumed,
  # awaits-arch park, merge done, brick closed) AND which holds no active task (belt — same
  # authority `pod_has_active_task?` as the lock duty: a gatekeeper mid-eval is never reaped).
  #
  # Live case 2026-07-19: a consultant idled INTERACTIVELY for 16 min after its redirect verdict.
  # A one-shot does NOT "end itself" — the pod model is a persistent interactive PTY (tmux), so
  # after the verdict the session sits at the prompt indefinitely (no lifetime cap since
  # `max_alive_sec` was nuked 2026-07-20) and re-briefed by the next dispatch (the #5 zombie loop
  # fed on this). No reason to live → reaped; a later re-dispatch re-spawns fresh (idempotent
  # dispatch, seed resume).
  # Fail-safe: enumeration failure → empty set (never kill blindly).
  defp quiesced_brick_pods(issues, pulls, %Seams{} = seams) do
    locked_issues = for i <- issues, locked?(i), into: MapSet.new(), do: i["number"]
    locked_prs = for p <- pulls, locked?(p), into: MapSet.new(), do: p["number"]

    seams.spawner.list_pods()
    |> Enum.flat_map(fn pod ->
      pod_id = pod[:pod_id]

      case parse_pod_ref(pod_id, seams.repo) do
        [{repo, phase, n}] ->
          locked? =
            (phase == :issue and MapSet.member?(locked_issues, n)) or
              (phase == :pr and MapSet.member?(locked_prs, n))

          if locked? or pod_has_active_task?(seams.task_queue, pod_id),
            do: [],
            else: [{repo, :pod, pod_id}]

        _ ->
          []
      end
    end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  # The reap is the NOMINAL end-of-life of a per-brick pod since 2026-07-19 (a one-shot never
  # "ends itself", cf. quiesced_brick_pods) → `info`, not warning (≠ reclaim_lock, which flags an
  # ANOMALY). Kill via the SINGLE authority `Spawn.safe_kill/2` (no fork of the kill wrapper);
  # a kill that fails is swallowed there — the next tick re-suspects, self-healing.
  defp reap_pod(%Seams{spawner: spawner, repo: repo}, pod_id) do
    Logger.info(
      "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} " <>
        "(brick unlocked, no active task) → reaped (a re-dispatch re-spawns fresh)"
    )

    Fleet.Pilot.StepDispatcher.Spawn.safe_kill(spawner, pod_id)
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
  # A brick under GATEKEEPER EVAL is owned TOO: during the eval (a claude turn = minutes),
  # the PRODUCER pod is done (dead one-shot or idle) and the GATEKEEPER carries the eval task under a
  # pod_id `permanent-*` (no repo slug) → without `gate_eval_owned_refs`, the ref would look orphaned
  # and the 2-tick grace (~60s) would RECLAIM it mid-eval → re-dispatch of the concurrent step (double
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
  # the eval task metadata is self-describing: it carries `gate_eval: true` + `resume_n` (issue number)
  # + `resume_payload.repository.full_name` (repo — multi-project: an eval of repoB does NOT own a
  # ref of repoA). ACTIVE states only (`TaskQueue.list_active`): an eval `:cleared` (clobbered by
  # a supersede at enqueue — 1 active work item/pod bound) or `:completed` (verdict rendered,
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

  # Does a pod have an ACTIVE task (owns its slot/lock)? The state of the pod's latest task (`pod_status`)
  # must be ACTIVE per the SINGLE AUTHORITY `WorkItem.active?/1` (`:pending`/`:assigned`/`:in_progress`).
  # `{:ok, nil}` (idle) and the TERMINAL states (`:completed`/`:failed`/`:cleared`) → `false`: a delivered
  # (`:completed`) pod no longer owns its lock (F-C050 — else a completion LOST before open_pr wedges the
  # lock forever). Tolerant (any anomaly → `false`: a pod whose activity cannot be established masks no orphan).
  defp pod_has_active_task?(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, state} -> Fleet.TaskQueue.WorkItem.active?(state)
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
    # the next real unlock, counting the dead time as work. Result discarded (`_ =`): the stopwatch is
    # time-tracking, not a pipeline invariant — a failed stop costs attribution minutes, never the reclaim
    # (the remove_label below carries the real op and logs error on failure). Symmetric to the spawn —
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
