defmodule Fleet.Admiral.Shutdown.Dispatcher do
  @moduledoc """
  Shutdown backend abstraction: refuse_new_jobs/1 and in_flight_count/0.
  NoOp is the unwired default; runtime configuration selects AggregateDispatcher.
  This seam avoids a global Fleet.Dispatcher module.
  """
  @callback refuse_new_jobs(opts :: keyword()) :: :ok
  @callback in_flight_count() :: non_neg_integer()
end

defmodule Fleet.Admiral.Shutdown.NoOpDispatcher do
  @moduledoc """
  Test and unwired fallback backend. It accepts quiescence and reports no
  in-flight work, so shutdown drains immediately.
  """
  @behaviour Fleet.Admiral.Shutdown.Dispatcher

  @impl true
  def refuse_new_jobs(_opts), do: :ok

  @impl true
  def in_flight_count, do: 0
end

defmodule Fleet.Admiral.Shutdown.AggregateDispatcher do
  @moduledoc """
  Activates shared quiescence and sums broker-active items, completion offloads
  and synchronous Quiesce.busy leases. Idle resident pods are not work; counting
  pods would prevent shutdown while an idle project architect remains alive.

  Broker presence is sampled via TaskQueue.Server. Absence counts as zero, including
  a restart gap; present-but-unreadable counts as one. The completion fun similarly
  uses one for unknown, invalid or raised/exited results; throws are not caught.
  Counts are separate observations and can overlap or miss handoffs.

  :admiral_completion_inflight_fun crosses the Admiral/Pilot boundary at runtime;
  the default fun returns zero. Runtime wiring distinguishes a down completion
  supervisor from one whose count is unreadable. :admiral_task_queue_mod injects
  the list_active reader but does not replace the live broker-presence check.
  """
  @behaviour Fleet.Admiral.Shutdown.Dispatcher

  require Logger

  # Positive sentinel prevents an unknown count from being treated as drained.
  @count_unavailable 1

  @task_queue_default Fleet.TaskQueue

  @impl true
  def refuse_new_jobs(_opts), do: Fleet.Shutdown.Quiesce.refuse!()

  @impl true
  # Busy leases cover synchronous finalizers invisible to broker/offload counts.
  def in_flight_count,
    do: broker_active() + completion_phases() + Fleet.Shutdown.Quiesce.busy_count()

  defp broker_active do
    if task_queue_running?() do
      case safe_count_active() do
        {:ok, n} ->
          n

        :error ->
          Logger.error(
            "Shutdown: active work-item count unavailable (task_queue broker present but " <>
              "unreachable — restart mid-quiesce?) — drain can NOT conclude 0, staying cautious"
          )

          @count_unavailable
      end
    else
      0
    end
  end

  defp task_queue_running?, do: is_pid(Process.whereis(Fleet.TaskQueue.Server))

  defp task_queue_mod,
    do: Application.get_env(:lcars_fleet, :admiral_task_queue_mod, @task_queue_default)

  defp safe_count_active do
    {:ok, length(task_queue_mod().list_active())}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp completion_phases do
    case Application.get_env(:lcars_fleet, :admiral_completion_inflight_fun, fn -> 0 end).() do
      n when is_integer(n) and n >= 0 ->
        n

      :unknown ->
        Logger.error(
          "Shutdown: completion count :unknown (supervisor present but uncountable) — drain stays cautious"
        )

        @count_unavailable

      _other ->
        @count_unavailable
    end
  rescue
    e ->
      Logger.error(
        "Shutdown: completion-phase count raised (#{Exception.message(e)}) — fail-closed sentinel"
      )

      @count_unavailable
  catch
    :exit, _ -> @count_unavailable
  end
end

