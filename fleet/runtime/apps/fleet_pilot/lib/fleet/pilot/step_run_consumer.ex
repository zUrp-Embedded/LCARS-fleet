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
  resumptions), the verdict application (`apply_verdict` — shared gatekeeper/consultant), the
  sync/offload execution discipline (`run_completion`) and the per-step-run derivation of the
  state (`step_run_state`: repo/remote from the event, multi-project).

  ## Gatekeeper = exception (escalation), NOT a step

  The gate of the finished step decides BEFORE advancing (`Fleet.Workflow.Gates.evaluate/3`,
  PURE):

    * `:pass`                  → advances in the workflow_map (next_step).
    * `{:fail, _}`             → bounded REBOUND to the 1st step (anti-runaway rework).
    * `{:dispatch_gatekeeper}` → **escalation**: an undecidable `soft` or `terminal`
      gate is NOT a scheduling step — it is a summons
      of the **permanent gatekeeper** (exception judge). We enqueue
      an eval brief to the gatekeeper (work-session, addressed by `pod_id` via
      TaskQueue/MCP), we hold the resume context in RAM (`gate_evals`, keyed
      by `correlation_id`), and the decision comes back async via
      `%Fleet.Event{source: :task_queue, type: :"work_item.completed"}` → `resume_gate/3`.

  The judge is **rare by construction**: the engine cannot over-summon it
  (the `soft`/undecidable is a *runtime condition*, not a *step tag*).
  No `role: gatekeeper` step, no `soft⟺gatekeeper` biconditional —
  all the explicit-step machinery is removed. This module REPLACES the old
  gatekeeper chaining of the RAM engine `Fleet.Workflow.Executor` (`do_dispatch_gatekeeper`/
  `handle_gate_decision`), DELETED: it redoes the same decision, but forge-driven.

  ## Residual `workflow_map_id` guard

  The RAM engine `Fleet.Workflow.Executor` (in-memory workflow_map_name↔step correlation)
  is DELETED — there is no more dual-run: this consumer is the only rail. No
  pod is spawned with `opts[:workflow_map_id]` anymore (the Executor was the only
  producer). The `workflow_map_id` present → skip branch (the `{:skip, :workflow_map_pod}` clause below) remains as a
  **defensive guard** (a residual workflow_map_name payload would not be processed by
  mistake), never triggered in practice.

    * **Step-dispatch pods** — no `workflow_map_id`, but (if they carry a
      project) the payload embeds `workspace` + `base_sha` + `role` (enriched at the
      source, `Fleet.Spawner.Pod.CompletedPayload`). **This consumer
      processes them.** The event carries all the state → stateless consumer FOR THE HAPPY PATH
      (pass/fail); pending gatekeeper escalations live in RAM (`gate_evals`)
      as a **fast-path optimization** — but this is no longer a hard dependency:
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
    * `:gatekeeper_pod_id_fun` — `fn -> pod_id | nil end` (default `&Fleet.Workflow.Gatekeeper.pod_id/0`)
    * `:subscribe` — bool default `true` (tests: `false` + manual send)
    * `:step_run_runner` — completion offload seam. Default `nil` → **SYNC** (the outcome bubbles up,
      seams/tests unchanged). Prod (`application.ex`) injects `&offload_async/1` → the completion (git push
      ≤30s + forge writes) runs in a `Task.Supervisor`: the **singleton StepRunConsumer does not block**
      (and a `.complete` that crashes is isolated by the supervised task).
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
  # Reads ONLY 4 seams (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery), passed as an
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
    # Gatekeeper escalation seams.
    :task_queue,
    :spawner,
    :gatekeeper_pod_id_fun,
    # Boot of the permanent gatekeeper in step-mode (idempotent ensure_booted, guarded
    # by :gatekeeper_autoboot). Without it, in step-only nothing boots/registers the gatekeeper →
    # pod_id/0 nil → any soft/terminal escalation fails {:error,:no_gatekeeper}.
    :gatekeeper_boot_fun,
    # Seam of the gatekeeper's wake recovery (default = the real fn). Lets us test that the
    # LOAD-BEARING return of the kick (`{:error,{:escalated,_}}`) is SURFACED (telemetry/warning), not swallowed.
    :wake_recovery,
    # Pending escalations, keyed by correlation_id (= task.id of the eval brief). Value =
    # resume context `%{n, role, payload, workflow_map, step}`. fast-path OPTIMIZATION only
    # (the verdict is self-descriptive via the task metadata → reconstructible at restart).
    gate_evals: %{},
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

  @doc false
  def task_supervisor, do: @step_run_task_supervisor

  # ASYNC runner (prod, injected as `:step_run_runner`) — offloads the completion into the
  # `Task.Supervisor`: the git push ≤30s + forge writes do NOT block the singleton. Returns
  # `{:ok, :offloaded}` (the real outcome is logged in the task). Spawn failure → fail-loud logged.
  # Shared skeleton `Fleet.Pilot.Offload` (single source); THIS consumer keeps its supervisor
  # and its loss consequence ("completion lost").
  @doc false
  def offload_async(fun),
    do:
      Fleet.Pilot.Offload.async(
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
      # (The rebound's anti-runaway bound is NO LONGER a hardcoded-default opt: it is DATA from the map
      # `spec.max_rework_rounds`, read by GateEngine.rebound. End of the hidden global default.)
      # Gatekeeper escalation seams (defaults = real broker/spawner/registry).
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      gatekeeper_pod_id_fun:
        Keyword.get(opts, :gatekeeper_pod_id_fun, &Fleet.Workflow.Gatekeeper.pod_id/0),
      gatekeeper_boot_fun:
        Keyword.get(opts, :gatekeeper_boot_fun, &Fleet.Workflow.Gatekeeper.ensure_booted/0),
      # Wake recovery seam (default = the real fn).
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      gate_evals: %{},
      # Prod (step_children) injects `&offload_async/1` here; without this
      # read, `run_completion` would fall back to sync → the git push would block the singleton (dead offload).
      step_run_runner: Keyword.get(opts, :step_run_runner)
    }

    Logger.info(
      "StepRunConsumer: start (MULTI-PROJECT F-037 : repo/remote per-step-run) " <>
        "fallback_repo=#{inspect(state.repo)} fallback_remote=#{inspect(state.remote)}"
    )

    # In step-mode, the StepRunConsumer IS the active path → it ensures the permanent
    # gatekeeper (handle_continue: boot outside init, OTP). Idempotent + autoboot-guarded (no-op
    # in test where gatekeeper_autoboot=false; no-op if the RAM path already booted it).
    {:ok, state, {:continue, :ensure_gatekeeper}}
  end

  @impl GenServer
  def handle_continue(:ensure_gatekeeper, state) do
    case state.gatekeeper_boot_fun.() do
      {:ok, :disabled} ->
        :ok

      {:ok, pod_id} ->
        Logger.info("StepRunConsumer: gatekeeper permanent ensured (pod=#{pod_id})")

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: ensure gatekeeper failed (#{inspect(reason)}) — escalations KO"
        )
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
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

        {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}

      {:skip, reason} ->
        Logger.debug("StepRunConsumer skip #{p["issue_id"]} (#{reason})")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: end-of-step-run FAIL #{p["issue_id"]}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
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

  # Pod FAILURE events (`pod.failed`/`wake.failed`) are routed by `Fleet.Pilot.IncidentConsumer`
  # (SEPARATE consumer → incident registry). Here they fall into the catch-all (no-op): this singleton
  # carries ONLY step-run completion, not the incident policy (distinct concern, isolated blast-radius).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

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

    cond do
      # A PRODUCER that cannot deliver (missing dependency/info) marks
      # `blocked: true` in its result → human ESCALATION via `await_arch` (posted reason = its
      # `summary` voice + `lcars-awaits-arch` + unlock → poller SKIPS, the human decides via the arch). OTHERWISE the
      # publish without a commit fail-loud `:no_deliverable_commit` = silent WEDGE (an honest eng refuses
      # to guess → un-escalated blockage). Reuses the whole await_arch safety net.
      producer?(role, state) and
          TerminalEscalation.blocked_flag?(
            Verdict.unwrap_worker_envelope(payload["result"] || %{})
          ) ->
        TerminalEscalation.escalate_blocked_producer(payload, n, role, terminal_seams(state))

      true ->
        # If the payload carries the workflow_map context (workflow_map_name+step), the next step
        # is computed by WorkflowMapNav (reassign to the next role, or close if terminal).
        # Without workflow_map context (1-step) → next_assignee nil → close. A workflow_map error
        # (DAG, unknown step) does NOT misroute: it bubbles up (the system does not advance blindly).
        case GateEngine.resolve_next(payload, n, gate_seams(state)) do
          {:error, reason} ->
            # Q2 DRAFT producer (best-effort, before the escalation): a workflow_map LOAD failure lights
            # the dormant Cat-5 rail (see emit_workflow_map_failed_draft/3).
            emit_workflow_map_failed_draft(reason, n, role)

            # G2 (funnel): a NON-TRANSIENT TERMINAL error must NOT bubble up as a log-only `{:noreply}`
            # — otherwise the reaper reclaims the lock 2 ticks later, re-dispatches the SAME step →
            # re-fail → infinite CHURN without ever notifying a human (asymmetry with the verdict path which
            # does escalate). We ESCALATE it to the arch (await_arch: comment + `lcars-awaits-arch` + unlock
            # → the poller SKIPS the issue, the churn stops, the human decides). The other errors bubble up
            # unchanged: transient/self-healing (`:no_gatekeeper` = the permanent gatekeeper reboots,
            # reconciliation re-dispatches) or handled elsewhere (unreadable workflow_map → IncidentRegistry, G6).
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
    # timeout 10s) lives INSIDE the offloaded closure — a degraded forge + a burst of pod.completed no longer
    # blocks the singleton's mailbox (handle_info becomes O(1) again in prod, the offload carries the I/O).
    run_completion(state, "##{n}", fn ->
      step_run = StepRunBuild.build(payload, n, role, route, build_seams(state))
      hc_opts = completer_opts(state) |> Opts.maybe_put(:deliverable, state.deliverable)

      state.step_run_completer.complete_pr(step_run, hc_opts)
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

  # Producer/judge classification — SINGLE AUTHORITY `GateEngine.producer?/2` (shared with the
  # gate decision and StepRunBuild); local wrapper that reads the `deliverable_mode_fun` seam of the state.
  defp producer?(role, state), do: GateEngine.producer?(role, state.deliverable_mode_fun)

  @doc false
  # Seam default: resolves the role's deliverable_mode via the cap-profile catalogue (single source).
  #
  # F-C053 — an UNLOADABLE cap-profile is a config PROBLEM (missing/corrupt profile), NOT the valid
  # absent-`deliverable_mode` of F-C143. It is only reachable as a TRANSIENT load failure (a role whose
  # profile can't load could never be SPAWNED, so it could never reach completion — the profile was there
  # at spawn, unreadable now). We keep the fail-SAFE default `"payload"` (a non-loadable role is NOT treated
  # as a producer → its output is never pushed as unverified code), but we LOG LOUD instead of classifying
  # SILENTLY: silently defaulting would MASK the misconfiguration (a real producer mishandled as a judge,
  # its code never pushed). D1 — observable > silent; the safe default avoids wedging on a transient blip.
  def default_deliverable_mode(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, cap} ->
        Fleet.CapProfile.deliverable_mode(cap)

      other ->
        Logger.error(
          "StepRunConsumer: cap-profile for role #{inspect(role)} UNLOADABLE (#{inspect(other)}) — " <>
            "deliverable_mode defaults to \"payload\" (fail-safe: NOT a producer, no unverified push). " <>
            "FIX the role's cap-profile; a real producer would be mishandled as a judge."
        )

        "payload"
    end
  end

  # The RESOLUTION of the next step (gate/rebound/judge-verdict/gatekeeper escalation) lives in
  # `GateEngine.resolve_next/3` (hardened boundary via `gate_seams/1`) — THIS module keeps only
  # the ORCHESTRATION (acting on the returned decision).

  # Builds the NARROW seams struct passed to `GatekeeperEscalation.dispatch` (via GateEngine):
  # the 4 async-out seams read from the state (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery).
  # We do NOT pass the whole `state` — hardened boundary: the escalation cluster can read nothing else.
  defp escalation_seams(state) do
    %GatekeeperEscalation.Seams{
      task_queue: state.task_queue,
      spawner: state.spawner,
      gatekeeper_pod_id_fun: state.gatekeeper_pod_id_fun,
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
  # brief-review consultant (verdict via `pod.completed` → gate_decide → run_step_run). continue → advances the
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
        # judge (brief-review consultant) → `:promote` (it validated the last gate of its workflow_map);
        # a next step → `:advance`. A single source of truth for the terminal intent.
        case GateEngine.advance_intent(workflow_map, step, producer?(role, state)) do
          {:ok, intent, {next_assignee, next_step}} ->
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

          {:error, reason} ->
            {:error, reason}
        end

      "abandon" ->
        # DO NOT bury it silently: the close comment is ADDRESSED to the arch (brief author)
        # + we KICK the arch (single airlock to the human) → the author LEARNS that its brief was discarded.
        arch_trace =
          "**Architecte** (auteur du brief) — brief ABANDONNÉ par le juge. " <>
            trace <> " (Non récupérable ; re-crée un brief corrigé si besoin.)"

        result = close_with_trace(n, role, arch_trace, state)
        _ = TerminalEscalation.kick_architect(state.spawner)
        result

      other ->
        # Q2 DRAFT producer (best-effort, before the escalation): an escalation-worthy judge verdict
        # (halt/`halt_invalid`/… → freeze-to-arch) lights the dormant audit rail (see emit_audit_verdict_draft/4).
        emit_audit_verdict_draft(other, n, role, trace)

        # `comment_body: trace` → the verdict trace (attributed to the judge via its label, halt_invalid
        # distinguished) is carried on the await_arch comment (which addresses it to the arch), continue/abandon parity.
        # SINGLE safety net `freeze_to_arch` (await_arch + kick) — same gesture as the terminal escalations.
        TerminalEscalation.freeze_to_arch(n, role, other, trace, terminal_seams(state))
    end
  end

  # ============================================================
  # Q2 DRAFT event producers (2026-07-09) — "at least it blinks"
  #
  # Two dormant Cat-5 rails had a wired consumer (Starfleet.DriftMonitor) but NO producer. These emit a
  # REAL, honest signal from the forge-driven rail so the chain DriftMonitor → Cat5Escalator/CoordBackend →
  # Coord.Policies → Emitter → coord.* fires end-to-end. DRAFT: honest but partial (see per-fun notes);
  # both are BEST-EFFORT (safe_emit, never crashes the load-bearing rail) and emit source `:workflow` so
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
  # (StepDispatcher) and parser can no longer drift. `parse_issue_number` remains the public API
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
            "allowed_emails=[] (F-01 will reject the push, fail-closed)"
        )

        []
    end
  end
end
