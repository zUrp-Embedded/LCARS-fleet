defmodule Fleet.MCP.PodTools.JudgeTarget do
  @moduledoc """
  What a judge pod is judging: its repository and pull request come from the channel (the pod's
  identity), never from the call's arguments, and the PR's refs from the forge. Shared by the
  tools that read or measure a delivery for a judge (`run_probe`, `ci_results`), so they cannot
  disagree on which PR a pod judges. An issue-bound pod is not a deliverable judge.
  """

  @doc """
  Resolves `{repo, pr, refs}` for a PR-bound pod. `forge` must provide `repo_full_name/2` and
  `pr_refs/3`; `forge_opts` is passed through.
  """
  @spec resolve(String.t(), module(), keyword()) ::
          {:ok, %{repo: String.t(), pr: pos_integer(), refs: map()}} | {:error, term()}
  def resolve(pod_id, forge, forge_opts) do
    with {:ok, repo} <- repo(pod_id, forge, forge_opts),
         {:ok, pr} <- pr_of(pod_id, repo),
         {:ok, refs} <- forge.pr_refs(repo, pr, forge_opts) do
      {:ok, %{repo: repo, pr: pr, refs: refs}}
    end
  end

  # Dispatched pods can carry repo_id without repo; resolve the numeric id through
  # the forge instead of rejecting the roles these tools serve.
  defp repo(pod_id, forge, forge_opts) do
    case Fleet.MCP.PodTools.PodResolver.resolved().(pod_id) do
      {:ok, %{repo: repo}} when is_binary(repo) and repo != "" ->
        {:ok, repo}

      {:ok, %{repo_id: id}} when is_integer(id) and id > 0 ->
        forge.repo_full_name(id, forge_opts)

      {:ok, _unbound} ->
        {:error, :repo_unbound}

      {:error, _} = err ->
        err
    end
  end

  # Parse the PR from the pod identity; issue-bound pods cannot select an arbitrary PR.
  defp pr_of(pod_id, repo) do
    case Fleet.PodId.parse_ref(pod_id, repo) do
      {:ok, {:pr, n}} -> {:ok, n}
      {:ok, {:issue, _}} -> {:error, :not_a_deliverable_judge}
      :error -> {:error, :pr_unresolvable}
    end
  end
end
