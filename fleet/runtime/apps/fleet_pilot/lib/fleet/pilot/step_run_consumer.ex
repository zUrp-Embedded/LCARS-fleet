defmodule Fleet.Pilot.StepRunConsumer do
  @moduledoc """
  Consumer Bus de la **fin-de-step-run** (la forge EST la machine à états ; ce module en réagit).
  Subscribe `Fleet.EventRouter.Bus` (topic `fleet.events`) ; sur chaque
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` d'un pod
  **step-dispatch** (assignee-driven), traduit l'event en `step_run` et délègue la
  séquence de complétion à `Fleet.Pilot.StepRunCompleter`.

  ## Gatekeeper = exception (escalade), PAS un step

  La gate du step fini décide AVANT d'avancer (`Fleet.Workflow.Gates.evaluate/3`,
  PUR) :

    * `:pass`                  → avance dans la workflow_map (next_step).
    * `{:fail, _}`             → REBOND borné vers le 1er step (rework anti-runaway).
    * `{:dispatch_gatekeeper}` → **escalade** : une gate `soft` ou `terminal`
      non-tranchable n'est PAS un step d'ordonnancement — c'est une convocation
      du **gatekeeper permanent** (juge d'exception). On enqueue
      un brief d'éval au gatekeeper (work-session, adressé par `pod_id` via
      TaskQueue/MCP), on tient le contexte de reprise en RAM (`gate_evals`, keyé
      par `correlation_id`), et la décision revient async via
      `%Fleet.Event{source: :task_queue, type: :"work_item.completed"}` → `resume_gate/3`.

  Le juge est **rare par construction** : le moteur ne peut pas le sur-convoquer
  (le `soft`/non-tranchable est une *condition runtime*, pas un *tag de step*).
  Pas de step `role: gatekeeper`, pas de biconditionnelle `soft⟺gatekeeper` —
  toute la machinerie explicit-step est retirée. Ce module REMPLACE l'ancien
  chaînage gatekeeper du moteur RAM `Fleet.Workflow.Executor` (`do_dispatch_gatekeeper`/
  `handle_gate_decision`), SUPPRIMÉ : il refait la même décision, mais forge-driven.

  ## Garde résiduelle `workflow_map_id`

  Le moteur RAM `Fleet.Workflow.Executor` (corrélation workflow_map_name↔step en mémoire)
  est SUPPRIMÉ — il n'y a plus de dual-run : ce consumer est le seul rail. Plus
  aucun pod n'est spawné avec `opts[:workflow_map_id]` (l'Executor était le seul
  producteur). La branche `workflow_map_id` présent → skip (L.399) subsiste comme
  **garde défensive** (un payload workflow_map_name résiduel ne serait pas traité par
  erreur), jamais déclenchée en pratique.

    * **Step-dispatch pods** — pas de `workflow_map_id`, mais (s'ils portent un
      projet) le payload embarque `workspace` + `base_sha` + `role` (enrichi à la
      source, `Fleet.Spawner.Pod.CompletedPayload`). **Ce consumer les
      traite.** L'event porte tout l'état → consumer stateless POUR LE HAPPY PATH
      (pass/fail) ; les escalades gatekeeper en attente vivent en RAM (`gate_evals`)
      comme **optimisation fast-path** — mais ce n'est plus une dépendance dure :
      le verdict est **auto-descriptif** (le metadata de la tâche d'éval
      porte le contexte de reprise → un crash du StepRunConsumer seul, broker vivant,
      reconstruit `eval_ctx` du metadata au lieu de jeter le verdict en silence).

  ## Traduction event → step_run

    * `issue_number` ← `issue_id` (`"issue-N"` → `N`)
    * `repo` ← **l'event** (`payload["repository"]["full_name"]`), per-step-run. MULTI-PROJET :
      le StepRunConsumer est un singleton qui traite les step_runs de TOUS les projets de l'humain → le repo
      (et le `remote` où pousser) ne peut PAS être figé en config ; il VOYAGE dans l'event (« l'event
      porte tout l'état »). `:repo`/`:remote` de config restent un **fallback** (single-repo legacy / test
      avec payload nu). Le state effectif d'un step_run est dérivé par `step_run_state/2` à l'entrée.
    * `remote` ← **l'event** (`payload["remote"]`, = le `repo_path` cloné = l'URL de push), per-step-run.
    * `deliverable_opts` ← `{mode: :git_native, workspace, base_sha,
      allowed_emails(role), remote, target_branch}` ; le SYSTÈME pousse
      (le pod a commité dans son workspace, le système vérifie+pousse) sur une branche système
      `lcars/issue-N-role` (merge-vers-main = ailleurs, pas ici).
    * `next_assignee: nil` → **1-step terminal** (close). Le multi-step
      (lookup du suivant dans la workflow_map) = le mode workflow_map.

  ## Config / seams

    * `:repo` — `"owner/name"` — **fallback** (le repo per-step-run vient de l'event)
    * `:remote` — URL/nom du remote où le système pousse — **fallback** (per-step-run vient de l'event)
    * `:forge_opts` — passé au ForgeClient via StepRunCompleter
    * `:role_emails` — `fn role -> [email] end` (défaut `"<role>@lcars.local"`),
      doit matcher l'identité git injectée au pod (la gate vérifie l'email du committer)
    * `:step_run_completer` — seam (défaut `Fleet.Pilot.StepRunCompleter`)
    * `:task_queue` — broker de briefs pour l'escalade gatekeeper (défaut `Fleet.TaskQueue`)
    * `:spawner` — wake du gatekeeper après enqueue (défaut `Fleet.Spawner`)
    * `:gatekeeper_pod_id_fun` — `fn -> pod_id | nil end` (défaut `&Fleet.Workflow.Gatekeeper.pod_id/0`)
    * `:subscribe` — bool défaut `true` (tests : `false` + envoi manuel)
    * `:step_run_runner` — seam d'offload de la complétion. Défaut `nil` → **SYNC** (l'outcome remonte,
      seams/tests inchangés). Prod (`application.ex`) injecte `&offload_async/1` → la complétion (git push
      ≤30s + writes forge) tourne dans une `Task.Supervisor` : le **singleton StepRunConsumer ne bloque pas**
      (et un `.complete` qui crash est isolé par la task supervisée).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.Opts

  # Cluster PUR du verdict (décodage gate-decision + rendu trace/review/voix-eng), extrait ici : aucun
  # champ `state`, opère sur le payload/result brut. Le cœur décisionnel stateful (apply_verdict,
  # gate_decide, resume_gate, complete_business_step_run) reste dans CE module.
  alias Fleet.Pilot.StepRunConsumer.Verdict

  # Cluster IMPUR « escalade gatekeeper » (async-out) : enqueue le brief d'éval + kick + télémétrie.
  # Ne lit QUE 4 seams (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery), passés en struct
  # explicite `GatekeeperEscalation.Seams` (pas `state` entier — frontière blindée). Appelé par
  # `gate_decide` sur le chemin `{:dispatch_gatekeeper, _}`. Le cœur décisionnel reste dans CE module.
  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation

  defstruct [
    :repo,
    :remote,
    :forge_opts,
    :role_emails,
    :step_run_completer,
    :forge_client,
    :loader,
    :deliverable,
    # Resout le deliverable_mode d'un role (`"git_native"` producteur / `"payload"` juge)
    # pour classer le step_run PR-natif. Defaut = catalogue cap-profile. Seam test (zero chargement).
    :deliverable_mode_fun,
    :max_rework_rounds,
    # Seams d'escalade gatekeeper.
    :task_queue,
    :spawner,
    :gatekeeper_pod_id_fun,
    # Boot du gatekeeper permanent en step-mode (ensure_booted idempotent, gardé
    # :gatekeeper_autoboot). Sans ça, en step-only rien ne boote/registre le gatekeeper →
    # pod_id/0 nil → toute escalade soft/terminal échoue {:error,:no_gatekeeper}.
    :gatekeeper_boot_fun,
    # Seam du recovery de wake du gatekeeper (défaut = la vraie fn). Permet de tester que le
    # retour LOAD-BEARING du kick (`{:error,{:escalated,_}}`) est SURFACÉ (telemetry/warning), pas avalé.
    :wake_recovery,
    # Escalades en attente, keyées par correlation_id (= task.id du brief d'éval). Valeur =
    # contexte de reprise `%{n, role, payload, workflow_map, step}`. OPTIMISATION fast-path uniquement
    # (le verdict est auto-descriptif via le metadata de la tâche → reconstructible au restart).
    gate_evals: %{},
    # Seam d'offload de la complétion. Défaut nil → `run_completion` retombe sur SYNC (l'outcome
    # remonte, seams `maybe_complete`/`resume_gate` + tous les tests inchangés). Prod = async Task.Supervisor.
    step_run_runner: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  # Superviseur de tasks pour l'offload de la complétion (prod). Nom partagé entre
  # `application.ex step_children` (qui le démarre AVANT le StepRunConsumer) et `offload_async/1`.
  @step_run_task_supervisor Fleet.Pilot.StepRunTaskSupervisor

  @doc false
  def task_supervisor, do: @step_run_task_supervisor

  # Runner ASYNC (prod, injecté en `:step_run_runner`) — offload la complétion dans la
  # `Task.Supervisor` : le git push ≤30s + writes forge ne bloquent PAS le singleton. Rend
  # `{:ok, :offloaded}` (le vrai outcome est loggé dans la task). Échec de spawn → fail-loud loggé.
  # Squelette partagé `Fleet.Pilot.Offload` (source unique) ; CE consumer garde son superviseur
  # et sa conséquence de perte (« complétion perdue »).
  @doc false
  def offload_async(fun),
    do:
      Fleet.Pilot.Offload.async(
        @step_run_task_supervisor,
        fun,
        {"StepRunConsumer", "complétion perdue"}
      )

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    # MULTI-PROJET : `:repo`/`:remote` ne sont PAS obligatoires — le singleton dérive le
    # repo (+ remote de push) per-step-run depuis l'event (`step_run_state/2`). Ils restent acceptés comme FALLBACK
    # (single-repo legacy / test avec payload nu). Pas de `{:stop, :missing_required_opt}` : un boot sans
    # repo est légitime (multi-projet) ; la garde fail-loud du rail vit côté `application.ex`
    # (forge base_url requis pour la découverte + le push).
    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      remote: Keyword.get(opts, :remote),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: Keyword.get(opts, :role_emails, &default_role_emails/1),
      step_run_completer: Keyword.get(opts, :step_run_completer, Fleet.Pilot.StepRunCompleter),
      # nil → StepRunCompleter applique son défaut (Fleet.Pilot.ForgeClient). Injectable
      # pour un backend forge alternatif (ou un sim en dogfood bare).
      forge_client: Keyword.get(opts, :forge_client),
      # Loader de workflow_map (mode workflow_map multi-step) : résout le step suivant. Défaut = Loader réel.
      loader: Keyword.get(opts, :loader, Fleet.Workflow.Loader),
      # nil → StepRunCompleter applique son défaut (Fleet.Workflow.Deliverable). Injectable (sim/test).
      deliverable: Keyword.get(opts, :deliverable),
      # Classification producteur/juge du step_run PR-natif. Defaut = catalogue cap-profile.
      deliverable_mode_fun: Keyword.get(opts, :deliverable_mode_fun, &default_deliverable_mode/1),
      # Bound anti-runaway du rebond de gate. Budget de step_runs = nb_steps *
      # (max_rework_rounds + 1) : la 1re passe + N rounds de rework. Au-delà → stuck
      # surfacé (pas de boucle). Défaut 2 rounds.
      max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2),
      # Seams d'escalade gatekeeper (défauts = broker/spawner/registry réels).
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      gatekeeper_pod_id_fun:
        Keyword.get(opts, :gatekeeper_pod_id_fun, &Fleet.Workflow.Gatekeeper.pod_id/0),
      gatekeeper_boot_fun:
        Keyword.get(opts, :gatekeeper_boot_fun, &Fleet.Workflow.Gatekeeper.ensure_booted/0),
      # Seam du recovery de wake (défaut = la vraie fn).
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      gate_evals: %{},
      # Prod (step_children) injecte `&offload_async/1` ici ; sans cette
      # lecture, `run_completion` retomberait sur sync → le git push bloquerait le singleton (offload mort).
      step_run_runner: Keyword.get(opts, :step_run_runner)
    }

    Logger.info(
      "fleet_pilot StepRunConsumer start (MULTI-PROJET F-037 : repo/remote per-step-run) " <>
        "fallback_repo=#{inspect(state.repo)} fallback_remote=#{inspect(state.remote)}"
    )

    # En step-mode, le StepRunConsumer EST le chemin actif → il assure le gatekeeper
    # permanent (handle_continue : boot hors init, OTP). Idempotent + gardé autoboot (no-op
    # en test où gatekeeper_autoboot=false ; no-op si le path RAM l'a déjà booté).
    {:ok, state, {:continue, :ensure_gatekeeper}}
  end

  @impl GenServer
  def handle_continue(:ensure_gatekeeper, state) do
    case state.gatekeeper_boot_fun.() do
      {:ok, :disabled} ->
        :ok

      {:ok, pod_id} ->
        Logger.info("StepRunConsumer: gatekeeper permanent assuré (pod=#{pod_id})")

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: ensure gatekeeper échoué (#{inspect(reason)}) — escalades KO"
        )
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    case maybe_complete(p, state) do
      # L'outcome est loggé par `run_completion` (dans la task en async), pas ici.
      {:ok, _outcome} ->
        {:noreply, state}

      # Gate non-tranchable : le brief d'éval est enqueué au gatekeeper
      # permanent ; on tient le contexte de reprise jusqu'au `work_item.completed` corrélé.
      # L'issue reste verrouillée (in-flight) → le poller ne re-spawn pas (pas d'avance
      # à l'aveugle avant le verdict).
      {:escalate, corr, eval_ctx} ->
        Logger.info(
          "StepRunConsumer gate→gatekeeper: #{p["issue_id"]} step=#{eval_ctx.step} corr=#{inspect(corr)}"
        )

        {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}

      {:skip, reason} ->
        Logger.debug("StepRunConsumer skip #{p["issue_id"]} (#{reason})")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer fin-de-step-run FAIL #{p["issue_id"]}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  # Décision du gatekeeper reçue : le brief d'éval (corrélé par
  # `correlation_id` = task.id de l'enqueue) est complété. On ne traite QUE les corr
  # qu'on a en attente (les autres work_item.completed — autres pods — sont ignorés).
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :"work_item.completed", correlation_id: corr} =
          ev,
        state
      )
      when is_binary(corr) do
    case Map.pop(state.gate_evals, corr) do
      # FAST-PATH absent : le contexte n'est pas en RAM. DEUX cas EXCLUSIFS :
      #  (a) le metadata du verdict porte `gate_eval` (escalade gatekeeper) → on RECONSTRUIT l'eval_ctx du
      #      metadata (verdict auto-descriptif) → resume. C'est le wedge fermé : crash du StepRunConsumer seul
      #      (broker vivant → la tâche + son metadata survivent) → le verdict arrive au StepRunConsumer redémarré
      #      (gate_evals vide) → reconstruction au lieu de `{:noreply}` silencieux (issue verrouillée à vie).
      #  (b) sinon → `{:noreply}` (cas NORMAL : chaque pod step-dispatch émet un `work_item.completed` sans
      #      `gate_eval` → ce n'est pas une escalade gatekeeper → on l'ignore).
      {nil, _} ->
        case reconstruct_eval_ctx(ev.payload, state) do
          {:ok, eval_ctx} ->
            do_resume_gate(eval_ctx, ev, corr, state)
            {:noreply, state}

          :not_gate_eval ->
            {:noreply, state}
        end

      # FAST-PATH : le contexte est en RAM (chemin nominal, pas de crash) → resume direct. EXCLUSIF du cas
      # reconstruction (corr présent ici ⊻ absent là) → jamais de double-resume.
      {eval_ctx, gate_evals} ->
        state = %{state | gate_evals: gate_evals}
        do_resume_gate(eval_ctx, ev, corr, state)
        {:noreply, state}
    end
  end

  # Les events d'ÉCHEC de pod (`pod.failed`/`wake.failed`) sont routés par `Fleet.Pilot.IncidentConsumer`
  # (consumer SÉPARÉ → registre d'incidents). Ici ils tombent dans le catch-all (no-op) : ce singleton ne
  # porte QUE la fin-de-step-run (complétion), pas la politique d'incidents (concern distinct, blast-radius isolé).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Exécute la reprise (commun fast-path / reconstruction). La reprise pousse/écrit sur le
  # repo du STEP_RUN escaladé (porté par le `pod.completed` d'origine, conservé dans `eval_ctx.payload`), pas sur la
  # config. Le verdict du gatekeeper arrive via un `work_item.completed` (autre event, sans repo) → on re-dérive
  # depuis le payload d'origine.
  defp do_resume_gate(eval_ctx, ev, corr, state) do
    case resume_gate(eval_ctx, ev.payload, step_run_state(eval_ctx.payload, state)) do
      # Outcome loggé par `run_completion` ; ici on ne logge que l'erreur de DÉCISION (pré-complétion).
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer gate resume FAIL corr=#{inspect(corr)}: #{inspect(reason)}"
        )
    end
  end

  # RECONSTRUIT l'eval_ctx depuis le metadata du verdict (verdict auto-descriptif), quand le
  # fast-path RAM (`gate_evals`) est vide (crash du StepRunConsumer seul). Le metadata voyage dans
  # `ev.payload[:metadata]` (posé par `task_queue/server.ex` ; clé atom). `:not_gate_eval` si absent ou pas une
  # éval gatekeeper → cas normal `{:noreply}`. `workflow_map` re-chargée du `workflow_map_name` (Loader seam — dérivable, pas
  # embarquée : trop grosse). Si le metadata est une éval mais malformé (payload/role/n manquants) → fail-loud
  # (`:not_gate_eval` log) plutôt qu'un resume sur contexte tronqué.
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
            "StepRunConsumer: metadata gate_eval mais reconstruction eval_ctx impossible " <>
              "(#{inspect(other)}) — verdict NON repris (fail-loud, pas de resume sur contexte tronqué)"
          )

          :not_gate_eval
      end
    else
      :not_gate_eval
    end
  end

  defp reconstruct_eval_ctx(_, _), do: :not_gate_eval

  # ============================================================
  # Traduction event → step_run (pure sauf l'appel StepRunCompleter / enqueue brief)
  # ============================================================

  @doc false
  # Exposé pour test : décide skip/complete/escalade sans passer par le GenServer.
  # Retourne `{:ok, outcome}` | `{:skip, reason}` | `{:escalate, corr, eval_ctx}` |
  # `{:error, reason}`.
  def maybe_complete(payload, state) do
    cond do
      Map.has_key?(payload, "workflow_map_id") ->
        {:skip, :workflow_map_pod}

      not project_payload?(payload) ->
        {:skip, :no_project}

      true ->
        case parse_issue_number(payload["issue_id"]) do
          # Repo + remote de CE step_run dérivés de l'event (per-step-run), pas de la config.
          {:ok, n} -> run_step_run(payload, n, step_run_state(payload, state))
          :error -> {:skip, {:bad_issue_id, payload["issue_id"]}}
        end
    end
  end

  # MULTI-PROJET — dérive le state EFFECTIF d'un step_run : le `repo` (forge API : list_open_pulls,
  # count_signed_step_runs, comments…) et le `remote` (URL de push du livrable) viennent de l'EVENT, pas de la
  # config. Le singleton StepRunConsumer traite les step_runs de TOUS les projets de l'humain → figer repo/remote en
  # config serait faux dès le 2e projet. Le Spawner enrichit `pod.completed` à la source
  # (`Fleet.Spawner.Pod.CompletedPayload` : `"repository" => %{"full_name"}` + `"remote"`). Payload nu
  # (sans repo : test/single-repo legacy) → on garde le state de config (fallback). `remote` absent mais
  # repo présent → fallback remote (rare ; un projet bien onboardé porte les deux).
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
      # Un PRODUCTEUR qui ne peut pas livrer (dépendance/info manquante) marque
      # `blocked: true` dans son result → ESCALADE humaine via `await_arch` (motif posté = sa voix
      # `summary` + `lcars-awaits-arch` + unlock → poller SKIP, l'humain tranche via l'arch). SINON la
      # publish sans commit fail-loud `:no_deliverable_commit` = WEDGE silencieux (un eng honnête refuse
      # de deviner → blocage non escaladé). Réutilise tout le filet await_arch.
      producer?(role, state) and
          blocked_flag?(Verdict.unwrap_worker_envelope(payload["result"] || %{})) ->
        escalate_blocked_producer(payload, n, role, state)

      true ->
        # Si le payload porte le contexte workflow_map (workflow_map_name+step), le step suivant
        # est calculé par WorkflowMapNav (reassign vers le rôle suivant, ou close si terminal).
        # Sans contexte workflow_map (1-step) → next_assignee nil → close. Une erreur de workflow_map
        # (DAG, step inconnu) NE misroute PAS : elle remonte (le système n'avance pas à l'aveugle).
        case resolve_next(payload, n, state) do
          {:error, reason} ->
            # G2 (entonnoir) : une erreur TERMINALE NON-TRANSITOIRE ne doit PAS remonter en `{:noreply}`
            # log-only — sinon le reaper réclame le verrou 2 ticks après, re-dispatch le MÊME step →
            # re-fail → CHURN infini sans jamais notifier un humain (asymétrie avec le chemin verdict qui,
            # lui, escalade). On l'ESCALADE vers l'arch (await_arch : comment + `lcars-awaits-arch` + unlock
            # → le poller SKIP l'issue, le churn s'arrête, l'humain tranche). Les autres erreurs remontent
            # inchangées : transitoires/auto-réparantes (`:no_gatekeeper` = le gatekeeper permanent reboote,
            # la réconciliation re-dispatche) ou traitées ailleurs (workflow_map illisible → IncidentRegistry, G6).
            if terminal_escalate?(reason),
              do: escalate_terminal_error(reason, n, role, state),
              else: {:error, reason}

          # Escalade gatekeeper : remonte au handle_info qui stocke `gate_evals`.
          {:escalate, corr, eval_ctx} ->
            {:escalate, corr, eval_ctx}

          # Le step qui finit est un JUGE (brief_kind:judge) : son verdict EST la décision →
          # `apply_verdict` (LA fonction de verdict, partagée avec le gatekeeper async). Pas de gate hard.
          {:judge_verdict, decision, trace, ctx} ->
            apply_verdict(decision, trace, ctx, state)

          {:ok, intent, {next_assignee, next_step}} ->
            complete_business_step_run(payload, n, role, intent, next_assignee, next_step, state)
        end
    end
  end

  # Escalade un producteur bloqué vers l'humain (await_arch), motif = sa voix `summary`.
  # Réutilise le filet existant (comment dédupé + lcars-awaits-arch + unlock) au lieu d'un wedge.
  defp blocked_flag?(m) when is_map(m), do: m["blocked"] == true
  defp blocked_flag?(_), do: false

  defp escalate_blocked_producer(payload, n, role, state) do
    reason = Verdict.eng_summary(payload)

    lead =
      if reason == "",
        do: "🚧 **#{role} BLOQUÉ** (dépendance/info manquante) — motif non fourni.",
        else: "🚧 **#{role} BLOQUÉ** (dépendance/info manquante) :\n\n#{reason}"

    step_run = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      decision: :blocked_dep,
      comment_body: lead
    }

    hc_opts = [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

    result =
      run_completion(state, "##{n} (blocked)", fn ->
        state.step_run_completer.await_arch(step_run, hc_opts)
      end)

    # KICK l'arch : un producteur bloqué = l'arch (auteur du brief) doit débloquer (clarifier/corriger).
    _ = kick_architect(state)
    result
  end

  # G2 (entonnoir) — quelles erreurs de fin de step_run sont TERMINALES NON-TRANSITOIRES (= un mur humain,
  # à escalader) vs remontées telles quelles (transitoires / auto-réparantes / traitées ailleurs) :
  #   - `rework_exhausted` : le budget est un compteur MONOTONE (step_runs signés) → re-dispatch = re-fail,
  #     jamais de convergence sans intervention → ESCALADE.
  #   - `rework_budget_unreadable` : le code choisit explicitement de « surfacer » plutôt que rebondir à
  #     l'aveugle (un rebond non vérifiable pourrait boucler) → ESCALADE (cohérent avec l'intent de `rebound`).
  # Tout le reste (`:no_gatekeeper` wrappé `gatekeeper_dispatch`, nav workflow_map, load workflow_map…) reste
  # remonté : transitoire (gatekeeper permanent reboote) ou d'un autre concern (G6 → IncidentRegistry).
  defp terminal_escalate?({:rework_exhausted, _}), do: true
  defp terminal_escalate?({:rework_budget_unreadable, _}), do: true

  # D2/G3 : aval humain requis (gate `human_approval_required`) → escalade directe (pas un échec, pas un rework).
  defp terminal_escalate?({:human_approval_required, _}), do: true
  defp terminal_escalate?(_), do: false

  # Escalade une erreur terminale vers l'humain (await_arch), même filet que `escalate_blocked_producer`
  # (comment adressé à l'arch + `lcars-awaits-arch` + unlock + kick). L'unlock est LOAD-BEARING : il retire
  # `lcars-in-flight` → le poller ne re-dispatche plus (l'issue porte `lcars-awaits-arch`, skippée) → fin du churn.
  defp escalate_terminal_error(reason, n, role, state) do
    step_run = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      decision: :terminal_error,
      comment_body: terminal_error_message(reason, role)
    }

    hc_opts = [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

    result =
      run_completion(state, "##{n} (terminal-error)", fn ->
        state.step_run_completer.await_arch(step_run, hc_opts)
      end)

    _ = kick_architect(state)
    result
  end

  defp terminal_error_message({:rework_exhausted, %{step_runs: sr, budget: b}}, role) do
    "🛑 **Rework épuisé** (dernier producteur : `#{role}`) — #{sr}/#{b} step_runs signés, budget atteint.\n\n" <>
      "L'issue ne peut plus avancer seule (re-dispatch = re-échec). Corrige le brief ou la workflow_map, " <>
      "ou abandonne l'issue."
  end

  defp terminal_error_message({:rework_budget_unreadable, reason}, _role) do
    "🛑 **Budget de rework illisible** (`#{inspect(reason)}`) — on ne rebondit pas à l'aveugle (risque de " <>
      "boucle). Vérifie l'état forge de l'issue (comments `[step_run:…]`) puis relance ou abandonne."
  end

  defp terminal_error_message({:human_approval_required, _reason}, role) do
    "✋ **Aval humain requis** (step `#{role}`, gate `human_approval_required`) — le livrable attend TON " <>
      "approbation. Valide (relance le cycle) ou renvoie en correction. La fleet ne s'auto-approuve jamais."
  end

  # Exécute la complétion d'un step_run via le seam `step_run_runner`. SYNC (défaut) → exécute, logge
  # l'outcome, et le REND (seams `maybe_complete`/`resume_gate` + tous les tests le reçoivent). ASYNC
  # (prod, Task.Supervisor) → offload : le git push ≤30s + writes forge ne bloquent PAS le singleton,
  # l'outcome est loggé DANS la task, le runner rend `{:ok, :offloaded}`. Ordering préservé (lock
  # lcars-in-flight + writes idempotentes). Un `.complete` qui crash en async est
  # isolé par la task supervisée (ne tue pas le StepRunConsumer).
  defp run_completion(state, label, fun) do
    exec = fn ->
      outcome = fun.()

      case outcome do
        {:error, reason} ->
          Logger.warning("StepRunConsumer fin-de-step-run FAIL #{label}: #{inspect(reason)}")

        _ ->
          Logger.info("StepRunConsumer fin-de-step-run #{label} → #{inspect(outcome)}")
      end

      outcome
    end

    (state.step_run_runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()

  # Construit + applique le step_run PR-natif. Classe le role qui FINIT (producteur git_native
  # → ouvre la PR ; juge payload → review la PR du producteur) puis delegue le routage selon
  # l'`intent` de gate a `StepRunCompleter.complete_pr`. `next_step` ne sert plus (la route de complétion
  # disparait avec le modèle PR-natif). `comment_body` (trace verdict gatekeeper sur continue) est porte
  # mais pas encore materialise sur la PR — gap transitionnel note (la trace vit dans le resultat de tache
  # du gatekeeper ; PR-trace = increment ulterieur).
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
    # E4 : TOUTE la construction (dont classify_pr_role → list_open_pulls HTTP inline, timeout 10s)
    # vit DANS la closure offloadée — forge dégradée + rafale de pod.completed ne bloque plus la
    # mailbox du singleton (le handle_info redevient O(1) en prod, l'offload porte l'I/O).
    run_completion(state, "##{n}", fn ->
      {pr_role, producer_branch} = classify_pr_role(payload, n, role, state)

      step_run =
        %{
          repo: state.repo,
          # pod_id du PRODUCTEUR (depuis le payload pod.completed) : porte jusqu'a l'emission de
          # `deliverable.published` (slot-freeze) pour adresser le pod resident a remettre :ready.
          pod_id: payload["pod_id"],
          issue_number: n,
          role: role,
          pr_role: pr_role,
          intent: intent,
          next_assignee: next_assignee,
          # Pont transitionnel : workflow_map_name+next_step gravent la route que le StepDispatcher lit
          # pour spawner le step suivant (retire a l'increment 4, switch sur la review-request).
          next_step: next_step,
          workflow_map: payload["workflow_map"],
          producer_branch: producer_branch,
          base_branch: "main"
        }
        |> put_unless_nil(:comment_body, comment_body)
        # judge_target (brief|nil) → complete_judge décide trace review-PR vs commentaire-issue ;
        # absent (chemin normal/gatekeeper) → comportement PR par défaut (fail-loud si pas de PR).
        |> put_unless_nil(:judge_target, judge_target)
        |> maybe_put_deliverable(pr_role, role, payload, n, state)
        |> maybe_put_review_event(pr_role, intent, payload)
        |> maybe_put_eng_summary(pr_role, payload)

      hc_opts =
        [forge_opts: state.forge_opts]
        |> Opts.maybe_put(:forge_client, state.forge_client)
        |> Opts.maybe_put(:deliverable, state.deliverable)

      state.step_run_completer.complete_pr(step_run, hc_opts)
    end)
  end

  # Le producteur (engineer) porte sa `deliverable_opts` (publish vers sa feature-branch) ; le juge
  # review (il ne pousse pas — son verdict est une review native), pas de livrable git.
  defp maybe_put_deliverable(step_run, :producer, role, payload, n, state),
    do: Map.put(step_run, :deliverable_opts, build_deliverable_opts(role, payload, n, state))

  defp maybe_put_deliverable(step_run, :judge, _role, _payload, _n, _state), do: step_run

  # Pour un JUGE no-workflow_map (intent `:reviewed`), le verdict de review (APPROVE/REQUEST_CHANGES)
  # est lu du gate-decision rendu par le pod (GateBrief : `continue`/`abandon`). On le mappe ici et on
  # le porte dans le step_run (`:review_event`) → `StepRunCompleter.record_review` poste la review correspondante.
  # `continue`→approve ; tout le reste (`abandon`/redirect/escalate/halt/illisible)→**request_changes**
  # (fail-closed DÉCISIF). PAS `:comment` : une review COMMENT n'est pas décisive → le juge resterait
  # « non tranché » et serait re-jugé en boucle. Un verdict non-`continue` = pas vert
  # → on bloque le merge (rework), jamais un merge sur verdict douteux. (escalade-gatekeeper d'un verdict
  # non-trivial = backlog ; ici fail-closed strict.)
  defp maybe_put_review_event(step_run, :judge, :reviewed, payload) do
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})
    event = Verdict.review_event(Verdict.gate_decision(result))
    step_run = Map.put(step_run, :review_event, event)

    # Le juge PRODUIT un `reason`/`details`/`chain` dans sa gate-decision → on le REND sur la review
    # (visu humaine + rework actionnable). Sinon `StepRunCompleter.record_review` retombe sur le corps
    # générique (« la brique ne satisfait pas son critère »), inactionnable — pour l'humain comme pour
    # le producteur en rework. On ne pose `:review_body` QUE s'il y a de la substance (sans
    # quoi `Map.get(step_run, :review_body, default)` renverrait `nil` au lieu du défaut).
    case Verdict.judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(step_run, :review_body, body)
      _ -> step_run
    end
  end

  defp maybe_put_review_event(step_run, _pr_role, _intent, _payload), do: step_run

  # VOIX DE L'ENG (info SORTANTE) : le PRODUCTEUR peut rendre un `summary` markdown dans submit_result
  # (ce qu'il a fait / réponse à la review / motif blocked). On l'extrait du résultat (déplié de
  # l'enveloppe worker) → `StepRunCompleter` le poste en commentaire PR (`as_role` engineer). Coercé par
  # `safe_str` (l'eng peut rendre un non-binaire → ne pas crasher le singleton). Absent/vide → rien
  # posé. Jumeau SORTANT de la famine d'info ENTRANTE — complète la « panne bidirectionnelle de substance ».
  defp maybe_put_eng_summary(step_run, :producer, payload) do
    case Verdict.eng_summary(payload) do
      "" -> step_run
      summary -> Map.put(step_run, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(step_run, _pr_role, _payload), do: step_run

  # Classe le role qui finit (engineer-first). Producteur = role git_native (engineer) →
  # pousse le code, ouvre la PR (head = sa propre branche). Juge = role payload (qualifier/reviewer
  # en AVAL) → review la PR du producteur (head = le head.ref de la PR ouverte de l'issue, résolu
  # sans workflow_map via `parse_feature_branch`). Un juge sans producteur resoluble → `producer_branch`
  # nil → `complete_pr` fail-loud `:no_producer_branch` (jamais un mauvais merge). Les steps design
  # AMONT du producteur (architect) sont hors-scope (decision engineer-first, mapping PR).
  defp classify_pr_role(payload, n, role, state) do
    if producer?(role, state) do
      # Format feature-branch = source unique `Fleet.Pilot.ForgeProtocol.feature_branch/2` (collé à son
      # parseur `parse_feature_branch/1`) — pas de construction `lcars/issue-...` en dur ici.
      {:producer, Fleet.Pilot.ForgeProtocol.feature_branch(n, role)}
    else
      {:judge, judge_producer_branch(payload, n, state)}
    end
  end

  defp producer?(role, state) when is_binary(role),
    do: state.deliverable_mode_fun.(role) == "git_native"

  defp producer?(_role, _state), do: false

  # Sans workflow_map : le producteur = celui qui a OUVERT la PR de l'issue N.
  # Sa branche = le `head.ref` de cette PR (`lcars/issue-N-<producteur>`), retrouvée en listant les PR
  # ouvertes + `parse_feature_branch` (même pattern que le Poller). Le modèle 1-brique=1-producteur
  # n'a pas de workflow_map (sans `payload["workflow_map"]`, une résolution workflow_map rendrait nil → merge
  # cassé). Aucune PR résoluble → nil → `complete_pr` fail-loud `:no_producer_branch` (jamais un
  # mauvais merge).
  defp judge_producer_branch(_payload, n, state) do
    forge = state.forge_client || Fleet.Pilot.ForgeClient

    with {:ok, pulls} <- forge.list_open_pulls(state.repo, state.forge_opts),
         head when is_binary(head) <- producer_head_for_issue(pulls, n) do
      head
    else
      _ -> nil
    end
  end

  # La branche producteur de l'issue N = le `head.ref` de la (1ʳᵉ) PR ouverte dont le head parse
  # vers l'issue N. Ambiguïté (≥2 PR pour N — anormal) → la première ; aucune → nil (fail-loud aval).
  defp producer_head_for_issue(pulls, n) do
    Enum.find_value(pulls, fn pr ->
      head = get_in(pr, ["head", "ref"]) || ""

      case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
        {:ok, {^n, _role}} -> head
        _ -> false
      end
    end)
  end

  # Defaut du seam : resout le deliverable_mode du role via le catalogue cap-profile (source unique).
  # Irresoluble → `"payload"` (fail-safe : un role non chargeable n'est pas traite comme producteur).
  defp default_deliverable_mode(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, cap} -> Fleet.CapProfile.deliverable_mode(cap)
      _ -> "payload"
    end
  end

  # Livrable d'un step_run métier : `:git_native`. Le pod a commité dans son workspace,
  # le système vérifie (gate identité/ancêtre) + pousse. Il n'existe PAS
  # de step `role: gatekeeper` → pas de branche `:payload`/verdict.json ici (le verdict
  # du gatekeeper est tracé par `resume_gate`, pas matérialisé comme livrable de step).
  defp build_deliverable_opts(role, payload, n, state) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      # La gate d'ancêtre se base sur `gate_base_sha` (DÉCONFLÉ de la clone-base) :
      # pour une résolution par rebase, HEAD descend de `main` (cible du rebase), pas de l'ancien tip de
      # feature (réécrit → `base_not_ancestor`). Forward (build/rework) : le resolver pose
      # `gate_base_sha == base_sha`. Fallback `base_sha` (payload nu de test / spawn antérieur au champ).
      base_sha: payload["gate_base_sha"] || payload["base_sha"],
      allowed_emails: state.role_emails.(role),
      # La gate d'identité vérifie le trailer `Co-authored-by: LCARS-<role>` (signature rôle).
      coauthor_role: role,
      remote: state.remote,
      # Format feature-branch = source unique `Fleet.Pilot.ForgeProtocol.feature_branch/2` (collé au parseur).
      target_branch: Fleet.Pilot.ForgeProtocol.feature_branch(n, role),
      push?: true,
      local_ref: "HEAD"
    }
  end

  # Résout le prochain assignee depuis la workflow_map. Le contexte workflow_map arrive dans le
  # payload `pod.completed` : `workflow_map_name` (nom de workflow_map) + `step` (nom du step courant —
  # le NOM, pas le rôle, cf. WorkflowMapNav qui indexe par nom de step). Absent → 1-step terminal.
  defp resolve_next(payload, n, state) do
    case {payload["workflow_map"], payload["step"]} do
      {workflow_map_name, step} when is_binary(workflow_map_name) and is_binary(step) ->
        with {:ok, workflow_map} <- load_workflow_map(state, workflow_map_name) do
          # Un pod dont le RÔLE ≠ le rôle déclaré du step qu'il porte n'EST pas ce step : c'est un
          # juge NO-WORKFLOW_MAP (qualifier/reviewer dispatché par `dispatch_review`) ayant HÉRITÉ la route de
          # l'issue (le step du producteur). Le traiter via la workflow_map le ferait avancer/merger à tort :
          # un qualifier portant `build` tomberait en terminal non-producteur → `:promote`
          # → merge sur 1 juge, court-circuitant le quorum. → résolution no-workflow_map (`:reviewed`) : il
          # enregistre sa review native, et le merge revient au quorum `dispatch_by_verdicts` (qui attend
          # TOUS les juges). Un vrai step de workflow_map (rôle = rôle du step) passe par la gate.
          if inherited_route?(workflow_map, step, payload["role"]) do
            no_workflow_map_resolve(payload, state)
          else
            gate_decide(workflow_map, step, payload, n, state)
          end
        end

      _ ->
        # Pas de workflow_map (single-brique) : l'intent dépend du RÔLE qui finit, pas de
        # `:promote` direct (un terminal qui promeut mergerait SANS juge). Le merge est piloté par
        # l'état-PR (dispatch_review), pas par l'intent d'un pod isolé.
        no_workflow_map_resolve(payload, state)
    end
  end

  # ROUTE HÉRITÉE = le step EXISTE dans la workflow_map MAIS son rôle déclaré ≠ le rôle du pod : c'est un
  # juge no-workflow_map (dispatché sur la PR) qui a hérité la route du producteur → à résoudre en no-workflow_map. Un
  # step INCONNU (route corrompue) n'est PAS « hérité » → `false` → laisse `gate_decide` fail-loud
  # (`unknown_step`, jamais un misroute silencieux). Un step sans `role` → `false` (gate_decide tranche).
  defp inherited_route?(workflow_map, step, role) do
    case Fleet.Pilot.WorkflowMapNav.step_spec(workflow_map, step) do
      {:ok, spec} ->
        case Map.get(spec, "role") do
          r when is_binary(r) -> r != role
          _ -> false
        end

      _ ->
        false
    end
  end

  # Résolution single-brique (sans workflow_map) :
  #   producteur (git_native) → `:review` : `complete_pr` ouvre la PR + met les juges en
  #     `requested_reviewers` + assigne l'humain + unlock l'issue ;
  #   juge (payload) → `:reviewed` : `complete_pr` poste la review native (verdict lu du gate-decision,
  #     porté plus loin via `:review_event`) + unlock la PR. Le merge/rework = poller (dispatch_review).
  defp no_workflow_map_resolve(payload, state) do
    if producer?(payload["role"], state) do
      {:ok, :review, {nil, nil}}
    else
      {:ok, :reviewed, {nil, nil}}
    end
  end

  # La gate du step FINI décide AVANT d'avancer.
  # `Gates.evaluate/3` est PUR (gate nil/absente → :pass) ; on lui passe la spec du
  # step qui vient de finir + le `result` du pod (outputs → prédicats hard).
  #
  #   :pass                     → avance dans la workflow_map (next_step)
  #   {:fail, _}                → REBOND vers le 1er step (rework), BORNÉ (anti-runaway :
  #                               une boucle de rework infinie ne doit pas être
  #                               représentable).
  #   {:dispatch_gatekeeper, _} → enqueue un brief d'éval au gatekeeper
  #                               permanent + `{:escalate, corr, eval_ctx}` (reprise async
  #                               sur `work_item.completed`). Enqueue raté → fail-loud (l'issue
  #                               reste verrouillée, pas d'avance à l'aveugle).
  defp gate_decide(workflow_map, step, payload, n, state) do
    spec =
      case Fleet.Pilot.WorkflowMapNav.step_spec(workflow_map, step) do
        {:ok, s} -> s
        # step inconnu : pas de gate → next_step tranchera ({:error,:unknown_step}),
        # pas de misroute silencieux.
        :error -> %{}
      end

    # Déplie l'enveloppe worker `%{"status","result"}` AVANT d'évaluer la gate —
    # sinon la gate voit l'enveloppe au lieu des outputs (hard-gate à tort).
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})

    if Map.get(spec, "brief_kind") == "judge" do
      # Le step qui finit EST un juge (brief_kind:judge, ex. brief-review/consultant). Son
      # result PORTE le verdict gate-decision-v1 : le juge a DÉJÀ tranché → PAS de Gates.evaluate (qui
      # jugerait les outputs du juge comme un hard-gate). Le verdict est appliqué par `apply_verdict` (LA
      # fonction, partagée avec le gatekeeper async). gate_decide reste un décideur PUR : il rend
      # l'intention `{:judge_verdict, …}`, c'est run_step_run qui agit.
      decision = Verdict.gate_decision(result)
      trace = Verdict.verdict_comment(payload["role"], decision, result)

      ctx = %{
        n: n,
        role: payload["role"],
        payload: payload,
        workflow_map: workflow_map,
        step: step,
        judge_target: Map.get(spec, "judge_target")
      }

      {:judge_verdict, decision, trace, ctx}
    else
      case Fleet.Workflow.Gates.evaluate(spec, result, %{}) do
        :pass ->
          # L'intent terminal dépend du RÔLE qui finit (cf. tag_advance/2).
          tag_advance(advance(workflow_map, step), producer?(payload["role"], state))

        {:fail, reason} ->
          Logger.info("StepRunConsumer gate FAIL repo=#{state.repo}##{n} step=#{step}: #{reason}")

          tag(:rework, rebound(workflow_map, n, state))

        {:human_approval, reason} ->
          # D2/G3 : un aval humain requis n'est PAS un échec de gate → on N'entre PAS en rework (qui
          # gaspillerait `budget` spawns avant d'escalader de toute façon). Erreur terminale ESCALÉE
          # DIRECTEMENT vers l'arch (via terminal_escalate?/escalate_terminal_error, même filet que
          # rework_exhausted) : comment + lcars-awaits-arch + unlock → poller skip → l'humain approuve.
          {:error, {:human_approval_required, reason}}

        {:dispatch_gatekeeper, _info} ->
          # `payload`/`n`/`role` passés au dispatch : ils sont EMBARQUÉS dans le metadata de la
          # tâche d'éval (contexte de reprise auto-descriptif). Le StepRunConsumer redémarré (gate_evals RAM
          # vide) reconstruit l'eval_ctx du metadata au lieu de jeter le verdict en silence. Le cluster
          # d'escalade reçoit un struct de seams étroit (pas `state` entier — frontière blindée).
          case GatekeeperEscalation.dispatch(
                 workflow_map,
                 step,
                 result,
                 payload,
                 n,
                 payload["role"],
                 escalation_seams(state)
               ) do
            {:ok, corr} ->
              {:escalate, corr,
               %{
                 n: n,
                 role: payload["role"],
                 payload: payload,
                 workflow_map: workflow_map,
                 step: step
               }}

            {:error, reason} ->
              {:error, {:gatekeeper_dispatch, reason}}
          end
      end
    end
  end

  # Invariant « un PRODUCTEUR ne merge JAMAIS seul » : `:pass` → `:advance` si un step suit ;
  # terminal (next_assignee nil) → selon le RÔLE qui finit :
  #   - PRODUCTEUR (git_native) → `:review` : son livrable ouvre une PR + demande les juges. JAMAIS
  #     d'auto-merge d'un livrable.
  #   - JUGE-WORKFLOW_MAP terminal (son rôle EST celui du step) → `:promote` : il a validé le dernier gate de
  #     SA workflow_map (1 step = 1 rôle = 1 juge) → merge terminal.
  # Ici on ne voit QUE de vrais steps de workflow_map (un juge NO-WORKFLOW_MAP à route héritée est dévié vers
  # `no_workflow_map_resolve` AVANT — cf. `resolve_next`/`inherited_route?` : sinon un qualifier portant
  # `build` mergerait sur 1 juge). Sans le split producteur/juge, une workflow_map terminant sur un producteur
  # (brief-gate `brief-review→build`) mergerait le code SANS juges. `{:error,_}` tel quel.
  defp tag_advance({:ok, {nil, nil}}, true), do: {:ok, :review, {nil, nil}}
  defp tag_advance({:ok, {nil, nil}}, false), do: {:ok, :promote, {nil, nil}}
  defp tag_advance({:ok, routing}, _producer?), do: {:ok, :advance, routing}
  defp tag_advance(other, _producer?), do: other

  defp tag(intent, {:ok, routing}), do: {:ok, intent, routing}
  defp tag(_intent, other), do: other

  # Construit le struct de seams ÉTROIT passé à `GatekeeperEscalation.dispatch` : les 4 seams
  # async-out lus du state (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery). On NE passe PAS
  # `state` entier — frontière blindée : le cluster d'escalade ne peut lire aucun autre champ.
  defp escalation_seams(state) do
    %GatekeeperEscalation.Seams{
      task_queue: state.task_queue,
      spawner: state.spawner,
      gatekeeper_pod_id_fun: state.gatekeeper_pod_id_fun,
      wake_recovery: state.wake_recovery
    }
  end

  # NOTIFIE l'arch (sas UNIQUE vers l'humain) qu'un verdict (escalate/abandon) ou un blocage requiert
  # son attention. KICK best-effort via le wake UNIVERSEL (`wake_pod` : flag PORTEUR/MCP → fallback send-keys
  # → log ; tout pod arme son Monitor au spawn). **PAS de reboot** : l'arch est la SESSION de l'humain, jamais
  # kill/relancée par la fleet (un arch injoignable = l'humain relance SA session, pas nous) — d'où PAS de
  # `WakeRecovery.wake` (qui porte un respawn). Échec wake → log-loud, non-bloquant (le label `lcars-awaits-arch`
  # + le commentaire adressé-arch restent ; l'arch query son inbox au prochain tour).
  defp kick_architect(state) do
    pod_id = architect_pod_id()

    case state.spawner.wake_pod(pod_id) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "StepRunConsumer: kick arch #{pod_id} → #{inspect(other)} (arch injoignable ? l'humain relance sa " <>
            "session — la fleet ne reboot PAS l'arch ; label+commentaire restent)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("StepRunConsumer: kick arch a levé #{inspect(e)} (non-bloquant)")
      :ok
  end

  # Pod id de l'arch permanent (sas user) — délégué à l'AUTORITÉ UNIQUE `Fleet.Pilot.Roles` (partagée
  # avec le re-kick awaits-arch du Poller ; plus de littéral "permanent-architect" retapé ici).
  defp architect_pod_id, do: Fleet.Pilot.Roles.architect_pod_id()

  @doc false
  # Reprise après le verdict du gatekeeper. Exposé pour test (le GenServer
  # appelle via handle_info(:work_item.completed)). `raw_payload` = payload brut du
  # `work_item.completed` (déplié ici par `gate_result/1` : enveloppe TaskQueue + enveloppe
  # worker). Vocab canon `gate-decision-v1.json` :
  #   continue → avance (push livrable métier + reassign) ;
  #   abandon  → close (trace verdict, PAS de push : travail rejeté) ;
  #   redirect|escalate_user|halt_wait_input|invalide → await_arch (fail-closed).
  # La TRACE du verdict est durable : portée dans le comment signé du step_run (continue/abandon)
  # ou du await_arch — c'est ce dont l'absence a coulé la v1.
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

  # APPLICATION d'un verdict de juge (gate-decision-v1). UNE fonction, partagée par TOUS les juges
  # quelle que soit leur position : le gatekeeper (verdict async via `work_item.completed` → resume_gate) ET le
  # consultant brief-review (verdict via `pod.completed` → gate_decide → run_step_run). continue → avance la
  # workflow_map ; abandon → close ; reste → await_arch. La SEULE diff (PR vs pré-PR) vit dans `complete_judge`
  # (trace = review native si PR, sinon commentaire issue), dérivée de l'état forge + `judge_target` du
  # ctx — PAS d'un fork ici. `trace` est déjà attribué au bon juge (label) par l'appelant.
  defp apply_verdict(
         decision,
         trace,
         %{n: n, role: role, payload: payload, workflow_map: workflow_map, step: step} = ctx,
         state
       ) do
    case decision do
      "continue" ->
        # Le split producteur/juge n'est PAS optionnel. Si l'intent était `if is_nil(next_assignee),
        # do: :promote, else: :advance`, alors sur un step TERMINAL (next_assignee nil), `apply_verdict`
        # hardcoderait `:promote` quel que soit le RÔLE qui finit → un PRODUCTEUR jugé « continue » sur un
        # terminal MERGERAIT le code SANS passer par les juges PR. On route par le MÊME
        # `tag_advance(advance(…), producer?(role, state))` que `gate_decide` (chemin :pass) : un producteur
        # terminal → `:review` (ouvre la PR + demande les juges, JAMAIS d'auto-merge d'un livrable) ; un juge
        # terminal (consultant brief-review) → `:promote` (il a validé le dernier gate de sa workflow_map) ;
        # un step suivant → `:advance`. Une seule source de vérité pour l'intent terminal.
        case tag_advance(advance(workflow_map, step), producer?(role, state)) do
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
        # NE PAS enterrer en silence : le commentaire de close est ADRESSÉ à l'arch (auteur du brief)
        # + on KICKE l'arch (sas unique vers l'humain) → l'auteur APPREND que son brief a été jeté.
        arch_trace =
          "**Architecte** (auteur du brief) — brief ABANDONNÉ par le juge. " <>
            trace <> " (Non récupérable ; re-crée un brief corrigé si besoin.)"

        result = close_with_trace(n, role, arch_trace, state)
        _ = kick_architect(state)
        result

      other ->
        # `comment_body: trace` → la trace verdict (attribuée au juge via son label, halt_invalid
        # distingué) est portée sur le comment await_arch (qui l'adresse à l'arch), parité continue/abandon.
        step_run = %{
          repo: state.repo,
          issue_number: n,
          role: role,
          decision: other,
          comment_body: trace
        }

        hc_opts =
          [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

        result =
          run_completion(state, "##{n}", fn ->
            state.step_run_completer.await_arch(step_run, hc_opts)
          end)

        # KICK l'arch (notification active : il arme son monitor au spawn comme tout pod). Best-effort.
        _ = kick_architect(state)
        result
    end
  end

  # Verdict `abandon` : close terminal forge, SANS push (le travail métier est rejeté).
  # Le terminal-échec du rail forge-driven EST la fermeture de l'issue (la forge porte l'état),
  # pas un signal d'échec en mémoire : aucun livrable n'est extrait/poussé sur un verdict non-continue.
  # `deliverable_opts: nil` + `step_run_sha` → StepRunCompleter saute l'étape publish, garde la
  # séquence idempotente (comment trace → close → unlock).
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

    hc_opts = [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

    run_completion(state, "##{n}", fn ->
      state.step_run_completer.complete(step_run, hc_opts)
    end)
  end

  defp advance(workflow_map, step) do
    case Fleet.Pilot.WorkflowMapNav.next_step(workflow_map, step) do
      {:ok, {next_step, next_role}} -> {:ok, {next_role, next_step}}
      :terminal -> {:ok, {nil, nil}}
      {:error, reason} -> {:error, {:workflow_map_nav, reason}}
    end
  end

  # Rebond borné. Budget = nb_steps * (max_rework_rounds + 1) step_runs signés. Le compteur
  # forge-natif = les comments `[step_run:role:sha]` déjà postés (monotone). Lu UNIQUEMENT ici
  # (branche fail) → zéro I/O sur le happy path. Budget illisible → on NE rebondit PAS à
  # l'aveugle (un rebond non vérifiable pourrait boucler) : on surface.
  defp rebound(workflow_map, n, state) do
    budget = step_count(workflow_map) * (state.max_rework_rounds + 1)

    case count_step_runs(state, n) do
      {:ok, step_runs} when step_runs >= budget ->
        {:error, {:rework_exhausted, %{step_runs: step_runs, budget: budget}}}

      {:ok, _step_runs} ->
        case Fleet.Pilot.WorkflowMapNav.first_step(workflow_map) do
          {:ok, {first_step, first_role}} -> {:ok, {first_role, first_step}}
          {:error, reason} -> {:error, {:workflow_map_nav, reason}}
        end

      {:error, reason} ->
        {:error, {:rework_budget_unreadable, reason}}
    end
  end

  # Budget rework = tous les steps de la workflow_map. Il n'existe PAS de step
  # `role: gatekeeper` (le juge est dispatché par gate, pas un step) → pas d'exclusion
  # à câbler (aucun gatekeeper-step à exclure du compte).
  defp step_count(workflow_map) do
    workflow_map |> Map.get("steps", %{}) |> map_size()
  end

  defp count_step_runs(state, n) do
    forge = state.forge_client || Fleet.Pilot.ForgeClient
    forge.count_signed_step_runs(state.repo, n, state.forge_opts)
  end

  # Pas de `validate_explicit_step` (biconditionnelle soft⟺gatekeeper) :
  # une gate soft sur un step métier est LÉGITIME (→ escalade gatekeeper), pas
  # une workflow_map malformée. La workflow_map est juste chargée (le Loader valide le schema).
  # R4 : délégué à l'autorité unique — et TAG UNIFIÉ (:workflow_map_load_failed ; l'ancien
  # :workflow_map_load était un 2e nom pour le même échec).
  defp load_workflow_map(state, workflow_map_name),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(state.loader, workflow_map_name)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp project_payload?(p) do
    is_binary(p["workspace"]) and is_binary(p["base_sha"]) and p["base_sha"] != "" and
      is_binary(p["role"])
  end

  # Le format issue_id "issue-<n>" a une SOURCE UNIQUE (Fleet.Pilot.IssueId) — writer
  # (StepDispatcher) et parser ne peuvent plus dériver. `parse_issue_number` reste l'API publique
  # (appelée par `maybe_complete` + testée step_run_consumer_test) mais délègue.
  @doc false
  defdelegate parse_issue_number(issue_id), to: Fleet.Pilot.IssueId, as: :parse

  # La gate d'identité `allowed_emails` = l'HUMAIN du brief (le pod git_native
  # commite EN TANT QUE l'humain, cf. `bwrap_launch.sh`/`ForgeIdentity`), PLUS le rôle. Même
  # catalogue que le spawn → cohérent (commit humain ⟺ la gate autorise l'humain). Irrésoluble →
  # `[]` fail-closed (la gate rejette tout). Le rôle est vérifié via le trailer, pas l'email.
  defp default_role_emails(role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} ->
        Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, id.author_email)

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: identité forge irrésoluble (role=#{role}): #{inspect(reason)} — " <>
            "allowed_emails=[] (F-01 rejettera le push, fail-closed)"
        )

        []
    end
  end
end
