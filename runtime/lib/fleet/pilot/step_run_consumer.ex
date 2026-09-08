defmodule Fleet.Pilot.StepRunConsumer do
  @moduledoc """
  Bus consumer for **step-run completion** (the forge IS the state machine; this module reacts to it).
  Subscribes to `Fleet.EventRouter.Bus` (topic `fleet.events`); on each
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` from a
  **step-dispatch** pod (assignee-driven), translates the event into a `step_run` and delegates the
  completion sequence to `Fleet.Pilot.StepRunCompleter`.

  ## Sub-modules

  Each is a hardened boundary reading a NARROW `Seams` struct, never the whole `state`. The
  decision engine returns an INTENT; acting on it is this module's job, never the engine's.

  THIS module keeps: the Bus GenServer, the async-resumption state, the verdict application, the
  sync/offload execution discipline, and the per-step-run derivation of the state.

  ## Gatekeeper = exception (escalation), NOT a step

  The gate of the finished step decides BEFORE advancing (`Fleet.Workflow.Gates.evaluate/3`,
  PURE):

    * `:pass`                  → advances in the workflow_map (next_step).
    * `{:fail, _}`             → bounded REBOUND to the 1st step (anti-runaway rework).
    * `{:dispatch_gatekeeper}` → **escalation**: an undecidable `soft` gate is NOT a scheduling
      step, it is a SUMMONS of the one-shot per-project judge. The eval brief is enqueued, the
      resume context is held in RAM, and the decision comes back ASYNC.

  ⚠ The judge is **rare BY CONSTRUCTION**: the engine cannot over-summon it, because the
  undecidable is a *runtime condition* and not a *step tag*. There is no `role: gatekeeper` step
  and no `soft⟺gatekeeper` biconditional — the decision is forge-driven.

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
    * `:ops_root` — root of the ops faces (default `Fleet.Layout.ops_root/0`), where a gate verdict
      is pinned; a seam because the real root is a hardcoded global path
    * `:escalate_fun` — the incident rail (default `IncidentRegistry.escalate_gated/5`)
    * `:gate_eval_ttl_ms` / `:gate_eval_sweep_ms` — the bound on the in-RAM gate contexts
    * `:step_run_runner` — completion offload seam. Default `nil` → **SYNC** (the outcome bubbles up,
      seams/tests unchanged). Prod (`application.ex`) injects `&offload_async/2` → the completion (git push
      ≤30s + forge writes) runs in a `Task.Supervisor`: the **singleton StepRunConsumer does not block**
      (and a `.complete` that crashes is isolated by the supervised task). An arity-1 runner stays a
      valid seam shape (legacy tests) — it simply carries no death-witness meta (BL-6-03 S2).
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
    # Seam d'escalade — meme forme que `:wake_recovery` : injecte par un test pour observer
    # l'incident sans ouvrir d'issue, resolu vers `IncidentRegistry.escalate_gated/5` en prod.
    :escalate_fun,
    # Seam of the ops root (default `Fleet.Layout.ops_root/0`), an init option here where the
    # completer takes it per call — same reason: the real root is a hardcoded global path, and
    # without it no test can watch a gate verdict get pinned.
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
      # ⚠ ARITE 2, CELLE DU SEAM. `GateEngine.producer?/4` appelle `fun.(role, root)` ; le defaut etait
      # `&default_deliverable_mode/1` — un BadArityError des qu'un work item arrive sans
      # `deliverable_mode` dans son payload (AwaitsArchDrainTest, suite complete du 2026-09-06 : vert
      # seul, rouge selon l'ordre — le defaut n'etait jamais appele quand le payload portait le mode).
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

    # 6-127 — LA REPRISE EST POSTEE, PAS FAITE DANS `init/1`. Une completion est une suite
    # d'ecritures forge : la jouer ici bloquerait le demarrage du rail sur du reseau, et un
    # superviseur qui attend son enfant est un rail qui ne demarre pas. On se l'envoie a soi-meme :
    # le GenServer est vivant, la reprise s'execute comme n'importe quel message.
    #
    # ⚠ ELLE DOIT PRECEDER LA RECLAMATION DU POLLER, et c'est le cas : la reclamation d'un verrou
    # orphelin attend une grace de 2 ticks (~60 s), la reprise part au premier message apres le
    # boot. Si elle perdait la course, le pire est un re-dispatch — l'etat d'avant 6-127.
    if Keyword.get(opts, :replay_outbox, true), do: send(self(), :replay_completion_outbox)

    {:ok, state}
  end

  # 6-127 — CE QUI RESTE DANS LE JOURNAL AU DEMARRAGE EST, PAR CONSTRUCTION, UNE COMPLETION DUE :
  # l'entree est posee avant que la chaine ne tourne et retiree quand elle a fini. On la rejoue par
  # le MEME chemin que la premiere fois (`maybe_complete/2`), ce qui est exactement ce que le
  # `@moduledoc` de `StepRunCompleter` promet : « recovery replays the sequence, the done steps
  # skip ».
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
    # CI-02
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

  # BL-6-03 S2
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

  # 6-127 — LE RESULTAT EST POSE AVANT QUE LA CHAINE NE TOURNE, ET RETIRE QUAND ELLE A FINI.
  #
  # `TaskQueue` a deja marque l'item `completed` quand on arrive ici : la charge utile est la SEULE
  # copie du travail de l'agent. Sans journal, une Task de completion qui meurt l'emporte, et le
  # poller reclame l'orphelin puis fait REFAIRE le travail. Le journal la rend reprenable.
  #
  # ⚠ UNE ERREUR DE JOURNALISATION N'EST PAS FATALE, ET C'EST DELIBERE : la completion se deroule de
  # toute facon, elle ne sera simplement pas reprenable — l'etat d'avant cette fiche. Refuser de
  # completer parce qu'on n'a pas pu ecrire un fichier echangerait une degradation bornee contre un
  # blocage.
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

  # RETRAIT SUR LES SEULS ETATS OU IL N'Y A PLUS RIEN A REPRENDRE. `{:error, _}` GARDE l'entree :
  # c'est precisement le cas que la fiche vise (chaine interrompue), et la rejouer est sans effet
  # sur les etapes deja faites.
  #
  # ⚠ `{:escalate, …}` RETIRE, et le trou est nomme plutot que comble a moitie : ce chemin range
  # son contexte d'evaluation EN MEMOIRE (`state.gate_evals`), donc un redemarrage le perd de toute
  # facon. Le rendre durable est un AUTRE mecanisme, et la preuve de sortie de 6-127 ne porte pas
  # sur lui — ses trois points de mort (avant push, apres push avant PR, apres PR avant unlock)
  # sont tous DANS la chaine, couverts ci-dessus.
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
          # LE POLLER NE RE-OFFRE RIEN, IL PASSE : l'etiquette reste posee, et
          # `StepDispatcher.decide/1` SAUTE toute issue qui la porte. Le ticket quitte le pipeline
          # pour de bon.
          drain_failed(repo, number, {:remove_label_failed, reason}, state)
      end
    else
      # Meme sortie, autre cause : on ne sait meme pas QUELLE issue deverrouiller. Rien ici ne peut
      # nommer un numero, donc rien ne peut agir sur la forge — l'incident est le seul canal qui
      # n'exige pas de connaitre la cible.
      drain_failed(repo, number, {:metadata_incomplete, meta}, state)
    end

    :ok
  end

  # UN TICKET QUI SORT DU PIPELINE NE SORT PLUS EN SILENCE. Les deux branches d'echec du drain
  # laissent `lcars-awaits-arch` en place, et `StepDispatcher.decide/1` saute toute issue qui la
  # porte (`{:skip, :awaits_arch}`) : le ticket est retire du pipeline DEFINITIVEMENT, et seule une
  # intervention humaine le debloque. Un `Logger.warning` ne survit pas a la nuit ; un incident est
  # une issue durable sur la forge, ce que la doctrine D1 exige pour tout ce qui est load-bearing.
  #
  # `escalate_gated/5` plutot que `escalate/5` : la signature porte le repo et le numero quand on
  # les a, donc une resolution qui echoue en boucle sur le meme ticket ouvre UNE issue, pas une par
  # occurrence. Sur la branche sans metadonnees, la signature retombe sur la cause seule — c'est le
  # mieux qu'on puisse nommer, et c'est deja mieux que rien.
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

  # F-037
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

    # DR-013
    case producer?(role, payload, state) do
      {:error, reason} ->
        TerminalEscalation.escalate_terminal_error(reason, n, role, terminal_seams(state))

      {:ok, is_producer?} ->
        run_step_run_classified(payload, n, role, is_producer?, state)
    end
  end

  # LE BROUILLON PART DANS TOUS LES CAS, l'escalade seulement pour les causes terminales : un
  # `workflow_map` illisible doit laisser une trace lisible meme quand il ne merite pas de reveiller
  # l'architecte.
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

  # BL-6-03 S2
  #
  # ⚠ CE POINT N'EST PAS UNE SAGA, ET LE RESULTAT DE L'AGENT EST DEJA CONSOMME QUAND ON Y ARRIVE :
  # le work item est persiste `completed` AVANT que cette chaine ne tourne, et la chaine est une
  # suite de mutations forge. Une erreur transitoire APRES une mutation reussie laisse donc un etat
  # partiel, que rien ici ne rejoue.
  #
  # CE QUI RATTRAPE, ET CE QUI NE RATTRAPE PAS :
  #   * le VERROU n'est pas perdu — un step_run interrompu laisse une issue dont plus aucun pod ne
  #     possede le ref, donc reclamation d'orphelin puis re-dispatch ;
  #   * le RESULTAT, lui, est consomme — le re-dispatch REFAIT travailler un agent, il ne reprend
  #     pas la chaine ou elle s'est arretee.
  #
  # Degradation BORNEE, pas un blocage, et c'est la seule promesse tenable sans etat durable : la
  # rendre reprenable demande une saga persistee a points de controle idempotents, qui est une
  # question de conception a trancher ailleurs qu'au detour d'un site.
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

  # ⚠ LA ROUTE ARRIVE DEJA FORMEE, ET C'EST L'APPELANT QUI LA CONNAIT. Ses cinq champs voyageaient
  # en positionnels pour etre recomposes en map des la premiere ligne : deux d'entre eux
  # (`next_assignee`, `next_step`) sortent d'un meme tuple chez les deux appelants, et les deux
  # derniers etaient des defauts optionnels qu'un appel sur trois oubliait de nommer.
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
  # The ROOT is the project's catalogue, threaded from the work item's repo. Without it this
  # would resolve every role in the FIRST active catalogue's image: a `dev` of `web` looked up
  # among `fleet`'s roles, absent there, and the step fails loud on a role that exists — the wedge
  # the boot validators cannot catch, because it only happens when a step of a second catalogue's
  # project runs. `nil` keeps the default image, which is what a single-catalogue deployment and
  # every test fixture want.
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
  # Le retour reste ouvert PAR CONSTRUCTION : il descend dans `apply_verdict`, qui rend soit le
  # resultat de `close_with_trace`, soit celui de `freeze_to_arch` — les deux traversant la couture
  # `run_completion` (`(String.t(), (-> term()) -> term())`). Le resserrer serait inventer un
  # contrat que la couture ne tient pas.
  @spec resume_gate(map(), map(), term()) :: term()
  def resume_gate(
        %{n: _n, role: _role, payload: _payload, workflow_map: _workflow_map, step: _step} = ctx,
        raw_payload,
        state
      ) do
    result = Verdict.gate_result(raw_payload)

    # Le SECOND chemin vers `apply_verdict`, et il doit porter le motif comme le premier : sinon la
    # passe de correction (B4) est detaillee sur une moitie du rail et generique sur l'autre.
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
    # SUMMARY + POINTER above the threshold, at the ONE site every emission path of this trace goes
    # through. The trace is composed from the judge's `reason`/`details`/`chain`, so its length is
    # the judge's and not ours; below ten lines `render/2` hands it back untouched and nothing is
    # written.
    #
    # `gate-verdicts/`, not `verdicts/`: the deliverable review already owns the second tree for the
    # same (issue, role) pair, and these are two different acts — one judges a DELIVERY, this one
    # records a gate decision. Same axis the brief trees already use (`briefs/` worker order,
    # `gate-briefs/` judge order), so the vocabulary was already there.
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
        # RESOLVED HERE, NOT RECEIVED: `apply_verdict/4` is shared with `resume_gate/3` (a verdict
        # resumed from the broker after a consumer restart), where no step-run fact is in scope.
        # The one site of the rail that derives the producer fact twice, and the reason is the
        # second door.
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

        # THE KICK IS INSIDE THE CLOSURE, AFTER THE CLOSE SUCCEEDED — the same order
        # `TerminalEscalation.freeze_to_arch/5` keeps (« vérifier puis annoncer »). Outside the
        # closure it would run before the close in offload mode: `run_completion` hands the closure
        # to the runner and returns `{:ok, :offloaded}` at once, and the architect would hear of
        # an abandon the forge has not recorded — or never records (2026-09-05, witness with a
        # runner that holds the closure).
        close_with_trace(n, role, arch_trace, state, fn ->
          TerminalEscalation.kick_architect(state.spawner, state.repo, arch_trace)
        end)

      # B4 — UNE ENVELOPPE MALFORMEE N'EST PAS UN VERDICT QU'ON NE PEUT PAS SATISFAIRE.
      #
      # Le repli fail-closed porte sur la FORME : le juge a lu le livrable, il a une opinion, il l'a
      # mal emballee — et le geler immobiliserait un humain pour un champ mal type. Une passe de
      # correction, une seule, bornee par un marqueur forge.
      #
      # ⚠ LE POD EST ENCORE LA POUR LA RECEVOIR : aucune fauche n'est declenchee par la PRODUCTION
      # d'un verdict, seulement par son INGESTION — et une enveloppe refusee n'est pas ingeree. Le
      # juge vit donc encore, avec la lecture du livrable qui lui a coute son contexte.
      #
      # Auto-gate et ETEINT par defaut : au-dela de la passe, ou si elle n'est pas armee, c'est
      # exactement le gel d'avant — en nommant pourquoi.
      "halt_invalid" ->
        VerdictCorrection.request(
          n,
          role,
          # Repli, jamais le cas nominal : les deux chemins qui atteignent ce point posent
          # `:invalid_reason`. Il couvre un ctx construit ailleurs un jour.
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
        # (Pas de second evenement `audit.verdict` ici : il re-dirait CE gel a une machinerie de
        # coordination dont le terminus re-emet un evenement. Le gel ci-dessous EST le chemin :
        # l'arch est reveille, le ticket est fige.)
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

  # The project's ops worktree, or nil when there is none. A project never onboarded has
  # nowhere to pin, and `Pinning.render/2` then leaves the trace inline — the same degradation the
  # brief materialization already takes on that path.
  # `nil` when the project has no ops face (nowhere to pin; `Pinning.render/2` leaves the body
  # inline) or when this event carries no repo — `Layout.project_name/1` refuses a nil rather than
  # naming a directory that is nobody's.
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
      # Fermeture SANS livraison : rien n'a ete livre, donc `stage/retired` et non `stage/merged`.
      # Declare ICI, ou le verdict est connu, plutot que devine plus bas a partir du `step_run_sha`.
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

  # The repo of the EVENT, falling back to the singleton's configured one: the card that answers an
  # engraved name is the project's own, and this consumer serves every catalogue's projects.
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
