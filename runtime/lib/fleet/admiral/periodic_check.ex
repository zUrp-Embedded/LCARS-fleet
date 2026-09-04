defmodule Fleet.Admiral.PeriodicCheck do
  @moduledoc """
  Plumbing for the admiral domain's periodic-check GenServers (its clients call `start_link/1` —
  grep for them, a list here would rot). Kept generic rather than inlined: the next periodic check
  should not have to re-derive the tick/re-arm/test-hook shape.

  Every client carries the SAME skeleton: named GenServer + recursive `Process.send_after/3`
  (a single deadline armed at any instant: the tick runs the check then re-arms the next) +
  test hook `:check_now` (a sync call that replays the timer's full code path). This skeleton lives
  HERE, as FUNCTIONS called from their callbacks — no `use` macro: functions suffice, and a callback
  that delegates explicitly stays auditable line by line (no generated code to reconstruct from
  memory).

  Each client keeps what is its OWN: its `init/1` (the state fields differ), its `do_check/1` (the
  business logic) and the SHAPE of its `:check_now` reply. Minimal state contract: a map carrying
  `interval_ms` (re-read on EVERY re-arm).

  ⚠ Do NOT generalize beyond the clients that actually call it: the runtime's other periodic
  GenServers have their own nuances (handle_continue, tick skip), and folding them in would force
  SPECULATIVE parameters. Real clients only, zero hypothetical ones.

  ## Contract

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

  @doc """
  Arms the next tick — `Process.send_after/3`, returning its reference.

  Separate from `tick/3` so a GenServer can arm the first one from `init/1` without running a check.
  """
  @spec schedule(atom(), pos_integer()) :: reference()
  def schedule(tick_message, interval_ms)
      when is_atom(tick_message) and is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), tick_message, interval_ms)
  end

  @doc """
  Runs one periodic check and RE-ARMS from the new state, in that order.

  The interval is read from the state AFTER the check, so a check that changes its own cadence takes
  effect on the next tick rather than the one after. Re-arming last also means a raising check stops
  the timer instead of looping on the failure.
  """
  @spec tick(map(), atom(), (map() -> map())) :: {:noreply, map()}
  def tick(state, tick_message, do_check) when is_function(do_check, 1) do
    new_state = do_check.(state)
    _ = schedule(tick_message, new_state.interval_ms)
    {:noreply, new_state}
  end

  @doc """
  Runs the check ON DEMAND and replies from the RESULTING state — the `handle_call` twin of `tick/3`.

  Does NOT re-arm: an out-of-band check must not shift the periodic cadence, or a caller polling it
  would silently suppress the scheduled one.
  """
  @spec check_now(map(), (map() -> map()), (map() -> term())) :: {:reply, term(), map()}
  def check_now(state, do_check, reply)
      when is_function(do_check, 1) and is_function(reply, 1) do
    new_state = do_check.(state)
    {:reply, reply.(new_state), new_state}
  end
end
