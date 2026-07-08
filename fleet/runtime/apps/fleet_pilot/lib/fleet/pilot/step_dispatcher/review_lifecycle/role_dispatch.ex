defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch do
  @moduledoc """
  EXECUTION leaf of the review flow, extracted from `ReviewLifecycle`: prepares and spawns
  ONE role on a PR — judge (`:judge`), producer in rework (`:rework`), producer in
  conflict resolution (`:resolve_conflict`).

  ## Why this cut (and not one per declared cluster)

  The three clusters of `ReviewLifecycle` (routing / rework-conflict / promotion)
  ALL converge on the same PR-role spawn mechanics: splitting routing↔rework into
  two modules would create a cycle (rework calls back the producer spawn). By
  extracting the shared LEAF, the graph becomes a strict DAG:
  routing → remediation → HERE → `Spawn` (global leaf). The decision stays upstream,
  this module EXECUTES (read-only resolutions then spawn, never a policy choice).

  ## Invariants carried here

    * **clone-base vs gate-base**: the review/rework pod clones the FEATURE-BRANCH
      (`base_branch: head` — the judge must see the DIFF, the rework resumes ITS work);
      a RESOLUTION (rebase) keeps the feature as clone-base but pins the ancestor
      gate to `main` (`gate_base_branch` — the feature tip is rewritten by the
      rebase, it would no longer be an ancestor).
    * **resolutions BEFORE any forge write** (project + route read-only): a failure
      never leaves an orphan lock.
    * **pod identity by scope**: rework/conflict = the PRODUCER (`slot_scope` project
      → `for_repo`, SAME identity as the issue flow; instance → `for_issue`); the JUDGE
      keys on the PR (`for_pr`, fan-out by review).
    * **serialization gate**: a busy project-scoped producer → `{:skipped,
      :role_busy}` (retry on the next tick), never re-brief-while-busy.

  Receives the review flow's `%Ctx{}` (built at the single site
  `StepDispatcher.dispatch_review/2`) and re-builds `Spawn.Seams` at the call site of
  the global leaf (narrow boundary preserved).
  """

  require Logger

  # Authority over the brief FORMAT (worker/judge/rework/conflict): the caller CHOOSES the `kind`,
  # BriefBuilder SHAPES the brief.
  alias Fleet.Pilot.BriefBuilder

  # Single source of the "put the key IF non-nil" idiom (spawn_opts builders).
  alias Fleet.Pilot.Opts

  # SINGLE-AUTHORITY spawn leaf (order lock→pod→enqueue→wake + compensation).
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Spawn opts builders / naming (rc_name / maybe_put_route / resolve_repo_id) — shared
  # with the issue flow (StepDispatcher), a single copy.
  alias Fleet.Pilot.StepDispatcher.Spawn.Naming

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  @typedoc "Nature of the PR dispatch: judge, producer rework, or conflict resolution (rebase)."
  @type kind :: :judge | :rework | :resolve_conflict

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
    # system (the pod has no forge token). `base_branch: head` → the pod CLONES and
    # starts from the feature-branch tip.
    #
    # The RESOLUTION (rebase) ALSO starts from the feature (its work to rebase),
    # but its deliverable must DESCEND from `main` (the rebase target), not from the old feature tip
    # (rewritten by the rebase → the gate would reject it: `base_not_ancestor`). We
    # DECONFLATE the two roles otherwise carried by `base_sha`: `base_branch` = clone-base (feature, the pod
    # starts from there, UNCHANGED); `gate_base_branch` = "main" → the resolver pins the GATE base to `main`.
    # judge/rework (forward, no rewrite): no `gate_base_branch` → gate = clone-base, unchanged.
    review_opts =
      opts
      |> Keyword.put(:base_branch, head)
      |> maybe_gate_base_main(kind)

    # PROJECT + ROUTE resolved BEFORE any forge write (read-only): a failure leaves no
    # orphan lock. The route (workflow_map_name, step) is read on the ISSUE (the pipeline-state stays there).
    # `route_reader`/`err_tagger` = captures of the core's helpers (route_for/tag_err), shared with the issue flow.
    with {:ok, project} <- ctx.err_tagger.(resolver.(repo, review_opts), :project_resolution),
         {:ok, route} <-
           ctx.err_tagger.(ctx.route_reader.(forge, repo, issue_n, forge_opts), :route_resolution) do
      # pod_id: rework/conflict = the PRODUCER, routed by `slot_scope` (project → for_repo = SAME
      # identity as dispatch_issue, ONE per project; instance → for_issue). The JUDGE keys on the PR
      # (for_pr, fan-out by review). The rework re-reads its state FROM THE FORGE (PR + findings) →
      # changing the pod identity loses no context.
      pod_id =
        case kind do
          k when k in [:rework, :resolve_conflict] ->
            Spawn.pod_id_for_scope(Fleet.CapProfile.slot_scope(profile), repo, issue_n, role)

          _ ->
            Fleet.Pilot.PodId.for_pr(repo, pr_number, role)
        end

      # Serialization gate (SAME rule as dispatch_issue): a project-scoped producer already alive
      # (busy with another issue) → we DEFER, never re-brief-while-busy. Judges (instance) and
      # instance rework → `:ok` (no-op, never gated). Uniform call via `slot_scope`. `{:skipped,
      # :role_busy}` bubbles up to the poller (which handles `{:skipped, _}` → retry on the next tick).
      case Spawn.serialize_project_scope(
             Fleet.CapProfile.slot_scope(profile),
             Fleet.CapProfile.lifetime_scope(profile),
             ctx.spawner,
             pod_id,
             project,
             "work"
           ) do
        {:skipped, :role_busy} ->
          {:skipped, :role_busy}

        :ok ->
          # :judge -> GateBrief defused; :rework -> brief to the PRODUCER (fix + push).
          brief =
            review_brief(
              kind,
              profile,
              role,
              forge,
              repo,
              issue_n,
              forge_opts,
              route,
              pr_number
            )

          spawn_opts =
            [brief: brief, pod_id: pod_id, rc_name: Naming.rc_name(repo, role)]
            |> Opts.maybe_put(:project, project)
            |> Naming.maybe_put_route(route)
            |> Opts.maybe_put(:repo_id, Naming.resolve_repo_id(forge, repo, forge_opts))

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
      end
    else
      {:error, {phase, reason}} ->
        Logger.warning(
          "StepDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, no lock)"
        )

        {:error, {phase, reason}}
    end
  end

  # DECONFLATION clone-base / gate-base. A RESOLUTION (rebase) starts from the
  # feature (clone-base, its work) but its deliverable must DESCEND from `main` (rebase target) → the
  # gate bases on `main`, not on the old feature tip (rewritten by the rebase, hence not an
  # ancestor). judge/rework (forward, no rewrite): no divergence → gate = clone-base.
  defp maybe_gate_base_main(opts, :resolve_conflict),
    do: Keyword.put(opts, :gate_base_branch, "main")

  defp maybe_gate_base_main(opts, _kind), do: opts

  # Brief of a PR dispatch: :judge -> GateBrief defused (via build_brief, the pod
  # judges the issue); :rework -> rework brief to the PRODUCER (fixes per the review, re-pushes).
  # PR-judge path — no workflow_map step here (PR-driven judges) → `step_spec = %{}`:
  # build_brief falls back to the profile's `brief_kind` (judge for qualifier/reviewer) AND to the
  # default `judge_target` (deliverable) → build_judge_brief (judges the deliverable/PR).
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
    do: BriefBuilder.rework_brief(role, forge, repo, pr, forge_opts, route)

  defp review_brief(
         :resolve_conflict,
         _profile,
         role,
         forge,
         repo,
         _issue_n,
         forge_opts,
         route,
         pr
       ),
       do: BriefBuilder.resolve_conflict_brief(role, forge, repo, pr, forge_opts, route)
end
