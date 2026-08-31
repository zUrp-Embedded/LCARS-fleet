defmodule Fleet.Admiral.Shutdown.Dispatcher do
  @moduledoc """
  Dispatcher backend behaviour consumed by `Fleet.Admiral.Shutdown`.

  **This behaviour IS the drain abstraction** (user decision): a global
  `Fleet.Dispatcher` god-module does not and must NOT exist. The
  `:shutdown_dispatcher` seam replaces that contract. Two implementations:

    * `NoOpDispatcher` — test/fallback default (0 in-flight, immediate drain)
    * `AggregateDispatcher` — canonical **prod** backend (wired in `runtime.exs`),
      aggregates the real in-flight + activates quiescence
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
  **Real** backend of the `:shutdown_dispatcher` seam — aggregates the in-flight
  and activates quiescence. User decision: **no** `Fleet.Dispatcher`
  god-module; the `:shutdown_dispatcher` seam IS the abstraction.

  ## `refuse_new_jobs/1`

  Activates `Fleet.Shutdown.Quiesce` → the points that OPEN new work refuse it: the admin write door
  (`POST /api/admin/spawn` on the AF_UNIX control socket, `Fleet.API.ControlRouter`), the permanent
  respawn (`Fleet.Spawner.PermanentWarden`),
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
      ⚠ COUNTING PODS INSTEAD keeps them in, so ONE OPEN PROJECT ⇒ `in_flight > 0` FOREVER ⇒ every
      stop times out. An arch mid-arbitration DOES have a work-item and IS counted, correctly.
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

  `Fleet.Admiral` does NOT depend on `Fleet.Pilot` (and must not — siblings). So the completion
  Task.Supervisor (a Pilot concern) cannot be referenced here at compile time. `:completion_inflight_fun`
  (`Application.get_env`, wired in `runtime.exs` to `&Fleet.Pilot.StepRunConsumer.inflight_completions/0`)
  crosses that boundary as a runtime fun, never a compile reference — same shape as `:shutdown_dispatcher`
  / `:coord_backend`. Default (no wiring / test) = `fn -> 0 end`. The broker count stays a direct call
  (`Fleet.TaskQueue` IS a declared downward dep), through the `:task_queue_mod` test seam.
  """
  @behaviour Fleet.Admiral.Shutdown.Dispatcher

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
  Coordinated shutdown server. `fleet_v2 stop` sends SIGTERM; OTP invokes
  `Fleet.Application.prep_stop/1`, which calls `begin/1` before supervisors stop.

  `begin/1` refuses new jobs, then synchronously polls the configured dispatcher
  until it observes zero in-flight work on consecutive reads or reaches its grace
  deadline. Synchronous handling is required so teardown cannot proceed before the
  drain replies.

  ⚠ THE LAUNCHER'S OUTER FALLBACK IS DERIVED FROM THIS DEADLINE, NOT SET BESIDE IT: `bin/fleet_v2`
  waits `grace + margin`, so it cannot hand back on a fleet that is still draining. An independent
  literal there would be a second number for one fact — cf. `grace_ms/0`.

  `drain_in_flight/1` runs the same bounded loop without refusing work and exists
  for tests. `NoOpDispatcher` is the unwired default; production config selects
  `AggregateDispatcher`.
  """

  use GenServer
  require Logger

  # LE DELAI DE DRAIN EST UNE SOURCE UNIQUE, ET IL NE L'ETAIT PAS. `bin/fleet_v2` attend la
  # disparition de la session tmux avec son propre litteral (`FLEET_V2_STOP_WAIT:-90`), pose la et
  # jamais derive de CETTE deadline — son commentaire l'avoue et nomme BL-6-52. Deux nombres pour un
  # seul fait : si le drain passe a 120 s, le launcher rend la main a 90 et l'operateur voit un stop
  # « fini » sur une fleet qui draine encore.
  # Le BEAM possede la deadline ; le shell la LIT (meme variable, meme defaut) et y ajoute sa marge.
  @default_grace_ms 45_000

  @doc "Le delai de drain effectif, en ms — source unique, partagee avec `bin/fleet_v2`."
  @spec grace_ms() :: pos_integer()
  def grace_ms,
    do: Application.get_env(:lcars_fleet, :admiral_shutdown_grace_ms, @default_grace_ms)

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
  # THE LEASE IS WHAT CLOSES IT (BL-6-43.1), and it is already taken: `in_flight_count/0` adds
  # `Quiesce.busy_count()`, and `StepRunConsumer` wraps its whole `pod.completed` handoff in
  # `Quiesce.busy/1`. So the ~10s `GateEngine.resolve_next` read is INSIDE the lease and is
  # counted: the drain cannot conclude while it runs.
  #
  # WHAT REMAINS UNCOVERED, precisely, because "closed" said flatly would be the next lie: the Bus
  # message in flight between `submit_result`'s broadcast and the consumer's `handle_info` entry.
  # There, the item is `:completed` and the lease is not yet taken. That gap is a local PubSub
  # delivery — microseconds — against 1.5s of CONTINUOUS zero required by the debounce, five
  # orders of magnitude. And it cannot widen under load: a backed-up consumer mailbox means the
  # previous message is being handled, so the lease is already held and the count is not zero.
  #
  # The debounce therefore keeps its own job — not a SINGLE racy 0-read — and carries no window it
  # was never sized for. Raising the count buys nothing.
  @default_drain_confirmations 3

  # Canonical default of the dispatcher backend: NoOp (inert drain) for the case where the real
  # prod backend `AggregateDispatcher` is NOT wired — it IS wired in `runtime.exs` hors `:test`,
  # donc ce defaut ne sert qu'aux tests et aux boots sans config runtime. Set HERE once
  # only — see `configured_dispatcher/0`.
  @default_dispatcher Fleet.Admiral.Shutdown.NoOpDispatcher

  # --- API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatcher backend resolved from config (`:lcars_fleet, :admiral_shutdown_dispatcher`),
  default `NoOpDispatcher`. SINGLE SOURCE of the default: this process reads it at `init` and
  readiness (the anti-hollow-green probe) reads it too — neither re-declares the default,
  so no drift between the real drain and what readiness believes is wired. (The test
  override `opts[:dispatcher]` stays handled locally by `init`, outside config.)
  """
  @spec configured_dispatcher() :: module()
  def configured_dispatcher do
    Application.get_env(:lcars_fleet, :admiral_shutdown_dispatcher, @default_dispatcher)
  end

  @doc "Refuse new jobs + drain to 0 or grace_ms — the SOLE prod shutdown entry (bin/fleet_v2 stop)."
  @spec begin(keyword()) :: :ok
  def begin(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, grace_ms())
    GenServer.call(server(opts), {:begin, grace_ms}, grace_ms + 5_000)
  end

  @doc "TEST-ONLY seam: same drain as `begin/1` WITHOUT the refuse step (exercise wait_drain in isolation). No prod caller."
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
