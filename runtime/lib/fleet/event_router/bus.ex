defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Canonical `%Fleet.Event{}` bus over `Fleet.PubSub`, with `"fleet.events"` as the
  main topic. Events are broadcast as structs and checked against the registry loaded
  from `events.yaml`; an unregistered type raises once that registry is populated.

  An empty registry follows `:lcars_fleet, :event_router_permit_when_registry_empty`: `true`
  by default permits the initialization window, while `false` refuses every event.

  `safe_emit/4` tolerates selected failures for lossy observability, not arbitrary exceptions.
  Lifecycle-bearing callers must use emit/3 or broadcast/2 and handle their results.
  PubSub broadcasts do not acknowledge subscriber processing or persist events.
  """

  require Logger

  alias Fleet.Event
  alias Phoenix.PubSub

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc "Phoenix.PubSub child spec for `Fleet.PubSub`."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: PubSub.child_spec(name: @pubsub_name)

  @doc "Returns the canonical main topic, `\"fleet.events\"`."
  @spec main_topic() :: String.t()
  def main_topic, do: @main_topic

  @doc """
  Builds a pod topic from main_topic/0 and the unvalidated binary pod id. Main-topic
  broadcasts fan out here so emitters need not remember a second destination.
  """
  @spec pod_topic(String.t()) :: String.t()
  def pod_topic(pod_id) when is_binary(pod_id), do: @main_topic <> ".pod." <> pod_id

  @doc """
  Checks type authorization, then broadcasts the struct on topic without rerunning Event.new/3
  validation. Only a successful main-topic broadcast with binary pod_id triggers a second
  broadcast to that pod's topic, excluding the calling process from that second delivery.

  These broadcasts are sequential, not atomic: the main topic may already receive an event
  before pod fan-out fails. An error is not proof of zero delivery; :ok is not an acknowledgement
  that subscribers processed it. Custom topics do not trigger pod fan-out.
  """
  @spec broadcast(String.t(), Event.t()) :: :ok | {:error, term()}
  def broadcast(topic, %Event{} = event) when is_binary(topic) do
    assert_authorized!(event)

    case pubsub_broadcast(topic, event) do
      :ok -> fan_out_to_pod(topic, event)
      other -> other
    end
  end

  # Address pods individually rather than waking all of them on each event. Exclude the emitter
  # by PID to avoid echoing its own lifecycle events, without a maintained list of event types.
  # Main-topic observers still receive their own emissions. This leg bypasses the injected seam.
  defp fan_out_to_pod(@main_topic, %Event{pod_id: pod_id} = event) when is_binary(pod_id),
    do: PubSub.broadcast_from(@pubsub_name, self(), pod_topic(pod_id), event)

  defp fan_out_to_pod(_topic, _event), do: :ok

  # Injection seam for delivery-error tests; production defaults to Phoenix.PubSub.
  defp pubsub_broadcast(topic, event) do
    case Application.get_env(:lcars_fleet, :event_router_broadcast_fun) do
      fun when is_function(fun, 3) -> fun.(@pubsub_name, topic, event)
      _ -> PubSub.broadcast(@pubsub_name, topic, event)
    end
  end

  @doc "Broadcasts a registered event on `main_topic/0`."
  @spec broadcast_main(Event.t()) :: :ok | {:error, term()}
  def broadcast_main(%Event{} = event), do: broadcast(@main_topic, event)

  @doc "Constructs an event with `Fleet.Event.new/3` and broadcasts it on the main topic."
  @spec emit(Event.source(), atom(), keyword()) :: :ok | {:error, term()}
  def emit(source, type, opts \\ []) do
    event = Event.new(source, type, opts)
    broadcast_main(event)
  end

  @doc """
  Emits a lossy observability event, rescuing UnregisteredError, ArgumentError and
  FunctionClauseError from the emission path. Other exceptions, exits and throws propagate.

  Binary types are converted with `String.to_existing_atom/1`. Unregistered types return
  `:ok` after a warning, or silently when `on_unregistered: :silent`. Construction errors
  are logged and return `:ok`. PubSub delivery errors are logged and returned unchanged.
  `:context` prefixes diagnostics. Requires valid keyword options, :log or :silent for
  on_unregistered, and an interpolatable context; malformed diagnostic options can raise.
  Argument/function-clause errors from delivery also enter the construction-error rescue.

  Do not use this function for lifecycle-bearing events: tolerated construction or registry
  failures are indistinguishable from successful delivery to the caller.
  """
  @spec safe_emit(Event.source(), atom() | String.t(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def safe_emit(source, type, opts \\ [], safe_opts \\ []) do
    case emit(source, coerce_type(type), opts) do
      {:error, reason} = err ->
        Logger.error(
          "#{log_context(safe_opts)} — event #{inspect(type)} (source=#{inspect(source)}) broadcast " <>
            "FAILED (lossy, not delivered): #{inspect(reason)}"
        )

        err

      :ok ->
        :ok
    end
  rescue
    e in Fleet.Event.UnregisteredError ->
      case Keyword.get(safe_opts, :on_unregistered, :log) do
        :silent ->
          :ok

        :log ->
          Logger.warning(
            "#{log_context(safe_opts)} — event #{inspect(type)} (source=#{inspect(source)}) " <>
              "not emitted, type outside the events.yaml registry: #{Exception.message(e)}"
          )

          :ok
      end

    e in [ArgumentError, FunctionClauseError] ->
      Logger.error(
        "#{log_context(safe_opts)} — event #{inspect(type)} (source=#{inspect(source)}) " <>
          "NOT emitted, malformed event (construction bug): #{inspect(e)}"
      )

      :ok
  end

  defp coerce_type(type) when is_atom(type), do: type
  defp coerce_type(type) when is_binary(type), do: String.to_existing_atom(type)

  defp log_context(safe_opts), do: Keyword.get(safe_opts, :context, "Bus.safe_emit")

  @doc "Returns the event types loaded from `events.yaml`, or an empty set before loading."
  @spec authorized_event_types() :: MapSet.t()
  def authorized_event_types do
    :persistent_term.get({__MODULE__, :authorized_event_types}, MapSet.new())
  end

  @doc "Replaces the authorized event-type set."
  @spec set_authorized_event_types(MapSet.t()) :: :ok
  def set_authorized_event_types(%MapSet{} = set) do
    :persistent_term.put({__MODULE__, :authorized_event_types}, set)
    :ok
  end

  @doc """
  Returns the routing table loaded from `events.yaml`, keyed by `{source, type}`.
  Consumers can match both source and type. Bus authorization itself checks only type
  membership and does not authenticate the claimed source or consult this table.
  """
  @spec event_routing() :: %{optional({atom(), atom()}) => map()}
  def event_routing do
    :persistent_term.get({__MODULE__, :event_routing}, %{})
  end

  @doc "Set the event routing table — called by `Catalog.load!/0` at boot (and by tests). Idempotent."
  @spec set_event_routing(map()) :: :ok
  def set_event_routing(routing) when is_map(routing) do
    :persistent_term.put({__MODULE__, :event_routing}, routing)
    :ok
  end

  # Permit boot/test emissions before loading; tests intentionally disable registry loading.
  # Normal Application.init loads and rejects an invalid/empty catalogue before starting children,
  # checked by boot.event_registry_before_children. This branch is still reachable when loading
  # is disabled or the public setter empties the set later; emptiness alone proves no boot phase.
  @permit_empty_default true

  defp assert_authorized!(%Event{type: type} = event) do
    types = authorized_event_types()

    cond do
      MapSet.size(types) == 0 ->
        if permit_when_registry_empty?() do
          :ok
        else
          raise Fleet.Event.UnregisteredError,
                "events.yaml registry EMPTY and :permit_when_registry_empty = false (fail-closed) — " <>
                  "broadcast of #{inspect(type)} (source=#{inspect(event.source)}) refused until " <>
                  "the registry is loaded (Catalog.load!/0 must run before any broadcast)."
        end

      type in types ->
        :ok

      true ->
        raise Fleet.Event.UnregisteredError,
              "event type #{inspect(type)} not in registry events.yaml " <>
                "(source=#{inspect(event.source)}). Add entry to events.yaml or " <>
                "use Fleet.EventRouter.Bus.set_authorized_event_types/1 in tests."
    end
  end

  defp permit_when_registry_empty? do
    Application.get_env(
      :lcars_fleet,
      :event_router_permit_when_registry_empty,
      @permit_empty_default
    )
  end

  @doc "Subscribes the caller to a topic; defaults to `main_topic/0`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @main_topic) when is_binary(topic) do
    PubSub.subscribe(@pubsub_name, topic)
  end

  @doc "Unsubscribes the caller from a topic; defaults to `main_topic/0`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic \\ @main_topic) when is_binary(topic) do
    PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Returns whether `pid` has a local Phoenix.PubSub subscription to `topic`.
  """
  @spec subscribed?(pid(), String.t()) :: boolean()
  def subscribed?(pid, topic \\ @main_topic) when is_pid(pid) and is_binary(topic) do
    @pubsub_name |> Registry.lookup(topic) |> Enum.any?(fn {sub_pid, _} -> sub_pid == pid end)
  end
end
