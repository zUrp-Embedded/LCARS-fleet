defmodule Fleet.Observation.ReadModel do
  @moduledoc """
  GenServer projection of public Bus events into protected named ETS; reads bypass
  the server. Restart loses history. Stream/deck lists are capped, but counts are not.
  Subscription status records the last successful attempt, not ongoing Bus health;
  deliberately unsubscribed static mode reports live.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @table :fleet_observation_projection
  @stream_max 100
  @deck_max 20

  # Returned subscribe failures retry indefinitely with capped exponential delay.
  @resubscribe_base_ms 1_000
  @resubscribe_max_ms 30_000

  # First matching event prefix selects a deck.
  @deck_prefixes [
    {"workflow_map.", :workflow_runs},
    {"gitea.", :coordination},
    {"fleet.boot", :diagnostics},
    {"oauth.", :diagnostics},
    {"mcp.server_crashed", :diagnostics}
    # Add routes only for emitted event families; orphan categories imply nonexistent input.
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reads ETS directly. Missing table or key returns an empty projection; a missing
  table also warns. Read projection_status separately to distinguish unavailable
  from empty. The two reads are not an atomic snapshot.
  """
  @spec projection() :: map()
  def projection do
    :ets.lookup_element(@table, :projection, 2)
  rescue
    ArgumentError ->
      if :ets.whereis(@table) == :undefined do
        Logger.warning(
          "ReadModel: ETS table #{inspect(@table)} absent — read-model is DOWN, the projection " <>
            "reads EMPTY (a dead read-model looks like a quiet-healthy fleet; the deck is blind until it restarts)"
        )
      end

      empty()
  end

  @doc """
  Returns unavailable for an absent table, live for a recorded subscription or
  deliberate static mode, otherwise deaf. Later subscription loss is not monitored;
  live does not establish event freshness or delivery.
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

  @impl GenServer
  def init(opts) do
    # ETS is owned by this process and disappears with it.
    _ = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(@table, {:projection, empty()})
    subscribe? = Keyword.get(opts, :subscribe, true)

    # Real subscription starts pessimistically; deliberate static mode is live immediately.
    :ets.insert(@table, {:subscribed, not subscribe?})

    {:ok,
     %{
       proj: empty(),
       subscribe?: subscribe?,
       subscribe_fun: Keyword.get(opts, :subscribe_fun, &Bus.subscribe/1),
       resubscribe_base_ms: Keyword.get(opts, :resubscribe_base_ms, @resubscribe_base_ms),
       resubscribe_delay: Keyword.get(opts, :resubscribe_base_ms, @resubscribe_base_ms)
     }, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, %{subscribe?: true} = state) do
    {:noreply, try_subscribe(state)}
  end

  def handle_continue(:subscribe, state), do: {:noreply, state}

  defp try_subscribe(%{subscribe_fun: subscribe_fun} = state) do
    topic = Bus.main_topic()

    case subscribe_fun.(topic) do
      :ok ->
        :ets.insert(@table, {:subscribed, true})

        %{state | resubscribe_delay: state.resubscribe_base_ms}

      other ->
        # Returned failures schedule retries; exceptions in subscribe_fun crash the server.
        Logger.error(
          "ReadModel: subscribe #{topic} FAILED (#{inspect(other)}) — read-model is DEAF: no event " <>
            "will arrive, /api/projection reports :deaf. Retrying in #{state.resubscribe_delay} ms."
        )

        schedule_resubscribe(state)
    end
  end

  defp schedule_resubscribe(state) do
    Process.send_after(self(), :resubscribe, state.resubscribe_delay)
    %{state | resubscribe_delay: min(state.resubscribe_delay * 2, @resubscribe_max_ms)}
  end

  @impl GenServer
  def handle_info(:resubscribe, %{subscribe?: true} = state),
    do: {:noreply, try_subscribe(state)}

  def handle_info(%Fleet.Event{} = event, state) do
    proj = project(state.proj, event)
    :ets.insert(@table, {:projection, proj})
    {:noreply, %{state | proj: proj}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @spec project(map(), Fleet.Event.t()) :: map()
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

  # Exclude arbitrary payload terms. IDs pass through unchanged and type/source require
  # String.Chars, so malformed direct Event structs are not guaranteed JSON-safe.
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
      coordination: [],
      diagnostics: []
    }
  end
end
