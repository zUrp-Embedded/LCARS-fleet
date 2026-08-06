defmodule Fleet.MCP.SocketWarden do
  @moduledoc """
  Runtime reaper for sockets whose pod disappeared without release. Owned sockets
  are reconciled against live pods with two-tick grace. Enumeration failure reaps
  nothing and preserves suspects.
  """

  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, 60_000)

    state = %{
      tick_ms: tick_ms,
      live_pods_fun: Keyword.get(opts, :live_pods_fun, &default_live_pods/0),
      owned_fun: Keyword.get(opts, :owned_fun, &Fleet.MCP.PodSocketSupervisor.live_pod_ids/0),
      release_fun:
        Keyword.get(opts, :release_fun, &Fleet.MCP.PodSocketSupervisor.release_pod_socket/1),
      suspects: MapSet.new()
    }

    Process.send_after(self(), :reap, tick_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reap, state) do
    Process.send_after(self(), :reap, state.tick_ms)

    case live_pod_ids(state) do
      :error ->
        # Unknown is not an empty live set.
        {:noreply, state}

      live ->
        orphans = state.owned_fun.() |> MapSet.new() |> MapSet.difference(live)
        confirmed = MapSet.intersection(orphans, state.suspects)

        for pod_id <- confirmed do
          Logger.warning(
            "SocketWarden: MCP socket of pod #{pod_id} ORPHANED (pod gone without releasing — " <>
              "brutal teardown?) → released"
          )

          _ = state.release_fun.(pod_id)
        end

        {:noreply, %{state | suspects: MapSet.difference(orphans, confirmed)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp live_pod_ids(state) do
    MapSet.new(state.live_pods_fun.())
  rescue
    e ->
      Logger.warning(
        "SocketWarden: live-pod enumeration failed (#{inspect(e)}) — nothing reaped this tick"
      )

      :error
  catch
    _, _ -> :error
  end

  defp default_live_pods do
    Enum.map(Fleet.Spawner.list_pods(), & &1[:pod_id])
  end
end
