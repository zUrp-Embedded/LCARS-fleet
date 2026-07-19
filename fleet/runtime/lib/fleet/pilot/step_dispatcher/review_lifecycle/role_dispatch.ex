defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch do
  @moduledoc """
  EXECUTION leaf of the review flow (`ReviewLifecycle`): prepares and spawns
  ONE role on a PR — judge (`:judge`) or producer in rework (`:rework`).

  ## Why this cut (and not one per declared cluster)

  The three clusters of `ReviewLifecycle` (routing / rework-conflict / promotion)
  ALL converge on the same PR-role spawn mechanics: splitting routing↔rework into
  two modules would create a cycle (rework calls back the producer spawn). By
  extracting the shared LEAF, the graph becomes a strict DAG:
  routing → remediation → HERE → `Spawn` (global leaf). The decision stays upstream,
  this module EXECUTES (read-only resolutions then spawn, never a policy choice).

  ## Invariants carried here

    * **clone-base = the FEATURE-BRANCH**: the review/rework pod clones `base_branch: head`
      (the judge must see the DIFF, the rework resumes ITS work) — never `main`.
    * **resolutions BEFORE any forge write** (project + route read-only): a failure
      never leaves an orphan lock.
    * **pod identity by scope**: rework = the PRODUCER (`slot_scope` project → `for_repo`,
      SAME identity as the issue flow; instance → `for_issue`); the JUDGE keys on the PR
      (`for_pr`, fan-out by review).
    * **serialization gate**: a busy project-scoped producer → `{:skipped,
      :role_busy}` (retry on the next tick), never re-brief-while-busy.

  Receives the review flow's `%Ctx{}` (built at the single site
  `StepDispatcher.dispatch_review/2`) and re-builds `Spawn.Seams` at the call site of
  the global leaf (narrow boundary preserved).

  **Last revised**: 2026-07-19
  """

  require Logger

  # Authority over the brief FORMAT (worker/judge/rework/conflict): the caller CHOOSES the `kind`,
  # BriefBuilder SHAPES the brief.
  alias Fleet.Pilot.BriefBuilder

  # Single source of the "put the key IF non-nil" idiom (spawn_opts builders).
  alias Fleet.Pilot.Opts

  # SINGLE-AUTHORITY spawn leaf (order lock→pod→enqueue→wake + compensation); its naming
  # helpers (rc_name / maybe_put_route / resolve_repo_id) are shared with the issue flow.
  alias Fleet.Pilot.StepDispatcher.Spawn

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  @typedoc "Nature of the PR dispatch: judge or producer rework."
  @type kind :: :judge | :rework | :conflict_rework

  @doc """
  Prepares and spawns the `role` role on PR `pr_number` (head = the producer's
  feature-branch). Resolves the brick (`parse_feature_branch_or_skip/1`) + the cap-profile,
  then executes. `{:skipped, _}` (non-fleet branch / unknown role / role_busy) bubbles
  up to the poller (retry on the next tick); `{:error, {phase, _}}` = resolution failed
  (no forge write laid).
  """
  @spec dispatch(kind(), integer(), String.t(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch(kind, pr_number, head, role, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx.loader, role) do
      do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx)
    end
  end

  @doc """
  Vocabulary of the fleet feature-branch, mapped to the poller's contract: non-fleet head →
  `{:skipped, :not_fleet_branch}` (never an error — a foreign PR is not an
  anomaly). Shared by the whole review flow (routing/remediation/promotion).
  """
  @spec parse_feature_branch_or_skip(String.t()) ::
          {:ok, {integer(), String.t()}} | {:skipped, :not_fleet_branch}
  def parse_feature_branch_or_skip(head) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, _} = ok -> ok
      :error -> {:skipped, :not_fleet_branch}
    end
  end

  defp load_role_or_skip(_loader, ""), do: {:skipped, :no_role}

  defp load_role_or_skip(loader, role) do
    case loader.load(role) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:skipped, :no_role}
    end
  end

  defp do_dispatch_review(pr_number, issue_n, head, role, profile, kind, %Ctx{} = ctx) do
    # Spawner/task_queue are not read here directly: they transit via `ctx` to `spawn_step`.
    %Ctx{
      repo: repo,
      forge: forge,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    # The review pod (judge) OR rework pod (producer) clones the FEATURE-BRANCH (`head.ref`), NOT
    # `main`: the judge must see the producer's DIFF (otherwise it judges `main`, i.e. nothing real);
    # the rework resumes ITS own work. Read-only on the code via the workspace provisioned by the
    # system (the pod has no forge token). `base_branch: head` → the pod CLONES and starts from the
    # feature-branch tip. (There is NO rebase-resolution role — merge conflicts are ESCALATED to
    # the architect; the pod is forge-blind and cannot rebase; cf. `ArchEscalation`.)
    review_opts = Keyword.put(opts, :base_branch, head)

    # Read-only pre-lock phase, CHEAP GATES FIRST (SAME rule/order as dispatch_issue,
    # lockstep): route (light forge GET on the issue) → pod identity → LOCAL scope gate → project
    # resolver (the heavy network call, 1-2× ls-remote) on the passing path only → reprovision
    # action. The forge LOCK (spawn_step) still comes after everything — no orphan lock on a
    # transient failure (invariant unchanged).
    # No captures — Spawn.route_for/Opts.tag_err taken at the source (shared with the issue flow).
    with {:ok, route} <-
           Opts.tag_err(Spawn.route_for(forge, repo, issue_n, forge_opts), :route_resolution),
         # pod_id: rework/conflict = the PRODUCER, routed by `slot_scope` (project → for_repo = SAME
         # identity as dispatch_issue, ONE per project; instance → for_issue). The JUDGE keys on the PR
         # (for_pr, fan-out by review). The rework re-reads its state FROM THE FORGE (PR + findings) →
         # changing the pod identity loses no context.
         pod_id =
           (case kind do
              k when k in [:rework, :conflict_rework] ->
                Spawn.pod_id_for_scope(Fleet.CapProfile.slot_scope(profile), repo, issue_n, role)

              _ ->
                Fleet.Pilot.PodId.for_pr(repo, pr_number, role)
            end),
         # Scope DECISION (SAME rule as dispatch_issue): a project-scoped producer already alive
         # (busy with another issue) → we DEFER, never re-brief-while-busy. Judges (instance) and
         # instance rework → `:proceed` (never gated). `{:skipped, :role_busy}` bubbles up to the
         # poller (which handles `{:skipped, _}` → retry on the next tick).
         decision =
           Spawn.project_scope_decision(
             Fleet.CapProfile.lifetime_scope(profile),
             ctx.spawner,
             pod_id
           ),
         :ok <- Spawn.gate_scope_decision(decision),
         {:ok, project} <- Opts.tag_err(resolver.(repo, review_opts), :project_resolution),
         :ok <- Spawn.maybe_reprovision(decision, ctx.spawner, pod_id, project, "work") do
      # :judge -> GateBrief defused; :rework -> brief to the PRODUCER (fix + push).
      case review_brief(
             kind,
             profile,
             role,
             forge,
             repo,
             issue_n,
             forge_opts,
             route,
             pr_number
           ) do
        {:ok, brief, brief_kind} ->
          spawn_opts =
            [brief: brief, brief_kind: brief_kind, pod_id: pod_id, rc_name: Spawn.rc_name(repo, role)]
            |> Opts.maybe_put(:project, project)
            |> Spawn.maybe_put_route(route)
            |> Opts.maybe_put(:repo_id, Spawn.resolve_repo_id(forge, repo, forge_opts))

          # Spawn LEAF shared with dispatch_issue (lock → pod → enqueue → wake + compensation).
          # Lock keyed on the PR (pr_number); issue_id + enqueue keyed on the ISSUE (issue_n — the
          # pipeline-state stays there). We build the seams struct at this site from `ctx` (the 6
          # seams, not the whole `ctx` — hardened boundary).
          log_ctx = "review pr=#{repo}##{pr_number} issue=##{issue_n}"

          Spawn.spawn_step(
            %Spawn.Seams{
              forge: ctx.forge,
              spawner: ctx.spawner,
              task_queue: ctx.task_queue,
              repo: ctx.repo,
              forge_opts: ctx.forge_opts,
              wake_recovery: ctx.wake_recovery
            },
            pod_id,
            role,
            profile,
            brief,
            spawn_opts,
            pr_number,
            issue_n,
            log_ctx
          )

        # The DELIVERABLE-judge's criterion (issue body) could not be READ from the forge
        # (transient/unreachable). We REFUSE to spawn a criterion-less judge (the diff without a
        # criterion → blind approval = false GREEN) → we DEFER; the lock lives in `BriefBuilder`.
        # The judge is instance-scoped (the scope gate returned `:proceed` WITHOUT taking a lock)
        # → nothing to release; the poller re-dispatches on the next tick (read-error ≠ absence).
        {:error, {:criterion_unavailable, reason}} ->
          Logger.warning(
            "StepDispatcher: judge criterion unavailable role=#{role} pr=#{repo}##{pr_number} → " <>
              "#{inspect(reason)} (skip, retry — refuse criterion-less judge)"
          )

          {:skipped, :criterion_unavailable}
      end
    else
      {:skipped, :role_busy} ->
        {:skipped, :role_busy}

      {:error, {phase, reason}} ->
        Logger.warning(
          "StepDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, no lock)"
        )

        {:error, {phase, reason}}
    end
  end

  # Brief of a PR dispatch: :judge -> GateBrief defused (via build_brief, the pod
  # judges the issue); :rework -> rework brief to the PRODUCER (fixes per the review, re-pushes).
  # PR-judge path — no workflow_map step here (PR-driven judges) → `step_spec = %{}`:
  # build_brief falls back to the profile's `brief_kind` (judge for qualifier/reviewer) AND to the
  # default `judge_target` (deliverable) → build_judge_brief (judges the deliverable/PR).
  # `{:ok, brief, kind} | {:error, {:criterion_unavailable, _}}` — the error is reachable ONLY on the
  # deliverable-judge path (a forge read-error on the criterion DEFERS, never a criterion-less
  # judge). rework builds unconditionally (feedback in hand) → always `{:ok, _, "worker"}` (a rework
  # brief is EXECUTABLE, addressed to the producer — it lands under `briefs/`, not `gate-briefs/`).
  defp review_brief(:judge, profile, role, forge, repo, issue_n, forge_opts, route, _pr),
    do:
      BriefBuilder.build_brief(
        profile,
        role,
        forge,
        repo,
        issue_n,
        %{},
        forge_opts,
        route,
        %{}
      )

  defp review_brief(:rework, _profile, role, forge, repo, _issue_n, forge_opts, route, pr),
    do: {:ok, BriefBuilder.rework_brief(role, forge, repo, pr, forge_opts, route), "worker"}

  # Conflict-rework (étage 1 — Remediation.conflict_rework): the SAME producer rework, with the
  # merge-conflict section leading the brief instead of judge feedback (there is none: the jury
  # APPROVED — main simply moved under the branch).
  defp review_brief(:conflict_rework, _profile, role, forge, repo, _issue_n, forge_opts, route, pr),
    do:
      {:ok, BriefBuilder.rework_brief(role, forge, repo, pr, forge_opts, route, conflict: true),
       "worker"}
end
