defmodule Fleet.Event do
  use Boundary, deps: [], exports: [UnregisteredError]

  @moduledoc """
  Canonical event schema broadcast as-is on `fleet.events`.

  `source` is a closed enum enforced by `new/3`; event `type` remains a free
  atom and is registered separately by the Bus from `events.yaml`. The
  constructor also enforces the timestamp, identifier and payload field types.
  """

  @type source ::
          :spawner
          | :task_queue
          | :mcp
          | :pilot
          | :workflow
          | :project
          | :admiral
          | :event_router
          | :credentials
          | :capprofile
          | :spbuilder
          | :doctrine
          | :api

  @type t :: %__MODULE__{
          source: source(),
          type: atom(),
          timestamp: DateTime.t(),
          pod_id: String.t() | nil,
          correlation_id: String.t() | nil,
          payload: map()
        }

  @enforce_keys [:source, :type, :timestamp]
  defstruct [:source, :type, :timestamp, :pod_id, :correlation_id, payload: %{}]

  @canonical_sources ~w(spawner task_queue mcp workflow pilot project admiral event_router credentials capprofile spbuilder doctrine api)a

  @doc "True if the source belongs to the canonical closed enum."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  @doc false
  @spec canonical_sources() :: [atom()]
  def canonical_sources, do: @canonical_sources

  @doc """
  Builds an event and raises on an invalid source or field type.

  `timestamp` defaults to `DateTime.utc_now/0`; identifiers accept binaries or
  `nil`; payload defaults to `%{}`. `type` must be an atom but is not registered
  here.
  """
  @spec new(source(), atom(), keyword()) :: t()
  def new(source, type, opts \\ []) when is_atom(type) and is_list(opts) do
    if not valid_source?(source) do
      raise ArgumentError,
            "Fleet.Event.new/3: source #{inspect(source)} outside the closed enum list " <>
              "#{inspect(@canonical_sources)} — a producer emitting an out-of-catalogue source " <>
              "is a bug (fix the source, do not widen the enum blindly)"
    end

    %__MODULE__{
      source: source,
      type: type,
      timestamp: canon_timestamp(Keyword.fetch(opts, :timestamp)),
      pod_id: canon_id!(Keyword.get(opts, :pod_id), :pod_id),
      correlation_id: canon_id!(Keyword.get(opts, :correlation_id), :correlation_id),
      payload: canon_payload!(Keyword.get(opts, :payload, %{}))
    }
  end

  defp canon_timestamp(:error), do: DateTime.utc_now()
  defp canon_timestamp({:ok, %DateTime{} = ts}), do: ts

  defp canon_timestamp({:ok, other}) do
    raise ArgumentError,
          "Fleet.Event.new/3: timestamp #{inspect(other)} is not a %DateTime{} — " <>
            "an event's timestamp can never be anything but a DateTime"
  end

  defp canon_id!(nil, _field), do: nil
  defp canon_id!(s, _field) when is_binary(s), do: s

  defp canon_id!(v, field) do
    raise ArgumentError,
          "Fleet.Event.new/3: #{field} #{inspect(v)} is not a String.t() | nil — " <>
            "an event id can only be a binary or nil"
  end

  defp canon_payload!(m) when is_map(m), do: m

  defp canon_payload!(v) do
    raise ArgumentError,
          "Fleet.Event.new/3: payload #{inspect(v)} is not a map — an event payload is always a map"
  end

  @doc """
  Splits a failure term into JSON-safe `{category, detail}` strings.

  Tuple categories derive recursively from their first element so variable
  details do not change the incident recurrence bucket. `detail` retains the
  inspected full term.
  """
  @spec reason_fields(term()) :: {String.t(), String.t()}
  def reason_fields(reason) when is_binary(reason), do: {reason, reason}

  def reason_fields(reason) when is_atom(reason),
    do: {Atom.to_string(reason), Atom.to_string(reason)}

  def reason_fields(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    {category, _} = reason_fields(elem(reason, 0))
    {category, inspect(reason)}
  end

  def reason_fields(reason), do: {inspect(reason), inspect(reason)}

  defmodule UnregisteredError do
    @moduledoc "Event published outside the `events.yaml` registry (strict fail-loud)."
    defexception [:message]
  end
end
