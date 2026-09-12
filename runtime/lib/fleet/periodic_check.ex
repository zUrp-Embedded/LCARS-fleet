defmodule Fleet.PeriodicCheck do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Callback helpers for GenServers that check, then schedule their next tick.
  start_link/2 passes all opts to init; opts[:name] defaults to the module, or nil for an unnamed server.
  Clients own init, check logic and synchronous reply shape; state must contain positive interval_ms.
  Call schedule from the server process and maintain one timer chain; these helpers do not deduplicate
  timers. Re-arming after completion avoids overlap and uses cadence changes returned by the check.

  Periodic check exceptions, throws and exits are logged while retaining prior state, preserving
  observations that a supervisor restart would reset. Scheduling errors and invalid returned state
  are outside that protection. check_now propagates failures and does not alter timer cadence;
  clients needing error values must convert failures inside their own check.

  These functions cover a regular tick loop, not per-subject deadlines, jitter, backoff or leases.
  """

  require Logger

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    GenServer.start_link(module, opts, name: Keyword.get(opts, :name, module))
  end

  @doc """
  Sends the next tick to self after interval_ms and returns its timer reference.
  Called from init to start the chain without immediately checking.
  """
  @spec schedule(atom(), pos_integer()) :: reference()
  def schedule(tick_message, interval_ms)
      when is_atom(tick_message) and is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), tick_message, interval_ms)
  end

  @doc """
  Runs the check, then schedules using the resulting state's interval_ms.
  A raised/thrown/exited check logs at error with server identity and tick message and retains
  prior state. Scheduling still requires a valid positive interval in that state.
  """
  @spec tick(map(), atom(), (map() -> map())) :: {:noreply, map()}
  def tick(state, tick_message, do_check) when is_function(do_check, 1) do
    new_state = safe_check(state, tick_message, do_check)
    _ = schedule(tick_message, new_state.interval_ms)
    {:noreply, new_state}
  end

  @doc """
  Runs an on-demand check and builds the reply from its resulting state. Failures propagate.
  Does not re-arm: polling this call must not postpone the scheduled check indefinitely.
  """
  @spec check_now(map(), (map() -> map()), (map() -> term())) :: {:reply, term(), map()}
  def check_now(state, do_check, reply)
      when is_function(do_check, 1) and is_function(reply, 1) do
    new_state = do_check.(state)
    {:reply, reply.(new_state), new_state}
  end

  defp safe_check(state, tick_message, do_check) do
    do_check.(state)
  rescue
    e ->
      Logger.error(
        "#{who()}: periodic check #{inspect(tick_message)} RAISED — #{Exception.message(e)} — " <>
          "state kept, next tick in #{state.interval_ms}ms"
      )

      state
  catch
    kind, reason ->
      Logger.error(
        "#{who()}: periodic check #{inspect(tick_message)} #{kind} — #{inspect(reason)} — " <>
          "state kept, next tick in #{state.interval_ms}ms"
      )

      state
  end

  defp who do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} -> inspect(name)
      _ -> inspect(self())
    end
  end
end
