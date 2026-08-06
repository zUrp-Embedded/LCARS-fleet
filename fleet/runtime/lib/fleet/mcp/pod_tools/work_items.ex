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
      sees a failure instead of believing its deliverable accepted. Recovery (CI-03): the broker
      commits `:completed` only AFTER a confirmed broadcast (broadcast-before-commit), so on
      failure the item STAYS ACTIVE → a pod re-submit RE-PLAYS the delivery (re-broadcast) — the
      intra-uptime backstop. A re-submit that DOES deliver returns `{:ok, "Result received"}`;
      `{:ok, "already received"}` is now returned only for a genuinely-delivered item. The
      across-restart backstop stays the poller/forge reconciliation (the still-active lock is
      reclaimed if the pod dies before re-submitting). The pod is not left believing success
      while the forge lock stays set for life.
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

  # JSON envelope of the work order exposed to the pod — work_item_id = correlation_id.
  #
  # `brief_ref`/`brief_sha` = the ADDRESS of the physical brief (`briefs/issue-<n>-<role>.md`
  # committed in work/ops; `gate-briefs/` for judges; `brief_sha` = the introducing COMMIT).
  # Exposed so the pod CITES the version it acted on, auditable from the forge by any third party.
  #
  # WHAT `"brief"` CARRIES, and it is not what this comment used to claim. On the nominal path it
  # is the SHORT POINTER (`BriefArtifact.pointer_brief/2`): "your complete work order is the
  # committed doc <ref> @ <sha7> — READ IT FIRST in ${LCARS_PROJECT_OPS}/<ref>". The full text is
  # NOT delivered here; the pod reads it in the RO bind of its project's work/ops worktree, and the
  # SP says the same (`runtime-contract.md`: "the work_item's `brief` field is only a short
  # pointer; the committed doc is the single source").
  #
  # The inline text appears on exactly ONE path: the transient materialization failure, where the
  # dispatcher marks the order unprovable and sends it whole. That is the DEGRADED case, and this
  # comment described it as the rule — which cost two turns of design analysis in the chantier that
  # rewrote this line, on the wrong mechanism, because a reader met the claim before the code.
  #
  # nil `brief_ref`/`brief_sha` therefore means exactly that degraded path, or a non-producer
  # mandate: nothing to cite.
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
