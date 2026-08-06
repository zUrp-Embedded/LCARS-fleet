defmodule Fleet.Starfleet.PeriodicCheck do
  @moduledoc """
  Plumbing for starfleet's periodic-check GenServers. `MCPMonitor` is its only user since
  MCPWatcher moved to CI (2026-08-03); kept generic rather than inlined — the next periodic
  check should not have to re-derive the tick/re-arm/test-hook shape.

  Both twins carry the SAME skeleton: named GenServer + recursive `Process.send_after/3`
  (a single deadline armed at any instant: the tick runs the check then re-arms the next) +
  test hook `:check_now` (a sync call that replays the timer's full code path). This skeleton lives
  HERE, as FUNCTIONS called from their callbacks — no `use` macro: functions
  suffice, and a callback that delegates explicitly stays auditable line by line (no generated
  code to reconstruct from memory).

  Each twin keeps what is its OWN: its `init/1` (the state fields differ — target and
  status for the monitor, package/fetcher/versions for the watcher), its `do_check/1` (the business logic)
  and the SHAPE of its `:check_now` reply (`{:ok, status}` for the monitor, `:ok` for the watcher).
  Minimal state contract: a map carrying `interval_ms` (re-read on EVERY re-arm).

  Do NOT generalize beyond these two modules: the runtime's other periodic GenServers
  (e.g. `Fleet.Spawner.PodWarden`) have their own nuances (handle_continue, tick skip) — folding
  them in here would force speculative parameters. Two real clients, zero hypothetical clients.

  ## Contract (called by `MCPMonitor`)

  - `start_link(module, opts)` — starts the named GenServer `module` (`opts[:name]`, default the
    module itself — tests inject a unique name to co-exist).
  - `schedule(tick_message, interval_ms)` — arms the NEXT deadline (`send_after` to `self()`,
    so called FROM the GenServer process: `init/1` and the tick handler).
  - `tick(state, tick_message, do_check)` — body of the tick `handle_info`: runs `do_check.(state)`
    then re-arms → `{:noreply, new_state}`.
  - `check_now(state, do_check, reply)` — body of `handle_call(:check_now, ...)`: same check as
    the timer, reply built by `reply.(new_state)` → `{:reply, _, new_state}`.
  """

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    GenServer.start_link(module, opts, name: Keyword.get(opts, :name, module))
  end

  @spec schedule(atom(), pos_integer()) :: reference()
  def schedule(tick_message, interval_ms)
      when is_atom(tick_message) and is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), tick_message, interval_ms)
  end

  @spec tick(map(), atom(), (map() -> map())) :: {:noreply, map()}
  def tick(state, tick_message, do_check) when is_function(do_check, 1) do
    new_state = do_check.(state)
    _ = schedule(tick_message, new_state.interval_ms)
    {:noreply, new_state}
  end

  @spec check_now(map(), (map() -> map()), (map() -> term())) :: {:reply, term(), map()}
  def check_now(state, do_check, reply)
      when is_function(do_check, 1) and is_function(reply, 1) do
    new_state = do_check.(state)
    {:reply, reply.(new_state), new_state}
  end
end
