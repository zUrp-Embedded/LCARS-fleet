defmodule Fleet.Pilot.StepRunConsumer do
  @moduledoc """
  Bus consumer for **step-run completion** (the forge IS the state machine; this module reacts to it).
  Subscribes to `Fleet.EventRouter.Bus` (topic `fleet.events`); on each
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` from a
  **step-dispatch** pod (assignee-driven), translates the event into a `step_run` and delegates the
  completion sequence to `Fleet.Pilot.StepRunCompleter`.

  ## Sub-modules (hardened boundaries — each reads a narrow `Seams` struct, never `state`)

    * `GateEngine` — DECISION engine (resolve_next: gate/rebound/judge-verdict/escalation);
      returns an intent, THIS module acts.
    * `TerminalEscalation` — human wall (freeze_to_arch: await_arch + kick arch) for
      non-transient terminal errors, blocked producers and fail-closed verdicts.
    * `StepRunBuild` — construction of the PR-native step_run map (producer/judge classification,
      deliverable_opts, review_event, eng_summary).
    * `Verdict` — PURE verdict cluster (gate-decision-v1 decoding + text rendering).
    * `GatekeeperEscalation` — async-out of the gatekeeper escalation (enqueue eval brief + kick).

  THIS module keeps: the Bus GenServer (subscribe/handle_info), the `gate_evals` state (async
  resumptions), the verdict application (`apply_verdict` — shared gatekeeper/scoper), the
  sync/offload execution discipline (`run_completion`) and the per-step-run derivation of the
  state (`step_run_state`: repo/remote from the event, multi-project).

  ## Gatekeeper = exception (escalation), NOT a step

  The gate of the finished step decides BEFORE advancing (`Fleet.Workflow.Gates.evaluate/3`,
  PURE):

    * `:pass`                  → advances in the workflow_map (next_step).
    * `{:fail, _}`             → bounded REBOUND to the 1st step (anti-runaway rework).
    * `{:dispatch_gatekeeper}` → **escalation**: an undecidable `soft` or `terminal`
      gate is NOT a scheduling step — it is a summons
      of the **one-shot per-project gatekeeper** (exception judge, reorg 2026-07-19). We enqueue
      an eval brief to the gatekeeper (work-session, addressed by `pod_id` via
      TaskQueue/MCP), we hold the resume context in RAM (`gate_evals`, keyed
      by `correlation_id`), and the decision comes back async via
      `%Fleet.Event{source: :task_queue, type: :"work_item.completed"}` → `resume_gate/3`.

  The judge is **rare by construction**: the engine cannot over-summon it
  (the `soft`/undecidable is a *runtime condition*, not a *step tag*).
  No `role: gatekeeper` step, no `soft⟺gatekeeper` biconditional —
  there is no explicit-step machinery: the decision is forge-driven.

  ## Defensive `workflow_map_id` guard

  This consumer is the ONLY completion rail (no RAM engine, no dual-run). No pod is
  spawned with `opts[:workflow_map_id]` — nothing produces it. The `workflow_map_id`
  present → skip branch (the `{:skip, :workflow_map_pod}` clause below) remains as a
  **defensive guard** (a residual workflow_map_name payload would not be processed by
  mistake), never triggered in practice.

    * **Step-dispatch pods** — no `workflow_map_id`, but (if they carry a
      project) the payload embeds `workspace` + `base_sha` + `role` (enriched at the
      source, `Fleet.Spawner.Pod.CompletedPayload`). **This consumer
      processes them.** The event carries all the state → stateless consumer FOR THE HAPPY PATH
      (pass/fail); pending gatekeeper escalations live in RAM (`gate_evals`)
      as a **fast-path optimization** — but this is NOT a hard dependency:
      the verdict is **self-descriptive** (the metadata of the eval task
      carries the resume context → a crash of the StepRunConsumer alone, broker alive,
      reconstructs `eval_ctx` from the metadata instead of silently discarding the verdict).

  ## Event → step_run translation

    * `issue_number` ← `issue_id` (`"issue-N"` → `N`)
    * `repo` ← **the event** (`payload["repository"]["full_name"]`), per-step-run. MULTI-PROJECT:
      the StepRunConsumer is a singleton that processes the step_runs of ALL the human's projects → the repo
      (and the `remote` to push to) CANNOT be pinned in config; it TRAVELS in the event ("the event
      carries all the state"). Config `:repo`/`:remote` remain a **fallback** (single-repo legacy / test
      with a bare payload). The effective state of a step_run is derived by `step_run_state/2` on entry.
    * `remote` ← **the event** (`payload["remote"]`, = the cloned `repo_path` = the push URL), per-step-run.
    * `deliverable_opts` ← `{mode: :git_native, workspace, base_sha,
      allowed_emails(role), remote, target_branch}`; the SYSTEM pushes
      (the pod committed in its workspace, the system verifies+pushes) onto a system branch
      `lcars/issue-N-role` (merge-to-main = elsewhere, not here).
    * `next_assignee: nil` → **1-step terminal** (close). Multi-step
      (lookup of the next in the workflow_map) = the workflow_map mode.

  ## Config / seams

    * `:repo` — `"owner/name"` — **fallback** (the per-step-run repo comes from the event)
    * `:remote` — URL/name of the remote the system pushes to — **fallback** (per-step-run comes from the event)
    * `:forge_opts` — passed to the ForgeClient via StepRunCompleter
    * `:role_emails` — `fn role -> [email] end` (default `"<role>@lcars.local"`),
      must match the git identity injected into the pod (the gate checks the committer's email)
    * `:step_run_completer` — seam (default `Fleet.Pilot.StepRunCompleter`)
    * `:task_queue` — brief broker for the gatekeeper escalation (default `Fleet.TaskQueue`)
    * `:spawner` — wake of the gatekeeper after enqueue (default `Fleet.Spawner`)
    * `:subscribe` — bool default `true` (tests: `false` + manual send)
    * `:step_run_runner` — completion offload seam. Default `nil` → **SYNC** (the outcome bubbles up,
      seams/tests unchanged). Prod (`application.ex`) injects `&offload_async/1` → the completion (git push
      ≤30s + forge writes) runs in a `Task.Supervisor`: the **singleton StepRunConsumer does not block**
      (and a `.complete` that crashes is isolated by the supervised task).

  **Last revised**: 2026-07-31
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.Opts

  # PURE verdict cluster (gate-decision decoding + trace/review/eng-voice rendering), extracted here: no
  # `state` field, operates on the raw payload/result. The stateful decision core (apply_verdict,
  # resume_gate, complete_business_step_run) stays in THIS module (gate_decide lives in `GateEngine`).
  alias Fleet.Pilot.StepRunConsumer.Verdict

  # IMPURE "gatekeeper escalation" cluster (async-out): enqueue the eval brief + kick + telemetry.
  # Reads ONLY the `Seams` fields (task_queue/spawner/repo/forge/forge_opts/loader/wake_recovery), passed as an
  # explicit `GatekeeperEscalation.Seams` struct (not the whole `state` — hardened boundary). Called by
  # the GateEngine on the `{:dispatch_gatekeeper, _}` path (seams forwarded via `gate_seams/1`).
  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation

  # Gate DECISION engine (resolve_next/advance_intent/producer?): returns an INTENT,
  # THIS module acts. Hardened boundary: reads a narrow `GateEngine.Seams` (`gate_seams/1`), not `state`.
  alias Fleet.Pilot.StepRunConsumer.GateEngine

  # TERMINAL escalation to the human (human wall → await_arch + kick arch). Hardened boundary:
  # reads a narrow `TerminalEscalation.Seams` (`terminal_seams/1`), the sync/offload discipline
  # (`run_completion/3`) stays HERE and travels in a closure.
  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation

  # Construction of the PR-native step_run (producer/judge classification + assembly). Hardened
  # boundary: reads a narrow `StepRunBuild.Seams` (`build_seams/1`), called INSIDE the offloaded
  # closure (E4: the judge-branch resolution I/O does not block the mailbox).
  alias Fleet.Pilot.StepRunConsumer.StepRunBuild

  defstruct [
    :repo,
    :remote,
    :forge_opts,
    :role_emails,
    :step_run_completer,
    :forge_client,
    :loader,
    :deliverable,
    # Resolves a role's deliverable_mode (`"git_native"` producer / `"payload"` judge)
    # to classify the PR-native step_run. Default = cap-profile catalogue. Test seam (zero loading).
    :deliverable_mode_fun,
    # Gatekeeper escalation seams (one-shot per-project judge since the 2026-07-19 reorg —
    # spawned per eval by GatekeeperEscalation, no resident pod_id/boot to hold here).
    :task_queue,
    :spawner,
    # Wake recovery seam (kept: used by TerminalEscalation's rails).
    :wake_recovery,
    # Pending escalations, keyed by correlation_id (= task.id of the eval brief). Value =
    # resume context `%{n, role, payload, workflow_map, step, stored_at}`. fast-path OPTIMIZATION
    # only (the verdict is self-descriptive via the task metadata → reconstructible at restart).
    # BOUNDED, two independent rails: the `work_item.cleared` of a superseded/cleared eval frees
    # its entry (event, lossy), and a periodic sweep drops whatever outlived `@gate_eval_ttl_ms`
    # (backstop that needs no message to arrive). Without them, only a CORRELATED completion ever
    # removed an entry → every other terminal fate stranded a payload + a full workflow_map in
    # this singleton's RAM, forever.
    gate_evals: %{},
    # TTL/cadence of the eval-context sweep (seams — a TTL only exercisable by waiting 2 h is a
    # TTL nobody tests). Defaults resolved in `init/1` from the module attributes.
    gate_eval_ttl_ms: nil,
    gate_eval_sweep_ms: nil,
    # Completion offload seam. Default nil → `run_completion` falls back to SYNC (the outcome
    # bubbles up, `maybe_complete`/`resume_gate` seams + all tests unchanged). Prod = async Task.Supervisor.
    step_run_runner: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  # Task supervisor for the completion offload (prod). Name shared between
  # `application.ex step_children` (which starts it BEFORE the StepRunConsumer) and `offload_async/1`.
  @step_run_task_supervisor Fleet.Pilot.StepRunTaskSupervisor

  # TTL of a RAM eval context + cadence of the sweep that enforces it (cf. `:sweep_gate_evals`).
  # 2 h ≫ any real gatekeeper eval (a claude turn — minutes); past that, the mandate can no longer
  # yield a verdict this fast-path would honour. Dropping the context loses NOTHING: a late verdict
  # still resumes through the broker's self-describing metadata (`reconstruct_eval_ctx/2`).
  # Both are test seams (`:gate_eval_ttl_ms` / `:gate_eval_sweep_ms`) — a TTL that can only be
  # exercised by waiting 2 h is a TTL nobody tests.
  @gate_eval_ttl_ms 7_200_000
  @gate_eval_sweep_ms 600_000

  @doc false
  def task_supervisor, do: @step_run_task_supervisor

  @doc """
  Count of IN-FLIGHT completion offloads — live children of the completion `Task.Supervisor` (CI-02).

  The graceful drain (`Fleet.Starfleet.Shutdown`) counts these as in-flight work: after `pod.completed`,
  the business completion (push + PR + forge writes, ≤30s) runs HERE, in a Task — neither a pod nor a
  broker work-item (the item is already `:completed`), so the pod/work-item aggregate would otherwise cut
  it mid-push. Wired into the drain via the `:completion_inflight_fun` seam (`runtime.exs`) — Starfleet must
  NOT reference Pilot at compile time (no boundary dep), so this crosses as a runtime fun, not a call.

  COUNTS FROM THE TASK'S BIRTH, NOT FROM THE WORK-ITEM'S DEATH. Between the work-item flipping to
  `:completed` and this Task being spawned, the completion is invisible to every counter — and that gap
  contains `GateEngine.resolve_next/3`, which can issue a synchronous forge read bounded by the
  transport's 10s `receive_timeout`. The drain's debounce mitigates that gap at ~1.5s and therefore does
  not close it (cf. `@default_drain_confirmations` in `Shutdown`). Closing it means taking a LEASE here,
  BEFORE the flip, so that what the drain counts starts when the completion is DECIDED rather than when
  it is SCHEDULED. This module is where such a lease would live.

  Counts the LIVE children (self-correcting: a Task gone/crashed leaves the supervisor → no leak, unlike a
  RAM inc/dec). Two distinct outcomes, NEVER conflated:
    * supervisor ABSENT (step off) → `0`: its Tasks are dead with it (work already lost, independent of
      the drain) — an HONEST 0.
    * supervisor PRESENT but `count_children` raises/exits → `:unknown`: we canNOT count the in-flight
      completions → the drain must stay fail-closed (a fake `0` here could cut a live completion
      mid-push), exactly like the broker's present-but-unreachable sentinel.
  """
  @spec inflight_completions() :: non_neg_integer() | :unknown
  def inflight_completions do
    if is_pid(Process.whereis(@step_run_task_supervisor)) do
      %{active: n} = DynamicSupervisor.count_children(@step_run_task_supervisor)
      n
    else
      0
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  # ASYNC runner (prod, injected as `:step_run_runner`) — offloads the completion into the
  # `Task.Supervisor`: the git push ≤30s + forge writes do NOT block the singleton. Returns
  # `{:ok, :offloaded}` (the real outcome is logged in the task). Spawn failure → fail-loud logged.
  # Shared skeleton `Fleet.Pilot.Offload` (single source); THIS consumer keeps its supervisor
  # and its loss consequence ("completion lost").
  @doc false
  def offload_async(fun),
    do:
      Fleet.Pilot.Offload.async_or_inline(
        @step_run_task_supervisor,
        fun,
        {"StepRunConsumer", "completion lost"}
      )

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    # MULTI-PROJECT: `:repo`/`:remote` are NOT mandatory — the singleton derives the
    # repo (+ push remote) per-step-run from the event (`step_run_state/2`). They remain accepted as a FALLBACK
    # (single-repo legacy / test with a bare payload). No `{:stop, :missing_required_opt}`: a boot without
    # a repo is legitimate (multi-project); the rail's fail-loud guard lives on the `application.ex` side
    # (forge base_url required for discovery + the push).
    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      remote: Keyword.get(opts, :remote),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: Keyword.get(opts, :role_emails, &default_role_emails/1),
      step_run_completer: Keyword.get(opts, :step_run_completer, Fleet.Pilot.StepRunCompleter),
      # nil → StepRunCompleter applies its default (Fleet.Pilot.ForgeClient). Injectable
      # for an alternative forge backend (or a sim in bare dogfood).
      forge_client: Keyword.get(opts, :forge_client),
      # workflow_map Loader (multi-step workflow_map mode): resolves the next step. Default = real Loader.
      loader: Keyword.get(opts, :loader, Fleet.Workflow.Loader),
      # nil → StepRunCompleter applies its default (Fleet.Workflow.Deliverable). Injectable (sim/test).
      deliverable: Keyword.get(opts, :deliverable),
      # Producer/judge classification of the PR-native step_run. Default = cap-profile catalogue.
      deliverable_mode_fun: Keyword.get(opts, :deliverable_mode_fun, &default_deliverable_mode/1),
      # (The rebound's anti-runaway bound is NOT an opt: it is DATA from the map
      # `spec.max_rework_rounds`, read by GateEngine.rebound — never a hidden global default.)
      # Gatekeeper escalation seams (defaults = real broker/spawner; the gatekeeper itself is
      # spawned one-shot per eval — reorg 2026-07-19, no resident registry fun).
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      # Wake recovery seam (default = the real fn).
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      gate_evals: %{},
      gate_eval_ttl_ms: Keyword.get(opts, :gate_eval_ttl_ms, @gate_eval_ttl_ms),
      gate_eval_sweep_ms: Keyword.get(opts, :gate_eval_sweep_ms, @gate_eval_sweep_ms),
      # Prod (step_children) injects `&offload_async/1` here; without this
      # read, `run_completion` would fall back to sync → the git push would block the singleton (dead offload).
      step_run_runner: Keyword.get(opts, :step_run_runner)
    }

    Logger.info(
      "StepRunConsumer: start (MULTI-PROJECT: repo/remote per-step-run) " <>
        "fallback_repo=#{inspect(state.repo)} fallback_remote=#{inspect(state.remote)}"
    )

    # Backstop sweep of the RAM eval contexts (TTL): armed unconditionally — the leak it bounds
    # does not depend on the Bus being subscribed, and the tick is a no-op on an empty map.
    Process.send_after(self(), :sweep_gate_evals, state.gate_eval_sweep_ms)

    # (No gatekeeper boot: since the 2026-07-19 reorg the gatekeeper is a ONE-SHOT per-project
    # judge, spawned per eval by GatekeeperEscalation.dispatch — no resident to ensure.)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    # `Quiesce.busy/1`: between this reception and the offload's start, the completion is
    # neither a work-item (already :completed) nor a counted offload — a drain's zero read
    # in that window would cut it. The wrap makes the handoff countable end to end.
    Fleet.Shutdown.Quiesce.busy(fn -> handle_pod_completed(p, state) end)
  end

  # Gatekeeper decision received: the eval brief (correlated by
  # `correlation_id` = task.id of the enqueue) is completed. We process ONLY the corr
  # we have pending (the other work_item.completed — other pods — are ignored).
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :"work_item.completed", correlation_id: corr} =
          ev,
        state
      )
      when is_binary(corr) do
    # ARCH INBOX DRAIN (serialize-via-forge): the arch RESOLVED an escalation
    # (its `submit_result`) → remove the `lcars-awaits-arch` label so the poller stops re-offering THIS one
    # and serves the NEXT awaits-arch issue (the forge is the arch's queue, one at a time). Correlated by the
    # work-item `metadata.awaits_arch` (+ repo/number), posted by `Poller.offer_arch_mandate`. Checked FIRST:
    # an arch mandate carries NO `gate_eval` → without this it would fall into the eval reconstruction below
    # (and the label would NEVER drain → infinite re-offer of a resolved escalation).
    if arch_escalation_resolved?(ev) do
      _ = drain_awaits_arch(ev, state)
      {:noreply, state}
    else
      resume_or_reconstruct(ev, corr, state)
    end
  end

  # An eval mandate that ends WITHOUT a verdict (superseded by a fresh enqueue on the gatekeeper,
  # or cleared with its pod) frees its RAM context: `gate_evals` only ever shrank on the CORRELATED
  # completion, so every non-completed terminal transition stranded an entry (payload + the whole
  # workflow_map) in this singleton — monotone growth on a long-lived daemon. Nothing is lost by
  # dropping it: without a verdict there is nothing to resume, and the durable truth (the eval task
  # + its self-describing metadata) lives in the broker, which is what `reconstruct_eval_ctx/2`
  # reads if a late verdict ever arrives.
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :"work_item.cleared", correlation_id: corr},
        state
      )
      when is_binary(corr) do
    case Map.pop(state.gate_evals, corr) do
      {nil, _} ->
        {:noreply, state}

      {_eval_ctx, gate_evals} ->
        Logger.info(
          "StepRunConsumer: eval mandate #{corr} cleared without a verdict — resume context released"
        )

        {:noreply, %{state | gate_evals: gate_evals}}
    end
  end

  # Periodic backstop of the same leak: the `work_item.cleared` rail above is LOSSY (Bus doctrine
  # D1), and a gatekeeper that dies mid-eval emits nothing at all. Any context older than the
  # eval's useful life is dead by construction (its mandate can no longer produce a verdict this
  # consumer would honour) → swept. Belt (event) AND braces (TTL): a singleton's RAM must be
  # bounded by a mechanism that does not depend on a message arriving.
  def handle_info(:sweep_gate_evals, state) do
    Process.send_after(self(), :sweep_gate_evals, state.gate_eval_sweep_ms)

    now = System.monotonic_time(:millisecond)
    ttl = state.gate_eval_ttl_ms

    {kept, expired} =
      Enum.split_with(state.gate_evals, fn {_corr, ctx} -> fresh?(ctx, now, ttl) end)

    for {corr, _ctx} <- expired do
      Logger.warning(
        "StepRunConsumer: eval context #{corr} expired (no verdict within the eval TTL) — " <>
          "released; a late verdict would still resume via the broker metadata"
      )
    end

    {:noreply, %{state | gate_evals: Map.new(kept)}}
  end

  # Pod FAILURE events (`pod.failed`/`wake.failed`) are routed by `Fleet.Pilot.IncidentConsumer`
  # (SEPARATE consumer → incident registry). Here they fall into the catch-all (no-op): this singleton
  # carries ONLY step-run completion, not the incident policy (distinct concern, isolated blast-radius).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}

  # BEFORE the catch-all: the death of an OFFLOADED completion task (Offload monitors it; the
  # :DOWN lands here, in the consumer that launched it). Without this clause the catch-all
  # swallowed the only witness of a completion dying mid-work — the pod's publish deadline then
  # expired 120s later for an unexplained reason.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    _ = Fleet.Pilot.Offload.handle_down(ref, pid, reason)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_pod_completed(p, state) do
    case maybe_complete(p, state) do
      # The outcome is logged by `run_completion` (in the task when async), not here.
      {:ok, _outcome} ->
        {:noreply, state}

      # Undecidable gate: the eval brief is enqueued to the permanent
      # gatekeeper; we hold the resume context until the correlated `work_item.completed`.
      # The issue stays locked (in-flight) → the poller does not re-spawn (no blind
      # advance before the verdict).
      {:escalate, corr, eval_ctx} ->
        Logger.info(
          "StepRunConsumer: gate→gatekeeper #{p["issue_id"]} step=#{eval_ctx.step} corr=#{inspect(corr)}"
        )

        # `stored_at` (monotonic) = the TTL clock of the sweep backstop. Stamped HERE, at the
        # single insertion point, so no context can enter the map without a deadline.
        eval_ctx = Map.put(eval_ctx, :stored_at, System.monotonic_time(:millisecond))

        {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}

      {:skip, reason} ->
        # `reason` can be a tuple ({:bad_issue_id, id}) — bare interpolation would crash the
        # singleton the moment the operator flips to :debug to diagnose (twin of :285 below).
        Logger.debug("StepRunConsumer: skip #{p["issue_id"]} (#{inspect(reason)})")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: end-of-step-run FAIL #{p["issue_id"]}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  # A context with no `stored_at` predates the stamping (or came from a test fixture): treated as
  # fresh — the sweep never drops what it cannot date (it bounds growth, it does not police).
  defp fresh?(%{stored_at: at}, now, ttl) when is_integer(at), do: now - at < ttl
  defp fresh?(_ctx, _now, _ttl), do: true

  # Executes the resume (common fast-path / reconstruction). The resume pushes/writes onto the
  # repo of the escalated STEP_RUN (carried by the original `pod.completed`, kept in `eval_ctx.payload`), not onto
  # config. The gatekeeper verdict arrives via a `work_item.completed` (other event, without repo) → we re-derive
  # from the original payload.
  defp do_resume_gate(eval_ctx, ev, corr, state) do
    case resume_gate(eval_ctx, ev.payload, step_run_state(eval_ctx.payload, state)) do
      # Outcome logged by `run_completion`; here we only log the DECISION error (pre-completion).
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: gate resume FAIL corr=#{inspect(corr)}: #{inspect(reason)}"
        )
    end
  end

  # The NOMINAL work_item.completed path (not an arch escalation): gatekeeper-eval resume (RAM fast-path or
  # metadata reconstruction), or `{:noreply}` for every other pod's completion. Extracted so the handler
  # stays a clean two-way branch (arch drain vs the rest); the eval logic is unchanged.
  defp resume_or_reconstruct(ev, corr, state) do
    case Map.pop(state.gate_evals, corr) do
      # FAST-PATH absent: the context is not in RAM. TWO EXCLUSIVE cases:
      #  (a) the verdict metadata carries `gate_eval` (gatekeeper escalation) → we RECONSTRUCT the eval_ctx from
      #      the metadata (self-descriptive verdict) → resume. This is the closed wedge: crash of the StepRunConsumer alone
      #      (broker alive → the task + its metadata survive) → the verdict arrives at the restarted StepRunConsumer
      #      (empty gate_evals) → reconstruction instead of a silent `{:noreply}` (issue locked forever).
      #  (b) otherwise → `{:noreply}` (NORMAL case: every step-dispatch pod emits a `work_item.completed` without
      #      `gate_eval` → it is not a gatekeeper escalation → we ignore it).
      {nil, _} ->
        case reconstruct_eval_ctx(ev.payload, state) do
          {:ok, eval_ctx} ->
            do_resume_gate(eval_ctx, ev, corr, state)
            {:noreply, state}

          :not_gate_eval ->
            {:noreply, state}
        end

      # FAST-PATH: the context is in RAM (nominal path, no crash) → direct resume. EXCLUSIVE of the
      # reconstruction case (corr present here ⊻ absent there) → never a double-resume.
      {eval_ctx, gate_evals} ->
        state = %{state | gate_evals: gate_evals}
        do_resume_gate(eval_ctx, ev, corr, state)
        {:noreply, state}
    end
  end

  # The completed work-item is an ARCH escalation mandate (`Poller.offer_arch_mandate`): its metadata carries
  # `awaits_arch: true` (+ repo/number). Same key convention as `reconstruct_eval_ctx` (`:metadata` atom,
  # string fallback). Distinguishes it from every other `work_item.completed` (which drains nothing).
  defp arch_escalation_resolved?(%Fleet.Event{payload: payload}) when is_map(payload) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    is_map(meta) and Map.get(meta, "awaits_arch") == true
  end

  defp arch_escalation_resolved?(_), do: false

  # Drains `lcars-awaits-arch` on the resolved issue → the poller serves the NEXT one (the forge is the arch's
  # queue). `remove_label` is idempotent (`:already_absent` no-op). repo+number travel in the work-item
  # metadata (a `WorkItem` has no repo field). BEST-EFFORT: a failed remove leaves the label → the poller
  # re-offers (a re-arbitration, never a loss) — logged so it stays visible, never a silent stuck label.
  defp drain_awaits_arch(%Fleet.Event{payload: payload}, state) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    repo = Map.get(meta, "repo")
    number = Map.get(meta, "number")
    forge = state.forge_client || Fleet.Pilot.ForgeClient

    if is_binary(repo) and is_integer(number) do
      case forge.remove_label(repo, number, Fleet.Labels.awaits_arch(), state.forge_opts) do
        {:ok, _} ->
          Logger.info(
            "StepRunConsumer: awaits-arch drained on #{repo}##{number} (arch resolved) → poller serves the next"
          )

        {:error, reason} ->
          Logger.warning(
            "StepRunConsumer: awaits-arch NOT drained on #{repo}##{number} (#{inspect(reason)}) — " <>
              "poller may re-offer (no loss)"
          )
      end
    else
      Logger.warning(
        "StepRunConsumer: arch escalation resolved but metadata lacks repo/number " <>
          "(#{inspect(meta)}) — label not drained"
      )
    end

    :ok
  end

  # RECONSTRUCTS the eval_ctx from the verdict metadata (self-descriptive verdict), when the
  # RAM fast-path (`gate_evals`) is empty (crash of the StepRunConsumer alone). The metadata travels in
  # `ev.payload[:metadata]` (set by `task_queue/server.ex`; atom key). `:not_gate_eval` if absent or not a
  # gatekeeper eval → normal `{:noreply}` case. `workflow_map` re-loaded from the `workflow_map_name` (Loader seam — derivable, not
  # embedded: too big). If the metadata is an eval but malformed (payload/role/n missing) → fail-loud
  # (`:not_gate_eval` log) rather than a resume on a truncated context.
  defp reconstruct_eval_ctx(payload, state) when is_map(payload) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    if is_map(meta) and meta["gate_eval"] == true do
      with rp when is_map(rp) <- meta["resume_payload"],
           workflow_map_name when is_binary(workflow_map_name) <- meta["workflow_map"],
           step when is_binary(step) <- meta["step"],
           role when is_binary(role) <- meta["resume_role"],
           n when is_integer(n) <- meta["resume_n"],
           {:ok, workflow_map} <- load_workflow_map(state, workflow_map_name) do
        {:ok, %{n: n, role: role, payload: rp, workflow_map: workflow_map, step: step}}
      else
        other ->
          Logger.warning(
            "StepRunConsumer: metadata gate_eval but eval_ctx reconstruction impossible " <>
              "(#{inspect(other)}) — verdict NOT resumed (fail-loud, no resume on truncated context)"
          )

          :not_gate_eval
      end
    else
      :not_gate_eval
    end
  end

  defp reconstruct_eval_ctx(_, _), do: :not_gate_eval

  # ============================================================
  # Event → step_run translation (pure except the StepRunCompleter call / brief enqueue)
  # ============================================================

  @doc false
  # Exposed for test: decides skip/complete/escalate without going through the GenServer.
  # Returns `{:ok, outcome}` | `{:skip, reason}` | `{:escalate, corr, eval_ctx}` |
  # `{:error, reason}`.
  def maybe_complete(payload, state) do
    cond do
      Map.has_key?(payload, "workflow_map_id") ->
        {:skip, :workflow_map_pod}

      not project_payload?(payload) ->
        {:skip, :no_project}

      true ->
        case parse_issue_number(payload["issue_id"]) do
          # Repo + remote of THIS step_run derived from the event (per-step-run), not from config.
          {:ok, n} -> run_step_run(payload, n, step_run_state(payload, state))
          :error -> {:skip, {:bad_issue_id, payload["issue_id"]}}
        end
    end
  end

  # MULTI-PROJECT — derives the EFFECTIVE state of a step_run: the `repo` (forge API: list_open_pulls,
  # count_signed_step_runs, comments…) and the `remote` (deliverable push URL) come from the EVENT, not from
  # config. The singleton StepRunConsumer processes the step_runs of ALL the human's projects → pinning repo/remote in
  # config would be wrong from the 2nd project on. The Spawner enriches `pod.completed` at the source
  # (`Fleet.Spawner.Pod.CompletedPayload`: `"repository" => %{"full_name"}` + `"remote"`). Bare payload
  # (without repo: test/single-repo legacy) → we keep the config state (fallback). `remote` absent but
  # repo present → fallback remote (rare; a well-onboarded project carries both).
  #
  # F-037 — KEEP: the config fallback co-exists with "the event is the source of truth" ON PURPOSE —
  # it is a BACK-COMPAT valid-default for single-repo-legacy + bare-payload tests, NEVER hit on the prod
  # multi-project path (the enriched event always carries the repo). It does NOT mask a wrong repo: a
  # MALFORMED prod event (no repo) falls back to the multi-project config repo = `nil` → downstream forge
  # calls fail (nil repo), not a SILENT-wrong-repo. Removing it would break the legacy/test path for no
  # prod gain → kept + documented (a valid default, so never a required opt).
  defp step_run_state(payload, state) do
    case payload_repo(payload) do
      repo when is_binary(repo) and repo != "" ->
        %{state | repo: repo, remote: payload["remote"] || state.remote}

      _ ->
        state
    end
  end

  defp payload_repo(payload),
    do: get_in(payload, ["repository", "full_name"]) || payload["repo"]

  defp run_step_run(payload, n, state) do
    role = payload["role"]

    # Producer/judge property = the EFFECTIVE deliverable_mode the pod ran with (payload), consumed
    # directly — resolve_next reads producer? on the SAME role+mode, so both decisions classify this pod
    # IDENTICALLY (no since-spawn skew). Only when the payload OMITS the mode (legacy) do we re-derive via
    # the cap-profile — and DR-013 then applies: an UNLOADABLE profile makes it UNKNOWN → never a silent
    # judge → ESCALATED to the arch (freeze + await_arch), never bubbled (G2 churn without a human).
    case producer?(role, payload["deliverable_mode"], state) do
      {:error, reason} ->
        TerminalEscalation.escalate_terminal_error(reason, n, role, terminal_seams(state))

      {:ok, is_producer?} ->
        run_step_run_classified(payload, n, role, is_producer?, state)
    end
  end

  # A PRODUCER that cannot deliver (missing dependency/info) marks
  # `blocked: true` in its result → human ESCALATION via `await_arch` (posted reason = its
  # `summary` voice + `lcars-awaits-arch` + unlock → poller SKIPS, the human decides via the arch). OTHERWISE the
  # publish without a commit fail-loud `:no_deliverable_commit` = silent WEDGE (an honest eng refuses
  # to guess → un-escalated blockage). Reuses the whole await_arch safety net.
  defp run_step_run_classified(payload, n, role, is_producer?, state) do
    if is_producer? and
         TerminalEscalation.blocked_flag?(
           Verdict.unwrap_worker_envelope(payload["result"] || %{})
         ) do
      TerminalEscalation.escalate_blocked_producer(payload, n, role, terminal_seams(state))
    else
      # If the payload carries the workflow_map context (workflow_map_name+step), the next step
      # is computed by WorkflowMapNav (reassign to the next role, or close if terminal).
      # Without workflow_map context (1-step) → next_assignee nil → close. A workflow_map error
      # (DAG, unknown step) does NOT misroute: it bubbles up (the system does not advance blindly).
      case GateEngine.resolve_next(payload, n, gate_seams(state)) do
        {:error, reason} ->
          # Q2 DRAFT producer (decoupled signal, before the escalation: a missed emit is logged warning
          # by emit_workflow_map_failed_draft and never blocks the escalation below — the human wall does
          # not depend on it): a workflow_map LOAD failure lights the dormant Cat-5 rail
          # (see emit_workflow_map_failed_draft/3).
          emit_workflow_map_failed_draft(reason, n, role)

          # G2 (funnel): a NON-TRANSIENT TERMINAL error must NOT bubble up as a log-only `{:noreply}`
          # — otherwise the reaper reclaims the lock 2 ticks later, re-dispatches the SAME step →
          # re-fail → infinite CHURN without ever notifying a human (asymmetry with the verdict path which
          # does escalate). We ESCALATE it to the arch (await_arch: comment + `lcars-awaits-arch` + unlock
          # → the poller SKIPS the issue, the churn stops, the human decides). The other errors bubble up
          # unchanged: transient/self-healing (`:no_gatekeeper` = the one-shot gatekeeper is (re)spawned
          # on the next dispatch tick) or handled elsewhere (unreadable workflow_map → IncidentRegistry, G6).
          if TerminalEscalation.terminal_escalate?(reason),
            do:
              TerminalEscalation.escalate_terminal_error(
                reason,
                n,
                role,
                terminal_seams(state)
              ),
            else: {:error, reason}

        # Gatekeeper escalation: bubbles up to the handle_info that stores `gate_evals`.
        {:escalate, corr, eval_ctx} ->
          {:escalate, corr, eval_ctx}

        # The finishing step is a JUDGE (brief_kind:judge): its verdict IS the decision →
        # `apply_verdict` (THE verdict function, shared with the async gatekeeper). No hard gate.
        {:judge_verdict, decision, trace, ctx} ->
          apply_verdict(decision, trace, ctx, state)

        {:ok, intent, {next_assignee, next_step}} ->
          complete_business_step_run(payload, n, role, intent, next_assignee, next_step, state)
      end
    end
  end

  # Hardened boundary to `TerminalEscalation`: the 5 authorized reads/effects, NOTHING else.
  # `run_completion` travels in a closure → the sync/offload discipline stays HERE (single source),
  # the escalation does not choose its execution mode.
  defp terminal_seams(state) do
    %TerminalEscalation.Seams{
      repo: state.repo,
      step_run_completer: state.step_run_completer,
      completer_opts: completer_opts(state),
      spawner: state.spawner,
      task_queue: state.task_queue,
      run_completion: fn label, fun -> run_completion(state, label, fun) end
    }
  end

  # Hardened boundary to `GateEngine`: the 7 authorized reads of the decision engine.
  # Built from the per-step-run DERIVED state (repo/forge_opts from the event, multi-project).
  defp gate_seams(state) do
    %GateEngine.Seams{
      loader: state.loader,
      deliverable_mode_fun: state.deliverable_mode_fun,
      repo: state.repo,
      forge_opts: state.forge_opts,
      forge_client: state.forge_client,
      escalation: escalation_seams(state)
    }
  end

  # Opts passed to the StepRunCompleter — SINGLE SOURCE of the assembly (forge_opts + optional
  # forge_client); `complete_business_step_run` adds `:deliverable` to it.
  defp completer_opts(state),
    do: [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

  # Executes a step_run completion via the `step_run_runner` seam. SYNC (default) → executes, logs
  # the outcome, and RETURNS it (`maybe_complete`/`resume_gate` seams + all tests receive it). ASYNC
  # (prod, Task.Supervisor) → offload: the git push ≤30s + forge writes do NOT block the singleton,
  # the outcome is logged INSIDE the task, the runner returns `{:ok, :offloaded}`. Ordering preserved (lock
  # lcars-in-flight + idempotent writes). A `.complete` that crashes in async is
  # isolated by the supervised task (does not kill the StepRunConsumer).
  defp run_completion(state, label, fun) do
    exec = fn ->
      outcome = fun.()

      case outcome do
        {:error, reason} ->
          Logger.warning("StepRunConsumer: end-of-step-run FAIL #{label}: #{inspect(reason)}")

        _ ->
          Logger.info("StepRunConsumer: end-of-step-run #{label} → #{inspect(outcome)}")
      end

      outcome
    end

    (state.step_run_runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()

  # Completes the PR-native step_run: the CONSTRUCTION (producer/judge classification + assembly of the
  # step_run map) is delegated to `StepRunBuild.build/5` (hardened boundary via `build_seams/1`);
  # HERE remains the orchestration (offload + completer call).
  defp complete_business_step_run(
         payload,
         n,
         role,
         intent,
         next_assignee,
         next_step,
         state,
         comment_body \\ nil,
         judge_target \\ nil
       ) do
    route = %{
      intent: intent,
      next_assignee: next_assignee,
      next_step: next_step,
      comment_body: comment_body,
      judge_target: judge_target
    }

    # E4: ALL the construction (including the judge-branch resolution → inline list_open_pulls HTTP,
    # timeout 10s) lives INSIDE the offloaded closure — a degraded forge + a burst of pod.completed does not
    # blocks the singleton's mailbox (handle_info becomes O(1) again in prod, the offload carries the I/O).
    run_completion(state, "##{n}", fn ->
      # DR-013: `build/5` returns `{:error, _}` if the producer/judge classification is UNKNOWN
      # (cap-profile unloadable) → we do NOT complete under an unknown property; `run_completion` logs
      # the FAIL. (In practice the upstream `producer?` guard in `run_step_run` already escalated this
      # role; this is the belt-and-suspenders on the build path.)
      case StepRunBuild.build(payload, n, role, route, build_seams(state)) do
        {:error, _} = err ->
          err

        step_run when is_map(step_run) ->
          hc_opts = completer_opts(state) |> Opts.maybe_put(:deliverable, state.deliverable)
          state.step_run_completer.complete_pr(step_run, hc_opts)
      end
    end)
  end

  # Hardened boundary to `StepRunBuild`: the 6 authorized reads of the construction.
  # Built from the per-step-run DERIVED state (repo/remote from the event, multi-project).
  defp build_seams(state) do
    %StepRunBuild.Seams{
      repo: state.repo,
      remote: state.remote,
      role_emails: state.role_emails,
      deliverable_mode_fun: state.deliverable_mode_fun,
      forge_client: state.forge_client,
      forge_opts: state.forge_opts
    }
  end

  # Producer/judge classification — SINGLE AUTHORITY `GateEngine.producer?/3` (shared with the gate
  # decision and StepRunBuild). Consumes the EFFECTIVE deliverable_mode the pod ran with (payload):
  # the completion never re-derives a fact it already carries (a since-spawn profile change could skew it).
  # Only a legacy/bare payload (mode absent) falls back to the state's `deliverable_mode_fun` seam.
  defp producer?(role, effective_mode, state),
    do: GateEngine.producer?(role, state.deliverable_mode_fun, effective_mode)

  @doc false
  # Seam default: resolves the role's deliverable_mode via the cap-profile catalogue (single source).
  #
  # DR-013 — an UNLOADABLE cap-profile at completion is a config PROBLEM (missing/corrupt profile). It used
  # to fall back to `"payload"` (LOUD log), but that fallback is NOT cosmetic: `producer?/2` then reads it
  # as non-producer → the role is silently reclassified `:judge` (a real producer's deliverable never
  # pushed, or a search for a nonexistent producer PR). A config anomaly must NOT become a DIFFERENT business
  # behavior. We return an EXPLICIT `{:error, :cap_profile_unloadable}` — the producer/judge classification
  # consumes a CLOSED result and FAILS LOUD (the step_run is not completed under an unknown property; the
  # issue stays locked, an operator sees the FAIL). The valid absent-`deliverable_mode` is `{:ok,
  # "payload"}` (a loadable profile that simply does not declare `git_native`) — DISTINCT from unloadable.
  @spec default_deliverable_mode(String.t()) ::
          {:ok, String.t()} | {:error, :cap_profile_unloadable}
  def default_deliverable_mode(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, cap} ->
        {:ok, Fleet.CapProfile.deliverable_mode(cap)}

      other ->
        Logger.error(
          "StepRunConsumer: cap-profile for role #{inspect(role)} UNLOADABLE (#{inspect(other)}) — " <>
            "deliverable_mode UNRESOLVABLE → producer/judge classification FAILS LOUD (no silent judge " <>
            "reclassification, no unverified push). FIX the role's cap-profile."
        )

        {:error, :cap_profile_unloadable}
    end
  end

  # The RESOLUTION of the next step (gate/rebound/judge-verdict/gatekeeper escalation) lives in
  # `GateEngine.resolve_next/3` (hardened boundary via `gate_seams/1`) — THIS module keeps only
  # the ORCHESTRATION (acting on the returned decision).

  # Builds the NARROW seams struct passed to `GatekeeperEscalation.dispatch` (via GateEngine):
  # the async-out seams read from the state (task_queue/spawner/repo/forge/forge_opts/loader/wake_recovery — cf. the `Seams` struct, which is the authority).
  # We do NOT pass the whole `state` — hardened boundary: the escalation cluster can read nothing else.
  defp escalation_seams(state) do
    # NB: `loader` stays nil → GatekeeperEscalation defaults to `Fleet.CapProfile` (the CAP loader).
    # `state.loader` is the WORKFLOW-MAP loader — a different authority, never passed here.
    %GatekeeperEscalation.Seams{
      task_queue: state.task_queue,
      spawner: state.spawner,
      repo: state.repo,
      forge: state.forge_client,
      forge_opts: state.forge_opts,
      wake_recovery: state.wake_recovery
    }
  end

  @doc false
  # Resume after the gatekeeper verdict. Exposed for test (the GenServer
  # calls via handle_info(:work_item.completed)). `raw_payload` = raw payload of the
  # `work_item.completed` (unwrapped here by `gate_result/1`: TaskQueue envelope + worker
  # envelope). Canon vocab `gate-decision-v1.json`:
  #   continue → advance (push business deliverable + reassign);
  #   abandon  → close (verdict trace, NO push: work rejected);
  #   redirect|escalate_user|halt_wait_input|invalide → await_arch (fail-closed).
  # The verdict TRACE is durable: carried in the signed comment of the step_run (continue/abandon)
  # or of the await_arch — this is what sank v1 by its absence.
  def resume_gate(
        %{n: _n, role: _role, payload: _payload, workflow_map: _workflow_map, step: _step} = ctx,
        raw_payload,
        state
      ) do
    result = Verdict.gate_result(raw_payload)
    decision = Verdict.gate_decision(result)
    trace = Verdict.verdict_comment("gatekeeper (juge d'exception §L441)", decision, result)
    apply_verdict(decision, trace, ctx, state)
  end

  # APPLICATION of a judge verdict (gate-decision-v1). ONE function, shared by ALL judges
  # whatever their position: the gatekeeper (async verdict via `work_item.completed` → resume_gate) AND the
  # brief-review scoper (verdict via `pod.completed` → gate_decide → run_step_run). continue → advances the
  # workflow_map; abandon → close; the rest → await_arch. The ONLY diff (PR vs pre-PR) lives in `complete_judge`
  # (trace = native review if PR, otherwise issue comment), derived from the forge state + the ctx's
  # `judge_target` — NOT from a fork here. `trace` is already attributed to the right judge (label) by the caller.
  defp apply_verdict(
         decision,
         trace,
         %{n: n, role: role, payload: payload, workflow_map: workflow_map, step: step} = ctx,
         state
       ) do
    case decision do
      "continue" ->
        # The producer/judge split is NOT optional. If the intent were `if is_nil(next_assignee),
        # do: :promote, else: :advance`, then on a TERMINAL step (next_assignee nil), `apply_verdict`
        # would hardcode `:promote` regardless of the ROLE that finishes → a PRODUCER judged "continue" on a
        # terminal would MERGE the code WITHOUT going through the PR judges. We route via the SAME
        # `GateEngine.advance_intent/3` as the gate `:pass` path: a terminal
        # producer → `:review` (opens the PR + requests the judges, NEVER an auto-merge of a deliverable); a terminal
        # judge (brief-review scoper) → `:promote` (it validated the last gate of its workflow_map);
        # a next step → `:advance`. A single source of truth for the terminal intent.
        # DR-013: resolve the producer/judge property (closed result) BEFORE advancing — an unloadable
        # cap-profile fails-loud, never a blind terminal intent under an unknown property.
        with {:ok, is_producer?} <- producer?(role, payload["deliverable_mode"], state),
             {:ok, intent, {next_assignee, next_step}} <-
               GateEngine.advance_intent(workflow_map, step, is_producer?) do
          complete_business_step_run(
            payload,
            n,
            role,
            intent,
            next_assignee,
            next_step,
            state,
            trace,
            Map.get(ctx, :judge_target)
          )
        end

      "abandon" ->
        # DO NOT bury it silently: the close comment is ADDRESSED to the arch (brief author)
        # + we KICK the arch (single airlock to the human) → the author LEARNS that its brief was discarded.
        arch_trace =
          "**Architecte** (auteur du brief) — brief ABANDONNÉ par le juge. " <>
            trace <> " (Non récupérable ; re-crée un brief corrigé si besoin.)"

        result = close_with_trace(n, role, arch_trace, state)

        # Content-carrying notification: the arch SEES the abandon in the wake itself (the issue is
        # closed — nothing to fetch, no phantom mandate), cf. TerminalEscalation.kick_architect/3.
        _ = TerminalEscalation.kick_architect(state.spawner, state.repo, arch_trace)
        result

      other ->
        # Q2 DRAFT producer (decoupled signal, before the escalation: a missed emit is logged warning by
        # emit_audit_verdict_draft and never blocks the freeze-to-arch below): an escalation-worthy judge
        # verdict (halt/`halt_invalid`/… → freeze-to-arch) lights the dormant audit rail
        # (see emit_audit_verdict_draft/4).
        emit_audit_verdict_draft(other, n, role, trace)

        # `comment_body: trace` → the verdict trace (attributed to the judge via its label, halt_invalid
        # distinguished) is carried on the await_arch comment (which addresses it to the arch), continue/abandon parity.
        # SINGLE safety net `freeze_to_arch` (await_arch + kick) — same gesture as the terminal escalations.
        TerminalEscalation.freeze_to_arch(n, role, other, trace, terminal_seams(state))
    end
  end

  # ============================================================
  # Q2 DRAFT event producers — "at least it blinks"
  #
  # Two dormant Cat-5 rails had a wired consumer (Starfleet.DriftMonitor) but NO producer. These emit a
  # REAL, honest signal from the forge-driven rail so the chain DriftMonitor → Cat5Escalator/CoordBackend →
  # Coord.Policies → Emitter → coord.* fires end-to-end. DRAFT: honest but partial (see per-fun notes);
  # both are DECOUPLED from the load-bearing rail (safe_emit: an emit failure is logged warning by each
  # producer, never crashes nor blocks the escalation that follows) and emit source `:workflow` so
  # they satisfy DriftMonitor's anti-spoof source match.
  # ============================================================

  # `workflow_map.failed` — emitted on a workflow_map LOAD failure (`:workflow_map_load_failed`, the
  # WorkflowMapNav single authority). This is the exact "forge-driven rail publishes a workflow_map
  # failure signal" the registry (events.yaml) anticipated. DRAFT: covers this dispatch path's load
  # failure, not yet every rail path (e.g. the gate-resume reconstruction). Other error reasons → no-op.
  defp emit_workflow_map_failed_draft({:workflow_map_load_failed, name, msg}, n, role) do
    case Bus.safe_emit(
           :workflow,
           :"workflow_map.failed",
           [
             # Traceability: correlate to the issue → DriftMonitor forwards this cid to
             # Cat5 (a nil cid would break the incident↔mandate link on the max-severity rail).
             correlation_id: to_string(n),
             payload: %{
               "workflow_map" => name,
               "issue" => n,
               "role" => role,
               "reason" => to_string(msg),
               "producer" => "draft:step_run_consumer"
             }
           ],
           on_unregistered: :log
         ) do
      :ok ->
        :ok

      {:error, why} ->
        Logger.warning("StepRunConsumer: workflow_map.failed draft NOT emitted: #{inspect(why)}")
    end
  end

  defp emit_workflow_map_failed_draft(_other_reason, _n, _role), do: :ok

  # `audit.verdict` — emitted on an escalation-worthy judge verdict (apply_verdict `other` branch:
  # halt/`halt_invalid`/… → freeze-to-arch; NOT continue/abandon). DRAFT: the pilot judge vocabulary is
  # coarsely translated to a decision-v1 `{decision: "escalate", reason: "audit_verdict"}` (which matches
  # the coord policy `escalate.audit_verdict`); the REAL verdict + issue + role + trace ride in `details`
  # so nothing is lost. Routed by DriftMonitor DIRECTLY to CoordBackend.handle_decision.
  defp emit_audit_verdict_draft(verdict, n, role, trace) do
    decision_json =
      Jason.encode!(%{
        "decision" => "escalate",
        "reason" => "audit_verdict",
        "details" => %{
          "verdict" => to_string(verdict),
          "issue" => n,
          "role" => role,
          "trace" => trace
        },
        "chain" => ["pilot.step_run_consumer.apply_verdict"]
      })

    case Bus.safe_emit(
           :workflow,
           :"audit.verdict",
           [payload: %{"decision_json" => decision_json}],
           on_unregistered: :log
         ) do
      :ok ->
        :ok

      {:error, why} ->
        Logger.warning("StepRunConsumer: audit.verdict draft NOT emitted: #{inspect(why)}")
    end
  end

  # `abandon` verdict: terminal forge close, WITHOUT push (the business work is rejected).
  # The terminal-failure of the forge-driven rail IS the closing of the issue (the forge carries the state),
  # not an in-memory failure signal: no deliverable is extracted/pushed on a non-continue verdict.
  # `deliverable_opts: nil` + `step_run_sha` → StepRunCompleter skips the publish step, keeps the
  # sequence idempotent (comment trace → close → unlock).
  defp close_with_trace(n, role, trace, state) do
    step_run = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      deliverable_opts: nil,
      step_run_sha: "gate-abandon",
      next_assignee: nil,
      comment_body: trace
    }

    run_completion(state, "##{n}", fn ->
      state.step_run_completer.complete(step_run, completer_opts(state))
    end)
  end

  # workflow_map loading (eval_ctx reconstruction) — single authority
  # `WorkflowMapNav.safe_load` (unified tag :workflow_map_load_failed), same source as the GateEngine.
  defp load_workflow_map(state, workflow_map_name),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(state.loader, workflow_map_name)

  defp project_payload?(p) do
    is_binary(p["workspace"]) and is_binary(p["base_sha"]) and p["base_sha"] != "" and
      is_binary(p["role"])
  end

  # The issue_id format "issue-<n>" has a SINGLE SOURCE (Fleet.Pilot.IssueId) — writer
  # (StepDispatcher) and parser cannot drift. `parse_issue_number` remains the public API
  # (called by `maybe_complete` + tested by step_run_consumer_test) but delegates.
  @doc false
  defdelegate parse_issue_number(issue_id), to: Fleet.Pilot.IssueId, as: :parse

  # The `allowed_emails` identity gate = the brief's HUMAN (the git_native pod
  # commits AS the human, cf. `bwrap_launch.sh`/`ForgeIdentity`), PLUS the role. Same
  # catalogue as the spawn → consistent (human commit ⟺ the gate authorizes the human). Unresolvable →
  # `[]` fail-closed (the gate rejects everything). The role is verified via the trailer, not the email.
  defp default_role_emails(role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} ->
        Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, id.author_email)

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: forge identity unresolvable (role=#{role}): #{inspect(reason)} — " <>
            "allowed_emails=[] (the deliverable identity gate will reject the push, fail-closed)"
        )

        []
    end
  end
end
