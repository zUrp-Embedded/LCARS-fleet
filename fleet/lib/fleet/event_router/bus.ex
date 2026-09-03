defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Canonical `%Fleet.Event{}` bus over `Fleet.PubSub`, with `"fleet.events"` as the
  main topic. Events are broadcast as structs and checked against the registry loaded
  from `events.yaml`; an unregistered type raises once that registry is populated.

  An empty registry follows `:lcars_fleet, :event_router_permit_when_registry_empty`: `true`
  by default permits the initialization window, while `false` refuses every event.

  `safe_emit/4` is reserved for lossy observability. It logs construction and delivery
  failures without crashing the emitter. Lifecycle-bearing events must use `emit/3` or
  `broadcast/2` so their failures remain actionable.
  """

  require Logger

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc "Phoenix.PubSub child spec for `Fleet.PubSub`."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Phoenix.PubSub.child_spec(name: @pubsub_name)

  @doc "Returns the canonical main topic, `\"fleet.events\"`."
  @spec main_topic() :: String.t()
  def main_topic, do: @main_topic

  @doc """
  Topic of ONE pod — `main_topic/0` plus the pod id.

  A pod subscribes here and nowhere else, so it is woken only by what is addressed to it. Nothing
  emits on this topic directly: `broadcast/2` fans out to it from the main topic, which is what
  keeps the routing a property of the bus instead of a discipline each emitter must remember.
  """
  @spec pod_topic(String.t()) :: String.t()
  def pod_topic(pod_id) when is_binary(pod_id), do: @main_topic <> ".pod." <> pod_id

  @doc """
  Broadcasts a registered `%Fleet.Event{}` directly on `topic`.

  An event carrying a `pod_id` ALSO lands on that pod's own topic (6-041) — see `pod_topic/1`.
  """
  @spec broadcast(String.t(), Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast(topic, %Fleet.Event{} = event) when is_binary(topic) do
    assert_authorized!(event)

    case pubsub_broadcast(topic, event) do
      :ok -> fan_out_to_pod(topic, event)
      other -> other
    end
  end

  # 6-041 — QUESTION D'ADRESSAGE, PAS DE DEBIT. Un pod ne consomme que les evenements portant SON
  # `pod_id`, donc le bus les lui ADRESSE. L'abonnement au seul sujet GLOBAL reveillerait les N pods
  # actifs (plafond 128) a chaque evenement, dont N-1 pour le jeter.
  #
  # LA REPARTITION VIT ICI ET NULLE PART AILLEURS, et c'est le point. La faire faire aux emetteurs
  # mettrait un devoir de MEMOIRE a chaque site : celui qui oublie le sujet du pod ne casse rien de
  # visible — le pod attend simplement un evenement qui ne viendra JAMAIS, sans trace.
  # `pubsub_broadcast/2` est le SEUL appel `Phoenix.PubSub.broadcast` de `lib/`, donc un seul
  # endroit tient l'invariant.
  #
  # Le sujet principal reste servi tel quel : les consommateurs transverses (read-model, audit,
  # step-run) y sont, et ils doivent tout voir.
  # ⚠ `broadcast_from` ET NON `broadcast`, ET CE N'EST PAS UN DETAIL. Un pod emet SES PROPRES
  # evenements de cycle de vie (`pod.spawned`, `pod.failed`, `pod.completed`) avec son propre
  # `pod_id` : une diffusion nue lui rendrait tout ce qu'il vient de dire. Ces evenements-la sont
  # pour les OBSERVATEURS, jamais pour leur emetteur. L'exclusion par pid est exacte et ne demande
  # aucune liste de types a tenir a jour — une liste qui derive rend le pod bavard sur lui-meme.
  #
  # Le sujet principal, lui, est diffuse normalement : un observateur doit tout voir, y compris ce
  # qu'il a emis.
  defp fan_out_to_pod(@main_topic, %Fleet.Event{pod_id: pod_id} = event) when is_binary(pod_id),
    do: Phoenix.PubSub.broadcast_from(@pubsub_name, self(), pod_topic(pod_id), event)

  defp fan_out_to_pod(_topic, _event), do: :ok

  # Injection seam for delivery-error tests; production defaults to Phoenix.PubSub.
  defp pubsub_broadcast(topic, event) do
    case Application.get_env(:lcars_fleet, :event_router_broadcast_fun) do
      fun when is_function(fun, 3) -> fun.(@pubsub_name, topic, event)
      _ -> Phoenix.PubSub.broadcast(@pubsub_name, topic, event)
    end
  end

  @doc "Broadcasts a registered event on `main_topic/0`."
  @spec broadcast_main(Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast_main(%Fleet.Event{} = event), do: broadcast(@main_topic, event)

  @doc "Constructs an event with `Fleet.Event.new/3` and broadcasts it on the main topic."
  @spec emit(Fleet.Event.source(), atom(), keyword()) :: :ok | {:error, term()}
  def emit(source, type, opts \\ []) do
    event = Fleet.Event.new(source, type, opts)
    broadcast_main(event)
  end

  @doc """
  Emits a lossy observability event without crashing its producer.

  Binary types are converted with `String.to_existing_atom/1`. Unregistered types return
  `:ok` after a warning, or silently when `on_unregistered: :silent`. Construction errors
  are logged and return `:ok`. PubSub delivery errors are logged and returned unchanged.
  `:context` prefixes every diagnostic.

  Do not use this function for lifecycle-bearing events: tolerated construction or registry
  failures are indistinguishable from successful delivery to the caller.
  """
  @spec safe_emit(Fleet.Event.source(), atom() | String.t(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def safe_emit(source, type, opts \\ [], safe_opts \\ []) do
    case emit(source, coerce_type(type), opts) do
      {:error, reason} = err ->
        # CI-09
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
  The paired key prevents a routed type from being accepted under a spoofed source.
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

  # PERMISSIVE ON PURPOSE, AND IT IS LOAD-BEARING. An empty registry means "the registry is not
  # loaded YET", not "nothing is authorized": this default holds the window between the first line
  # of boot and `Catalog.load!/0`. The hermetic suite runs with the registry off by design
  # (`event_router_load_event_registry: false`), so a fail-closed default here does not harden the
  # bus: it makes the boot and a large part of the suite unable to emit at all.
  #
  # WHAT MAKES IT SAFE IS NOT WRITTEN IN THIS MODULE, so read it here: `Catalog.load!/0` RAISES on
  # an absent, invalid or empty `events.yaml`, and it runs in `EventRouter.Application.init/1`
  # ABOVE the children list. A fleet that reaches its first broadcast therefore has a populated
  # registry, and this branch is unreachable in a live fleet.
  #
  # The `boot.event_registry_before_children` lock in `mix lcars.contracts.check` is what holds that
  # ordering: moving the `load!/0` call one line below the children widens this window to the whole
  # boot, and nothing else goes red — the failure needs an unregistered event AND a real supervision
  # tree, which no hermetic test plays.
  @permit_empty_default true

  defp assert_authorized!(%Fleet.Event{type: type} = event) do
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
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc "Unsubscribes the caller from a topic; defaults to `main_topic/0`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Returns whether `pid` has a local Phoenix.PubSub subscription to `topic`.
  """
  @spec subscribed?(pid(), String.t()) :: boolean()
  def subscribed?(pid, topic \\ @main_topic) when is_pid(pid) and is_binary(topic) do
    @pubsub_name |> Registry.lookup(topic) |> Enum.any?(fn {sub_pid, _} -> sub_pid == pid end)
  end
end
