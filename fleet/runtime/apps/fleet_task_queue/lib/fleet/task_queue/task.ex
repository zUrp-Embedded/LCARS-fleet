defmodule Fleet.TaskQueue.Task do
  @moduledoc """
  Le mandat — unité de la TaskQueue.

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
    # NB : champ VESTIGIAL jamais incrémenté (toujours 0). Le retry borné système-side N'est PAS
    # ici — il vit dans `Fleet.Pipeline.Executor` (`retry_counts`, autorité per-run), volontairement HORS
    # du Task pod-facing (le compteur ne doit pas être influençable par le pod). Conservé pour compat de
    # schéma (sérialisé) ; à câbler en miroir d'observabilité ou retirer (décision de design, pas un oubli).
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

  @doc """
  Désérialise depuis la map persistée. `{:error, :invalid}` si champ requis absent OU `state` inconnu.

  Parser UNIQUE → `rich_from_map`, qui reconstruit TOUS les champs : pas de clause « minimale »
  concurrente qui masquerait la recovery de `brief`/`role`/`ticket_id`/`deadline`/`result`/`metadata`.
  `state` via liste fermée (pas `to_existing_atom`, qui RAISE sur un `state.json` corrompu et bypasse `:corrupt`).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid}
  def from_map(map) when is_map(map), do: rich_from_map(map)
  def from_map(_), do: {:error, :invalid}

  # Reconstruit TOUS les champs (requis + optionnels). State en liste FERMÉE (pas to_existing_atom).
  defp rich_from_map(
         %{"id" => id, "pod_id" => pod_id, "enqueued_at" => enq, "state" => state} = m
       )
       when is_binary(id) and is_binary(pod_id) and is_binary(enq) and is_binary(state) do
    # `enqueued_at` est REQUIS (@enforce_keys + clé de tri DateTime de find_active) : un ISO invalide
    # doit FAIL-LOUD ici, PAS devenir nil silencieusement (sinon boot OK puis crash au tri).
    # Les autres DateTime (deadline/assigned/completed) sont optionnels → nil OK.
    with {:ok, st} <- parse_state(state),
         {:ok, eat} <- parse_required_dt(enq) do
      {:ok,
       %__MODULE__{
         id: id,
         pod_id: pod_id,
         ticket_id: m["ticket_id"],
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

  # Liste FERMÉE des états (atomes littéraux ⇒ garantis exister, pas d'atom-leak ni de raise).
  defp parse_state("pending"), do: {:ok, :pending}
  defp parse_state("assigned"), do: {:ok, :assigned}
  defp parse_state("in_progress"), do: {:ok, :in_progress}
  defp parse_state("completed"), do: {:ok, :completed}
  defp parse_state("failed"), do: {:ok, :failed}
  defp parse_state("cleared"), do: {:ok, :cleared}
  defp parse_state(_), do: :error

  # `enqueued_at` requis → `{:ok, dt} | :error` (vs `parse/1` qui tolère nil pour les champs optionnels).
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
