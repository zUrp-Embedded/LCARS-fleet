defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Phoenix.PubSub event bus, instance `Fleet.PubSub`, topic `fleet.events`.

  ## API — strict canonical schema

    * `broadcast/2 (topic, %Fleet.Event{} = event)` — emits the struct directly
      (subscribers receive `%Fleet.Event{}`, not a tuple). Fail-loud
      `Fleet.Event.UnregisteredError` if `event.type` is outside the events.yaml registry.

  ## Common

    * `child_spec/1` — for the Application supervisor (instantiates `Phoenix.PubSub`)
    * `main_topic/0` — the main topic (`"fleet.events"`), the central authority for the
      literal. Producers/consumers go through here rather than re-typing the string.
    * `broadcast_main/1` — `broadcast(main_topic(), event)`, the canonical shortcut.
    * `emit/3` — `Fleet.Event.new(source, type, opts) |> broadcast_main()`, the producer
      idiom "construct a canonical event + broadcast to main" in one call.
    * `safe_emit/3-4` — PROTECTED variant of `emit/3` for fire-and-forget emitters
      (observability/escalation — a lost event costs visibility, never a lifecycle):
      UNIFIED error policy (boot-order tolerated, construction bug logged, never a
      crash of the emitter).
    * `subscribe/1` / `unsubscribe/1` — topic subscription management (default `main_topic/0`)
    * `authorized_event_types/0` — MapSet of atoms loaded at boot by `Catalog.load!/0`
    * `set_authorized_event_types/1` — called by `Catalog.load!/0` at boot

  ## Struct-only

  ALL producers (pod, starfleet, coord, webhooks) emit the `%Fleet.Event{}` struct via
  `broadcast/2` — a subscriber always receives the struct, never a tuple to unwrap. The
  only validation on the broadcast path is the registry (`UnregisteredError`); the struct
  shape itself is enforced at construction (`Fleet.Event.new/3`).

  ## Mandatory registry

  Populated at boot from `priv/event_router/events.yaml` via `:persistent_term`
  (`Catalog.load!/0`). As soon as it is populated, any event outside the set raises
  `UnregisteredError`.

  The behavior when the set is EMPTY (test `load_event_registry: false`, or any config that disables
  the boot-time `Catalog.load!`) is **explicit** via `:fleet_event_router, :permit_when_registry_empty`:
  `true` (default) = let through (intended init safety-net); `false` = fail-closed
  (raise while the registry is not loaded). See `assert_authorized!/1`.
  """

  require Logger

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc """
  Phoenix.PubSub child spec for the Application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Phoenix.PubSub.child_spec(name: @pubsub_name)

  @doc """
  The bus's main topic (`"fleet.events"`) — the single broadcast/subscribe substrate.

  Central authority for the literal: every producer (`broadcast_main/1`) and
  consumer (`subscribe/0`) resolves the topic here rather than re-typing the string,
  which guarantees a producer and a consumer always match the same topic.
  """
  @spec main_topic() :: String.t()
  def main_topic, do: @main_topic

  @doc """
  Broadcasts an event with the strict canonical schema `%Fleet.Event{}` on the given
  topic (typically `"fleet.events"`).

  Strict fail-loud: raises `Fleet.Event.UnregisteredError` if `event.type` is not in the
  `events.yaml` registry (the set loaded by `Fleet.EventRouter.Catalog` at boot).

  Emits the struct directly — subscribers receive `%Fleet.Event{}`, not a tuple.
  Consumer pattern match:
  `handle_info(%Fleet.Event{type: :"pod.drift", payload: payload, correlation_id: cid}, state)`.
  """
  @spec broadcast(String.t(), Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast(topic, %Fleet.Event{} = event) when is_binary(topic) do
    assert_authorized!(event)
    pubsub_broadcast(topic, event)
  end

  # Seam (test-only): Phoenix.PubSub.broadcast rarely returns {:error, reason} in practice, yet
  # safe_emit's CI-09 delivery-error branch (log LOUD + passthrough) is load-bearing and MUST be
  # provable. Default = the real broadcast; a test injects a failing fun via
  # `:fleet_event_router, :broadcast_fun` (arity 3, `(pubsub_name, topic, event) -> :ok | {:error, _}`).
  defp pubsub_broadcast(topic, event) do
    case Application.get_env(:fleet_event_router, :broadcast_fun) do
      fun when is_function(fun, 3) -> fun.(@pubsub_name, topic, event)
      _ -> Phoenix.PubSub.broadcast(@pubsub_name, topic, event)
    end
  end

  @doc """
  Broadcasts an event on the main topic (`main_topic/0`) — the shortcut
  `broadcast(main_topic(), event)`, with the same fail-loud registry semantics as
  `broadcast/2`.

  Prefer it everywhere the topic is the main topic (the near-universal case):
  centralizes the `"fleet.events"` literal behind the authority.
  """
  @spec broadcast_main(Fleet.Event.t()) :: :ok | {:error, term()}
  def broadcast_main(%Fleet.Event{} = event), do: broadcast(@main_topic, event)

  @doc """
  Constructs a `%Fleet.Event{}` via `Fleet.Event.new/3` and broadcasts it on the main
  topic via `broadcast_main/1` — the single call for the producer idiom "construct the
  canonical envelope + broadcast to main".

  Factors ONLY the construction + broadcast: `emit/3` rescues nothing, classes nothing.
  Two error regimes exist among producers:

    * **observability/escalation** (fire-and-forget: a lost event costs visibility,
      never a lifecycle — failures are logged, never propagated) — the policy is
      UNIFIED in `safe_emit/3-4` below. Do NOT re-implement a local rescue around
      `emit/3`: that is exactly the duplication `safe_emit` absorbed.
    * **surface-specific** — the producer keeps ITS policy AROUND `emit/3`: HTTP
      surface `{:error, msg}` on the API side, load-bearing propagation on the spawner
      side (`Fleet.Spawner.Pod.Events.required_broadcast/2`).

  Return: that of `broadcast_main/1` (`:ok | {:error, term()}`). May RAISE
  `Fleet.Event.UnregisteredError` (type outside registry) or `ArgumentError`/`FunctionClauseError`
  (source outside enum, timestamp not a `%DateTime{}`) — deliberately not caught here, the
  caller's responsibility to decide its policy.
  """
  @spec emit(Fleet.Event.source(), atom(), keyword()) :: :ok | {:error, term()}
  def emit(source, type, opts \\ []) do
    event = Fleet.Event.new(source, type, opts)
    broadcast_main(event)
  end

  @doc """
  PROTECTED variant of `emit/3` — the SINGLE authority of the "protected-bus-emission"
  idiom (fire-and-forget emitters: coord, starfleet monitors, spawner pod events). A local
  rescue around `emit/3` is exactly the duplication this core absorbs — never re-implement
  one. Lives here, in the substrate, next to `emit/3` whose signature it shares.

  4th argument `safe_opts`:

    * `:on_unregistered` — policy against `Fleet.Event.UnregisteredError` (type outside
      the `events.yaml` registry, typically the boot window where the registry is not yet
      populated by `Catalog.load!/0`):
        * `:log` (default) — `Logger.warning` then `:ok`: the event is lost but the loss
          stays VISIBLE.
        * `:silent` — silent `:ok`: for emitters whose boot-order window is a NOMINAL
          case (boot orchestrator, pre-registry escalations) — a warning on every boot
          would be noise, not signal.
    * `:context` — prefix of the log message (e.g. `"MCPMonitor: mcp.server_crashed alert
      NOT emitted"`): carries the emitter's BUSINESS context into the centralized log,
      without each site re-implementing its own rescue just to customize a message.

  ## Error contract (the WHY of each branch)

    * `Fleet.Event.UnregisteredError` → tolerated per `:on_unregistered` (boot-order),
      returns `:ok`.
    * `ArgumentError` / `FunctionClauseError` → event CONSTRUCTION bug (source outside
      the enum, timestamp not a `%DateTime{}`, non-keyword opts, a type name never
      pre-registered), NOT a runtime hazard: ALWAYS `Logger.error` + `:ok`. Never
      swallowed silently — an escalation/alert that vanishes silently is undiagnosable.
      Never propagated — the fire-and-forget emitter (monitor GenServer, boot Task, pod
      gen_statem) must NEVER crash over an OBSERVABILITY defect: letting it crash would
      loop its supervisor over a malformed producer.

  The `type` also accepts a binary, converted via `String.to_existing_atom/1` UNDER the
  rescue's protection (anti atom-leak): a type name never pre-registered is classed as a
  construction bug (logged), never a crash. This is what lets producers that SYNTHESIZE the
  type name (`"starfleet.audit_cat5_\#{source}"`, a binary `event_type` on the pod side)
  keep NO local rescue.

  What `safe_emit` is NOT: the path of LOAD-BEARING events. A `pod.completed` flattened to
  a logged `:ok` would be indistinguishable from a success and would wedge the step_run
  (a lifelong forge lock) — that path must PROPAGATE the failure to its caller, cf.
  `Fleet.Spawner.Pod.Events.required_broadcast/2`, deliberately OUTSIDE this core.

  Return: `:ok` (emitted, or a tolerated/logged failure) | `{:error, reason}` (passthrough
  of `Phoenix.PubSub.broadcast/3` — now ALSO `Logger.error`-ed with context, CI-09: the single
  lossy publisher logs DELIVERY errors, not only construction bugs; each wrapper stops re-implementing it).
  """
  @spec safe_emit(Fleet.Event.source(), atom() | String.t(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def safe_emit(source, type, opts \\ [], safe_opts \\ []) do
    case emit(source, coerce_type(type), opts) do
      {:error, reason} = err ->
        # CI-09 (audit integrite 2026-07-20): the PubSub broadcast `{:error, reason}` was PASSED THROUGH
        # UNLOGGED — each lossy wrapper handled it differently (logged locally, dropped, or let its caller
        # drop it; "failure logged" was a LIE for this branch). safe_emit is THE single lossy publisher: it
        # now logs BOTH the construction exceptions (rescue below) AND this DELIVERY error, with the
        # emitter's context. Return kept (passthrough) — a caller that genuinely acts on it still can.
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

  # Conversion of a binary type name → EXISTING atom (anti atom-leak), called inside the
  # protected body of `safe_emit/4`: a name never pre-registered raises ArgumentError → classed
  # as a construction bug (Logger.error + :ok), never a crash of the emitter.
  defp coerce_type(type) when is_atom(type), do: type
  defp coerce_type(type) when is_binary(type), do: String.to_existing_atom(type)

  defp log_context(safe_opts), do: Keyword.get(safe_opts, :context, "Bus.safe_emit")

  @doc """
  The set of authorized event types (MapSet of atoms), loaded from
  `events.yaml` at boot by `Fleet.EventRouter.Catalog`.

  Empty until boot has populated the set. `broadcast/2` lets through without a
  check while empty (initialization), raises `UnregisteredError` as soon as
  populated for any event outside the set.
  """
  @spec authorized_event_types() :: MapSet.t()
  def authorized_event_types do
    :persistent_term.get({__MODULE__, :authorized_event_types}, MapSet.new())
  end

  @doc """
  Set the authorized event types (MapSet of atoms) — called by
  `Fleet.EventRouter.Catalog.load!/0` at boot after reading `events.yaml`.

  Idempotent — may be re-called via `Fleet.EventRouter.Catalog.load!/0`.
  """
  @spec set_authorized_event_types(MapSet.t()) :: :ok
  def set_authorized_event_types(%MapSet{} = set) do
    :persistent_term.put({__MODULE__, :authorized_event_types}, set)
    :ok
  end

  @doc """
  The declarative event ROUTING table — `%{{source, type} => %{action:, cat5_source:, threshold:}}`,
  keyed on `{source_atom, type_atom}` (the anti-spoof pair: a spoofed-source event of a routed type
  misses the table and is ignored). Loaded from `events.yaml` by `Catalog.load!/0` (schema-validated,
  fail-loud) — the classification chain (DriftMonitor → Cat5Escalator / coord) reads it HERE, so
  adding an incident class or changing a threshold/sink is a registry edit, not code. Empty map
  before load (tests with `load_event_registry: false` set it explicitly — same seam as
  `set_authorized_event_types/1`).
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

  # Behavior when the registry is EMPTY — made EXPLICIT and configurable, no longer a silent hole.
  #
  # The registry is empty in legitimate situations: in tests with `load_event_registry: false`
  # (hermeticity — no full boot to validate a type), or any deployment that disables the boot-time
  # `Catalog.load!`. (Normal prod boot is NOT one of them: `Application.init/1` runs `Catalog.load!/0` BEFORE starting the supervisor children, so the registry is already populated when the Bus process starts — see application.ex.) In these windows, validating against an empty set would reject
  # EVERY event. The `:permit_when_registry_empty` flag chooses the regime:
  #
  #   * `true` (default) — empty registry ⇒ LET THROUGH. INTENDED safety-net: do not force each test
  #     to populate the registry by hand. This is NOT a disabled validation — in normal boot the set
  #     is ALREADY populated (`Catalog.load!` runs BEFORE the Bus child starts), so the
  #     `type in types` branch decides and any event outside the registry raises. Producers already
  #     all emit the canonical schema, and the `UnregisteredError` rescue on the caller side covers
  #     the residue. It is an INTENTIONAL admission of the init window, not a silent by-pass.
  #   * `false` — empty registry ⇒ FAIL-CLOSED (raise `UnregisteredError`). For a deployment that
  #     wants to forbid any broadcast until the registry is loaded (no event may leave unvalidated,
  #     even at boot). Enable only if boot guarantees `Catalog.load!` BEFORE the 1st broadcast,
  #     otherwise boot itself crashes.
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

  # Empty-registry regime flag. Default `true` (intended init safety-net). Read on every broadcast
  # (not memoized) → a test can flip it without restarting the Bus.
  defp permit_when_registry_empty? do
    Application.get_env(:fleet_event_router, :permit_when_registry_empty, @permit_empty_default)
  end

  @doc """
  Subscribes to a Phoenix.PubSub topic. Default `"fleet.events"`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc """
  Unsubscribes from the topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Is `pid` currently subscribed to `topic` (default the main topic)? Phoenix.PubSub 2.x keeps local
  subscriptions in a Registry NAMED like the pubsub (`subscribe/2` = `Registry.register(name, topic, _)`),
  so a pid is subscribed iff it appears among the topic's Registry entries. Owned HERE (the PubSub
  authority) so consumers can probe liveness WITHOUT leaking the Registry detail — cf. readiness anti-hollow-green.
  """
  @spec subscribed?(pid(), String.t()) :: boolean()
  def subscribed?(pid, topic \\ @main_topic) when is_pid(pid) and is_binary(topic) do
    @pubsub_name |> Registry.lookup(topic) |> Enum.any?(fn {sub_pid, _} -> sub_pid == pid end)
  end
end