defmodule Fleet.Admiral.Shutdown do
  @moduledoc """
  Synchronous shutdown server used by Fleet.Application.prep_stop before teardown.
  begin refuses new work, then polls until consecutive zero counts or grace expiry.
  Both outcomes reply :ok; only server state distinguishes drained from timeout.

  The deadline is checked between callbacks and sleeps, not enforced around them:
  a blocking backend can exceed grace. Default NoOp does not activate quiescence.
  The launcher's outer fallback must allow configured grace plus its stop margin.
  """

  use GenServer
  require Logger

  # Keep launcher grace + margin aligned with the runtime drain configuration.
  @default_grace_ms 45_000

  @doc "Le delai de drain effectif, en ms — source unique, partagee avec `bin/fleet`."
  @spec grace_ms() :: pos_integer()
  def grace_ms,
    do: Application.get_env(:lcars_fleet, :admiral_shutdown_grace_ms, @default_grace_ms)

  @default_poll_ms 500

  # Consecutive zero samples mitigate handoff gaps; they do not prove continuous zero.
  # Three default samples are about 1 s apart end-to-end (two 500 ms sleeps).
  # Quiesce.busy covers the consumer's synchronous completion handling, including
  # potentially slow forge reads, but starts only on handler entry. A queued Bus
  # message before that lease remains uncounted; there is no timing guarantee.
  @default_drain_confirmations 3

  @default_dispatcher Fleet.Admiral.Shutdown.NoOpDispatcher

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns configured admiral_shutdown_dispatcher or NoOpDispatcher. Shared by
  initialization and readiness; an instance's opts[:dispatcher] override is separate.
  """
  @spec configured_dispatcher() :: module()
  def configured_dispatcher do
    Application.get_env(:lcars_fleet, :admiral_shutdown_dispatcher, @default_dispatcher)
  end

  @doc """
  Checks that the configured module exports both backend callbacks. This does not
  execute them or validate their return types; invalid non-module config can raise.
  """
  @spec resolved_conforming() ::
          {:ok, module()} | {:error, {:shutdown_dispatcher_misconfigured, module(), [atom()]}}
  def resolved_conforming do
    mod = configured_dispatcher()
    _ = Code.ensure_loaded(mod)

    manquants =
      for {fun, arite} <- [refuse_new_jobs: 1, in_flight_count: 0],
          not function_exported?(mod, fun, arite),
          do: fun

    if manquants == [],
      do: {:ok, mod},
      else: {:error, {:shutdown_dispatcher_misconfigured, mod, manquants}}
  end

  @doc "Refuses work and synchronously drains; replies :ok even on grace expiry. Calls can exit."
  @spec begin(keyword()) :: :ok
  def begin(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, grace_ms())
    GenServer.call(server(opts), {:begin, grace_ms}, grace_ms + 5_000)
  end

  @doc "Test seam: same drain without refusing work. Actual reply is :ok, despite the integer spec."
  @spec drain_in_flight(keyword()) :: non_neg_integer()
  def drain_in_flight(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, grace_ms())
    GenServer.call(server(opts), {:drain, grace_ms}, grace_ms + 5_000)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  @impl true
  def init(opts) do
    backend = opts[:dispatcher] || configured_dispatcher()

    {:ok,
     %{
       status: :running,
       backend: backend,
       in_flight: 0,
       poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
       confirmations:
         max(1, Keyword.get(opts, :drain_confirmations, @default_drain_confirmations))
     }}
  end

  @impl true
  def handle_call({:begin, grace_ms}, _from, state) do
    :ok = state.backend.refuse_new_jobs(reason: :shutdown)
    Logger.info("Shutdown: begin — new jobs refused, drain #{grace_ms}ms")
    {:reply, :ok, wait_drain(state, grace_ms)}
  end

  def handle_call({:drain, grace_ms}, _from, state) do
    {:reply, :ok, wait_drain(state, grace_ms)}
  end

  defp wait_drain(state, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait_drain(state, deadline, 0)
  end

  defp do_wait_drain(state, deadline, zero_streak) do
    in_flight = state.backend.in_flight_count()
    zero_streak = if in_flight == 0, do: zero_streak + 1, else: 0

    cond do
      zero_streak >= state.confirmations ->
        %{state | status: :drained, in_flight: 0}

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Shutdown: drain timeout, #{in_flight} job(s) in-flight")
        %{state | status: :timeout, in_flight: in_flight}

      true ->
        Process.sleep(state.poll_ms)
        do_wait_drain(%{state | in_flight: in_flight}, deadline, zero_streak)
    end
  end
end
