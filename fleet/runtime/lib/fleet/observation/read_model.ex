defmodule Fleet.Observation.ReadModel do
  @moduledoc """
  Read-model frontier of observability.

  **A single** process consumes the `%Fleet.Event{}` stream (subscribed to the
  `Fleet.EventRouter.Bus` bus, topic `fleet.events`) and maintains a readable
  **projection** in an ETS table it owns. The readers (the surface `Deck`)
  read the projection via `projection/0` — a **direct ETS read** that *bypasses*
  the GenServer (OTP Iron Law: writes serialize through the process, reads
  don't touch it).

  The ReadModel **never introspects** the internal state of a third-party GenServer: it
  sees only the public events. This is the explicit read frontier of the core.

  ## Projection (JSON-safe shape)

      %{
        total: n,                      # events seen since boot
        counts: %{type => n},          # tally per type (BRIDGE + FLOW derive from here)
        stream: [summary, ...],        # last 100 (the backbone)
        workflow_runs: [summary, ...], # last 20 workflow_map.*
        gatekeeper: [summary, ...],    # last 20 audit.verdict / coord.escalation_*
        coordination: [summary, ...],  # last 20 coord.* / gitea.*
        diagnostics: [summary, ...]    # last 20 boot/oauth/mcp/sdk/signal/git
      }

  `summary = %{type, source, pod_id, correlation_id, ts}` — only
  encodable fields (never the raw `payload`, which can carry non-JSON
  terms, cf. `Deck.pod_view/2`).

  ## Snapshot at boot

  The event-derived decks start empty (the bus is a stream, not a store);
  the **pods** stay a *live* snapshot via `Spawner.list_pods/0` (endpoint
  `/api/pods`), because `pod.*` emits only terminals (completed/failed/drift),
  not a full lifecycle.

  ## Configuration

    * `:subscribe` (opt, default `true`) — subscribe to the bus. Tests pass
      `false` and send events via `send/2` (hermetic, no real bus).
    * `:fleet_observation, :start_readmodel` (app env, default `true`) —
      `false` in `:test` (no parasitic subscriber, hermetic invariant).

  **Last revised**: 2026-07-21
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @table :fleet_observation_projection
  @stream_max 100
  @deck_max 20

  # Re-subscribe backoff (recovery): a failed Bus subscribe leaves the read-model DEAF; without a
  # retry it stays deaf FOR LIFE (only a restart recovers). We retry with a bounded exponential backoff —
  # base `@resubscribe_base_ms`, doubling, capped at `@resubscribe_max_ms` — so a transient/boot-race Bus
  # unavailability heals itself while the status honestly reads :deaf until a retry lands.
  @resubscribe_base_ms 1_000
  @resubscribe_max_ms 30_000

  # Deck routing catalogue (DATA, not mechanics): type prefix → deck.
  # Order matters (first matched prefix wins). One single mechanic
  # (`String.starts_with?`), the catalogue varies.
  @deck_prefixes [
    {"workflow_map.", :workflow_runs},
    {"audit.verdict", :gatekeeper},
    {"coord.escalation", :gatekeeper},
    {"coord.", :coordination},
    {"gitea.", :coordination},
    {"fleet.boot", :diagnostics},
    {"oauth.", :diagnostics},
    {"mcp.server_crashed", :diagnostics},
    {"sdk.upstream_alert", :diagnostics},
    {"state.corrupt", :diagnostics},
    {"os.signal", :diagnostics}
  ]

  # ── Client ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reads the current projection. **Direct ETS read** — does NOT do a `GenServer.call`
  (bypass, Iron Law). If the ReadModel isn't started (table absent), returns
  an empty projection — the deck never crashes on a dead read-model.
  """
  @spec projection() :: map()
  def projection do
    :ets.lookup_element(@table, :projection, 2)
  rescue
    ArgumentError ->
      # A dead ReadModel (ETS table gone) renders as `empty()` = INDISTINGUISHABLE from a quiet-healthy
      # fleet (total:0, decks empty) → the deck is silently blind. Distinguish: table ABSENT = the
      # read-model is DOWN (a real blind spot) → log LOUD; table present but the `:projection` key not yet
      # written (fresh boot, transient) → silent `empty()`. Supervised → the absent window is brief.
      if :ets.whereis(@table) == :undefined do
        Logger.warning(
          "ReadModel: ETS table #{inspect(@table)} absent — read-model is DOWN, the projection " <>
            "reads EMPTY (a dead read-model looks like a quiet-healthy fleet; the deck is blind until it restarts)"
        )
      end

      empty()
  end

  @doc """
  Health of the read-model behind `projection/0` (F-C124, DR-027):
    * `:unavailable` — the ETS table is DOWN (table gone → `projection/0` reads `empty()`);
    * `:deaf` — the process is ALIVE but its Bus subscribe FAILED → no event can arrive (a deaf
      read-model is INDISTINGUISHABLE from a quiet-healthy fleet without this signal);
    * `:live` — table present AND subscribed (or deliberate static no-subscribe mode).
  Surfaced in `/api/projection` (`_status`) so a client sees a DEAD/DEAF read-model instead of a false
  "quiet fleet". (A `:live` table can still be transiently stale on a fresh boot — brief, silent by design.)
  """
  @spec projection_status() :: :live | :deaf | :unavailable
  def projection_status do
    cond do
      :ets.whereis(@table) == :undefined -> :unavailable
      subscribed?() -> :live
      true -> :deaf
    end
  end

  defp subscribed? do
    :ets.lookup_element(@table, :subscribed, 2)
  rescue
    ArgumentError -> false
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Table owned by THIS process (`:protected`) → concurrent reads bypass,
    # writes via the GenServer. Auto-deleted on process death.
    _ = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(@table, {:projection, empty()})
    subscribe? = Keyword.get(opts, :subscribe, true)
    # DR-027: `:subscribed` gates the :live status. A REAL subscribe (subscribe? true) starts PESSIMISTIC
    # (false) and flips true only once the Bus subscribe SUCCEEDS (handle_continue) — an alive-but-deaf
    # read-model then reads :deaf, never a lying :live. The deliberate no-subscribe mode (subscribe? false,
    # test/static) is live from init (no subscribe attempt = not a failure; also avoids a boot race).
    :ets.insert(@table, {:subscribed, not subscribe?})

    {:ok,
     %{
       proj: empty(),
       subscribe?: subscribe?,
       # Seam: the subscribe fn (default `Bus.subscribe/1`) — injectable to exercise the DEAF path in test.
       subscribe_fun: Keyword.get(opts, :subscribe_fun, &Bus.subscribe/1),
       # Current backoff delay for the re-subscribe retry (grows on failure, resets on success). Base
       # overridable so tests exercise the recovery without a real-time wait.
       resubscribe_base_ms: Keyword.get(opts, :resubscribe_base_ms, @resubscribe_base_ms),
       resubscribe_delay: Keyword.get(opts, :resubscribe_base_ms, @resubscribe_base_ms)
     }, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, %{subscribe?: true} = state) do
    {:noreply, try_subscribe(state)}
  end

  # Deliberate no-subscribe mode (test/static config): already :live from init (no subscribe attempt).
  def handle_continue(:subscribe, state), do: {:noreply, state}

  defp try_subscribe(%{subscribe_fun: subscribe_fun} = state) do
    topic = Bus.main_topic()

    case subscribe_fun.(topic) do
      :ok ->
        :ets.insert(@table, {:subscribed, true})
        # Recovered (or first-try success) → reset the backoff for any future re-subscribe.
        %{state | resubscribe_delay: state.resubscribe_base_ms}

      other ->
        # DR-027 hollow-green: a failed subscribe leaves the read-model ALIVE but DEAF — no event will
        # ever arrive, and `projection_status/0` would otherwise say :live (a deaf process INDISTINGUISHABLE from
        # a quiet-healthy fleet). We leave `:subscribed` FALSE → status reports :deaf, and we LOG LOUD.
        # We also RETRY (bounded backoff) — a deaf read-model must self-heal once the Bus is up,
        # never stay deaf until a manual restart. The status stays honest (:deaf) until a retry lands.
        Logger.error(
          "ReadModel: subscribe #{topic} FAILED (#{inspect(other)}) — read-model is DEAF: no event " <>
            "will arrive, /api/projection reports :deaf. Retrying in #{state.resubscribe_delay} ms."
        )

        schedule_resubscribe(state)
    end
  end

  # Schedules the next re-subscribe attempt and grows the backoff (capped). Returns the state with the
  # NEXT delay so successive failures back off, resetting to base on success.
  defp schedule_resubscribe(state) do
    Process.send_after(self(), :resubscribe, state.resubscribe_delay)
    %{state | resubscribe_delay: min(state.resubscribe_delay * 2, @resubscribe_max_ms)}
  end

  # Bounded backoff re-subscribe: fired by `schedule_resubscribe/1` after a failed attempt.
  @impl GenServer
  def handle_info(:resubscribe, %{subscribe?: true} = state),
    do: {:noreply, try_subscribe(state)}

  def handle_info(%Fleet.Event{} = event, state) do
    proj = project(state.proj, event)
    :ets.insert(@table, {:projection, proj})
    {:noreply, %{state | proj: proj}}
  end

  # Defensive: a non-`%Fleet.Event{}` message is ignored, never a crash.
  def handle_info(_other, state), do: {:noreply, state}

  # ── Projection (pure) ────────────────────────────────────────────────────────

  @doc false
  def project(proj, %Fleet.Event{} = event) do
    s = summarize(event)
    type = s.type

    proj
    |> Map.update!(:total, &(&1 + 1))
    |> update_in([:counts, type], fn
      nil -> 1
      n -> n + 1
    end)
    |> Map.update!(:stream, &cap([s | &1], @stream_max))
    |> route_deck(type, s)
  end

  defp route_deck(proj, type, summary) do
    case Enum.find(@deck_prefixes, fn {prefix, _deck} -> String.starts_with?(type, prefix) end) do
      {_prefix, deck} -> Map.update!(proj, deck, &cap([summary | &1], @deck_max))
      nil -> proj
    end
  end

  # `payload` excluded (can carry non-encodable terms); we keep only
  # JSON-safe fields.
  defp summarize(%Fleet.Event{} = e) do
    %{
      type: to_string(e.type),
      source: to_string(e.source),
      pod_id: e.pod_id,
      correlation_id: e.correlation_id,
      ts: stringify_ts(e.timestamp)
    }
  end

  defp stringify_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_ts(ts) when is_integer(ts) or is_binary(ts), do: ts
  defp stringify_ts(ts), do: inspect(ts)

  defp cap(list, max), do: Enum.take(list, max)

  defp empty do
    %{
      total: 0,
      counts: %{},
      stream: [],
      workflow_runs: [],
      gatekeeper: [],
      coordination: [],
      diagnostics: []
    }
  end
end
