defmodule Fleet.Pilot.PollerTelemetry do
  use GenServer
  require Logger

  @moduledoc """
  The poller's telemetry, ATTACHED (BL-6-40 Phase 0).

  `Fleet.Pilot.Poller` has emitted `[:fleet_pilot, :poller, :poll]` from three sites since it was
  written — duration, dispatched/skipped/errors, per-repo status. Nothing anywhere in `lib/` ever
  called `:telemetry.attach`, so every one of those measurements was computed and dropped: nobody,
  human or agent, could state how long a tick actually took. The amplifiers that make ticks slow
  (three `list_pods` calls per repo at a 5 s timeout, a redundant label GET per issue, a 15 s
  network `ls-remote` inside the GenServer) were therefore only ever REASONED about. This module
  is what turns them into something measurable, and it is deliberately the first phase: the rest
  of BL-6-40 is a set of optimisations that cannot be proven without it.

  ## What it does, and what it deliberately does NOT do

  Keeps the last #{100} ticks in a ring and answers `stats/0` — count, last, p50/p95/max, and the
  error tally by scope. Logs ONLY when a tick crosses `:poller_slow_tick_ms` (default 10 s) or
  reports an error status.

  It does not log nominal ticks, and that restraint is a contract, not a taste: the poller is a
  ~30 s cron, its own moduledoc records that logging every nominal pass drowns the trace under
  hundreds of routine lines. An observability layer that re-introduces the noise the observed
  module removed on purpose has made the trace less readable, not more.

  ## The handler runs in the POLLER's process — three consequences

  `:telemetry.execute` invokes handlers inline, in the emitting process. So:

    * **It must be total.** A raise makes telemetry DETACH the handler permanently (by design) —
      the blindness would come back silently, and later than the change that caused it. Hence a
      `rescue`, and a body with nothing in it that can fail.
    * **It must not block.** `cast`, never `call`: a `call` would put this process's mailbox on
      the poller's critical path, which is exactly the class of coupling BL-6-40 is about.
    * **It is a NAMED function, never a closure.** `:telemetry` warns on anonymous handlers because
      they pin the defining module's code version; a captured `&__MODULE__.fun/4` does not.

  `cast` is lossy under saturation, and that is the correct trade here: dropping a metric is
  strictly better than delaying the tick it measures. A mailbox that actually grows is itself the
  signal, and it belongs to the gauge listed as a cousin item of BL-6-40, not to this module.

  ## Config
    * `:fleet_pilot, :poller_slow_tick_ms` — warn threshold (default `10_000`).

  **Last revised**: 2026-08-03
  """

  @window 100
  @default_slow_tick_ms 10_000
  @event [:fleet_pilot, :poller, :poll]
  @handler_id "fleet-pilot-poller-telemetry"

  defstruct ticks: [], count: 0, slow_tick_ms: @default_slow_tick_ms

  # ============================================================
  # Public surface
  # ============================================================

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Rolling summary of the last #{@window} ticks, or `:no_data` before the first one.

  `p50`/`p95`/`max` are over the window, not since boot: the question this answers is "is the
  poller healthy NOW", and an all-time average hides a rail that started degrading an hour ago
  behind the thousands of fast ticks that preceded it.

      %{count: 412, window: 100, last_ms: 82, p50_ms: 76, p95_ms: 310, max_ms: 5_204,
        errors: %{repo_list: 2}, slow_tick_ms: 10_000}

  `count` is the total observed since boot; every other figure describes the window.
  """
  @spec stats() :: map() | :no_data
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc false
  # The telemetry callback. Public because `:telemetry` dispatches to it by name from the poller's
  # process — NOT an API anyone should call (BL-6-42: a public function that exists only for a
  # framework is documented as such, here, rather than left looking like a surface).
  def handle_event(@event, measurements, metadata, _config) do
    GenServer.cast(
      __MODULE__,
      {:tick, Map.get(measurements, :duration_ms, 0), Map.get(metadata, :status, :ok),
       Map.get(metadata, :scope), Map.get(metadata, :repo)}
    )
  rescue
    # Total by obligation: a raise here detaches the handler for the lifetime of the node, and the
    # blindness returns without a word. Nothing above can realistically fail, which is the point —
    # if it ever does, we lose one metric, not the instrument.
    _ -> :ok
  end

  # ============================================================
  # GenServer
  # ============================================================

  @impl GenServer
  def init(opts) do
    slow =
      Keyword.get(opts, :slow_tick_ms) ||
        Application.get_env(:fleet_pilot, :poller_slow_tick_ms, @default_slow_tick_ms)

    # Attach here rather than at application boot: the handler's target is THIS process, so the
    # attachment must not outlive it. `:already_exists` is not an error — a supervisor restart
    # re-attaches over the previous incarnation's registration.
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{slow_tick_ms: slow}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    # Detach on the way out: a handler pointing at a dead process would make every subsequent
    # `execute` in the poller do a doomed cast, and telemetry has no way to know.
    # `{:error, :not_found}` is a legitimate outcome, not a failure: init tolerates re-attaching
    # over a previous incarnation, so a restart pair can detach a registration already replaced.
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @impl GenServer
  def handle_cast({:tick, duration_ms, status, scope, repo}, state) do
    _ = maybe_warn(state, duration_ms, status, scope, repo)

    {:noreply,
     %{
       state
       | count: state.count + 1,
         ticks: Enum.take([{duration_ms, status, scope} | state.ticks], @window)
     }}
  end

  @impl GenServer
  def handle_call(:stats, _from, %{ticks: []} = state), do: {:reply, :no_data, state}

  def handle_call(:stats, _from, state) do
    durations = state.ticks |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    errors =
      state.ticks
      |> Enum.filter(fn {_d, status, _scope} -> status == :error end)
      |> Enum.frequencies_by(fn {_d, _status, scope} -> scope || :discovery end)

    {last_ms, _, _} = hd(state.ticks)

    {:reply,
     %{
       count: state.count,
       window: length(durations),
       last_ms: last_ms,
       p50_ms: percentile(durations, 50),
       p95_ms: percentile(durations, 95),
       max_ms: List.last(durations),
       errors: errors,
       slow_tick_ms: state.slow_tick_ms
     }, state}
  end

  # ============================================================
  # Internals
  # ============================================================

  defp maybe_warn(_state, _ms, :error, scope, repo) do
    Logger.warning(
      "PollerTelemetry: tick in ERROR scope=#{inspect(scope || :discovery)} repo=#{inspect(repo)}"
    )
  end

  defp maybe_warn(%{slow_tick_ms: slow}, ms, _status, _scope, repo) when ms >= slow do
    Logger.warning(
      "PollerTelemetry: SLOW tick #{ms}ms (>= #{slow}ms) repo=#{inspect(repo)} — " <>
        "candidates: list_pods x3/repo at 5s timeout, per-issue label GET, synchronous ls-remote"
    )
  end

  defp maybe_warn(_state, _ms, _status, _scope, _repo), do: :ok

  # Nearest-rank on a SORTED list. No interpolation: these are millisecond counts over a window of
  # at most #{@window} samples, where an interpolated value would suggest a precision the sample
  # size does not carry.
  defp percentile([single], _p), do: single

  defp percentile(sorted, p) do
    idx = max(0, min(length(sorted) - 1, ceil(length(sorted) * p / 100) - 1))
    Enum.at(sorted, idx)
  end
end
