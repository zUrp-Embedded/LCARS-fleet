defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch do
  @moduledoc """
  Shared execution for PR judges, producer rework and outsider conflict resolution.
  Keeping spawn mechanics here avoids a routing/remediation dependency cycle.

  Pods start from the producer's feature branch. Rework identity follows the profile's
  slot scope; judges use PR identity. Scope guards also apply to long-lived instance
  pods. The forge lock targets the PR, while labels and queued work identify the parent issue.

  Resolution precedes the spawn lock, but role failures may record incidents and
  reprovisioning/base refresh precede brief construction. These steps are not a transaction.
  """

  require Logger

  alias Fleet.Pilot.BriefBuilder

  alias Fleet.Opts

  alias Fleet.Pilot.StepDispatcher.Spawn

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  @typedoc """
  PR dispatch intent. Conflict kinds share mechanics but select owner vs outsider brief
  voices. Keep that distinction independent of the role holding the conflict-resolver
  capability: the outsider has no original producer brief to resume.
  """
  @type kind :: :judge | :rework | :conflict_rework | :conflict_rework_exception

  @doc """
  Resolves the fleet branch and capability profile, prepares the project and dispatches the role.

  Returns skips or phase-tagged errors from supported paths. A conflict refresh returning
  `{:skipped, :stale_base_unrefreshed}` is not covered by the execution `with`'s
  `else` clauses and raises; this function does not normalize all dependency failures.
  """
  @spec dispatch(kind(), integer(), String.t(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch(kind, pr_number, head, role, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx, role) do
      do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx)
    end
  end

  defp maybe_refresh_conflict_base(kind, decision, spawner, pod_id, project)
       when kind in [:conflict_rework, :conflict_rework_exception],
       do: Spawn.refresh_conflict_base(decision, spawner, pod_id, project)

  defp maybe_refresh_conflict_base(_kind, _decision, _spawner, _pod_id, _project), do: :ok

  @doc """
  Maps feature-branch parsing to the poller's skip contract.
  """
  @spec parse_feature_branch_or_skip(String.t()) ::
          {:ok, {integer(), String.t()}} | {:skipped, :not_fleet_branch}
  def parse_feature_branch_or_skip(head) do
    case Fleet.Forge.Protocol.parse_feature_branch(head) do
      {:ok, _} = ok -> ok
      :error -> {:skipped, :not_fleet_branch}
    end
  end

  # Empty means no judge configured; resolution failures below additionally record an incident.
  defp load_role_or_skip(%Ctx{}, ""), do: {:skipped, :no_role}

  defp load_role_or_skip(%Ctx{} = ctx, role) do
    # Compose role modops with resolve's defaults; no repository catalogue root is forwarded here.
    case Fleet.CapProfile.resolve(ctx.loader, role) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        note_unresolvable_role(ctx, role, reason)
        {:skipped, :no_role}
    end
  end

  # Key incidents on the role, not the PR, so one resolution defect across PRs aggregates.
  # Keep the repository in the detail. A returned load error alone does not prove permanence.
  defp note_unresolvable_role(%Ctx{} = ctx, role, reason) do
    incident =
      Keyword.get(ctx.opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

    _ =
      try do
        incident.("review_role", role, :cap_profile_unresolvable,
          reason_detail: "#{ctx.repo}: #{inspect(reason)}"
        )
      catch
        # Exceptions, throws and exits only warn; returned incident errors are ignored.
        kind, why ->
          Logger.warning(
            "StepDispatcher: incident rail unavailable for unresolvable role #{inspect(role)} " <>
              "(#{inspect(kind)} #{inspect(why)}) — the skip stands, its trace does not"
          )
      end

    :ok
  end

  defp do_dispatch_review(pr_number, issue_n, head, role, profile, kind, %Ctx{} = ctx) do
    %Ctx{repo: repo, forge: forge, forge_opts: forge_opts, opts: opts} = ctx

    # Use the feature branch for both judging the diff and resuming work; this is a branch
    # reference, not a snapshot shared atomically with later forge reads.
    review_opts = Keyword.put(opts, :base_branch, head)

    with {:ok, %{route: route, pod_id: pod_id, decision: decision, project: project}} <-
           prepare_dispatch(kind, pr_number, issue_n, role, profile, ctx, review_opts),
         :ok <- Spawn.maybe_reprovision(decision, ctx.spawner, pod_id, project, "work"),
         # A pod rebriefed in place may retain a stale lcars/base ref; conflict kinds refresh it.
         :ok <- maybe_refresh_conflict_base(kind, decision, ctx.spawner, pod_id, project) do
      case review_brief(kind, ctx, profile, role, issue_n, route, pr_number, review_opts) do
        {:ok, brief, brief_kind, mandate} ->
          project_slug = Fleet.Layout.project_slug(repo)

          spawn_opts =
            [
              brief: brief,
              brief_kind: brief_kind,
              pod_id: pod_id,
              # Human labels follow the parent issue even when the dispatch is driven by a PR.
              rc_name: Fleet.Layout.pod_label(project_slug, role, issue_n),
              project_slug: project_slug
            ]
            |> Opts.maybe_put(:project, project)
            |> Spawn.maybe_put_route(route)
            |> Opts.maybe_put(:repo_id, Spawn.resolve_repo_id(forge, repo, forge_opts))
            # Carry the mandate from the same build that generated its mounted path in the brief.
            |> Opts.maybe_put(:mandate, mandate)

          # Lock on the PR; queue against the parent issue where pipeline state lives.
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
            %Spawn.Order{
              pod_id: pod_id,
              role: role,
              profile: profile,
              brief: brief,
              spawn_opts: spawn_opts,
              lock_target: pr_number,
              issue_number: issue_n,
              log_ctx: log_ctx
            }
          )

        # An unreadable deliverable criterion skips before the spawn lock; reprovisioning may
        # already have happened. This does not prove that all earlier work was read-only.
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

  # Read route, derive identity, check scope, then resolve the project on the passing path.
  # The spawn lock is acquired later.
  defp prepare_dispatch(kind, pr_number, issue_n, role, profile, %Ctx{} = ctx, review_opts) do
    %Ctx{repo: repo, forge: forge, resolver: resolver, forge_opts: forge_opts} = ctx

    with {:ok, route} <-
           Opts.tag_err(Spawn.route_for(forge, repo, issue_n, forge_opts), :route_resolution),
         # Rework preserves the producer's scope-based identity; judges fan out by PR.
         pod_id =
           (case kind do
              k when k in [:rework, :conflict_rework, :conflict_rework_exception] ->
                Spawn.pod_id_for_scope(Fleet.CapProfile.slot_scope(profile), repo, issue_n, role)

              _ ->
                Fleet.PodId.for_pr(repo, pr_number, role)
            end),
         # Long-lived scopes consult readiness before reuse; instance scope is not a blanket bypass.
         decision =
           Spawn.project_scope_decision(
             Fleet.CapProfile.lifetime_scope(profile),
             ctx.spawner,
             pod_id,
             Fleet.CapProfile.slot_scope(profile)
           ),
         :ok <- Spawn.gate_scope_decision(decision),
         {:ok, project} <- Opts.tag_err(resolver.(repo, review_opts), :project_resolution) do
      # Completion needs the target face separately from the cloned feature branch.
      {:ok,
       %{
         route: route,
         pod_id: pod_id,
         decision: decision,
         project: stamp_pr_base(project, review_opts)
       }}
    end
  end

  # Carry a nonempty PR target base into CompletedPayload; a nil project stays nil.
  defp stamp_pr_base(nil, _opts), do: nil

  defp stamp_pr_base(project, opts) when is_map(project) do
    case Keyword.get(opts, :pr_base_branch) do
      base when is_binary(base) and base != "" -> Map.put(project, "pr_base_branch", base)
      _ -> project
    end
  end

  # With no step override, the profile selects brief_kind and judge_target defaults.
  # Forward options including measured CI facts, gray-zone data and the builder's ops root.
  defp review_brief(:judge, %Ctx{} = ctx, profile, role, issue_n, route, _pr, opts),
    do:
      BriefBuilder.build_brief(
        profile,
        role,
        %BriefBuilder.Access{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts},
        issue_n,
        %{},
        route,
        %{},
        opts
      )

  defp review_brief(:rework, %Ctx{} = ctx, _profile, role, _issue_n, route, pr, _opts),
    do:
      {:ok, BriefBuilder.rework_brief(role, ctx.forge, ctx.repo, pr, ctx.forge_opts, route),
       "worker", nil}

  # Producer voice resumes its own work; the PR's actual target base is required.
  defp review_brief(:conflict_rework, %Ctx{} = ctx, _profile, role, _issue_n, route, pr, opts),
    do:
      {:ok,
       BriefBuilder.rework_brief(role, ctx.forge, ctx.repo, pr, ctx.forge_opts, route,
         conflict: :producer,
         base_branch: Keyword.fetch!(opts, :pr_base_branch)
       ), "worker", nil}

  # Outsider voice must not imply ownership of the producer's original brief.
  defp review_brief(
         :conflict_rework_exception,
         %Ctx{} = ctx,
         _profile,
         role,
         _issue_n,
         route,
         pr,
         opts
       ),
       do:
         {:ok,
          BriefBuilder.rework_brief(role, ctx.forge, ctx.repo, pr, ctx.forge_opts, route,
            conflict: :exception,
            base_branch: Keyword.fetch!(opts, :pr_base_branch)
          ), "worker", nil}
end
