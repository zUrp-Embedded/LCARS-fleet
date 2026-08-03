defmodule Fleet.Pilot.PollerTelemetry do
  use GenServer
  require Logger

  @moduledoc """
  The poller's telemetry, ATTACHED (BL-6-40 Phase 0).

  `Fleet.Pilot.Poller` has emitted `[:fleet_pilot, :poller, :poll]` from three sites since it was
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

  ⚠ **A sample is ONE REPO, not one cycle.** `[:fleet_pilot, :poller, :poll]` is emitted once per
  repo — every emission carries `repo:` — so this distribution describes what a single repo costs
  to poll, never what a full pass costs. Measured on 2026-08-03: 12 repos at a 30 s interval made
  the counter advance by 12 per cycle. **The cost of a CYCLE is not measured here**, and no name in
  this module may suggest otherwise: the readiness key was first called `tick`, which asserted a
  scope the mechanism does not have, and a measurement was read wrong before that name was fixed.
  Deriving a cycle cost from these figures requires knowing how the repos are folded (serially or
  not) — that is a different instrument, not an arithmetic on this one.

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
  signal — and c'est ce que la jauge ci-dessous mesure.

  ## La jauge de mailbox (cousin de BL-6-40, livre ici)

  « Aucune jauge de `message_queue_len` sur les mailboxes StepRunConsumer/Poller — un consumer en
  retard est invisible jusqu'au symptome. » Elle est echantillonnee a CHAQUE poll, dans ce module
  plutot qu'ailleurs, parce que le poll est deja la cadence a laquelle on veut la reponse : aucun
  timer de plus, aucun process de plus, et l'instrument mesure les deux singletons du rail.

  Elle warn au FRANCHISSEMENT du seuil, pas a chaque poll au-dessus : une mailbox qui reste haute
  est UN fait, et le repeter toutes les 30 s noierait la trace que ce module existe pour garder
  lisible — la meme discipline que le silence du poll nominal. Le retour sous le seuil est dit
  aussi : sans lui, un operateur ne sait pas si c'est resorbe ou si le rail est mort.

  ## Config
    * `:fleet_pilot, :poller_slow_tick_ms` — warn threshold (default `10_000`).

  **Last revised**: 2026-08-03
  """

  @window 100
  # Les deux singletons du rail dont la mailbox est un signal : le Poller (si ses ticks
  # s'accumulent, la fleet est en retard sur elle-meme) et le StepRunConsumer (un consumer en
  # retard est INVISIBLE jusqu'au symptome — BL-6-40, cousin nomme). Ils sont echantillonnes ICI
  # parce qu'un poll de depot est deja la cadence a laquelle on veut la reponse : pas de timer de
  # plus, pas de process de plus.
  @watched [Fleet.Pilot.Poller, Fleet.Pilot.StepRunConsumer]
  # Au-dela, la mailbox n'absorbe plus : elle accumule. Seuil volontairement BAS — ces deux
  # process traitent un message en dizaines de millisecondes, donc dix en attente veut deja dire
  # que quelque chose bloque, pas que la charge est forte.
  @mailbox_warn 10
  @default_slow_tick_ms 10_000
  @event [:fleet_pilot, :poller, :poll]
  @handler_id "fleet-pilot-poller-telemetry"

  defstruct samples: [], count: 0, slow_tick_ms: @default_slow_tick_ms, mailboxes: %{}

  # ============================================================
  # Public surface
  # ============================================================

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

  @doc false
  # The telemetry callback. Public because `:telemetry` dispatches to it by name from the poller's
  # process — NOT an API anyone should call (BL-6-42: a public function that exists only for a
  # framework is documented as such, here, rather than left looking like a surface).
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

  # `Process.info(pid, :message_queue_len)` sur un pid VIVANT uniquement — un nom non enregistre
  # (rail off, redemarrage en cours) sort de la mesure au lieu d'y entrer comme un zero, qui
  # ressemblerait a « sain ».
  defp sample_mailboxes do
    for name <- @watched, pid = Process.whereis(name), into: %{} do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> {name, n}
        # Mort entre le `whereis` et le `info` : on ne fabrique pas une valeur.
        nil -> {name, :gone}
      end
    end
  end

  # Warn au FRANCHISSEMENT, pas a chaque tick au-dessus du seuil : une mailbox qui reste haute est
  # un seul fait, et le repeter toutes les 30 s noierait la trace que ce module existe pour garder
  # lisible. Le retour sous le seuil est dit aussi — sans lui, un operateur ne sait pas si c'est
  # resorbe ou si le rail est mort.
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
