defmodule Fleet.Event do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: [UnregisteredError]

  @moduledoc """
  Canonical schema of the events published on the Phoenix.PubSub topic `fleet.events`.

  SINGLE wire format: every producer emits this `%Fleet.Event{}` struct. The `Bus` exposes no
  3-arity `{atom, map}` shim — "subscribe to `fleet.events`" therefore guarantees a single shape,
  not a tuple to un-wrap on the consumer side.

  The `source` is a **closed enum** (the `source()` type below), defined and enforced HERE only:
  `new/3` (the canonical constructor) raises on an out-of-enum source, so the invalid event is never
  represented. `events.yaml` is a SEPARATE authority — it registers event *types* (`<...>.<...>`
  keys, validated on `event.type` by `Bus.broadcast/2`), NOT sources; there is no source registry in
  `events.yaml`. A new producer must satisfy BOTH independently: (1) its `source` ∈ this enum, and
  (2) each `event.type` it emits has a key in `events.yaml`.

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

  # Closed enum of sources — the SOLE authority for `source`. (events.yaml registers event *types*, not sources.)
  @canonical_sources ~w(spawner task_queue mcp coord workflow starfleet event_router credentials capprofile spbuilder doctrine api)a

  @doc "True if the source belongs to the canonical closed enum."
  @spec valid_source?(atom()) :: boolean()
  def valid_source?(source), do: source in @canonical_sources

  # Test-facing accessor: the guard test proves `@type source` (docs) and `@canonical_sources`
  # (enforcement) name the SAME set — two free copies of a closed enum drift silently otherwise
  # (a source added to one list only either rejects a legitimate producer or documents a ghost).
  @doc false
  @spec canonical_sources() :: [atom()]
  def canonical_sources, do: @canonical_sources

  @doc """
  Canonical constructor of a `%Fleet.Event{}` — "parse, don't validate": it makes the invalid
  non-representable and is the SOLE construction point for producers.

  Guarantees (a producer that violates them is a bug, not a case to tolerate → fail-loud):

    * `source` is validated against the closed enum (`valid_source?/1`); an out-of-catalogue source
      raises `ArgumentError` (fix the source on the producer side, do not widen the enum blindly).
    * `timestamp` is ALWAYS a `%DateTime{}`: default `DateTime.utc_now/0`. An override via
      `opts[:timestamp]` is accepted ONLY if it is already a `%DateTime{}` — any other value raises
      `ArgumentError` (an event's timestamp can never be anything but a DateTime).
    * `pod_id`/`correlation_id` are a binary or nil, and `payload` is a map — any other value raises
      `ArgumentError`. The struct's `@type` is ENFORCED at construction, not merely documented: a
      non-map payload / non-binary id is a producer bug, never a representable event.

  The `type` stays a free `atom()`: the closed enum of `type` is not enforced here (only `source`
  is, per the schema). Recognized options: `:timestamp` (`%DateTime{}`), `:pod_id`
  (`String.t() | nil`), `:correlation_id` (`String.t() | nil`), `:payload` (`map()`, default `%{}`).
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

  # The timestamp can NEVER be anything but a DateTime: absent → utc_now; override
  # `%DateTime{}` → as-is; anything else → fail-loud (a string/int timestamp is a producer bug).
  defp canon_timestamp(:error), do: DateTime.utc_now()
  defp canon_timestamp({:ok, %DateTime{} = ts}), do: ts

  defp canon_timestamp({:ok, other}) do
    raise ArgumentError,
          "Fleet.Event.new/3: timestamp #{inspect(other)} is not a %DateTime{} — " <>
            "an event's timestamp can never be anything but a DateTime"
  end

  # pod_id/correlation_id can ONLY be a binary or nil (the struct's `@type`): a non-binary is a
  # producer bug → fail-loud, same stance as source/timestamp (never silently store an ill-typed id).
  defp canon_id!(nil, _field), do: nil
  defp canon_id!(s, _field) when is_binary(s), do: s

  defp canon_id!(v, field) do
    raise ArgumentError,
          "Fleet.Event.new/3: #{field} #{inspect(v)} is not a String.t() | nil — " <>
            "an event id can only be a binary or nil"
  end

  # payload can ONLY be a map (the struct's `@type`, and every JSON-event consumer assumes it): a
  # non-map is a producer bug → fail-loud (otherwise it would crash `Jason.encode!` downstream).
  defp canon_payload!(m) when is_map(m), do: m

  defp canon_payload!(v) do
    raise ArgumentError,
          "Fleet.Event.new/3: payload #{inspect(v)} is not a map — an event payload is always a map"
  end

  defmodule UnregisteredError do
    @moduledoc "Event published outside the `events.yaml` registry (strict fail-loud)."
    defexception [:message]
  end

  # No `SchemaError` here: the canonical `Bus.broadcast/2` path validates no JSON schema, it
  # pattern-matches `%Fleet.Event{}` and checks the registry → the only validation error is
  # `UnregisteredError`. (A malformed event simply does not compile / does not match the struct.)
end
