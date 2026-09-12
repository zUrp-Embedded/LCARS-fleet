defmodule Fleet.Spawner.Pod.CompletedPayload do
  @moduledoc """
  Builds the `pod.completed` payload consumed by `Fleet.Pilot.StepRunConsumer`.

  Every payload carries `pod_id`, `issue_id` and `result`, plus brief kind when supplied.
  An effective project with a non-empty repo_path adds workspace, clone/gate bases, role and
  deliverable mode. Repository, workflow-map and brief provenance are added when available.
  """

  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Paths

  @doc """
  Builds a completion payload from immutable pod state and the submitted result.
  """
  @spec build(map(), map()) :: map()
  def build(data, result) do
    opts = data.opts || []

    base =
      %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        "result" => result
      }
      |> maybe_put_brief_kind(opts)

    case LaunchSpec.effective_project(data.opts, data.cap_profile) do
      %{"repo_path" => rp} = proj when is_binary(rp) and rp != "" ->
        base
        |> Map.merge(%{
          "workspace" => Paths.pod_workspace_path(data.pod_dir),
          "base_sha" => proj["base_sha"],
          "base_branch" => proj["base_branch"],
          "pr_base_branch" => proj["pr_base_branch"],
          "gate_base_sha" => proj["gate_base_sha"] || proj["base_sha"],
          "role" => Fleet.CapProfile.name(data.cap_profile),
          "deliverable_mode" => Fleet.CapProfile.deliverable_mode(data.cap_profile)
        })
        |> maybe_put_repo(proj)
        |> maybe_put_workflow_map_ctx(opts)
        |> maybe_put_brief_provenance(opts)

      _ ->
        base
    end
  end

  # StepRunBuild reads the top-level brief_sha supplied by dispatch. The broker's nested
  # result.brief_sha comes from the work item and does not replace this provenance field.
  defp maybe_put_brief_provenance(payload, opts) do
    case Keyword.get(opts, :brief_sha) do
      sha when is_binary(sha) and sha != "" ->
        Map.merge(payload, %{"brief_sha" => sha, "brief_ref" => Keyword.get(opts, :brief_ref)})

      _ ->
        payload
    end
  end

  defp maybe_put_workflow_map_ctx(payload, opts) do
    case {Keyword.get(opts, :workflow_map), Keyword.get(opts, :step)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        Map.merge(payload, %{"workflow_map" => p, "step" => s})

      _ ->
        payload
    end
  end

  defp maybe_put_brief_kind(payload, opts) do
    case Keyword.get(opts, :brief_kind) do
      kind when is_binary(kind) and kind != "" -> Map.put(payload, "brief_kind", kind)
      _ -> payload
    end
  end

  defp maybe_put_repo(payload, %{"repo" => repo} = proj) when is_binary(repo) and repo != "" do
    payload
    |> Map.put("repository", %{"full_name" => repo})
    |> maybe_put_remote(proj["repo_path"])
  end

  defp maybe_put_repo(payload, _proj), do: payload

  defp maybe_put_remote(payload, remote) when is_binary(remote) and remote != "",
    do: Map.put(payload, "remote", remote)

  defp maybe_put_remote(payload, _), do: payload
end
