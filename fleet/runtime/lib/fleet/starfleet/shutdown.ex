defmodule Fleet.Starfleet.Shutdown.Dispatcher do
  @moduledoc """
  Dispatcher backend behaviour consumed by `Fleet.Starfleet.Shutdown`.

  **This behaviour IS the drain abstraction** (user decision 2026-06-05, ring0
  design-note amended): the design-note sketch named a global `Fleet.Dispatcher`
  — it does not and must NOT exist. The `:shutdown_dispatcher` seam replaces that
  contract. Two implementations:

    * `NoOpDispatcher` — test/fallback default (0 in-flight, immediate drain)
    * `AggregateDispatcher` — canonical **prod** backend (wired in `runtime.exs`),
      aggregates the real in-flight + activates quiescence
  """
  @callback refuse_new_jobs(opts :: keyword()) :: :ok
  @callback in_flight_count() :: non_neg_integer()
end

defmodule Fleet.Starfleet.Shutdown.NoOpDispatcher do
  @moduledoc """
  **Test/fallback** backend — immediate drain, 0 in-flight. Honestly-degraded:
  no job to drain. Default in `:test` (hermeticity) and config fallback when no
  real backend is wired. NOT silent (documented), not a Goodhart. The prod
  backend is `AggregateDispatcher`.
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  @impl true
  def refuse_new_jobs(_opts), do: :ok

  @impl true
  def in_flight_count, do: 0
end

defmodule Fleet.Starfleet.Shutdown.AggregateDispatcher do
  @moduledoc """
  **Real** backend of the `:shutdown_dispatcher` seam — aggregates the in-flight
  and activates quiescence. User decision (2026-06-05): **no** `Fleet.Dispatcher`
  god-module; the `:shutdown_dispatcher` seam IS the abstraction (ring0
  design-note amended, upward field feedback).

  ## `refuse_new_jobs/1`

  Activates `Fleet.Shutdown.Quiesce` → the top-level REST entry point
  `/api/admin/spawn` (`Fleet.API.Rest` reads `quiescing?`) refuses new work. That
  admission is the SOLE way new work enters, so gating it is total. The internal work
  of an in-flight step_run is NOT gated.

  ## `in_flight_count/0` — scope (user decision)

  **Every live NON-PERMANENT pod counts** (the real forge work) + unassigned queued
  work items. Permanent pods (arch, gatekeeper…) are RESIDENTS, not work — EXCLUDED
  (see below). In-flight is read from the pods and the queue, NEVER from an in-memory
  run table: RAM state can lie (it drifts on a crash/restart), the pods and the forge
  stay true — one live pod = one step_run in progress.

    * `Fleet.Spawner.list_pods/0` filtered to NON-permanent — active workers (also covers
      assigned work: an assigned work item ⇒ its pod is live ⇒ counted here)
    * `Fleet.TaskQueue.list_pending/0` — queued work items **not yet assigned**

  **No double-counting**: `list_pending` filters `state == :pending` STRICT
  (cf. `task_queue/server.ex` `handle_call(:list_pending)`) — `:assigned`/`:in_progress`
  work items are excluded from it and are represented by their live pod
  (counted in `list_pods`). Neither double-counting nor under-counting.

  ⚠ Permanents EXCLUDED (DrDree fix, 2026-07-05): permanent pods (Type 1/3 "forever":
  gatekeeper, archivist…) live continuously, so counting them kept `in_flight_count > 0`
  forever ⇒ EVERY graceful stop consumed its full grace then concluded "timeout" instead
  of "drained". They are now filtered out (`list_pods` |> reject `permanent?`), so the
  drain can actually reach empty on the real forge work.

  **Fail-CLOSED when counting fails**: if a component (Spawner / task_queue
  broker) is PRESENT but unreachable — typically a restart RIGHT IN THE MIDDLE OF
  quiesce — its count returns a sentinel > 0 (never `0`) → the drain never
  concludes "empty" on an unknown, it waits out its timeout (the safeguard).
  The old `0` was fail-OPEN: under-counting ⇒ drain wrongly declared complete ⇒
  stop WHILE work is in flight. A task_queue app GENUINELY absent from the
  build stays `0` (there really is nothing to drain) — we distinguish "absent"
  from "crashed" via the actually-started applications, not the code path
  (in an umbrella all modules are loadable, that would distinguish nothing).

  ## Layering

  `fleet_starfleet` depends on `fleet_spawner` (`list_pods` as a direct call — the
  `:spawner_mod` app-env seam exists ONLY to inject a stub in test, default
  = the real `Fleet.Spawner`). It does NOT depend on `fleet_task_queue` (no
  inversion) → `list_pending` is read via `apply` (module in a variable, no
  compile-time dependency), resilient if the app is absent.
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  require Logger

  # Sentinel "in-flight count unavailable". The drain-end condition (`do_wait_drain`) concludes
  # "empty" only on `in_flight == 0` → any value > 0 PREVENTS concluding and forces the drain
  # to wait out its timeout (the safeguard, never an indefinite block). 1 = minimal "not empty". We
  # return this value when the count FAILS (component unreachable): fail-CLOSED ("I don't know
  # ⇒ I do NOT declare the drain complete"), the opposite of the fail-open `0` that cut during work.
  @count_unavailable 1

  # Spawner module — defaults to the real `Fleet.Spawner` (direct call, real compile-time dep). App-env
  # seam ONLY to inject a stub in test (induce a list_pods that raises/exits); prod never
  # sets this key → behavior = direct call `Fleet.Spawner.list_pods/0`.
  @spawner_default Fleet.Spawner

  @impl true
  def refuse_new_jobs(_opts), do: Fleet.Shutdown.Quiesce.refuse!()

  @impl true
  def in_flight_count do
    # In-flight = live NON-PERMANENT pods + queued work not yet pulled — counted from the pods
    # and the queue, NEVER from an in-memory run table: RAM state can lie (it drifts on a
    # crash/restart), the pods and the forge stay true (one live pod = one step_run in progress).
    # The PERMANENTS (arch, gatekeeper) are RESIDENTS, not work: they live continuously, so counting
    # them keeps the drain unreachable → every graceful stop burned its full grace and concluded
    # "timeout" instead of "drained". Hence excluded.
    spawner_pods() + tasks_pending()
  end

  # Live pods. fleet_spawner is a HARD compile-time dep (always present in prod): a
  # `list_pods` that raises/exits = the Spawner is unreachable, ABNORMAL — typically a restart RIGHT
  # IN THE MIDDLE OF quiesce. We NO LONGER mask as `0` (the `0` under-counted the in-flight → drain declared
  # complete wrongly → stop WHILE work is in flight, fail-open). Instead: Logger.error + sentinel "not
  # empty" → the drain does not conclude, it waits out its timeout (safeguard).
  defp spawner_pods do
    # Filter by the prefix AUTHORITY (PermanentBoot.permanent?/1) — residents do not count.
    spawner_mod().list_pods()
    |> Enum.reject(fn %{pod_id: pod_id} -> Fleet.Spawner.PermanentBoot.permanent?(pod_id) end)
    |> length()
  rescue
    e ->
      Logger.error(
        "Shutdown: live pod count unavailable (Spawner unreachable — restart " <>
          "mid-quiesce?) — drain can NOT conclude 0, staying cautious: #{Exception.message(e)}"
      )

      @count_unavailable
  catch
    :exit, reason ->
      Logger.error(
        "Shutdown: live pod count unavailable (Spawner exit #{inspect(reason)} " <>
          "— restart mid-quiesce?) — drain can NOT conclude 0, staying cautious"
      )

      @count_unavailable
  end

  defp spawner_mod, do: Application.get_env(:fleet_starfleet, :spawner_mod, @spawner_default)

  # Unassigned queued mandates. `fleet_starfleet` does NOT depend on `fleet_task_queue` (no
  # layering inversion) → call via `apply` (module in a variable: no remote-call reference
  # → no compile-time dep). Two regimes NOT to confuse:
  #   * task_queue app ABSENT from this build/env (legitimate: isolated starfleet test, deployment without the
  #     broker) → there really is NO queue to drain → HONEST `0` (not a failure mask).
  #   * app PRESENT but the call raises/exits (broker restarting during the quiesce) → ABNORMAL: we do NOT
  #     mask as `0` (under-counting ⇒ drain would conclude "empty" wrongly) → sentinel "not empty".
  # All modules are loadable in the single app, so "module loaded" does not distinguish absent
  # from crashed: we decide on the ACTUALLY-running broker PROCESS (`Process.whereis`), not the
  # code path. (Z2 collapse 2026-07-12 : the old check keyed on the `:fleet_task_queue` OTP app
  # in `started_applications` — that app no longer exists, the check would be `false` FOREVER
  # → drain short-circuited to 0 with tasks still queued. The live process is the real fact.)
  defp tasks_pending do
    if task_queue_running?() do
      case safe_count_pending() do
        {:ok, n} ->
          n

        :error ->
          Logger.error(
            "Shutdown: queued work item count unavailable (task_queue broker " <>
              "present but unreachable — restart mid-quiesce?) — drain can NOT conclude 0, cautious"
          )

          @count_unavailable
      end
    else
      0
    end
  end

  defp task_queue_running? do
    is_pid(Process.whereis(Fleet.TaskQueue.Server))
  end

  # Module in a VARIABLE for the `apply`: no literal remote call `Fleet.TaskQueue.x()` → no
  # compile-time dependency on fleet_task_queue (the layering forbids the inversion).
  defp safe_count_pending do
    mod = Fleet.TaskQueue

    case apply(mod, :list_pending, []) do
      list when is_list(list) -> {:ok, length(list)}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end

