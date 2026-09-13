defmodule Fleet.Pilot.PollerTelemetry do
  use GenServer
  require Logger

  @moduledoc """
  Collects poller telemetry in separate rolling windows of #{100} samples for
  :poll and :cycle. Poll samples mix per-repository measurements and discovery
  failures; cycle samples describe whole passes. They must not share percentiles.
  Counts are cumulative since this process started; distributions cover each window.

  Named telemetry callbacks run inline in the emitter and cast to this singleton.
  They rescue exceptions to avoid handler detachment, but do not validate field
  values. Casts have no acknowledgement or bounded mailbox here: the sample windows
  are bounded, not admission to the process. Missing recipients can lose samples.

  Poll samples warn on error status or duration at/above :pilot_poller_slow_tick_ms
  (default 10_000). Nominal samples are quiet. Cycle samples do not warn: a repository
  threshold would misclassify large multi-repo passes. Item-error tallies carried by
  successful poll events are not retained; only status == :error contributes errors.

  On handling each poll sample, gauge Poller and StepRunConsumer mailbox lengths.
  Warn on crossing ten messages and report observed recovery below it. This is a
  queue-length signal, not proof of a stuck process; cycle events do not sample it.
  A stalled emitter produces no new gauge observations.
  """

  @window 100
  # Sample these singleton queues on poll events, without another timer.
  @watched [Fleet.Pilot.Poller, Fleet.Pilot.StepRunConsumer]
  # Alert threshold; queue length alone does not identify the cause of backlog.
  @mailbox_warn 10
  @default_slow_tick_ms 10_000
  @event [:lcars_fleet, :pilot_poller, :poll]
  # Separate event scales require separate windows.
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
  Summarizes the last #{@window} poll events, or :no_data. Durations and status-error
  counts cover the window; count is cumulative. Scope-less errors are grouped as
  :discovery. Repositories are pooled together, and discovery failures also enter
  this distribution; these are not cycle durations.

  slow_tick_ms is configuration and mailboxes is the latest gauge snapshot, not
  a window statistic. Calls can exit if the telemetry process is unavailable.
  """
  @spec stats() :: map() | :no_data
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Summarizes the last #{@window} cycle events, or :no_data. count is cumulative;
  durations and errors cover the window. last_repos and last_served accompany the
  most recent duration; missing served remains nil.

  Both regular and kick cycles enter the same distribution; retained mode is not
  exposed. This measures pass duration but does not certify every repository was
  processed or that a snapshot stayed fresh. Calls can exit if the owner is absent.
  """
  @spec cycle_stats() :: map() | :no_data
  def cycle_stats, do: GenServer.call(__MODULE__, :cycle_stats)

  @doc false
  # Framework callback, named to avoid pinning an anonymous handler's code version.
  # Rescue conversion exceptions here; malformed values can still reach the GenServer.
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@cycle_event, measurements, metadata, _config) do
    GenServer.cast(
      __MODULE__,
      {
        :cycle,
        Map.get(measurements, :duration_ms, 0),
        Map.get(measurements, :repos, 0),
        # Missing served must remain unknown; zero would spuriously degrade readiness.
        Map.get(measurements, :served),
        Map.get(metadata, :status, :ok),
        Map.get(metadata, :mode)
      }
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
    # Avoid detaching the telemetry handler on callback exceptions.
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

    # Attach the named callback for this owner. An existing registration is accepted,
    # not replaced; casts resolve the singleton name after a restart.
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
    # Detach on orderly termination. An untrappable kill can bypass this callback.
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
  def handle_cast({:cycle, duration_ms, repos, served, status, mode}, state) do
    # A whole-cycle alert needs its own policy; do not reuse the per-poll threshold.
    {:noreply,
     %{
       state
       | cycle_count: state.cycle_count + 1,
         cycles: Enum.take([{duration_ms, repos, served, status, mode} | state.cycles], @window)
     }}
  end

  @impl GenServer
  def handle_call(:cycle_stats, _from, %{cycles: []} = state), do: {:reply, :no_data, state}

  def handle_call(:cycle_stats, _from, state) do
    durations = state.cycles |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    {last_ms, last_repos, last_served, _, _} = hd(state.cycles)

    {:reply,
     %{
       count: state.cycle_count,
       window: length(durations),
       last_ms: last_ms,
       last_repos: last_repos,
       last_served: last_served,
       p50_ms: percentile(durations, 50),
       p95_ms: percentile(durations, 95),
       max_ms: List.last(durations),
       errors: Enum.count(state.cycles, fn {_d, _r, _s, status, _m} -> status == :error end)
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
        "candidates: the synchronous ls-remote (15 s) of the project resolver, the per-tick " <>
        "list_pods (5 s timeout), the forge listings"
    )
  end

  defp maybe_warn(_state, _ms, _status, _scope, _repo), do: :ok

  # Omit unregistered processes rather than report false zero backlog.
  defp sample_mailboxes do
    for name <- @watched, pid = Process.whereis(name), into: %{} do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> {name, n}
        # Died between the `whereis` and the `info`: we do not manufacture a value.
        nil -> {name, :gone}
      end
    end
  end

  # Report threshold transitions only; disappearance is not a measured recovery.
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

  # Nearest-rank percentiles on sorted durations; no interpolation.
  defp percentile([single], _p), do: single

  defp percentile(sorted, p) do
    idx = max(0, min(length(sorted) - 1, ceil(length(sorted) * p / 100) - 1))
    Enum.at(sorted, idx)
  end
end
