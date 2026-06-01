defmodule Fleet.TaskQueue.Task do
  @moduledoc """
  Le mandat — unité de la TaskQueue. Cf. DN `orchestration/task-queue` §A.

  `id` = UUID v4 du mandat (= `correlation_id` canonique, propagé end-to-end).
  Distinct de `pod_id` (UUID de session du pod cible).
  """

  @type state :: :pending | :assigned | :in_progress | :completed | :failed | :cleared

  @type t :: %__MODULE__{
          id: String.t(),
          pod_id: String.t(),
          ticket_id: String.t() | nil,
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
    :ticket_id,
    :role,
    :brief,
    :deadline,
    :enqueued_at,
    :assigned_at,
    :completed_at,
    :result,
    state: :pending,
    retry_count: 0,
    metadata: %{}
  ]

  @doc "Sérialise un mandat en map JSON-able (persistence `state.json`)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "pod_id" => t.pod_id,
      "ticket_id" => t.ticket_id,
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

  @doc "Désérialise depuis la map persistée. `{:error, :invalid}` si champ requis absent."
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(%{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state})
      when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    {:ok,
     %__MODULE__{
       id: id,
       pod_id: pod_id,
       ticket_id: nil,
       role: nil,
       brief: nil,
       deadline: nil,
       retry_count: 0,
       enqueued_at: parse(enq),
       assigned_at: nil,
       completed_at: nil,
       state: String.to_existing_atom(state),
       result: nil,
       metadata: %{}
     }}
  end

  def from_map(map) when is_map(map), do: rich_from_map(map)
  def from_map(_), do: {:error, :invalid}

  # Reconstruit tous les champs optionnels en plus des requis.
  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    {:ok,
     %__MODULE__{
       id: id,
       pod_id: pod_id,
       ticket_id: m["ticket_id"],
       role: m["role"],
       brief: m["brief"],
       deadline: parse(m["deadline"]),
       retry_count: m["retry_count"] || 0,
       enqueued_at: parse(enq),
       assigned_at: parse(m["assigned_at"]),
       completed_at: parse(m["completed_at"]),
       state: String.to_existing_atom(state),
       result: m["result"],
       metadata: m["metadata"] || %{}
     }}
  end

  defp rich_from_map(_), do: {:error, :invalid}

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