defmodule Fleet.Starfleet.Shutdown do
  @moduledoc """
  Coordinated grace shutdown. The historical trigger (systemd `ExecStop` /
  `lcars-fleet-restart`) was removed (systemd gone 2026-06-16) and is NOT yet
  re-wired — to be re-wired onto `fleet_v2 stop` (graceful-shutdown backlog). As
  a result this GenServer starts but NO caller currently invokes `begin/1`: the
  graceful shutdown is INERT until the trigger is re-wired. The drain logic
  itself stays valid.

  Three phases:
  1. `begin/1` — refuse new jobs (dispatcher gate), drain queue
  2. `drain_in_flight/1` — wait for in-progress workflows, max grace_ms
  3. final (`fleet_umbrella stop`) — stop the OTP umbrella

  ## Dispatcher backend (seam `:shutdown_dispatcher`)

  Configurable backend `:fleet_starfleet, :shutdown_dispatcher` (default
  `NoOpDispatcher` test/fallback; prod = `AggregateDispatcher` wired in
  `runtime.exs`). The seam IS the drain abstraction (user decision 2026-06-05,
  no `Fleet.Dispatcher` god-module — ring0 design-note amended).

  No cosmetic Goodhart: `wait_drain` polls a real `in_flight_count`
  until 0 or deadline (not an arbitrary `sleep`).

  ## Synchronous blocking REQUIRED (not an anti-pattern to refactor)

  `begin/1`/`drain_in_flight/1` block inside the `handle_call` until the drain
  ends: this is the required semantics. The caller (the shutdown trigger →
  `Fleet.Starfleet.Shutdown.begin` then `fleet_umbrella stop`) MUST know the
  drain is finished before stopping the umbrella. An async reply
  (`handle_continue`/`Task`) would stop the umbrella DURING the drain → guarantee
  broken. During a shutdown there is no legitimate concurrent call to this
  GenServer; the block is bounded by `grace_ms` (+ a final SIGKILL as last
  resort, formerly systemd `TimeoutStopSec` — also gone with systemd).
  """

  use GenServer
  require Logger

  @default_grace_ms 45_000

  # Canonical default of the dispatcher backend: NoOp (inert drain) as long as the real
  # prod backend `AggregateDispatcher` is not wired (runtime.exs). Set HERE once
  # only — see `configured_dispatcher/0`.
  @default_dispatcher Fleet.Starfleet.Shutdown.NoOpDispatcher

  # --- API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatcher backend resolved from config (`:fleet_starfleet, :shutdown_dispatcher`),
  default `NoOpDispatcher`. SINGLE SOURCE of the default: this process reads it at `init` and
  readiness (the anti-hollow-green probe) reads it too — neither re-declares the default,
  so no drift between the real drain and what readiness believes is wired. (The test
  override `opts[:dispatcher]` stays handled locally by `init`, outside config.)
  """
  @spec configured_dispatcher() :: module()
  def configured_dispatcher do
    Application.get_env(:fleet_starfleet, :shutdown_dispatcher, @default_dispatcher)
  end

  @doc "Phase 1: refuse new jobs + drain (max grace_ms)."
  def begin(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    GenServer.call(server(opts), {:begin, grace_ms}, grace_ms + 5_000)
  end

  @doc "Phase 2: wait in-flight → 0 or grace_ms."
  def drain_in_flight(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    GenServer.call(server(opts), {:drain, grace_ms}, grace_ms + 5_000)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  # --- GenServer ---

  @impl true
  def init(opts) do
    # `opts[:dispatcher]` = injected test override; otherwise the backend resolved from
    # config via the single source (canonical NoOp default included).
    backend = opts[:dispatcher] || configured_dispatcher()

    {:ok, %{status: :running, backend: backend, in_flight: 0}}
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

  # --- real drain (no Goodhart) ---

  defp wait_drain(state, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait_drain(state, deadline)
  end

  defp do_wait_drain(state, deadline) do
    in_flight = state.backend.in_flight_count()

    cond do
      in_flight == 0 ->
        %{state | status: :drained, in_flight: 0}

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Shutdown: drain timeout, #{in_flight} job(s) in-flight")
        %{state | status: :timeout, in_flight: in_flight}

      true ->
        Process.sleep(500)
        do_wait_drain(%{state | in_flight: in_flight}, deadline)
    end
  end
end
