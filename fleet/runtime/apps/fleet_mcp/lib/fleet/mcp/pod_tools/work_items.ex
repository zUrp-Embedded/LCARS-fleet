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
  PUSHes the deliverable (`payload`) to the broker, correlated by `work_item_id`.

  The correlator is looked up at the top-level of `args` (canonical format) THEN in the
  `payload` (a judge agent sometimes tucks it into its verdict payload). Absent from
  BOTH → `{:error, :work_item_id_required}`. The broker then validates pod_id ↔
  work_item_id and broadcasts `%Fleet.Event{work_item.completed}`.

  Returns:

    * `{:ok, message}` — deliverable accepted (or idempotent double submit: the 1st submit
      IS recorded, the duplicate is ignored with a dedicated message).
    * `{:error, :no_active_work_item}` — no active brief: the deliverable has NOWHERE
      to go (never assigned, or closed/reassigned since) → DROP reported as an error,
      never masked as a success (otherwise the pod believes its deliverable accepted).
    * `{:error, :work_item_id_mismatch}` — the correlator does not name the pod's active
      brief (the broker's anti-impersonation lock).
    * `{:error, :broadcast_failed}` — the `work_item.completed` lifecycle broadcast
      failed: the step_run will NOT finish (the StepRunConsumer received nothing). The pod
      must see a failure → it can re-submit (the broadcast will be re-emitted), instead of
      believing its deliverable accepted while the forge lock stays set for life.
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
            {:ok, "Resultat recu par le fleet. Tache close."}

          {:error, :no_active_work_item} ->
            {:error, :no_active_work_item}

          {:error, :double_submit_ignored} ->
            {:ok, "Resultat deja recu (ignore)."}

          {:error, :work_item_id_mismatch} ->
            {:error, :work_item_id_mismatch}

          {:error, {:broadcast_failed, _reason}} ->
            {:error, :broadcast_failed}
        end
    end
  end

  # The `work_item_id` (correlator) looked up at the wire top-level THEN in the payload: a judge agent
  # sometimes tucks the correlator INTO its verdict payload rather than at the top-level parameter. Returns the
  # non-empty work_item_id found (top-level takes priority), or nil if absent from both. The broker then correlates on
  # `result["work_item_id"]` and rejects (`:work_item_id_mismatch`) if it does not match ITS active brief → a pod
  # cannot close another pod's task (a lock orthogonal to the transport). The location (top-level vs
  # payload) does NOT enter into the security: the work_item_id stays explicit and validated; only the
  # implicit "last active" fallback was the hole.
  defp effective_work_item_id(args, payload) do
    present_work_item_id(Map.get(args, "work_item_id") || Map.get(args, :work_item_id)) ||
      present_work_item_id(Map.get(payload, "work_item_id") || Map.get(payload, :work_item_id))
  end

  defp present_work_item_id(tid) when is_binary(tid) and tid != "", do: tid
  defp present_work_item_id(_), do: nil

  # JSON envelope of the brief exposed to the pod — work_item_id = correlation_id.
  defp envelope(%Fleet.TaskQueue.WorkItem{} = t) do
    %{
      "work_item_id" => t.id,
      "issue_id" => t.issue_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
