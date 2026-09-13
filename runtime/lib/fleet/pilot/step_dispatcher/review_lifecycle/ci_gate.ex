defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate do
  @moduledoc """
  Checks CI before summoning a pending judge when the supplied policy is :required.
  Success passes its SHA and named contexts to BriefBuilder; it does not attest test
  coverage or proof. Failure requests rework. Pending and absent statuses never pass.

  Waiting uses the PR's updated_at, not commit age or persisted time first seen.
  More than 45 minutes escalates pending/none; no workflow can escalate immediately,
  and unclaimed job labels can escalate after 5 minutes. These are observations of
  a possible blockage, not proof of a missing runner. An unreadable date leaves the
  generic wait unbounded with a distinct reason. Other PR updates can move this clock.
  """

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  # Operational waiting threshold; exceeding it does not prove a run is orphaned.
  @pending_deadline_sec 45 * 60

  # Probe unclaimed jobs sooner than unfinished CI; a busy runner pool can look unclaimed too.
  @unclaimed_deadline_sec 5 * 60

  # Inspect both workflow locations to avoid declaring a rail absent after checking only one.
  @workflow_dirs [".gitea/workflows", ".github/workflows"]

  # Keep distinct reasons in the type and callers for source-based wait-label contracts.
  @type wait_reason ::
          :ci_pending
          | {:ci_head_unreadable, term()}
          | {:ci_unreadable, term()}
          | {:ci_deadline_unreachable, term()}

  @type decision ::
          {:proceed, ci_fact :: map() | nil}
          | {:refuse, :ci_red, String.t()}
          | {:wait, wait_reason()}
          | {:escalate, {:ci_stalled, atom()} | {:ci_impossible, :no_workflow}, String.t()}

  @doc """
  Only :required invokes the gate; every other policy value returns {:proceed, nil}.
  The policy callback must validate its vocabulary. Successful required CI returns
  a SHA/context fact for the judge, without proving which harness should have run.
  """
  @spec decide(integer(), String.t(), Ctx.t(), (-> :required | :ignore)) :: decision()
  def decide(pr_number, head, %Ctx{} = ctx, policy_fun) do
    case policy_fun.() do
      :required -> gate(pr_number, head, ctx)
      _ -> {:proceed, nil}
    end
  end

  defp gate(pr_number, head, %Ctx{} = ctx) do
    case head_commit(pr_number, head, ctx) do
      {:ok, sha, committed_at} ->
        classify(sha, committed_at, pr_number, ctx)

      {:error, reason} ->
        {:wait, {:ci_head_unreadable, reason}}
    end
  end

  # Report supplied contexts; this module cannot verify they cover the project's intended proof.
  defp classify(sha, committed_at, pr_number, %Ctx{} = ctx) do
    case ci_report(sha, ctx) do
      {:ok, :success, contexts} ->
        {:proceed, %{state: :success, sha: sha, contexts: contexts}}

      {:ok, :failure, _} ->
        {:refuse, :ci_red,
         "CI ROUGE sur #{String.slice(sha, 0, 8)} — aucun juge n'est convoqué sur du rouge. " <>
           "Le rail machine a rendu son verdict avant le jury : corrige, pousse, la CI se relance."}

      {:ok, :pending, _} ->
        stalled_or_wait(:pending, sha, committed_at, pr_number)

      {:ok, :none, _} ->
        no_status_yet_or_never(sha, committed_at, pr_number, ctx)

      {:error, reason} ->
        {:wait, {:ci_unreadable, reason}}
    end
  end

  # Prefer the report API; legacy clients lacking it return the status with empty contexts.
  defp ci_report(sha, %Ctx{} = ctx) do
    if Fleet.Opts.exported?(ctx.forge, :commit_ci_report, 3) do
      case ctx.forge.commit_ci_report(ctx.repo, sha, ctx.forge_opts) do
        {:ok, {state, contexts}} -> {:ok, state, contexts}
        {:error, _} = err -> err
      end
    else
      case ctx.forge.commit_ci_state(ctx.repo, sha, ctx.forge_opts) do
        {:ok, state} -> {:ok, state, []}
        {:error, _} = err -> err
      end
    end
  end

  # No YAML workflow names in either readable directory is an immediate missing-rail diagnosis.
  # Failed listings preserve uncertainty; the generic deadline can still expire afterward.
  defp no_status_yet_or_never(sha, committed_at, pr_number, %Ctx{} = ctx) do
    case declares_workflow?(sha, ctx) do
      :no ->
        {:escalate, {:ci_impossible, :no_workflow},
         "AUCUN WORKFLOW dans ce depot (#{Enum.join(@workflow_dirs, " ni ")}) au sha " <>
           "#{String.slice(sha, 0, 8)} (PR ##{pr_number}), et la carte de ce projet exige la CI. " <>
           "Aucun statut ne viendra jamais : ce n'est pas une attente, c'est une impasse. " <>
           "Ajoute un workflow, ou declare une carte dont `ci` vaut `ignore`."}

      _yes_or_unknown ->
        unclaimed_or_wait(sha, committed_at, pr_number, ctx)
    end
  end

  # After the short PR-age threshold, named unclaimed jobs justify an actionable question.
  # They do not establish that no runner supports the labels, or how long each job waited.
  defp unclaimed_or_wait(sha, committed_at, pr_number, %Ctx{} = ctx) do
    with true <- past?(committed_at, @unclaimed_deadline_sec),
         {:ok, [_ | _] = labels} <- unclaimed_labels(sha, ctx) do
      {:escalate, {:ci_stalled, :unclaimed},
       "AUCUN RUNNER n'a reclame ce job depuis plus de " <>
         "#{div(@unclaimed_deadline_sec, 60)} min sur #{String.slice(sha, 0, 8)} " <>
         "(PR ##{pr_number}) — il demande #{inspect(labels)}. Un runner sert-il ce label ? " <>
         "Un job jamais reclame ne rougit jamais : il bloque la fusion en ressemblant a du travail."}
    else
      _ -> stalled_or_wait(:none, sha, committed_at, pr_number)
    end
  end

  # Empty results can mean claimed jobs, no runs, unreadable jobs or missing job labels.
  defp unclaimed_labels(sha, %Ctx{} = ctx) do
    runs_fun = Keyword.get(ctx.opts, :runs_for_sha_fun, &default_runs_for_sha/4)
    jobs_fun = Keyword.get(ctx.opts, :run_jobs_fun, &default_run_jobs/3)

    with {:ok, runs} <- runs_fun.(ctx.repo, sha, [], ctx.forge_opts) do
      labels =
        runs
        |> Enum.flat_map(&jobs_of_run(&1, jobs_fun, ctx))
        |> Enum.filter(&unclaimed?/1)
        |> Enum.flat_map(&Payload.labels/1)
        |> Enum.uniq()

      {:ok, labels}
    end
  end

  # Bench API responses used queued; retain waiting for compatibility with the internal spelling.
  @unclaimed_statuses ["queued", "waiting"]

  defp unclaimed?(job) do
    Map.get(job, "status") in @unclaimed_statuses and Map.get(job, "runner_id") in [nil, 0]
  end

  defp past?(nil, _sec), do: false
  defp past?(committed_at, sec), do: age_sec(committed_at) > sec

  # Use the shared :forge_actions runtime seam also used by probe/seal paths;
  # Actions is not a direct compile-time boundary export.
  defp forge_actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)

  # An unreadable run contributes no jobs but does not discard observations from other runs.
  defp jobs_of_run(run, jobs_fun, %Ctx{} = ctx) do
    case jobs_fun.(ctx.repo, Map.get(run, "id"), ctx.forge_opts) do
      {:ok, jobs} -> jobs
      _ -> []
    end
  end

  defp default_runs_for_sha(repo, sha, filters, opts),
    do: forge_actions().runs_for_sha(repo, sha, filters, opts)

  defp default_run_jobs(repo, run_id, opts), do: forge_actions().jobs(repo, run_id, opts)

  defp declares_workflow?(ref, %Ctx{} = ctx) do
    lister = Keyword.get(ctx.opts, :list_dir_fun, &Fleet.Forge.Client.Files.list_dir/3)
    opts = Keyword.put(ctx.forge_opts, :ref, ref)

    Enum.reduce_while(@workflow_dirs, :no, fn dir, acc ->
      workflow_dir_verdict(lister.(ctx.repo, dir, opts), acc)
    end)
  end

  defp workflow_dir_verdict({:ok, names}, acc),
    do: if(Enum.any?(names, &workflow_file?/1), do: {:halt, :yes}, else: {:cont, acc})

  # The directory is absent — that is an ANSWER, and it is "not here".
  defp workflow_dir_verdict({:error, :not_found}, acc), do: {:cont, acc}

  # Anything else is a forge we could not read. Unknown, and unknown is not absent.
  defp workflow_dir_verdict({:error, _}, _acc), do: {:cont, :unknown}

  defp workflow_file?(name) when is_binary(name),
    do: String.ends_with?(name, ".yml") or String.ends_with?(name, ".yaml")

  defp workflow_file?(_), do: false

  # Missing date returns a distinct wait/ci reason rather than an invented age or escalation.
  # No persistent first-seen clock exists here, so this wait can remain unbounded.
  defp stalled_or_wait(_state, _sha, nil, _pr_number),
    do: {:wait, {:ci_deadline_unreachable, :no_pull_date}}

  defp stalled_or_wait(state, sha, committed_at, pr_number) do
    if age_sec(committed_at) > @pending_deadline_sec do
      {:escalate, {:ci_stalled, state},
       "CI #{state} depuis plus de #{div(@pending_deadline_sec, 60)} min sur " <>
         "#{String.slice(sha, 0, 8)} (PR ##{pr_number}) — un runner sert-il ce label ? " <>
         "Le gate n'attend pas indéfiniment : il le DIT."}
    else
      {:wait, :ci_pending}
    end
  end

  # Read head SHA and PR updated_at together; there is no fallback to the branch ref here.
  # Missing SHA is an error; missing date flows to the deadline-unreachable wait.
  defp head_commit(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} ->
        # Unexpected outer return shapes raise instead of being mislabeled as a missing SHA.
        case Payload.head_sha(pull) do
          sha when is_binary(sha) -> {:ok, sha, pull_updated_at(pull)}
          _ -> {:error, {:no_head_sha, head}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # PR updated_at is the clock proxy; it is not restricted to changes of head SHA.
  defp pull_updated_at(pull) do
    with str when is_binary(str) <- Payload.updated_at(pull),
         {:ok, dt, _} <- DateTime.from_iso8601(str) do
      dt
    else
      _ -> nil
    end
  end

  # Handle missing dates before age calculation so they cannot silently become age zero.
  defp age_sec(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :second)

  @doc """
  Shares the 45-minute PR-update threshold with post-merge-failure remediation.
  Returns :unknown when the head/date cannot be read; the caller chooses its wait reason.
  """
  @spec pending_stalled?(integer(), String.t(), Ctx.t()) :: :stalled | :waiting | :unknown
  def pending_stalled?(pr_number, head, %Ctx{} = ctx) do
    case head_commit(pr_number, head, ctx) do
      {:ok, _sha, %DateTime{} = committed_at} ->
        if age_sec(committed_at) > @pending_deadline_sec, do: :stalled, else: :waiting

      _ ->
        :unknown
    end
  end

  @doc """
  Exposes the threshold for an independent assertion. Test fixtures must use their
  own expected duration: deriving fixture ages from this value would hide threshold drift.
  """
  @spec pending_deadline_sec() :: pos_integer()
  def pending_deadline_sec, do: @pending_deadline_sec
end
