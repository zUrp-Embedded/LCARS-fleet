defmodule Fleet.Starfleet.Shutdown.Dispatcher do
  @moduledoc """
  Dispatcher backend behaviour consumed by `Fleet.Starfleet.Shutdown`.

  **This behaviour IS the drain abstraction** (user decision): a global
  `Fleet.Dispatcher` god-module does not and must NOT exist. The
  `:shutdown_dispatcher` seam replaces that contract. Two implementations:

    * `NoOpDispatcher` — test/fallback default (0 in-flight, immediate drain)
    * `AggregateDispatcher` — canonical **prod** backend (wired in `runtime.exs`),
      aggregates the real in-flight + activates quiescence

  **Last revised**: 2026-08-03
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
  and activates quiescence. User decision: **no** `Fleet.Dispatcher`
  god-module; the `:shutdown_dispatcher` seam IS the abstraction.

  ## `refuse_new_jobs/1`

  Activates `Fleet.Shutdown.Quiesce` → the points that OPEN new work refuse it: the REST admin door
  (`/api/admin/spawn`, `Fleet.API.ControlRouter`), the permanent respawn (`Fleet.Spawner.PermanentWarden`),
  AND the producer-spawn point (`Fleet.Pilot.StepDispatcher.dispatch_issue`, CI-01 — a fresh issue or the
  next step of an engaged run). The FINALIZATION of an in-flight step_run (completion/review/merge) is NOT
  gated (cf. `Fleet.Shutdown.Quiesce` for the full reader list + the finish-vs-open rationale).

  ## `in_flight_count/0` — the WORK to finish (CI-02)

  In-flight = the broker's ACTIVE work-items + the in-flight COMPLETION offloads. Read from the
  living truth (the broker + the supervisors), NEVER from an in-memory run table: RAM state can lie
  (it drifts on a crash/restart).

    * `Fleet.TaskQueue.list_active/0` — the `@active_states` work-items (`:pending` queued +
      `:assigned` being worked). This IS the real forge work, and it EXCLUDES the idle
      residents by construction: a project architect (`architect-<name>`, `forever` but NOT
      `permanent-` prefixed) or a `pipe` engineer between briefs has NO active work-item → not counted.
      (The old `list_pods` count kept them in — one open project ⇒ `in_flight > 0` FOREVER ⇒ every stop
      timed out. An arch mid-arbitration DOES have a work-item and IS counted, correctly.)
    * the **completion offloads** via the `:completion_inflight_fun` seam — after `pod.completed`, the
      business completion (push + PR + forge writes, ≤30s) runs in `Fleet.Pilot.StepRunConsumer`'s
      `Task.Supervisor`: neither a pod nor a work-item (the item is already `:completed`), so the
      old count cut it mid-push. See `## Boundary` for why it is a seam and not a call.

  **Fail-CLOSED on the broker**: broker PRESENT but unreachable (restart mid-quiesce) → sentinel
  `> 0` (`@count_unavailable`) → the drain waits its timeout, never concludes "empty" on an unknown
  (a `0` would be fail-open: under-count ⇒ stop WHILE work is in flight). Broker GENUINELY absent
  (isolated test) → honest `0`, decided on the live PROCESS (`Process.whereis`), not the code path.

  **ASYMMETRY on the completion seam** — ONLY for a genuinely DOWN supervisor: its Tasks are already
  dead WITH it (the work is already lost, independent of the drain) → the seam returns an honest `0`,
  NOT the broker's `> 0` sentinel (a `> 0` there would make every stop time out whenever step is off).
  But a supervisor PRESENT whose count FAILS is `:unknown` → the fail-CLOSED sentinel, same as the
  broker: we never fake a `0` we could not measure.

  ## Boundary — why the completion count is a runtime seam

  `Fleet.Starfleet` does NOT depend on `Fleet.Pilot` (and must not — siblings). So the completion
  Task.Supervisor (a Pilot concern) cannot be referenced here at compile time. `:completion_inflight_fun`
  (`Application.get_env`, wired in `runtime.exs` to `&Fleet.Pilot.StepRunConsumer.inflight_completions/0`)
  crosses that boundary as a runtime fun, never a compile reference — same shape as `:shutdown_dispatcher`
  / `:coord_backend`. Default (no wiring / test) = `fn -> 0 end`. The broker count stays a direct call
  (`Fleet.TaskQueue` IS a declared downward dep), through the `:task_queue_mod` test seam.
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  require Logger

  # Sentinel "broker count unavailable". `do_wait_drain` concludes "empty" only on a STABLE `in_flight
  # == 0` → any value > 0 prevents concluding and forces the drain to wait out its timeout (the
  # safeguard). 1 = minimal "not empty". Returned when the BROKER count fails (present but unreachable):
  # fail-CLOSED, the opposite of the fail-open `0` that would cut during work.
  @count_unavailable 1

  # Broker module — direct call to the real `Fleet.TaskQueue` (declared downward dep). App-env seam
  # ONLY to inject a stub in test (induce a `list_active` that raises/exits); prod never sets it.
  @task_queue_default Fleet.TaskQueue

  @impl true
  def refuse_new_jobs(_opts), do: Fleet.Shutdown.Quiesce.refuse!()

  @impl true
  # + the synchronous finalizers inside `Quiesce.busy/1` (poller tick review/merge work,
  # completion handlers pre-offload) — invisible to the broker and the offload counts,
  # yet exactly the work a stop must not cut between a merge and its terminal projection.
  def in_flight_count,
    do: broker_active() + completion_phases() + Fleet.Shutdown.Quiesce.busy_count()

  # The broker's ACTIVE work-items (queued + being worked) — the real forge work, minus the idle
  # residents (no work-item). Fail-CLOSED: broker present-but-unreachable → sentinel > 0; genuinely
  # absent → honest 0 (decided on the live process, not the code path).
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
    do: Application.get_env(:fleet_starfleet, :task_queue_mod, @task_queue_default)

  # The nominal return IS a list (`list_active/0` spec) — the real "broker down mid-quiesce" protection
  # is the rescue/catch (noproc/exit → `:error` → sentinel), never a mask as `0`.
  defp safe_count_active do
    {:ok, length(task_queue_mod().list_active())}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # In-flight completion offloads via the runtime seam (cf. ## Boundary). ASYMMETRIC vs the broker ONLY
  # for a genuinely dead/absent completion supervisor: its Tasks are ALREADY dead (work lost, not the
  # drain's concern) → the seam returns an honest integer 0. But a supervisor PRESENT whose count could
  # not run returns `:unknown`, and a raising seam fun is caught here — BOTH map to the fail-CLOSED
  # sentinel, never a fake 0 we could not measure (the Tasks may be alive mid-push).
  defp completion_phases do
    case Application.get_env(:fleet_starfleet, :completion_inflight_fun, fn -> 0 end).() do
      n when is_integer(n) and n >= 0 ->
        n

      # The completion supervisor is PRESENT but its count failed: we do NOT know how many
      # completions are in flight → fail-CLOSED sentinel, never a fake 0 that could cut a live
      # completion mid-push. The genuinely-absent supervisor returns an honest 0 (integer) above.
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

defmodule Fleet.Starfleet.Shutdown do
  @moduledoc """
  Coordinated grace shutdown. The trigger is `fleet_v2 stop` (no systemd):
  `bin/fleet_v2` cmd_stop RPCs `Fleet.Starfleet.Shutdown.begin(grace_ms: …)` then
  `:init.stop()`. The GenServer serves that RPC; the drain is LIVE.

  `begin/1` is the SOLE prod entry (`bin/fleet_v2 stop` RPCs it): it refuses new jobs (dispatcher
  gate) THEN drains in ONE loop — `wait_drain` polls `in_flight_count` (the broker's active work-items +
  the in-flight completion offloads, cf. `AggregateDispatcher`) until it reads 0 on N consecutive polls
  (the CI-02 debounce) or `grace_ms`. `bin/fleet_v2` then calls `:init.stop()` (ordered OTP stop).
  `drain_in_flight/1` re-enters that same drain WITHOUT the refuse step — a TEST-ONLY seam to exercise
  `wait_drain` in isolation (convergence/timeout); no prod caller.

  ## Dispatcher backend (seam `:shutdown_dispatcher`)

  Configurable backend `:fleet_starfleet, :shutdown_dispatcher` (default
  `NoOpDispatcher` test/fallback; prod = `AggregateDispatcher` wired in
  `runtime.exs`). The seam IS the drain abstraction (user decision:
  no `Fleet.Dispatcher` god-module).

  No cosmetic Goodhart: `wait_drain` polls a real `in_flight_count`
  until 0 or deadline (not an arbitrary `sleep`).

  ## Synchronous blocking REQUIRED (not an anti-pattern to refactor)

  `begin/1`/`drain_in_flight/1` block inside the `handle_call` until the drain
  ends: this is the required semantics. The caller (the shutdown trigger →
  `Fleet.Starfleet.Shutdown.begin` then `:init.stop()`) MUST know the
  drain is finished before stopping the umbrella. An async reply
  (`handle_continue`/`Task`) would stop the node DURING the drain → guarantee
  broken. During a shutdown there is no legitimate concurrent call to this
  GenServer; the block is bounded by `grace_ms` (no automatic SIGKILL backstop
  exists — systemd is gone; the operator is the last resort).
  """

  use GenServer
  require Logger

  @default_grace_ms 45_000
  @default_poll_ms 500

  # CI-02 debounce: `in_flight` must read 0 on N CONSECUTIVE polls before concluding `:drained`. It
  # MITIGATES the `pod.completed` → offload HANDOFF window — the work-item is already `:completed` but
  # the completion `Task` has not started yet, so the work-item/Task aggregate momentarily reads 0.
  # Without it, a single racy 0-read would conclude the drain mid-handoff and `:init.stop()` would cut
  # the completion. Default 3 × 500ms ≈ 1.5s of stable 0.
  #
  # IT DOES NOT COVER THE WINDOW — and the count was never sized to. `3` answers "not a SINGLE racy
  # 0-read" (it is clamped to ≥1 because 0 would be fail-open); it is not a duration derived from the
  # window's length. The window contains `GateEngine.resolve_next/3`, which can issue a SYNCHRONOUS
  # forge read (`count_step_runs` → `count_signed_step_runs`) before the offload, bounded by the
  # transport's `receive_timeout: 10_000`. So a legitimate handoff can reach ~10s against 1.5s of
  # debounce, and on a slow forge the drain concludes `:drained` and cuts a completion mid-push.
  # The window is real: `submit_result` broadcasts then COMMITS `:completed` (broadcast-before-commit),
  # so the item leaves `list_active` before this consumer has even decided, let alone offloaded.
  # Raising the count would buy the same instrument, slower, at the price of every clean shutdown.
  #
  # What would actually close it: a LEASE taken BEFORE the work-item flips to `:completed`, so the
  # drain counts the lease instead of an aggregate that misses the window by construction. Open.
  @default_drain_confirmations 3

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

  @doc "Refuse new jobs + drain to 0 or grace_ms — the SOLE prod shutdown entry (bin/fleet_v2 stop)."
  def begin(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    GenServer.call(server(opts), {:begin, grace_ms}, grace_ms + 5_000)
  end

  @doc "TEST-ONLY seam: same drain as `begin/1` WITHOUT the refuse step (exercise wait_drain in isolation). No prod caller."
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

    {:ok,
     %{
       status: :running,
       backend: backend,
       in_flight: 0,
       # Poll interval + debounce count (opts for fast tests; prod defaults 500ms / 3 confirmations).
       # `confirmations` clamped to ≥ 1: 0 would make `zero_streak >= 0` conclude `:drained` on the FIRST
       # poll regardless of `in_flight` (fail-OPEN, the exact opposite of the debounce's purpose).
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

  # --- real drain (no Goodhart) ---

  defp wait_drain(state, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait_drain(state, deadline, 0)
  end

  # `zero_streak` = number of CONSECUTIVE `in_flight == 0` reads so far. Conclude `:drained` only when it
  # reaches `state.confirmations` (the debounce, CI-02): a lone transitory 0 (handoff window) does not end
  # the drain. Any non-zero read RESETS the streak. NB the streak bounds only SHORT handoffs — see the
  # `@default_drain_confirmations` note: a handoff stretched by a slow forge read outlasts it.
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
