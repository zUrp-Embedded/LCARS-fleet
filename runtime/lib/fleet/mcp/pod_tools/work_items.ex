defmodule Fleet.MCP.PodTools.WorkItems do
  @moduledoc """
  TaskQueue adapter for pod work-item pulls and correlated submissions.
  PodTools supplies the channel's pod_id; this module does not authenticate it.
  Pull exposes work_item_id; submission requires that explicit correlator and lets
  the broker validate it against the pod's work.
  """

  alias Fleet.TaskQueue

  @doc """
  Returns done: true when no task is available, otherwise the work-item envelope.
  The pod must return its work_item_id with the deliverable.
  """
  @spec get_work_item(String.t()) :: map()
  def get_work_item(pod_id) when is_binary(pod_id) and pod_id != "" do
    case TaskQueue.get_for_pod(pod_id) do
      {:ok, task} -> %{"done" => false, "work_item" => envelope(task)}
      {:error, :no_work_item} -> %{"done" => true}
    end
  end

  @doc """
  Submits a deliverable with an explicit correlator. CI-03 keeps the item active
  when completion broadcast fails, so resubmission replays delivery.
  """
  @spec submit_result(String.t(), map(), map()) :: {:ok, String.t()} | {:error, atom()}
  def submit_result(pod_id, args, payload)
      when is_binary(pod_id) and pod_id != "" and is_map(args) and is_map(payload) do
    case effective_work_item_id(args, payload) do
      nil ->
        {:error, :work_item_id_required}

      work_item_id ->
        pod_id
        |> TaskQueue.submit_result(Map.put(payload, "work_item_id", work_item_id))
        |> submit_outcome()
    end
  end

  defp submit_outcome({:ok, _task}), do: {:ok, "Result received by the fleet. Task closed."}

  defp submit_outcome({:error, :double_submit_ignored}),
    do: {:ok, "Result already received (ignored)."}

  # Unlike an accepted duplicate, an unpulled item has no acknowledged delivery.
  defp submit_outcome({:error, :work_item_not_pulled}), do: {:error, :work_item_not_pulled}
  defp submit_outcome({:error, :no_active_work_item}), do: {:error, :no_active_work_item}
  defp submit_outcome({:error, :work_item_id_mismatch}), do: {:error, :work_item_id_mismatch}
  defp submit_outcome({:error, {:broadcast_failed, _reason}}), do: {:error, :broadcast_failed}

  # Accept the canonical top-level correlator or a judge payload's explicit copy.
  defp effective_work_item_id(args, payload) do
    present_work_item_id(Map.get(args, "work_item_id") || Map.get(args, :work_item_id)) ||
      present_work_item_id(Map.get(payload, "work_item_id") || Map.get(payload, :work_item_id))
  end

  defp present_work_item_id(tid) when is_binary(tid) and tid != "", do: tid
  defp present_work_item_id(_), do: nil

  # brief carries the full order text; the pod does not fetch a mounted ops tree.
  # Optional brief_ref/brief_sha identify the committed version for audit (briefs/ or
  # gate-briefs/). Nil pointers can mean failed materialization or a mandate without an artifact.
  defp envelope(%Fleet.TaskQueue.WorkItem{} = t) do
    %{
      "work_item_id" => t.id,
      "issue_id" => t.issue_id,
      "role" => t.role,
      "brief" => t.brief,
      "brief_ref" => t.brief_ref,
      "brief_sha" => t.brief_sha,
      "deadline" => iso(t.deadline)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
