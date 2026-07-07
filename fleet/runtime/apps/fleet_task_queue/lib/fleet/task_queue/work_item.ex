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

  @doc """
  Smart constructor for a FRESH work item (used by `enqueue`). Casts the caller `attrs` (atom OR
  string keys) to the struct types — `deadline` (DateTime | ISO string → DateTime | nil), `metadata`
  (a map), `issue_id`/`role`/`brief` (binary | nil) — so the queue never stores a semi-typed struct
  (a string `deadline` would silently arm no watchdog; a non-map `metadata` would crash any JSON-event
  consumer). `id` (UUID v4) + `enqueued_at` (now) + `state: :pending` are set here; `retry_count` stays
  0 (never pod-influenceable). `{:error, {:bad_attr, {field, value}}}` on a malformed attr.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, {:bad_attr, term()}}
  def new(pod_id, attrs) when is_binary(pod_id) and is_map(attrs) do
    with {:ok, deadline} <- cast_deadline(fetch(attrs, :deadline)),
         {:ok, metadata} <- cast_map(fetch(attrs, :metadata) || %{}, :metadata),
         {:ok, issue_id} <- cast_str_nil(fetch(attrs, :issue_id), :issue_id),
         {:ok, role} <- cast_str_nil(fetch(attrs, :role), :role),
         {:ok, brief} <- cast_str_nil(fetch(attrs, :brief), :brief) do
      {:ok,
       %__MODULE__{
         id: UUID.uuid4(),
         pod_id: pod_id,
         issue_id: issue_id,
         role: role,
         brief: brief,
         deadline: deadline,
         enqueued_at: DateTime.utc_now(),
         state: :pending,
         metadata: metadata
       }}
    end
  end

  # attrs may carry atom OR string keys (enqueue callers use both).
  defp fetch(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  # Reconstructs ALL the fields (required + optional). State via a CLOSED list (not to_existing_atom).
  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    # `enqueued_at` is REQUIRED (@enforce_keys + find_active's DateTime sort key): an invalid ISO
    # must FAIL-LOUD here, NOT silently become nil (otherwise boot OK then crash at sort time).
    # The other DateTimes (deadline/assigned/completed) are optional → nil OK.
    # Optional fields via the SAME casters as `new/2` (SSoT): a malformed one (non-map metadata/result,
    # non-neg-int retry_count, non-binary id/role/brief) is CORRUPTION → `:invalid` (→ the Server's
    # `state.corrupt` path), NOT a silent coercion that would crash a downstream reader.
    with {:ok, st} <- parse_state(state),
         {:ok, eat} <- parse_required_dt(enq),
         {:ok, issue_id} <- cast_str_nil(m["issue_id"], :issue_id),
         {:ok, role} <- cast_str_nil(m["role"], :role),
         {:ok, brief} <- cast_str_nil(m["brief"], :brief),
         {:ok, retry_count} <- cast_retry(m["retry_count"]),
         {:ok, result} <- cast_result(m["result"], :result),
         {:ok, metadata} <- cast_map(m["metadata"] || %{}, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         pod_id: pod_id,
         issue_id: issue_id,
         role: role,
         brief: brief,
         # deadline/assigned/completed stay TOLERANT (parse → nil on a bad ISO): an optional timestamp
         # that no longer parses just becomes nil on recovery (no re-arm), not a corrupt-the-whole-state.
         deadline: parse(m["deadline"]),
         retry_count: retry_count,
         enqueued_at: eat,
         assigned_at: parse(m["assigned_at"]),
         completed_at: parse(m["completed_at"]),
         state: st,
         result: result,
         metadata: metadata
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

  # Shared casters (SSoT, used by BOTH `new/2` [strict → {:bad_attr}] and `rich_from_map` [→ :invalid]).
  defp cast_deadline(nil), do: {:ok, nil}
  defp cast_deadline(%DateTime{} = dt), do: {:ok, dt}

  defp cast_deadline(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:bad_attr, {:deadline, s}}}
    end
  end

  defp cast_deadline(v), do: {:error, {:bad_attr, {:deadline, v}}}

  defp cast_map(m, _field) when is_map(m), do: {:ok, m}
  defp cast_map(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_result(nil, _field), do: {:ok, nil}
  defp cast_result(m, _field) when is_map(m), do: {:ok, m}
  defp cast_result(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_str_nil(nil, _field), do: {:ok, nil}
  defp cast_str_nil(s, _field) when is_binary(s), do: {:ok, s}
  defp cast_str_nil(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_retry(nil), do: {:ok, 0}
  defp cast_retry(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp cast_retry(v), do: {:error, {:bad_attr, {:retry_count, v}}}

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
