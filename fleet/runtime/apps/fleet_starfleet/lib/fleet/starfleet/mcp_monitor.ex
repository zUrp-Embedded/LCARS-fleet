defmodule Fleet.Starfleet.MCPMonitor do
  @moduledoc """
  Health check passif du serveur MCP local (`Fleet.MCP.Server`).

  DN 13 `orchestration/fleet_starfleet.md` §Extensions V2 (BL-021 chantier 8).

  ## Mécanique

  GenServer + `Process.send_after/3` récursif. À chaque tick (default 60s),
  consulte `Process.whereis(Fleet.MCP.Server)` :

    * pid non-nil → status `:ok`
    * nil → status `:crashed`

  Détecte la transition `:ok → :crashed` (PAS `:unknown → :crashed` au boot,
  PAS `:crashed → :crashed` pour ne pas spammer) et broadcast un event canon.
  Le retour `:crashed → :ok` log juste (recovery silencieuse, pas d'event
  dédié dans la DN MVP).

  ## Configuration

    * `:fleet_starfleet, :mcp_monitor_check_interval_ms` — default `60_000` (1 min)
    * `:fleet_starfleet, :mcp_monitor_target` — module cible (default
      `Fleet.MCP.Server`). Permet aux tests d'injecter une cible factice.

  ## Event broadcast

  Schema canon `%Fleet.Event{source: :starfleet, type: :mcp_server_crashed,
  payload: %{previous_status, new_status, target}, correlation_id: nil}`.

  ## Post-C5.1 ADR-G

  Les channels push (FleetControl/FleetForge) ont été retirés au chantier 7
  BL-021 (PoC Channel KO 4 itérations), mais le serveur MCP reste critique
  (drive métier `get_task`/`submit_result` via tools pull). Monitorer son
  process est nécessaire pour détecter un crash silencieux post-purge.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @default_interval_ms 60_000
  @default_target Fleet.MCP.Server

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      target: Keyword.get(opts, :target) || config_target(),
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval_ms(),
      status: :unknown,
      last_check: nil
    }

    schedule_check(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    new_state = do_check(state)
    schedule_check(new_state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Hook test : déclenche un check immédiat sync (équivalent au timer).
  @impl GenServer
  def handle_call(:check_now, _from, state) do
    new_state = do_check(state)
    {:reply, {:ok, new_state.status}, new_state}
  end

  defp do_check(state) do
    new_status = check_target(state.target)
    new_state = %{state | status: new_status, last_check: DateTime.utc_now()}

    case {state.status, new_status} do
      {:ok, :crashed} ->
        Logger.error("MCPMonitor: target=#{inspect(state.target)} transition :ok → :crashed")

        broadcast_crashed(state.target, :ok, :crashed)

      {:crashed, :ok} ->
        Logger.info("MCPMonitor: target=#{inspect(state.target)} recovered :crashed → :ok")

      {previous, ^new_status} when previous == new_status ->
        :ok

      {previous, current} ->
        Logger.debug(
          "MCPMonitor: target=#{inspect(state.target)} transition #{inspect(previous)} → #{inspect(current)} (no broadcast)"
        )
    end

    new_state
  end

  defp check_target(target) when is_atom(target) do
    case Process.whereis(target) do
      nil -> :crashed
      pid when is_pid(pid) -> :ok
    end
  end

  defp broadcast_crashed(target, previous, new) do
    event = %Fleet.Event{
      source: :starfleet,
      type: :mcp_server_crashed,
      timestamp: DateTime.utc_now(),
      pod_id: nil,
      correlation_id: nil,
      payload: %{
        "target" => inspect(target),
        "previous_status" => Atom.to_string(previous),
        "new_status" => Atom.to_string(new)
      }
    }

    Bus.broadcast("fleet.events", event)
  rescue
    _e in Fleet.Event.UnregisteredError -> :ok
    _e in [ArgumentError, FunctionClauseError] -> :ok
  end

  defp schedule_check(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp config_interval_ms do
    Application.get_env(:fleet_starfleet, :mcp_monitor_check_interval_ms, @default_interval_ms)
  end

  defp config_target do
    Application.get_env(:fleet_starfleet, :mcp_monitor_target, @default_target)
  end
end
