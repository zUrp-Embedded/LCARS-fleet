defmodule Fleet.MCP.PodTools.WorkItems do
  @moduledoc """
  "drive work-item" domain logic — extracted from `Fleet.MCP.PodTools` (which keeps the
  `handle_tool_call/3` routing table and the MCP content format).

  The pod's two channels to the `Fleet.TaskQueue` broker:

    * `get_work_item/1`: IN channel — the pod PULLs its brief. `%{"done" => true}` when
      there is no brief (the pod stops); otherwise `%{"done" => false, "work_item" => %{...}}`.
    * `submit_result/3`: OUT channel — the pod PUSHes its deliverable (`payload`), correlated
      to ONE specific brief by the MANDATORY `work_item_id`.

  Server-side mediation: the pod never touches the TaskQueue directly (the queue, its
  schema, its storage stay invisible to the pod). This module is a **`correlation_id`
  carrier**: `work_item_id` exposed on the `get_work_item` side, validated on the
  `submit_result` side (the broker rejects a `work_item_id` ≠ the active brief).

  Identity (which pod) DOES NOT ARRIVE here: it is resolved upstream by the socket
  acceptor (identity IS the channel) and verified by `PodTools`'s clauses — this module
  receives an already-established `pod_id`, never read off the wire.
  """

  alias Fleet.TaskQueue

  @doc """
  PULLs the pod's active brief from the broker.

  Returns the tool result map (`%{"done" => boolean(), ...}`): `done: true` = no more
  task (the pod stops), otherwise the work item under a JSON envelope (`work_item_id` =
  correlation_id, exposed so the pod hands it back to `submit_result`).
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
        case TaskQueue.submit_result(pod_id, Map.put(payload, "work_item_id", work_item_id)) do
          {:ok, _task} ->
            {:ok, "Result received by the fleet. Task closed."}

          {:error, :no_active_work_item} ->
            {:error, :no_active_work_item}

          {:error, :double_submit_ignored} ->
            {:ok, "Result already received (ignored)."}

          {:error, :work_item_id_mismatch} ->
            {:error, :work_item_id_mismatch}

          {:error, {:broadcast_failed, _reason}} ->
            {:error, :broadcast_failed}
        end
    end
  end

  # Accept the canonical top-level correlator or a judge payload's explicit copy.
  defp effective_work_item_id(args, payload) do
    present_work_item_id(Map.get(args, "work_item_id") || Map.get(args, :work_item_id)) ||
      present_work_item_id(Map.get(payload, "work_item_id") || Map.get(payload, :work_item_id))
  end

  defp present_work_item_id(tid) when is_binary(tid) and tid != "", do: tid
  defp present_work_item_id(_), do: nil

  # JSON envelope of the work order exposed to the pod — work_item_id = correlation_id.
  #
  # `brief_ref`/`brief_sha` = the ADDRESS of the physical brief (`briefs/issue-<n>-<role>.md`
  # committed in ops; `gate-briefs/` for judges; `brief_sha` = the introducing COMMIT).
  # Exposed so the pod CITES the version it acted on, auditable from the forge by any third party.
  #
  # WHAT `"brief"` CARRIES: the FULL TEXT of the order, always. The dispatcher resolves the pinned
  # object and ships its content — the pod never fetches anything, and it has no path to the tree
  # that object lives in.
  #
  # This comment claimed the opposite for one commit longer than it was true, and the cost was
  # measured: it described the field as a short pointer into a mounted ops, which is what the
  # rail did BEFORE the order was weaned off that mount. A reader — human or agent — meets the
  # claim before the code, so a stale comment on a payload contract does not sit inert: it sends
  # the next change to the wrong mechanism.
  #
  # nil `brief_ref`/`brief_sha` means the order was never materialized (transient failure, marked
  # unprovable) or a non-producer mandate: nothing to cite, the text stands alone.
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
