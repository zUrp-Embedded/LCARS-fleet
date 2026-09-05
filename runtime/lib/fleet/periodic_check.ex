defmodule Fleet.PeriodicCheck do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Plumbing for the runtime's periodic-check GenServers (its clients call `start_link/2` — grep for
  them, a list here would rot). Kept generic rather than inlined: the next periodic check should
  not have to re-derive the tick / re-arm / safety-net / test-hook shape.

  Every client carries the SAME skeleton: a named GenServer + a recursive `Process.send_after/3`
  (a single deadline armed at any instant: the tick runs the check then re-arms the next) + the
  test hook `:check_now` (a sync call that replays the timer's full code path). This skeleton lives
  HERE, as FUNCTIONS called from their callbacks — no `use` macro: functions suffice, and a
  callback that delegates explicitly stays auditable line by line (no generated code to
  reconstruct from memory).

  Each client keeps what is its OWN: its `init/1` (the state fields differ), its `do_check/1` (the
  business logic) and the SHAPE of its `:check_now` reply. Minimal state contract: a map carrying
  `interval_ms` (re-read on EVERY re-arm).

  ## The safety net, and why it is here and not in each client

  `tick/3` runs the check under a net: a check that raises, throws or exits is logged at `error`
  with the GenServer's registered name and the tick message, the state from BEFORE the check is
  kept, and the next tick is armed from it. Lossy by construction — and every client had written
  that net for itself before it lived here, which is how a contract gets recognised.

  The alternative reads better than it is. Without the net, a raise in `handle_info` kills the
  GenServer; its domain supervisor restarts it (3 per 60 s, everywhere in this runtime); `init/1`
  re-arms. A check that raises on every tick therefore restarts once per interval, UNDER the
  intensity, forever: the failure loops anyway — through a crash report per tick instead of one
  error line, and with the client's state reset each time (a monitor whose status is reset to
  `:unknown` never sees the `:ok → :crashed` transition it exists to broadcast). The net is what
  makes the failure visible AND the state durable.

  `check_now/3` has NO net, on purpose: an on-demand check is a test or an operator asking, and a
  raise there must reach its caller rather than be swallowed into a log line. A client that wants
  its on-demand failure as a VALUE (rather than an exit) rescues inside its own `do_check`; the
  toolchain reconciler does, to hand `check_now` an `{:error, {:raised, _}}`.

  ## Re-arm LAST, from the resulting state

  The interval is read from the state AFTER the check, so a check that changes its own cadence
  takes effect on the next tick rather than the one after. Re-arming FIRST would make the period
  fixed regardless of the check's duration — and let a check longer than its interval pile ticks
  up in the mailbox. Under the net, re-arming last costs nothing and keeps both properties.

  ## Real clients only

  Still no speculative parameter: a module joins because its tick IS this shape — arm, check,
  re-arm, replay on demand — not because it could be made to fit. A reconciler that also owns a
  family of per-subject timers (respawn deadlines per role) is not this shape; a reactor with
  jitter, error backoff and a drain lease around its tick is not this shape either. Both keep
  their own plumbing.

  ## Contract

  - `start_link(module, opts)` — starts the named GenServer `module` (`opts[:name]`, default the
    module itself — tests inject a unique name, or `nil`, to co-exist). The whole `opts` reaches
    `init/1`.
  - `schedule(tick_message, interval_ms)` — arms the NEXT deadline (`send_after` to `self()`,
    so called FROM the GenServer process: `init/1` and the tick handler).
  - `tick(state, tick_message, do_check)` — body of the tick `handle_info`: runs `do_check.(state)`
    under the net, then re-arms → `{:noreply, new_state}`.
  - `check_now(state, do_check, reply)` — body of `handle_call(:check_now, ...)`: same check as
    the timer, no net, no re-arm, reply built by `reply.(new_state)` → `{:reply, _, new_state}`.
  """

  require Logger

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
  Runs one periodic check under the net and RE-ARMS from the resulting state, in that order.

  A check that raises, throws or exits leaves the prior state in place (logged at `error` with the
  GenServer's name and the tick message); the timer never stops.
  """
  @spec tick(map(), atom(), (map() -> map())) :: {:noreply, map()}
  def tick(state, tick_message, do_check) when is_function(do_check, 1) do
    new_state = safe_check(state, tick_message, do_check)
    _ = schedule(tick_message, new_state.interval_ms)
    {:noreply, new_state}
  end

  @doc """
  Runs the check ON DEMAND and replies from the RESULTING state — the `handle_call` twin of `tick/3`.

  Does NOT re-arm: an out-of-band check must not shift the periodic cadence, or a caller polling it
  would silently suppress the scheduled one. Does NOT catch: the caller asked, the caller sees.
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
