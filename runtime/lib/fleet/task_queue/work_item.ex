defmodule Fleet.TaskQueue.WorkItem do
  @moduledoc """
  Broker work item. new/2 generates a UUID v4 id used as event correlation_id, distinct
  from the target pod_id (accepted as any binary, not validated as a UUID).
  Server enqueue uses this constructor; direct structs bypass its casts. There is no
  state-file recovery constructor because the broker is ephemeral. Metadata remains an
  unchecked map shared with consumers rather than opaque typed variants.
  """

  # Only states written by real transitions belong here; pulling already means :assigned,
  # not a separate speculative :in_progress state.
  @type state :: :pending | :assigned | :completed | :failed | :cleared

  @type t :: %__MODULE__{
          id: String.t(),
          pod_id: String.t(),
          issue_id: String.t() | nil,
          role: String.t() | nil,
          brief: String.t() | nil,
          brief_ref: String.t() | nil,
          brief_sha: String.t() | nil,
          deadline: DateTime.t() | nil,
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
    :brief_ref,
    :brief_sha,
    :deadline,
    :enqueued_at,
    :assigned_at,
    :completed_at,
    :result,
    state: :pending,
    metadata: %{}
  ]

  # Rework limits belong to the system-side forge rail (max_rework_rounds), not pod-influenced attrs.
  # Shared active vocabulary drives queue selection, supersession, deadlines, retention and
  # poller ownership reconciliation. Completed means broker-terminal, not proof of PR delivery
  # or forge unlock; reconciliation can reclaim orphaned locks after terminal work.
  @active_states [:pending, :assigned]

  @doc "Returns broker-active states used by queue transitions and poller ownership checks."
  @spec active_states() :: [state()]
  def active_states, do: @active_states

  @doc "Tests broker-active membership; terminal or unknown states return false. Does not inspect a forge lock."
  @spec active?(state()) :: boolean()
  def active?(state), do: state in @active_states

  @doc """
  Builds a pending work item from atom- or string-keyed attributes.

  Truthy atom-key values precede string-key values; nil/false atom values fall through.
  Unknown attributes are ignored. Optional values may be nil; metadata nil/false becomes %{}.
  After key selection, invalid checked values return {:error, {:bad_attr, {field, value}}}.
  Deadlines accept DateTime structs or ISO8601 strings. Unreadable strings must not become
  nil, which means no expiry. Struct internals and metadata contents are not validated.
  `brief_sha` checks only 40 lowercase hexadecimal characters, not commit existence;
  `brief_ref` must satisfy `Fleet.Layout.valid_brief_ref?/1` without filesystem lookup.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, {:bad_attr, term()}}
  def new(pod_id, attrs) when is_binary(pod_id) and is_map(attrs) do
    with {:ok, deadline} <- cast_deadline(fetch(attrs, :deadline)),
         {:ok, metadata} <- cast_map(fetch(attrs, :metadata) || %{}, :metadata),
         {:ok, issue_id} <- cast_str_nil(fetch(attrs, :issue_id), :issue_id),
         {:ok, role} <- cast_str_nil(fetch(attrs, :role), :role),
         {:ok, brief} <- cast_str_nil(fetch(attrs, :brief), :brief),
         {:ok, brief_ref} <- cast_brief_ref(fetch(attrs, :brief_ref), :brief_ref),
         {:ok, brief_sha} <- cast_brief_sha(fetch(attrs, :brief_sha), :brief_sha) do
      {:ok,
       %__MODULE__{
         id: UUID.uuid4(),
         pod_id: pod_id,
         issue_id: issue_id,
         role: role,
         brief: brief,
         brief_ref: brief_ref,
         brief_sha: brief_sha,
         deadline: deadline,
         enqueued_at: DateTime.utc_now(),
         state: :pending,
         metadata: metadata
       }}
    end
  end

  defp fetch(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

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

  defp cast_str_nil(nil, _field), do: {:ok, nil}
  defp cast_str_nil(s, _field) when is_binary(s), do: {:ok, s}
  defp cast_str_nil(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_brief_sha(nil, _field), do: {:ok, nil}

  defp cast_brief_sha(s, field) when is_binary(s) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_sha(v, field), do: {:error, {:bad_attr, {field, v}}}

  defp cast_brief_ref(nil, _field), do: {:ok, nil}

  defp cast_brief_ref(s, field) when is_binary(s) do
    if Fleet.Layout.valid_brief_ref?(s),
      do: {:ok, s},
      else: {:error, {:bad_attr, {field, s}}}
  end

  defp cast_brief_ref(v, field), do: {:error, {:bad_attr, {field, v}}}
end
