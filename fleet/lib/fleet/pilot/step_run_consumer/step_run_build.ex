defmodule Fleet.Pilot.StepRunConsumer.StepRunBuild do
  @moduledoc """
  Builds the PR-native step-run map from a completed pod and a resolved route.

  Producers receive git deliverable options for their own feature branch. Judges resolve the unique
  open Fleet PR for the issue and carry a fail-closed native review; an absent or ambiguous producer
  branch remains `nil` for the completer to reject.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Per-run repository context and dependencies used to build a step run.
    """
    @enforce_keys [:repo, :remote, :role_emails, :deliverable_mode_fun, :forge_opts]
    defstruct [
      :repo,
      :remote,
      :role_emails,
      :deliverable_mode_fun,
      :forge_client,
      :forge_opts
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            remote: String.t() | nil,
            role_emails: (String.t() -> [String.t()]),
            deliverable_mode_fun: (String.t() -> {:ok, String.t()} | {:error, term()}),
            forge_client: module() | nil,
            forge_opts: keyword()
          }
  end

  @typedoc """
  Route decided by the gate engine or a judge verdict.
  """
  @type route :: %{
          required(:intent) => atom(),
          required(:next_assignee) => String.t() | nil,
          required(:next_step) => String.t() | nil,
          optional(:comment_body) => String.t() | nil,
          optional(:judge_target) => String.t() | nil
        }

  @doc """
  Builds the map consumed by `StepRunCompleter.complete_pr/2`.
  """
  @spec build(map(), pos_integer(), String.t(), route(), Seams.t()) :: map() | {:error, term()}
  def build(payload, n, role, route, %Seams{} = seams) do
    # DR-013
    case classify_pr_role(payload, n, role, seams) do
      {:error, _} = err ->
        err

      {pr_role, producer_branch} ->
        build_step_run(payload, n, role, route, seams, pr_role, producer_branch)
    end
  end

  defp build_step_run(payload, n, role, route, seams, pr_role, producer_branch) do
    %{
      repo: seams.repo,
      pod_id: payload["pod_id"],
      issue_number: n,
      role: role,
      pr_role: pr_role,
      intent: route.intent,
      next_assignee: route.next_assignee,
      next_step: route.next_step,
      workflow_map: payload["workflow_map"],
      producer_branch: producer_branch,
      base_branch: payload["pr_base_branch"] || payload["base_branch"]
    }
    |> put_unless_nil(:comment_body, Map.get(route, :comment_body))
    |> put_unless_nil(:judge_target, Map.get(route, :judge_target))
    |> put_unless_nil(:brief_sha, payload["brief_sha"])
    |> put_unless_nil(:brief_ref, payload["brief_ref"])
    |> maybe_put_deliverable(pr_role, role, payload, n, seams)
    |> maybe_put_review_event(pr_role, route.intent, payload)
    |> maybe_put_eng_summary(pr_role, payload)
  end

  defp classify_pr_role(payload, n, role, seams) do
    case GateEngine.producer?(role, seams.deliverable_mode_fun, payload["deliverable_mode"]) do
      {:ok, true} ->
        {:producer, Fleet.Pilot.ForgeProtocol.feature_branch(n, role)}

      {:ok, false} ->
        {:judge, judge_producer_branch(payload, n, seams)}

      {:error, _} = err ->
        err
    end
  end

  defp judge_producer_branch(_payload, n, seams) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient

    with {:ok, pulls} <- forge.list_open_pulls(seams.repo, seams.forge_opts),
         head when is_binary(head) <- producer_head_for_issue(pulls, n) do
      head
    else
      _ -> nil
    end
  end

  defp producer_head_for_issue(pulls, n) do
    case pulls
         |> Fleet.Pilot.ForgeProtocol.fleet_prs_by_issue()
         |> Enum.filter(&match?({^n, _}, &1)) do
      [] ->
        nil

      [{^n, pr}] ->
        get_in(pr, ["head", "ref"])

      several ->
        numbers = Enum.map(several, fn {_n, pr} -> pr["number"] end)

        Logger.error(
          "StepRunConsumer: issue ##{n} has #{length(several)} open fleet PRs #{inspect(numbers)} " <>
            "— one issue = one producer branch; REFUSING to pick one arbitrarily (treated as " <>
            "no-producer-head; close the stray PR to unblock)"
        )

        nil
    end
  end

  defp maybe_put_deliverable(step_run, :producer, role, payload, n, seams),
    do: Map.put(step_run, :deliverable_opts, build_deliverable_opts(role, payload, n, seams))

  defp maybe_put_deliverable(step_run, :judge, _role, _payload, _n, _seams), do: step_run

  defp build_deliverable_opts(role, payload, n, seams) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      base_sha: payload["gate_base_sha"] || payload["base_sha"],
      allowed_emails: seams.role_emails.(role),
      coauthor_role: role,
      remote: seams.remote,
      target_branch: Fleet.Pilot.ForgeProtocol.feature_branch(n, role),
      push?: true,
      local_ref: "HEAD"
    }
  end

  defp maybe_put_review_event(step_run, :judge, :reviewed, payload) do
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})
    event = Verdict.review_event(Verdict.gate_decision(result))
    step_run = Map.put(step_run, :review_event, event)

    case Verdict.judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(step_run, :review_body, body)
      _ -> step_run
    end
  end

  defp maybe_put_review_event(step_run, _pr_role, _intent, _payload), do: step_run

  defp maybe_put_eng_summary(step_run, :producer, payload) do
    case Verdict.eng_summary(payload) do
      "" -> step_run
      summary -> Map.put(step_run, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(step_run, _pr_role, _payload), do: step_run

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
