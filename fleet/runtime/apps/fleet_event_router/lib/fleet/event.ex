defmodule Fleet.Event do
  @moduledoc """
  Canonical schema of the events published on the Phoenix.PubSub topic `fleet.events`.

  SINGLE wire format: every producer emits this `%Fleet.Event{}` struct. The `Bus` exposes no
  3-arity `{atom, map}` shim — "subscribe to `fleet.events`" therefore guarantees a single shape,
  not a tuple to un-wrap on the consumer side.

  The `source` is a **closed enum** (the `source()` type below). Extending it = amend this list AND
  add the matching entry in `events.yaml` (otherwise the event leaves the registry). This membership
  is no longer merely documented: `new/3` (the canonical constructor) **enforces** it at construction
  — an out-of-enum source raises, the invalid event is never represented.

  Constructing an event = `Fleet.Event.new(source, type, opts)` ("parse, don't validate"). It is the
  sole construction point for producers: it guarantees `source ∈ enum` and `timestamp` = `%DateTime{}`.
  Consumers, on the other hand, pattern-match the struct
  (`%Fleet.Event{source: :task_queue, type: :"work_item.completed"} = ev`) — they do not construct it.

  Event naming convention = `<source>.<type>` (e.g. `:spawner.pod_degraded`,
  `:task_queue."work_item.completed"`). Consumer matching:
  `handle_info(%Fleet.Event{source: :task_queue, type: :"work_item.completed"} = ev, state)`.
  """

  @type source ::
          :spawner
          | :task_queue
          | :mcp
          | :coord
          | :workflow
          | :starfleet
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

  # Closed enum of sources. Extend = amend this list + the matching events.yaml entry.
  @canonical_sources ~w(spawner task_queue mcp coord workflow starfleet event_router credentials capprofile spbuilder doctrine api)a

  @doc "The canonical sources (closed enum)."
  @spec canonical_sources() :: [source()]
  def canonical_sources, do: @canonical_sources

  @doc "True if the source belongs to the canonical closed enum."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  @doc """
  Canonical constructor of a `%Fleet.Event{}` — "parse, don't validate": it makes the invalid
  non-representable and is the SOLE construction point for producers.

  Guarantees (a producer that violates them is a bug, not a case to tolerate → fail-loud):

    * `source` is validated against the closed enum (`valid_source?/1`); an out-of-catalogue source
      raises `ArgumentError` (fix the source on the producer side, do not widen the enum blindly).
    * `timestamp` is ALWAYS a `%DateTime{}`: default `DateTime.utc_now/0`. An override via
      `opts[:timestamp]` is accepted ONLY if it is already a `%DateTime{}` — any other value raises
      `ArgumentError` (an event's timestamp can never be anything but a DateTime).

  The `type` stays a free `atom()`: the closed enum of `type` is not enforced here (only `source`
  is, per the schema). Recognized options: `:timestamp` (`%DateTime{}`), `:pod_id`
  (`String.t() | nil`), `:correlation_id` (`String.t() | nil`), `:payload` (`map()`, default `%{}`).
  """
  @spec new(source(), atom(), keyword()) :: t()
  def new(source, type, opts \\ []) when is_atom(type) and is_list(opts) do
    if not valid_source?(source) do
      raise ArgumentError,
            "Fleet.Event.new/3 : source #{inspect(source)} hors enum closed list " <>
              "#{inspect(@canonical_sources)} — un producteur qui émet une source hors-catalogue " <>
              "est un bug (corrige la source, n'élargis pas l'enum à l'aveugle)"
    end

    %__MODULE__{
      source: source,
      type: type,
      timestamp: canon_timestamp(Keyword.fetch(opts, :timestamp)),
      pod_id: Keyword.get(opts, :pod_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      payload: Keyword.get(opts, :payload, %{})
    }
  end

  # The timestamp can NEVER be anything but a DateTime: absent → utc_now; override
  # `%DateTime{}` → as-is; anything else → fail-loud (a string/int timestamp is a producer bug).
  defp canon_timestamp(:error), do: DateTime.utc_now()
  defp canon_timestamp({:ok, %DateTime{} = ts}), do: ts

  defp canon_timestamp({:ok, other}) do
    raise ArgumentError,
          "Fleet.Event.new/3 : timestamp #{inspect(other)} n'est pas un %DateTime{} — " <>
            "le timestamp d'un event ne peut jamais être autre chose qu'un DateTime"
  end

  @doc """
  Canonical string-keyed representation of the envelope (payload **nested**, not
  hoisted). For dual-stack consumers that still read `event["…"]`: a struct does
  not implement `Access`, so `event["event_type"]` would return `nil` there
  (this was the cause of a silent skip on the webhook→workflow consumer path).
  The `payload` keeps its own keys (already string on the webhook JSON side).
  Canonical helper provided here rather than copied by each consumer, so the
  string-keyed shape stays single and does not drift.
  """
  @spec to_string_map(t()) :: %{optional(String.t()) => any()}
  def to_string_map(%__MODULE__{} = e) do
    %{
      "event_type" => Atom.to_string(e.type),
      "type" => Atom.to_string(e.type),
      "source" => to_string(e.source),
      "pod_id" => e.pod_id,
      "correlation_id" => e.correlation_id,
      "timestamp" => e.timestamp,
      "payload" => e.payload || %{}
    }
  end

  defmodule UnregisteredError do
    @moduledoc "Event published outside the `events.yaml` registry (strict fail-loud)."
    defexception [:message]
  end

  # No `SchemaError` here: the canonical `Bus.broadcast/2` path validates no JSON schema, it
  # pattern-matches `%Fleet.Event{}` and checks the registry → the only validation error is
  # `UnregisteredError`. (A malformed event simply does not compile / does not match the struct.)
end
