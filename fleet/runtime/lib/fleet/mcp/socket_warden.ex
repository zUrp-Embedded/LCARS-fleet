defmodule Fleet.MCP.SocketWarden do
  @moduledoc """
  Reaps the ORPHANED pod sockets — the runtime net that `release_pod_socket/1` cannot be.

  A pod releases its socket from `terminate/3`. A BRUTAL kill (wedged tmux teardown, `kill -9`,
  BEAM crash) never runs that callback: the acceptor process, its AF_UNIX listener, its Registry
  entry and the socket file survive their pod. `sweep_stale_sockets/0` only cleans them at COLD
  BOOT — so, until the next reboot, the leak accumulates: FDs, processes, and a stale file that
  makes a dead pod look reachable. The tmux sessions and pod_dirs already have their runtime
  reaper (`Fleet.Spawner.PodWarden`); the sockets did not. This is that reaper.

  ## Mechanics — reconcile, never guess

  Every tick, it confronts what THIS domain believes it serves (`PodSocketSupervisor.live_pod_ids/0`
  = the Registry) with the pods the SPAWNER reports live (`Fleet.Spawner.list_pods/0` — a declared
  boundary dep of `Fleet.MCP`, no seam to widen). A socket whose pod is absent is a candidate.

  **2-tick grace** (same doctrine as the PodWarden): a candidate is only released if it was ALSO a
  candidate at the previous tick. `ensure_pod_socket/1` runs during the pod's `:projecting` state —
  a socket can legitimately exist for a few instants before the pod is registered. Reaping on the
  first sighting would kill the socket of a pod being born; the grace makes the race impossible.

  **Fail-safe**: if the spawner enumeration fails, the tick releases NOTHING (an empty live-set
  would make EVERY socket look orphaned — a reconciliation must never become the outage it exists
  to prevent). Same stance as the poller's lock reconciliation.

  ## Seams

    * `:tick_ms` (default 60_000) — reconciliation cadence.
    * `:live_pods_fun` — `() -> [pod_id]` (default = the spawner's live pods).
    * `:owned_fun` — `() -> [pod_id]` (default = this domain's Registry).
    * `:release_fun` — `(pod_id) -> :ok` (default = `PodSocketSupervisor.release_pod_socket/1`).

  Boot gate: `:fleet_mcp, :start_socket_warden` (default true prod, false test — hermeticity: the
  tests drive it with explicit seams).
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
      # Sockets seen orphaned at the PREVIOUS tick (2-tick grace).
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
        # Fail-safe: an unavailable spawner would make every socket look orphaned. We keep the
        # suspects as they are and reap NOTHING — never unmount blindly.
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

  # The live set is the TRUTH the reconciliation leans on: a failure to enumerate must degrade to
  # `:error` (reap nothing), never to an empty set (reap everything).
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
