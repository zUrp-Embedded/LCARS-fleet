defmodule Fleet.Pilot.StepRunConsumer do
  @moduledoc """
  Consumes pod.completed events, derives per-run context and delegates forge completion.
  GateEngine resolves intent; this GenServer applies verdicts, stores pending evaluations
  and chooses synchronous vs runner execution. It also handles evaluation results and
  architect-resolution metadata from work_item.completed.

  Payloads with any workflow_map_id key skip. Others need binary workspace/role and
  nonempty binary base_sha plus a parseable issue_id; this is not filesystem or SHA validation.
  Repository comes from the event (nested repository before bare repo), with configured
  repo/remote fallback. Event remote overrides only when an event repo is accepted.

  Gates may advance, rebound or summon an issue-keyed exception judge; undecidable
  does not imply a gatekeeper workflow step. Evaluation context lives in gate_evals
  with TTL/sweep. Broker metadata can reconstruct it after consumer loss, provided
  that metadata survives and the named card still loads. Reconstruction reloads the
  card using metadata repo/config fallback, not the resume payload's repo.

  CompletionOutbox writes before processing and deletes on ok, skip or escalation.
  With offload, ok may mean only Task admission: the entry is deleted before the
  eventual forge result. Replay is a boot message, not a periodic retry or a guarantee
  of beating orphan reclamation. Evaluation continuations are not journaled here.

  Seams include repo/remote, forge_client/forge_opts, role_emails (default ForgeIdentity),
  loader, deliverable/deliverable_mode_fun, completer, task_queue, spawner and wake_recovery.
  subscribe defaults true. ops_root affects gate-trace pinning here, not all completer calls.
  escalate_fun reports stuck architect drains; gate_eval_ttl_ms/sweep_ms bound dated RAM contexts.
  step_run_runner nil runs synchronously; production injects offload_async. Arity 2 carries
  death metadata, arity 1 does not. Offload can fall back inline; gates/resolution before
  the closure still run in the singleton.
  """

  use GenServer
  require Logger

  alias Fleet.Event
  alias Fleet.EventRouter.Bus
  alias Fleet.Opts
  alias Fleet.Pilot.CompletionOutbox

  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation
  alias Fleet.Pilot.StepRunConsumer.StepRunBuild
  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation
  alias Fleet.Pilot.StepRunConsumer.Verdict
  alias Fleet.Pilot.StepRunConsumer.VerdictCorrection

  defstruct [
    :repo,
    :remote,
    :forge_opts,
    :role_emails,
    :step_run_completer,
    :forge_client,
    :loader,
    :deliverable,
    :deliverable_mode_fun,
    :task_queue,
    :spawner,
    :wake_recovery,
    :escalate_fun,
    ops_root: nil,
    gate_evals: %{},
    gate_eval_ttl_ms: nil,
    gate_eval_sweep_ms: nil,
    step_run_runner: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @step_run_task_supervisor Fleet.Pilot.StepRunTaskSupervisor
  @gate_eval_ttl_ms 7_200_000
  @gate_eval_sweep_ms 600_000

  @doc false
  @spec task_supervisor() :: module()
  def task_supervisor, do: @step_run_task_supervisor

  @doc """
  Counts live completion tasks for graceful shutdown. Returns `0` when the supervisor is absent and
  `:unknown` when a present supervisor cannot be queried. `CI-02`.
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

  @doc false
  @spec offload_async((-> any()), map()) ::
          {:ok, :inline | :offloaded} | {:error, :inline_crashed}
  def offload_async(fun, meta \\ %{}),
    do:
      Fleet.Pilot.Offload.async_or_inline(
        @step_run_task_supervisor,
        fun,
        {"StepRunConsumer", "completion lost", meta}
      )

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      remote: Keyword.get(opts, :remote),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: Keyword.get(opts, :role_emails, &default_role_emails/1),
      step_run_completer: Keyword.get(opts, :step_run_completer, Fleet.Pilot.StepRunCompleter),
      forge_client: Keyword.get(opts, :forge_client),
      loader: Keyword.get(opts, :loader, Fleet.Workflow.Loader),
      deliverable: Keyword.get(opts, :deliverable),
      # Role resolution needs both role and catalogue root when no effective mode travels in the payload.
      deliverable_mode_fun: Keyword.get(opts, :deliverable_mode_fun, &default_deliverable_mode/2),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      escalate_fun:
        Keyword.get(opts, :escalate_fun, &Fleet.Pilot.IncidentRegistry.escalate_gated/5),
      gate_evals: %{},
      gate_eval_ttl_ms: Keyword.get(opts, :gate_eval_ttl_ms, @gate_eval_ttl_ms),
      gate_eval_sweep_ms: Keyword.get(opts, :gate_eval_sweep_ms, @gate_eval_sweep_ms),
      step_run_runner: Keyword.get(opts, :step_run_runner),
      ops_root: Keyword.get(opts, :ops_root)
    }

    Logger.info(
      "StepRunConsumer: start (MULTI-PROJECT: repo/remote per-step-run) " <>
        "fallback_repo=#{inspect(state.repo)} fallback_remote=#{inspect(state.remote)}"
    )

    Process.send_after(self(), :sweep_gate_evals, state.gate_eval_sweep_ms)

    # Defer replay until after init so boot does not wait on forge writes.
    # A self-message starts replay promptly but cannot guarantee completion before poller reclamation.
    if Keyword.get(opts, :replay_outbox, true), do: send(self(), :replay_completion_outbox)

    {:ok, state}
  end

  # Reprocess retained payloads; entries may already have partial or complete forge effects.
  @impl GenServer
  def handle_info(:replay_completion_outbox, state) do
    case CompletionOutbox.pending() do
      [] ->
        {:noreply, state}

      entries ->
        Logger.info(
          "StepRunConsumer: #{length(entries)} completion(s) DUE au demarrage — reprise " <>
            "(chaine idempotente : les etapes deja faites sautent, aucun run d'agent)"
        )

        Enum.reduce(entries, {:noreply, state}, fn payload, {:noreply, acc} ->
          handle_pod_completed(payload, acc)
        end)
    end
  end

  @impl GenServer
  def handle_info(%Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    Fleet.Shutdown.Quiesce.busy(fn -> handle_pod_completed(p, state) end)
  end

  def handle_info(
        %Event{source: :task_queue, type: :"work_item.completed", correlation_id: corr} =
          ev,
        state
      )
      when is_binary(corr) do
    if arch_escalation_resolved?(ev) do
      _ = drain_awaits_arch(ev, state)
      {:noreply, state}
    else
      resume_or_reconstruct(ev, corr, state)
    end
  end

  def handle_info(
        %Event{source: :task_queue, type: :"work_item.cleared", correlation_id: corr},
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

  def handle_info(%Event{}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Fleet.Pilot.Offload.handle_down(ref, pid, reason) do
      {:handled, {:died, death_reason, %{pod_id: pod_id} = meta}}
      when is_binary(pod_id) and pod_id != "" ->
        emit_publish_lost(pod_id, death_reason, meta)

      _nominal_metaless_or_not_mine ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp emit_publish_lost(pod_id, death_reason, meta) do
    _ =
      Bus.safe_emit(
        :workflow,
        :"deliverable.publish_lost",
        [
          pod_id: pod_id,
          correlation_id: meta |> Map.get(:issue) |> to_string(),
          payload: %{"reason" => death_reason |> inspect() |> String.slice(0, 200)}
        ],
        context: "StepRunConsumer: deliverable.publish_lost (completion task died, non-fatal)"
      )

    :ok
  end

  # Journal before processing. Returned journal errors allow completion to continue;
  # purge sees the runner's return, which may be admission rather than forge completion.
  defp handle_pod_completed(p, state) do
    _ = journalise_completion(p)

    outcome = maybe_complete(p, state)
    _ = purge_outbox(p, outcome)
    completion_reply(p, outcome, state)
  end

  defp journalise_completion(p) do
    case CompletionOutbox.put(p) do
      {:ok, _key} ->
        :ok

      {:error, :no_work_item_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: completion NON journalisee #{p["issue_id"]} (#{inspect(reason)}) — " <>
            "elle se deroule, mais une mort de la Task la perdrait (6-127)"
        )
    end
  end

  # Remove on ok/skip/escalate, retain returned errors. Offload ok purges before the Task
  # finishes; escalation also removes the original while its continuation lives in RAM/broker.
  defp purge_outbox(p, {:ok, _}), do: CompletionOutbox.delete(p)
  defp purge_outbox(p, {:skip, _}), do: CompletionOutbox.delete(p)
  defp purge_outbox(p, {:escalate, _, _}), do: CompletionOutbox.delete(p)
  defp purge_outbox(_p, _outcome), do: :ok

  defp completion_reply(_p, {:ok, _outcome}, state), do: {:noreply, state}

  defp completion_reply(p, {:escalate, corr, eval_ctx}, state) do
    Logger.info(
      "StepRunConsumer: gate→gatekeeper #{p["issue_id"]} step=#{eval_ctx.step} corr=#{inspect(corr)}"
    )

    eval_ctx = Map.put(eval_ctx, :stored_at, System.monotonic_time(:millisecond))

    {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}
  end

  defp completion_reply(p, {:skip, reason}, state) do
    Logger.debug("StepRunConsumer: skip #{p["issue_id"]} (#{inspect(reason)})")
    {:noreply, state}
  end

  defp completion_reply(p, {:error, reason}, state) do
    Logger.warning("StepRunConsumer: end-of-step-run FAIL #{p["issue_id"]}: #{inspect(reason)}")
    {:noreply, state}
  end

  # Undated contexts are retained.
  defp fresh?(%{stored_at: at}, now, ttl) when is_integer(at), do: now - at < ttl
  defp fresh?(_ctx, _now, _ttl), do: true

  defp do_resume_gate(eval_ctx, ev, corr, state) do
    case resume_gate(eval_ctx, ev.payload, step_run_state(eval_ctx.payload, state)) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: gate resume FAIL corr=#{inspect(corr)}: #{inspect(reason)}"
        )
    end
  end

  defp resume_or_reconstruct(ev, corr, state) do
    case Map.pop(state.gate_evals, corr) do
      {nil, _} ->
        case reconstruct_eval_ctx(ev.payload, state) do
          {:ok, eval_ctx} ->
            do_resume_gate(eval_ctx, ev, corr, state)
            {:noreply, state}

          :not_gate_eval ->
            {:noreply, state}
        end

      {eval_ctx, gate_evals} ->
        state = %{state | gate_evals: gate_evals}
        do_resume_gate(eval_ctx, ev, corr, state)
        {:noreply, state}
    end
  end

  defp arch_escalation_resolved?(%Event{payload: payload}) when is_map(payload) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    is_map(meta) and Map.get(meta, "awaits_arch") == true
  end

  defp arch_escalation_resolved?(_), do: false

  defp drain_awaits_arch(%Event{payload: payload}, state) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}
    repo = Map.get(meta, "repo")
    number = Map.get(meta, "number")
    forge = state.forge_client || Fleet.Forge.Client

    if is_binary(repo) and is_integer(number) do
      case forge.remove_label(repo, number, Fleet.Labels.awaits_arch(), state.forge_opts) do
        {:ok, _} ->
          Logger.info(
            "StepRunConsumer: awaits-arch drained on #{repo}##{number} (arch resolved) → poller serves the next"
          )

        {:error, reason} ->
          # The label still blocks worker dispatch; report the failed drain through the incident seam.
          drain_failed(repo, number, {:remove_label_failed, reason}, state)
      end
    else
      # Without a valid target, only the incident path can name the failure.
      drain_failed(repo, number, {:metadata_incomplete, meta}, state)
    end

    :ok
  end

  # Report a stuck drain with target-keyed gating; unknown targets share one signature.
  # The escalation result is ignored and exceptions propagate, so no durable incident is guaranteed.
  # Worker exclusion does not imply that ArchWake/Poller cannot re-offer the issue.
  defp drain_failed(repo, number, cause, state) do
    target = if is_binary(repo) and is_integer(number), do: "#{repo}##{number}", else: "unknown"

    Logger.error(
      "StepRunConsumer: awaits-arch NOT drained on #{target} (#{inspect(cause)}) — the label " <>
        "STAYS and the dispatcher skips every issue that carries it: this ticket has left the " <>
        "pipeline and no tick will re-offer it"
    )

    escalate = state.escalate_fun || (&Fleet.Pilot.IncidentRegistry.escalate_gated/5)

    _ =
      escalate.(
        :awaits_arch_stuck,
        target,
        cause,
        "awaits_arch_stuck:#{target}",
        state.forge_opts
      )

    :ok
  end

  defp reconstruct_eval_ctx(payload, state) when is_map(payload) do
    meta = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

    if is_map(meta) and meta["gate_eval"] == true do
      with rp when is_map(rp) <- meta["resume_payload"],
           workflow_map_name when is_binary(workflow_map_name) <- meta["workflow_map"],
           step when is_binary(step) <- meta["step"],
           role when is_binary(role) <- meta["resume_role"],
           n when is_integer(n) <- meta["resume_n"],
           {:ok, workflow_map} <- load_workflow_map(state, workflow_map_name, meta["repo"]) do
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

  @doc false
  @spec maybe_complete(map(), term()) ::
          {:ok, term()} | {:skip, term()} | {:escalate, term(), map()} | {:error, term()}
  def maybe_complete(payload, state) do
    cond do
      Map.has_key?(payload, "workflow_map_id") ->
        {:skip, :workflow_map_pod}

      not project_payload?(payload) ->
        {:skip, :no_project}

      true ->
        case parse_issue_number(payload["issue_id"]) do
          {:ok, n} -> run_step_run(payload, n, step_run_state(payload, state))
          :error -> {:skip, {:bad_issue_id, payload["issue_id"]}}
        end
    end
  end

  defp step_run_state(payload, state) do
    case GateEngine.payload_repo(payload) do
      repo when is_binary(repo) and repo != "" ->
        %{state | repo: repo, remote: payload["remote"] || state.remote}

      _ ->
        state
    end
  end

  defp run_step_run(payload, n, state) do
    role = payload["role"]

    case producer?(role, payload, state) do
      {:error, reason} ->
        TerminalEscalation.escalate_terminal_error(reason, n, role, terminal_seams(state))

      {:ok, is_producer?} ->
        run_step_run_classified(payload, n, role, is_producer?, state)
    end
  end

  # Only workflow_map_load_failed emits this draft; terminal categories also request architect action.
  defp gate_error(reason, n, role, state) do
    emit_workflow_map_failed_draft(reason, n, role)

    if TerminalEscalation.terminal_escalate?(reason),
      do: TerminalEscalation.escalate_terminal_error(reason, n, role, terminal_seams(state)),
      else: {:error, reason}
  end

  defp run_step_run_classified(payload, n, role, is_producer?, state) do
    if is_producer? and
         TerminalEscalation.blocked_flag?(
           Verdict.unwrap_worker_envelope(payload["result"] || %{})
         ) do
      TerminalEscalation.escalate_blocked_producer(payload, n, role, terminal_seams(state))
    else
      case GateEngine.resolve_next(payload, n, gate_seams(state), is_producer?) do
        {:error, reason} ->
          gate_error(reason, n, role, state)

        {:escalate, corr, eval_ctx} ->
          {:escalate, corr, eval_ctx}

        {:judge_verdict, decision, trace, ctx} ->
          apply_verdict(decision, trace, ctx, state)

        {:ok, intent, {next_assignee, next_step}} ->
          complete_business_step_run(
            payload,
            n,
            role,
            %{
              intent: intent,
              next_assignee: next_assignee,
              next_step: next_step,
              comment_body: nil,
              judge_target: nil
            },
            state,
            is_producer?
          )
      end
    end
  end

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

  defp completer_opts(state),
    do: [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

  defp run_completion(state, label, fun) when is_function(fun, 0),
    do: run_completion(state, label, %{}, fun)

  # A runner may return before exec completes; errors log inside the closure but do not
  # update the outbox there. Orphan reclamation re-dispatches work, not this saved result.
  defp run_completion(state, label, meta, fun) do
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

    case state.step_run_runner do
      nil -> run_sync(exec)
      runner when is_function(runner, 2) -> runner.(exec, meta)
      runner when is_function(runner, 1) -> runner.(exec)
    end
  end

  defp run_sync(fun), do: fun.()

  # The caller supplies a named route; execution/building is deferred together.
  defp complete_business_step_run(payload, n, role, route, state, producer?) do
    run_completion(state, "##{n}", %{pod_id: payload["pod_id"], issue: n}, fn ->
      case StepRunBuild.build(payload, n, role, route, build_seams(state), producer?) do
        {:error, _} = err ->
          err

        step_run when is_map(step_run) ->
          hc_opts = completer_opts(state) |> Opts.maybe_put(:deliverable, state.deliverable)
          state.step_run_completer.complete_pr(step_run, hc_opts)
      end
    end)
  end

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

  defp producer?(role, payload, state),
    do:
      GateEngine.producer?(
        role,
        state.deliverable_mode_fun,
        payload["deliverable_mode"],
        GateEngine.catalogue_root(payload)
      )

  @doc false
  # Resolve each role in its event catalogue; nil uses the default image.
  # An unloadable profile must not silently reclassify a producer as a judge.
  @spec default_deliverable_mode(String.t(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, :cap_profile_unloadable}
  def default_deliverable_mode(role, root \\ nil) do
    case Fleet.CapProfile.load(role, root) do
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

  defp escalation_seams(state) do
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
  # Resumption returns the completion runner's open result contract.
  @spec resume_gate(map(), map(), term()) :: term()
  def resume_gate(
        %{n: _n, role: _role, payload: _payload, workflow_map: _workflow_map, step: _step} = ctx,
        raw_payload,
        state
      ) do
    result = Verdict.gate_result(raw_payload)

    # Preserve invalid_reason on the resumed path as well as direct gate decoding.
    {decision, invalid_reason} = Verdict.gate_decision_with_reason(result)
    trace = Verdict.verdict_comment("gatekeeper (juge d'exception §L441)", decision, result)
    apply_verdict(decision, trace, Map.put(ctx, :invalid_reason, invalid_reason), state)
  end

  defp apply_verdict(
         decision,
         trace,
         %{n: n, role: role, payload: payload, workflow_map: workflow_map, step: step} = ctx,
         state
       ) do
    # Gate traces use gate-verdicts, separate from deliverable verdicts for the same issue/role.
    # Pinning may summarize long traces; short ones remain inline.
    trace =
      Fleet.Workflow.Pinning.render(trace,
        work_dir: verdict_work_dir(state),
        ref: Fleet.Layout.gate_verdict_ref(n, role),
        kind: "Verdict",
        label: "gate-verdict",
        repo: state.repo
      )

    case decision do
      "continue" ->
        # Reclassify on this shared direct/resume path, then use the same terminal intent rule:
        # producer -> review, nonproducer -> promote, next step -> advance.
        with {:ok, is_producer?} <- producer?(role, payload, state),
             {:ok, intent, {next_assignee, next_step}} <-
               GateEngine.advance_intent(workflow_map, step, is_producer?) do
          complete_business_step_run(
            payload,
            n,
            role,
            %{
              intent: intent,
              next_assignee: next_assignee,
              next_step: next_step,
              comment_body: trace,
              judge_target: Map.get(ctx, :judge_target)
            },
            state,
            is_producer?
          )
        end

      "abandon" ->
        arch_trace =
          "**Architecte** (auteur du brief) — brief ABANDONNÉ par le juge. " <>
            trace <> " (Non récupérable ; re-crée un brief corrigé si besoin.)"

        # Notify inside the closure only after successful close, even when runner admission returns early.
        close_with_trace(n, role, arch_trace, state, fn ->
          TerminalEscalation.kick_architect(state.spawner, state.repo, arch_trace)
        end)

      # Invalid envelope is a format failure, not an authored refusal. VerdictCorrection owns
      # its flag/budget and attempts reuse; this point does not prove the judge pod is still alive.
      "halt_invalid" ->
        VerdictCorrection.request(
          n,
          role,
          # Direct and resumed decoding normally provide invalid_reason.
          Map.get(ctx, :invalid_reason) || "enveloppe `gate-decision.json` invalide",
          trace,
          %VerdictCorrection.Seams{
            repo: state.repo,
            forge: state.forge_client,
            forge_opts: state.forge_opts,
            task_queue: state.task_queue,
            spawner: state.spawner,
            terminal: terminal_seams(state)
          }
        )

      other ->
        # Freeze through the shared terminal path; avoid a second audit event for the same action.
        TerminalEscalation.freeze_to_arch(n, role, other, trace, terminal_seams(state))
    end
  end

  defp emit_workflow_map_failed_draft({:workflow_map_load_failed, name, msg}, n, role) do
    case Bus.safe_emit(
           :workflow,
           :"workflow_map.failed",
           [
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

  # Missing directory leaves trace inline; missing repo cannot name an ops worktree.
  # Directory absence alone does not establish onboarding history.
  defp verdict_work_dir(%{repo: repo, ops_root: ops_root}) when is_binary(repo) do
    dir = Path.join(ops_root || Fleet.Layout.ops_root(), Fleet.Layout.project_name(repo))
    if File.dir?(dir), do: dir
  end

  defp verdict_work_dir(_state) do
    Logger.warning(
      "StepRunConsumer: verdict NOT pinned — this event names no repo, so no ops face can be " <>
        "addressed (a producer defect, not a missing face); the trace posts inline"
    )

    nil
  end

  # `on_closed` runs inside the completion closure, only on `{:ok, _}` — whatever the runner.
  defp close_with_trace(n, role, trace, state, on_closed) when is_function(on_closed, 0) do
    step_run = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      deliverable_opts: nil,
      step_run_sha: "gate-abandon",
      next_assignee: nil,
      # Declare retirement at the verdict site; do not infer it from a signature downstream.
      closure: :retired,
      comment_body: trace
    }

    run_completion(state, "##{n}", fn ->
      result = state.step_run_completer.complete(step_run, completer_opts(state))

      case result do
        {:ok, _} -> _ = on_closed.()
        _ -> :ok
      end

      result
    end)
  end

  # Reconstruction uses metadata repo, then configured fallback, to select the card catalogue.
  defp load_workflow_map(state, workflow_map_name, repo),
    do:
      Fleet.Pilot.WorkflowMapNav.safe_load(
        state.loader,
        workflow_map_name,
        Fleet.Workflow.Loader.card_opts_for_repo(repo || Map.get(state, :repo))
      )

  defp project_payload?(p) do
    is_binary(p["workspace"]) and is_binary(p["base_sha"]) and p["base_sha"] != "" and
      is_binary(p["role"])
  end

  @doc false
  @spec parse_issue_number(String.t()) :: {:ok, integer()} | :error
  defdelegate parse_issue_number(issue_id), to: Fleet.Pilot.IssueId, as: :parse

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
