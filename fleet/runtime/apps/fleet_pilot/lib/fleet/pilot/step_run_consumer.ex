defmodule Fleet.Pilot.StepRunConsumer do
  @moduledoc """
  Consumer Bus de la **fin-de-step-run** (la forge EST la machine à états ; ce module en réagit).
  Subscribe `Fleet.EventRouter.Bus` (topic `fleet.events`) ; sur chaque
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` d'un pod
  **step-dispatch** (assignee-driven), traduit l'event en `step_run` et délègue la
  séquence de complétion à `Fleet.Pilot.StepRunCompleter`.

  ## Sous-modules (frontières blindées — chacun lit un struct `Seams` étroit, jamais `state`)

    * `GateEngine` — moteur de DÉCISION (resolve_next : gate/rebond/verdict-juge/escalade) ;
      rend une intention, CE module agit.
    * `TerminalEscalation` — mur humain (freeze_to_arch : await_arch + kick arch) pour les
      erreurs terminales non-transitoires, producteurs bloqués et verdicts fail-closed.
    * `StepRunBuild` — construction de la map step_run PR-natif (classement producteur/juge,
      deliverable_opts, review_event, eng_summary).
    * `Verdict` — cluster PUR du verdict (décodage gate-decision-v1 + rendu texte).
    * `GatekeeperEscalation` — async-out de l'escalade gatekeeper (enqueue brief d'éval + kick).

  CE module garde : le GenServer Bus (subscribe/handle_info), l'état `gate_evals` (reprises
  async), l'application du verdict (`apply_verdict` — partagée gatekeeper/consultant), la
  discipline d'exécution sync/offload (`run_completion`) et la dérivation per-step-run du
  state (`step_run_state` : repo/remote depuis l'event, multi-projet).

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
  # le GateEngine sur le chemin `{:dispatch_gatekeeper, _}` (seams transmis via `gate_seams/1`).
  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation

  # Moteur de DÉCISION de gate (resolve_next/advance_intent/producer?) : rend une INTENTION,
  # CE module agit. Frontière blindée : lit un `GateEngine.Seams` étroit (`gate_seams/1`), pas `state`.
  alias Fleet.Pilot.StepRunConsumer.GateEngine

  # Escalade TERMINALE vers l'humain (mur humain → await_arch + kick arch). Frontière blindée :
  # lit un `TerminalEscalation.Seams` étroit (`terminal_seams/1`), la discipline sync/offload
  # (`run_completion/3`) reste ICI et voyage en closure.
  alias Fleet.Pilot.StepRunConsumer.TerminalEscalation

  # Construction du step_run PR-natif (classement producteur/juge + assemblage). Frontière
  # blindée : lit un `StepRunBuild.Seams` étroit (`build_seams/1`), appelé DANS la closure
  # offloadée (E4 : l'I/O de résolution de branche juge ne bloque pas la mailbox).
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
      "StepRunConsumer: start (MULTI-PROJET F-037 : repo/remote per-step-run) " <>
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
          "StepRunConsumer: gate→gatekeeper #{p["issue_id"]} step=#{eval_ctx.step} corr=#{inspect(corr)}"
        )

        {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}

      {:skip, reason} ->
        Logger.debug("StepRunConsumer skip #{p["issue_id"]} (#{reason})")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "StepRunConsumer: fin-de-step-run FAIL #{p["issue_id"]}: #{inspect(reason)}"
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
          "StepRunConsumer: gate resume FAIL corr=#{inspect(corr)}: #{inspect(reason)}"
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
          TerminalEscalation.blocked_flag?(
            Verdict.unwrap_worker_envelope(payload["result"] || %{})
          ) ->
        TerminalEscalation.escalate_blocked_producer(payload, n, role, terminal_seams(state))

      true ->
        # Si le payload porte le contexte workflow_map (workflow_map_name+step), le step suivant
        # est calculé par WorkflowMapNav (reassign vers le rôle suivant, ou close si terminal).
        # Sans contexte workflow_map (1-step) → next_assignee nil → close. Une erreur de workflow_map
        # (DAG, step inconnu) NE misroute PAS : elle remonte (le système n'avance pas à l'aveugle).
        case GateEngine.resolve_next(payload, n, gate_seams(state)) do
          {:error, reason} ->
            # G2 (entonnoir) : une erreur TERMINALE NON-TRANSITOIRE ne doit PAS remonter en `{:noreply}`
            # log-only — sinon le reaper réclame le verrou 2 ticks après, re-dispatch le MÊME step →
            # re-fail → CHURN infini sans jamais notifier un humain (asymétrie avec le chemin verdict qui,
            # lui, escalade). On l'ESCALADE vers l'arch (await_arch : comment + `lcars-awaits-arch` + unlock
            # → le poller SKIP l'issue, le churn s'arrête, l'humain tranche). Les autres erreurs remontent
            # inchangées : transitoires/auto-réparantes (`:no_gatekeeper` = le gatekeeper permanent reboote,
            # la réconciliation re-dispatche) ou traitées ailleurs (workflow_map illisible → IncidentRegistry, G6).
            if TerminalEscalation.terminal_escalate?(reason),
              do:
                TerminalEscalation.escalate_terminal_error(
                  reason,
                  n,
                  role,
                  terminal_seams(state)
                ),
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

  # Frontière blindée vers `TerminalEscalation` : les 5 lectures/effets autorisés, RIEN d'autre.
  # `run_completion` voyage en closure → la discipline sync/offload reste ICI (source unique),
  # l'escalade ne choisit pas son mode d'exécution.
  defp terminal_seams(state) do
    %TerminalEscalation.Seams{
      repo: state.repo,
      step_run_completer: state.step_run_completer,
      completer_opts: completer_opts(state),
      spawner: state.spawner,
      run_completion: fn label, fun -> run_completion(state, label, fun) end
    }
  end

  # Frontière blindée vers `GateEngine` : les 7 lectures autorisées du moteur de décision.
  # Construit depuis le state DÉRIVÉ per-step-run (repo/forge_opts de l'event, multi-projet).
  defp gate_seams(state) do
    %GateEngine.Seams{
      loader: state.loader,
      deliverable_mode_fun: state.deliverable_mode_fun,
      max_rework_rounds: state.max_rework_rounds,
      repo: state.repo,
      forge_opts: state.forge_opts,
      forge_client: state.forge_client,
      escalation: escalation_seams(state)
    }
  end

  # Opts passés au StepRunCompleter — SOURCE UNIQUE de l'assemblage (forge_opts + forge_client
  # éventuel) ; `complete_business_step_run` y ajoute `:deliverable`.
  defp completer_opts(state),
    do: [forge_opts: state.forge_opts] |> Opts.maybe_put(:forge_client, state.forge_client)

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
          Logger.warning("StepRunConsumer: fin-de-step-run FAIL #{label}: #{inspect(reason)}")

        _ ->
          Logger.info("StepRunConsumer: fin-de-step-run #{label} → #{inspect(outcome)}")
      end

      outcome
    end

    (state.step_run_runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()

  # Complète le step_run PR-natif : la CONSTRUCTION (classement producteur/juge + assemblage de la
  # map step_run) est déléguée à `StepRunBuild.build/5` (frontière blindée via `build_seams/1`) ;
  # ICI reste l'orchestration (offload + appel completer).
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

    # E4 : TOUTE la construction (dont la résolution de branche juge → list_open_pulls HTTP inline,
    # timeout 10s) vit DANS la closure offloadée — forge dégradée + rafale de pod.completed ne bloque
    # plus la mailbox du singleton (le handle_info redevient O(1) en prod, l'offload porte l'I/O).
    run_completion(state, "##{n}", fn ->
      step_run = StepRunBuild.build(payload, n, role, route, build_seams(state))
      hc_opts = completer_opts(state) |> Opts.maybe_put(:deliverable, state.deliverable)

      state.step_run_completer.complete_pr(step_run, hc_opts)
    end)
  end

  # Frontière blindée vers `StepRunBuild` : les 6 lectures autorisées de la construction.
  # Construit depuis le state DÉRIVÉ per-step-run (repo/remote de l'event, multi-projet).
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

  # Classement producteur/juge — AUTORITÉ UNIQUE `GateEngine.producer?/2` (partagée avec la
  # décision de gate et StepRunBuild) ; wrapper local qui lit le seam `deliverable_mode_fun` du state.
  defp producer?(role, state), do: GateEngine.producer?(role, state.deliverable_mode_fun)

  # Defaut du seam : resout le deliverable_mode du role via le catalogue cap-profile (source unique).
  # Irresoluble → `"payload"` (fail-safe : un role non chargeable n'est pas traite comme producteur).
  defp default_deliverable_mode(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, cap} -> Fleet.CapProfile.deliverable_mode(cap)
      _ -> "payload"
    end
  end

  # La RÉSOLUTION du prochain step (gate/rebond/verdict-juge/escalade gatekeeper) vit dans
  # `GateEngine.resolve_next/3` (frontière blindée via `gate_seams/1`) — CE module ne garde que
  # l'ORCHESTRATION (agir sur la décision rendue).

  # Construit le struct de seams ÉTROIT passé à `GatekeeperEscalation.dispatch` (via GateEngine) :
  # les 4 seams async-out lus du state (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery).
  # On NE passe PAS `state` entier — frontière blindée : le cluster d'escalade ne peut rien lire d'autre.
  defp escalation_seams(state) do
    %GatekeeperEscalation.Seams{
      task_queue: state.task_queue,
      spawner: state.spawner,
      gatekeeper_pod_id_fun: state.gatekeeper_pod_id_fun,
      wake_recovery: state.wake_recovery
    }
  end

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
        # `GateEngine.advance_intent/3` que le chemin gate `:pass` : un producteur
        # terminal → `:review` (ouvre la PR + demande les juges, JAMAIS d'auto-merge d'un livrable) ; un juge
        # terminal (consultant brief-review) → `:promote` (il a validé le dernier gate de sa workflow_map) ;
        # un step suivant → `:advance`. Une seule source de vérité pour l'intent terminal.
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
        # NE PAS enterrer en silence : le commentaire de close est ADRESSÉ à l'arch (auteur du brief)
        # + on KICKE l'arch (sas unique vers l'humain) → l'auteur APPREND que son brief a été jeté.
        arch_trace =
          "**Architecte** (auteur du brief) — brief ABANDONNÉ par le juge. " <>
            trace <> " (Non récupérable ; re-crée un brief corrigé si besoin.)"

        result = close_with_trace(n, role, arch_trace, state)
        _ = TerminalEscalation.kick_architect(state.spawner)
        result

      other ->
        # `comment_body: trace` → la trace verdict (attribuée au juge via son label, halt_invalid
        # distingué) est portée sur le comment await_arch (qui l'adresse à l'arch), parité continue/abandon.
        # Filet UNIQUE `freeze_to_arch` (await_arch + kick) — même geste que les escalades terminales.
        TerminalEscalation.freeze_to_arch(n, role, other, trace, terminal_seams(state))
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

    run_completion(state, "##{n}", fn ->
      state.step_run_completer.complete(step_run, completer_opts(state))
    end)
  end

  # Chargement de workflow_map (reconstruction d'eval_ctx) — autorité unique
  # `WorkflowMapNav.safe_load` (tag unifié :workflow_map_load_failed), même source que le GateEngine.
  defp load_workflow_map(state, workflow_map_name),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(state.loader, workflow_map_name)

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
