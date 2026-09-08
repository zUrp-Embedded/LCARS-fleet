defmodule Fleet.Admiral.MCPMonitor do
  @moduledoc """
  Passive health check of the **pod-facing MCP substrate** (the DynamicSupervisor
  of per-pod sockets, `Fleet.MCP.PodSocketSupervisor`).

  ## Mechanics

  GenServer + recursive `Process.send_after/3` — the plumbing (named start_link, tick + re-arming,
  test hook `:check_now`) lives in `Fleet.PeriodicCheck` (foundation); this module keeps its state, its
  `do_check/1` and the shape of its reply (`{:ok, status}`). On each tick, checks the target's
  liveness:

    * target alive → status `:ok`
    * absent / dead → status `:crashed`

  Detects the `:ok → :crashed` transition (NOT `:unknown → :crashed` at boot,
  NOT `:crashed → :crashed` so as not to spam) and broadcasts a canonical event.
  The `:crashed → :ok` return just logs — silent recovery, with no dedicated event.

  ## Target

  The pod-facing substrate (`get_work_item`/`submit_result`) is served by a per-pod
  AF_UNIX socket, fanned out by the DynamicSupervisor `Fleet.MCP.PodSocketSupervisor`.
  We check its liveness via the **supervision tree**: target
  `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` →
  `Supervisor.which_children/1` looks up the child and tests that its pid is alive.
  Robust (pure OTP) and semantically correct: substrate absent → silent `:crashed`
  (no broadcast from `:unknown`, nothing to monitor). An **atom** target stays
  supported (`Process.whereis`, for tests + any named process).

  ## Event broadcast

  Canonical schema `%Fleet.Event{source: :admiral, type: :"mcp.server_crashed",
  payload: %{previous_status, new_status, target}, correlation_id: nil}`.

  ## Configuration

    * `:lcars_fleet, :admiral_mcp_monitor_check_interval_ms` — default `60_000` (1 min)
    * `:lcars_fleet, :admiral_mcp_monitor_target` — target (default
      `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}`). Accepts an
      atom (named process) OR `{:supervised, sup, child_id}`. Tests inject a fake target.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.PeriodicCheck

  @default_interval_ms 60_000
  @default_target {:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: PeriodicCheck.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{
      target: Keyword.get(opts, :target) || config_target(),
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval_ms(),
      status: :unknown,
      last_check: nil
    }

    _ = PeriodicCheck.schedule(:health_check, state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:health_check, state),
    do: PeriodicCheck.tick(state, :health_check, &do_check/1)

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:check_now, _from, state),
    do: PeriodicCheck.check_now(state, &do_check/1, &{:ok, &1.status})

  defp do_check(state) do
    new_status = check_target(state.target)
    new_state = %{state | status: new_status, last_check: DateTime.utc_now()}

    _ =
      case {state.status, new_status} do
        {:ok, :crashed} ->
          Logger.error("MCPMonitor: target=#{inspect(state.target)} transition :ok → :crashed")

          _ = broadcast_crashed(state.target, :ok, :crashed)

        {:crashed, :ok} ->
          Logger.info("MCPMonitor: target=#{inspect(state.target)} recovered :crashed → :ok")

        {same, same} ->
          :ok

        {previous, current} ->
          Logger.debug(
            "MCPMonitor: target=#{inspect(state.target)} transition #{inspect(previous)} → #{inspect(current)} (no broadcast)"
          )
      end

    new_state
  end

  defp check_target({:supervised, sup, child_id}) do
    case List.keyfind(Supervisor.which_children(sup), child_id, 0) do
      {^child_id, pid, _type, _modules} when is_pid(pid) -> :ok
      _ -> :crashed
    end
  rescue
    _ -> :crashed
  catch
    :exit, _ -> :crashed
  end

  defp check_target(target) when is_atom(target) do
    case Process.whereis(target) do
      nil -> :crashed
      pid when is_pid(pid) -> :ok
    end
  end

  defp broadcast_crashed(target, previous, new) do
    Bus.safe_emit(
      :admiral,
      :"mcp.server_crashed",
      [
        payload: %{
          "target" => inspect(target),
          "previous_status" => Atom.to_string(previous),
          "new_status" => Atom.to_string(new)
        }
      ],
      on_unregistered: :silent,
      context: "MCPMonitor: mcp.server_crashed alert NOT emitted"
    )
  end

  defp config_interval_ms do
    Application.get_env(
      :lcars_fleet,
      :admiral_mcp_monitor_check_interval_ms,
      @default_interval_ms
    )
  end

  defp config_target do
    Application.get_env(:lcars_fleet, :admiral_mcp_monitor_target, @default_target)
  end
end
