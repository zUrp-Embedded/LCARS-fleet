defmodule Fleet.TaskQueue.WorkItem do
  @moduledoc """
  The work item — the TaskQueue's unit.

  `id` = the work item's UUID v4 (= the canonical `correlation_id`, propagated end-to-end).
  Distinct from `pod_id` (the target pod's session UUID).
  """

  @type state :: :pending | :assigned | :in_progress | :completed | :failed | :cleared

  @type t :: %__MODULE__{
          id: String.t(),
          pod_id: String.t(),
          issue_id: String.t() | nil,
          role: String.t() | nil,
          brief: String.t() | nil,
          deadline: DateTime.t() | nil,
          retry_count: non_neg_integer(),
          enqueued_at: DateTime.t(),
          assigned_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          state: state(),
          result: map() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :pod_id, :enqueued_at, :state]
  defstruct [
    :id,
    :pod_id,
    :issue_id,
    :role,
    :brief,
    :deadline,
    :enqueued_at,
    :assigned_at,
    :completed_at,
    :result,
    state: :pending,
    # NB: VESTIGIAL field, never incremented (always 0). The system-side bounded retry is NOT
    # here (it must not be influenceable by the pod): the forge-driven rail is what bounds the
    # rework, outside the pod-facing work item. Kept for schema compat (serialized); to be wired as
    # an observability mirror or removed (a design decision, not an oversight).
    retry_count: 0,
    metadata: %{}
  ]

  @doc "Serializes a work item into a JSON-able map (persistence `state.json`)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "pod_id" => t.pod_id,
      "issue_id" => t.issue_id,
      "role" => t.role,
      "brief" => t.brief,
      "deadline" => iso(t.deadline),
      "retry_count" => t.retry_count,
      "enqueued_at" => iso(t.enqueued_at),
      "assigned_at" => iso(t.assigned_at),
      "completed_at" => iso(t.completed_at),
      "state" => Atom.to_string(t.state),
      "result" => t.result,
      "metadata" => t.metadata
    }
  end

  @doc """
  Deserializes from the persisted map. `{:error, :invalid}` if a required field is absent OR `state` is unknown.

  SINGLE parser → `rich_from_map`, which reconstructs ALL the fields: no competing "minimal" clause
  that would mask the recovery of `brief`/`role`/`issue_id`/`deadline`/`result`/`metadata`.
  `state` via a closed list (not `to_existing_atom`, which RAISES on a corrupt `state.json` and bypasses `:corrupt`).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map), do: rich_from_map(map)
  def from_map(_), do: {:error, :invalid}

  # Reconstructs ALL the fields (required + optional). State via a CLOSED list (not to_existing_atom).
  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    # `enqueued_at` is REQUIRED (@enforce_keys + find_active's DateTime sort key): an invalid ISO
    # must FAIL-LOUD here, NOT silently become nil (otherwise boot OK then crash at sort time).
    # The other DateTimes (deadline/assigned/completed) are optional → nil OK.
    with {:ok, st} <- parse_state(state),
         {:ok, eat} <- parse_required_dt(enq) do
      {:ok,
       %__MODULE__{
         id: id,
         pod_id: pod_id,
         issue_id: m["issue_id"],
         role: m["role"],
         brief: m["brief"],
         deadline: parse(m["deadline"]),
         retry_count: m["retry_count"] || 0,
         enqueued_at: eat,
         assigned_at: parse(m["assigned_at"]),
         completed_at: parse(m["completed_at"]),
         state: st,
         result: m["result"],
         metadata: m["metadata"] || %{}
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp rich_from_map(_), do: {:error, :invalid}

  # CLOSED list of states (literal atoms ⇒ guaranteed to exist, no atom-leak nor raise).
  defp parse_state("pending"), do: {:ok, :pending}
  defp parse_state("assigned"), do: {:ok, :assigned}
  defp parse_state("in_progress"), do: {:ok, :in_progress}
  defp parse_state("completed"), do: {:ok, :completed}
  defp parse_state("failed"), do: {:ok, :failed}
  defp parse_state("cleared"), do: {:ok, :cleared}
  defp parse_state(_), do: :error

  # `enqueued_at` required → `{:ok, dt} | :error` (vs `parse/1` which tolerates nil for optional fields).
  defp parse_required_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse(nil), do: nil

  defp parse(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
