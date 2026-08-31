defmodule Fleet.Pilot.PollerTelemetry do
  use GenServer
  require Logger

  @moduledoc """
  The poller's telemetry, ATTACHED (BL-6-40 Phase 0).

  `Fleet.Pilot.Poller` has emitted `[:lcars_fleet, :pilot_poller, :poll]` from three sites since it was
  written — duration, dispatched/skipped/errors, per-repo status. Nothing anywhere in `lib/` ever
  called `:telemetry.attach`, so every one of those measurements was computed and dropped: nobody,
  human or agent, could state how long a poll actually took. The amplifiers that make polls slow
  (three `list_pods` calls per repo at a 5 s timeout, a redundant label GET per issue, a 15 s
  network `ls-remote` inside the GenServer) were therefore only ever REASONED about. This module
  is what turns them into something measurable, and it is deliberately the first phase: the rest
  of BL-6-40 is a set of optimisations that cannot be proven without it.

  ## What it does, and what it deliberately does NOT do

  Keeps the last #{100} samples in a ring and answers `stats/0` — count, last, p50/p95/max, and
  the error tally by scope. Logs ONLY when a sample crosses `:poller_slow_tick_ms` (default 10 s)
  or reports an error status.

  ⚠ **A sample is ONE REPO, not one cycle.** `[:lcars_fleet, :pilot_poller, :poll]` is emitted once per
  repo — every emission carries `repo:` — so this distribution describes what a single repo costs
  to poll, never what a full pass costs — N repos at a fixed interval make the counter advance by N
  per cycle. **The cost of a CYCLE is not measured here**, and no name in this module may suggest
  otherwise: a readiness key called `tick` asserts a scope the mechanism does not have, and a
  measurement gets read wrong for exactly as long as such a name stands.
  Deriving a cycle cost from these figures requires knowing how the repos are folded (serially or
  not) — that is a different instrument, not an arithmetic on this one.

  That different instrument is `[:lcars_fleet, :pilot_poller, :cycle]`, kept in a SECOND ring and read by
  `cycle_stats/0`: one sample per whole pass, carrying the repo count that produced it. Two rings
  rather than one field, because the two scales have different cardinalities (R against 1) — mixed
  in a single ring, the p50 would describe neither a repo nor a pass.

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
  strictly better than delaying the poll it measures. A mailbox that actually grows is itself the
  signal — and that is what the gauge below measures.

  ## The mailbox gauge (BL-6-40's cousin, delivered here)

  "No `message_queue_len` gauge on the StepRunConsumer/Poller mailboxes — a consumer falling behind
  is invisible until the symptom." It is sampled at EVERY poll, in this module rather than
  elsewhere, because the poll is already the cadence at which we want the answer: no extra timer,
  no extra process, and the instrument measures both singletons of the rail.

  It warns on CROSSING the threshold, not on every poll above it: a mailbox that stays high is ONE
  fact, and repeating it every 30 s would drown the trace this module exists to keep readable — the
  same discipline as the silent nominal poll. The return below the threshold is announced too:
  without it, an operator cannot tell resolved from dead.

  ## Config
    * `:lcars_fleet, :pilot_poller_slow_tick_ms` — warn threshold (default `10_000`).
  """

  @window 100
  # The two singletons of the rail whose mailbox is a signal: the Poller (if its ticks pile up, the
  # fleet is behind itself) and the StepRunConsumer (a consumer falling behind is INVISIBLE until
  # the symptom — BL-6-40, named cousin). They are sampled HERE
  # because a repo poll is already the cadence at which we want the answer: no extra timer, no extra
  # process.
  @watched [Fleet.Pilot.Poller, Fleet.Pilot.StepRunConsumer]
  # Beyond this, the mailbox no longer absorbs: it accumulates. Deliberately LOW — these two
  # processes handle a message in tens of milliseconds, so ten waiting already means something is
  # stuck, not that the load is high.
  @mailbox_warn 10
  @default_slow_tick_ms 10_000
  @event [:lcars_fleet, :pilot_poller, :poll]
  # The cycle is a DISTINCT event, not one more field on `:poll`: the two have different scales (one
  # repo / one pass) and different cardinalities (R against 1). Mixed into a single ring, the p50
  # would describe neither a repo nor a pass.
  @cycle_event [:lcars_fleet, :pilot_poller, :cycle]
  @handler_id "fleet-pilot-poller-telemetry"

  defstruct samples: [],
            count: 0,
            cycles: [],
            cycle_count: 0,
            slow_tick_ms: @default_slow_tick_ms,
            mailboxes: %{}

  # ============================================================
  # Public surface
  # ============================================================

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Rolling summary of the last #{@window} PER-REPO polls, or `:no_data` before the first one.

  `p50`/`p95`/`max` are over the window, not since boot: the question this answers is "is the
  poller healthy NOW", and an all-time average hides a rail that started degrading an hour ago
  behind the thousands of fast samples that preceded it.

      %{count: 412, window: 100, last_ms: 82, p50_ms: 76, p95_ms: 310, max_ms: 5_204,
        errors: %{repo_list: 2}, slow_tick_ms: 10_000}

  `count` is the total observed since boot; every other figure describes the window.

  ⚠ Every figure here is scoped to ONE REPO (cf. the moduledoc). With R repos in the org the
  counter advances by R per cycle, so `count` is not a number of cycles and `p50_ms` is not the
  duration of one.
  """
  @spec stats() :: map() | :no_data
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Rolling summary of the last #{@window} POLL CYCLES, or `:no_data` before the first one.

  A cycle is one whole pass: discover the org's repos, snapshot the pods, fold the R repos
  SERIALLY, then the two fleet-global passes. `last_repos` carries R for the most recent one, so a
  duration is readable against the size of the org that produced it — the single figure that made
  `stats/0` unreadable as a cycle cost.

      %{count: 96, window: 96, last_ms: 164, last_repos: 12, p50_ms: 158, p95_ms: 402,
        max_ms: 1_204, errors: 0}

  This is the figure to use when asking whether a value frozen at the start of a pass (a
  `base_sha`, the pod snapshot) can go stale before the pass ends. `stats/0` cannot answer that:
  it describes one repo and does not know how many there are.
  """
  @spec cycle_stats() :: map() | :no_data
  def cycle_stats, do: GenServer.call(__MODULE__, :cycle_stats)

  @doc false
  # The telemetry callback. Public because `:telemetry` dispatches to it by name from the poller's
  # process — NOT an API anyone should call (BL-6-42: a public function that exists only for a
  # framework is documented as such, here, rather than left looking like a surface).
  def handle_event(@cycle_event, measurements, metadata, _config) do
    GenServer.cast(
      __MODULE__,
      {:cycle, Map.get(measurements, :duration_ms, 0), Map.get(measurements, :repos, 0),
       Map.get(metadata, :status, :ok), Map.get(metadata, :mode)}
    )
  rescue
    _ -> :ok
  end

  def handle_event(@event, measurements, metadata, _config) do
    GenServer.cast(
      __MODULE__,
      {:sample, Map.get(measurements, :duration_ms, 0), Map.get(metadata, :status, :ok),
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
        Application.get_env(:lcars_fleet, :pilot_poller_slow_tick_ms, @default_slow_tick_ms)

    # Attach here rather than at application boot: the handler's target is THIS process, so the
    # attachment must not outlive it. `:already_exists` is not an error — a supervisor restart
    # re-attaches over the previous incarnation's registration.
    case :telemetry.attach_many(
           @handler_id,
           [@event, @cycle_event],
           &__MODULE__.handle_event/4,
           nil
         ) do
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
  def handle_cast({:sample, duration_ms, status, scope, repo}, state) do
    _ = maybe_warn(state, duration_ms, status, scope, repo)
    mailboxes = sample_mailboxes()
    _ = warn_saturated(mailboxes, state.mailboxes)

    {:noreply,
     %{
       state
       | count: state.count + 1,
         mailboxes: mailboxes,
         samples: Enum.take([{duration_ms, status, scope} | state.samples], @window)
     }}
  end

  @impl GenServer
  def handle_cast({:cycle, duration_ms, repos, status, mode}, state) do
    # No warn here: the `slow_tick_ms` threshold is calibrated on ONE REPO. A cycle over R repos
    # legitimately exceeds it R times over, so reusing that number would fire on every pass as soon
    # as the org grows — noise that teaches an operator to ignore the instrument. The cycle's
    # threshold is a separate decision, and until it is taken we MEASURE without alerting rather
    # than alert on a number nobody chose.
    {:noreply,
     %{
       state
       | cycle_count: state.cycle_count + 1,
         cycles: Enum.take([{duration_ms, repos, status, mode} | state.cycles], @window)
     }}
  end

  @impl GenServer
  def handle_call(:cycle_stats, _from, %{cycles: []} = state), do: {:reply, :no_data, state}

  def handle_call(:cycle_stats, _from, state) do
    durations = state.cycles |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    {last_ms, last_repos, _, _} = hd(state.cycles)

    {:reply,
     %{
       count: state.cycle_count,
       window: length(durations),
       last_ms: last_ms,
       last_repos: last_repos,
       p50_ms: percentile(durations, 50),
       p95_ms: percentile(durations, 95),
       max_ms: List.last(durations),
       errors: Enum.count(state.cycles, fn {_d, _r, status, _m} -> status == :error end)
     }, state}
  end

  def handle_call(:stats, _from, %{samples: []} = state), do: {:reply, :no_data, state}

  def handle_call(:stats, _from, state) do
    durations = state.samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    errors =
      state.samples
      |> Enum.filter(fn {_d, status, _scope} -> status == :error end)
      |> Enum.frequencies_by(fn {_d, _status, scope} -> scope || :discovery end)

    {last_ms, _, _} = hd(state.samples)

    {:reply,
     %{
       count: state.count,
       window: length(durations),
       last_ms: last_ms,
       p50_ms: percentile(durations, 50),
       p95_ms: percentile(durations, 95),
       max_ms: List.last(durations),
       errors: errors,
       slow_tick_ms: state.slow_tick_ms,
       mailboxes: state.mailboxes
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

  # `Process.info(pid, :message_queue_len)` on a LIVE pid only — an unregistered name (rail off,
  # restart in progress) drops OUT of the measurement instead of entering it as a zero, which would
  # look like "healthy".
  defp sample_mailboxes do
    for name <- @watched, pid = Process.whereis(name), into: %{} do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> {name, n}
        # Died between the `whereis` and the `info`: we do not manufacture a value.
        nil -> {name, :gone}
      end
    end
  end

  # Warn on CROSSING, not on every tick above the threshold: a mailbox that stays high is ONE fact,
  # and repeating it every 30 s would drown the trace this module exists to keep readable. The
  # return below the threshold is announced too — without it, an operator cannot tell resolved from
  # dead.
  defp warn_saturated(now, before) do
    for {name, n} <- now, is_integer(n) do
      was = Map.get(before, name)

      cond do
        n >= @mailbox_warn and (not is_integer(was) or was < @mailbox_warn) ->
          Logger.warning(
            "PollerTelemetry: mailbox de #{inspect(name)} a #{n} messages (seuil #{@mailbox_warn}) " <>
              "— ce process prend du retard, les faits qu'il traite arrivent plus vite qu'il ne les consomme"
          )

        n < @mailbox_warn and is_integer(was) and was >= @mailbox_warn ->
          Logger.info("PollerTelemetry: mailbox de #{inspect(name)} resorbee (#{n})")

        true ->
          :ok
      end
    end
  end

  # Nearest-rank on a SORTED list. No interpolation: these are millisecond counts over a window of
  # at most #{@window} samples, where an interpolated value would suggest a precision the sample
  # size does not carry.
  defp percentile([single], _p), do: single

  defp percentile(sorted, p) do
    idx = max(0, min(length(sorted) - 1, ceil(length(sorted) * p / 100) - 1))
    Enum.at(sorted, idx)
  end
end
