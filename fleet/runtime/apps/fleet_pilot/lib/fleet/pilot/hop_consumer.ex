defmodule Fleet.Pilot.HopConsumer do
  @moduledoc """
  Consumer Bus de la **fin-de-hop** (DN `orchestration/forge-state-machine.md`).
  Subscribe `Fleet.EventRouter.Bus` (topic `fleet.events`) ; sur chaque
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` d'un pod
  **stage-dispatch** (assignee-driven), traduit l'event en `hop` et délègue la
  séquence §5 à `Fleet.Pilot.HopCompleter`.

  ## Gatekeeper = pattern B (§L441 exception), PAS un stage

  La gate du stage fini décide AVANT d'avancer (`Fleet.Pipeline.Gates.evaluate/3`,
  PUR) :

    * `:pass`                  → avance dans la carte (next_stage).
    * `{:fail, _}`             → REBOND borné vers le 1er stage (rework anti-runaway).
    * `{:dispatch_gatekeeper}` → **escalade** : une gate `soft` ou `terminal`
      non-tranchable n'est PAS un stage d'ordonnancement — c'est une convocation
      du **gatekeeper permanent** (juge d'exception §L441 ; GATE-D1). On enqueue
      un mandat d'éval au gatekeeper (work-session, adressé par `pod_id` via
      TaskQueue/MCP), on tient le contexte de reprise en RAM (`gate_evals`, keyé
      par `correlation_id`), et la décision revient async via
      `%Fleet.Event{source: :task_queue, type: :task_completed}` → `resume_gate/3`.

  Le juge est **rare par construction** : le moteur ne peut pas le sur-convoquer
  (le `soft`/non-tranchable est une *condition runtime*, pas un *tag de stage*).
  Pas de stage `role: gatekeeper`, pas de biconditionnelle `soft⟺gatekeeper` —
  toute la machinerie explicit-stage (A2.3b) est retirée. Jumeau forge-driven de
  `Fleet.Pipeline.Executor.do_dispatch_gatekeeper`/`handle_gate_decision` (RAM).

  ## Pourquoi un consumer séparé de l'Executor

  Deux stacks cohabitent (dual-run, le temps que l'Executor RAM soit retiré) :

    * **Pipeline pods** — payload porte `pipeline_id` → l'`Executor` les corrèle
      à leur stage. **Ce consumer les IGNORE** (`pipeline_id` présent → skip).
    * **Stage-dispatch pods** — pas de `pipeline_id`, mais (s'ils portent un
      projet) le payload embarque `workspace` + `base_sha` + `role` (enrichi à la
      source, `Fleet.Spawner.Pod.pod_completed_payload`). **Ce consumer les
      traite.** L'event porte tout l'état → consumer stateless POUR LE HAPPY PATH
      (pass/fail) ; seules les escalades gatekeeper en attente vivent en RAM
      (`gate_evals`) — parité Executor (fragile au restart ; recovery forge =
      hors-scope).

  ## Traduction event → hop

    * `issue_number` ← `ticket_id` (`"issue-N"` → `N`)
    * `repo` ← config `:repo`
    * `deliverable_opts` ← `{mode: :git_native, workspace, base_sha,
      allowed_emails(role), remote, target_branch}` ; le SYSTÈME pousse
      (barrière §4, F-04) sur une branche système `lcars/issue-N-role`
      (merge-vers-main = BL-044/A2, pas ici).
    * `next_assignee: nil` → **1-stage terminal** (close). Le multi-stage
      (lookup du suivant dans la carte) = **A2**.

  ## Config / seams

    * `:repo` — `"owner/name"` (obligatoire)
    * `:remote` — URL/nom du remote où le système pousse (obligatoire)
    * `:forge_opts` — passé au ForgeClient via HopCompleter
    * `:role_emails` — `fn role -> [email] end` (défaut `"<role>@lcars.local"`),
      doit matcher l'identité git injectée au pod (gate F-01)
    * `:hop_completer` — seam (défaut `Fleet.Pilot.HopCompleter`)
    * `:task_queue` — broker de mandats pour l'escalade gatekeeper (défaut `Fleet.TaskQueue`)
    * `:spawner` — wake du gatekeeper après enqueue (défaut `Fleet.Spawner`)
    * `:gatekeeper_pod_id_fun` — `fn -> pod_id | nil end` (défaut `&Fleet.Pipeline.Gatekeeper.pod_id/0`)
    * `:subscribe` — bool défaut `true` (tests : `false` + envoi manuel)
    * `:hop_runner` — F067 : seam d'offload de la complétion. Défaut `nil` → **SYNC** (l'outcome remonte,
      seams/tests inchangés). Prod (`application.ex`) injecte `&offload_async/1` → la complétion (git push
      ≤30s + writes forge) tourne dans une `Task.Supervisor` : le **singleton HopConsumer ne bloque pas**
      (et un `.complete` qui crash est isolé par la task supervisée).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  defstruct [
    :repo,
    :remote,
    :forge_opts,
    :role_emails,
    :hop_completer,
    :forge_client,
    :loader,
    :deliverable,
    # Corr.3 — resout le deliverable_mode d'un role (`"git_native"` producteur / `"payload"` juge)
    # pour classer le hop PR-natif. Defaut = catalogue cap-profile. Seam test (zero chargement).
    :deliverable_mode_fun,
    :max_rework_rounds,
    # B (§L441) — seams d'escalade gatekeeper.
    :task_queue,
    :spawner,
    :gatekeeper_pod_id_fun,
    # F066 — boot du gatekeeper permanent en stage-mode (ensure_booted idempotent, gardé
    # :gatekeeper_autoboot). Sans ça, en stage-only rien ne boote/registre le gatekeeper →
    # pod_id/0 nil → toute escalade soft/terminal échoue {:error,:no_gatekeeper}.
    :gatekeeper_boot_fun,
    # B (§L441) — escalades en attente, keyées par correlation_id (= task.id du
    # mandat d'éval). Valeur = contexte de reprise `%{n, role, payload, carte, stage}`.
    gate_evals: %{},
    # F067 : seam d'offload de la complétion. Défaut nil → `run_completion` retombe sur SYNC (l'outcome
    # remonte, seams `maybe_complete`/`resume_gate` + tous les tests inchangés). Prod = async Task.Supervisor.
    hop_runner: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  # F067 : superviseur de tasks pour l'offload de la complétion (prod). Nom partagé entre
  # `application.ex stage_children` (qui le démarre AVANT le HopConsumer) et `offload_async/1`.
  @hop_task_supervisor Fleet.Pilot.HopTaskSupervisor

  @doc false
  def task_supervisor, do: @hop_task_supervisor

  # F067 : runner ASYNC (prod, injecté en `:hop_runner`) — offload la complétion dans la
  # `Task.Supervisor` : le git push ≤30s + writes forge ne bloquent PAS le singleton. Rend
  # `{:ok, :offloaded}` (le vrai outcome est loggé dans la task). Échec de spawn → fail-loud loggé.
  @doc false
  def offload_async(fun) do
    case Task.Supervisor.start_child(@hop_task_supervisor, fun) do
      {:ok, _pid} ->
        {:ok, :offloaded}

      {:error, reason} ->
        Logger.error("HopConsumer: offload Task échoué (#{inspect(reason)}) — complétion perdue")
        {:error, {:offload_failed, reason}}
    end
  end

  @impl GenServer
  def init(opts) do
    with {:ok, repo} <- require_opt(opts, :repo),
         {:ok, remote} <- require_opt(opts, :remote) do
      if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()

      state = %__MODULE__{
        repo: repo,
        remote: remote,
        forge_opts: Keyword.get(opts, :forge_opts, []),
        role_emails: Keyword.get(opts, :role_emails, &default_role_emails/1),
        hop_completer: Keyword.get(opts, :hop_completer, Fleet.Pilot.HopCompleter),
        # nil → HopCompleter applique son défaut (Fleet.Pilot.ForgeClient). Injectable
        # pour un backend forge alternatif (ou un sim en dogfood bare).
        forge_client: Keyword.get(opts, :forge_client),
        # Loader de carte (A2 multi-stage) : résout le stage suivant. Défaut = Loader réel.
        loader: Keyword.get(opts, :loader, Fleet.Pipeline.Loader),
        # nil → HopCompleter applique son défaut (Fleet.Pipeline.Deliverable). Injectable (sim/test).
        deliverable: Keyword.get(opts, :deliverable),
        # Corr.3 — classification producteur/juge du hop PR-natif. Defaut = catalogue cap-profile.
        deliverable_mode_fun:
          Keyword.get(opts, :deliverable_mode_fun, &default_deliverable_mode/1),
        # A2.3 : bound anti-runaway du rebond de gate. Budget de hops = nb_stages *
        # (max_rework_rounds + 1) : la 1re passe + N rounds de rework. Au-delà → stuck
        # surfacé (pas de boucle). Défaut 2 rounds.
        max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2),
        # B (§L441) — seams d'escalade gatekeeper (défauts = broker/spawner/registry réels).
        task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
        spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
        gatekeeper_pod_id_fun:
          Keyword.get(opts, :gatekeeper_pod_id_fun, &Fleet.Pipeline.Gatekeeper.pod_id/0),
        gatekeeper_boot_fun:
          Keyword.get(opts, :gatekeeper_boot_fun, &Fleet.Pipeline.Gatekeeper.ensure_booted/0),
        gate_evals: %{},
        # F067 (critique panel) : prod (stage_children) injecte `&offload_async/1` ici ; sans cette
        # lecture, `run_completion` retombait sur sync → le git push bloquait le singleton (offload mort).
        hop_runner: Keyword.get(opts, :hop_runner)
      }

      Logger.info("fleet_pilot HopConsumer start repo=#{repo} remote=#{remote}")
      # F066 : en stage-mode, le HopConsumer EST le chemin actif → il assure le gatekeeper
      # permanent (handle_continue : boot hors init, OTP). Idempotent + gardé autoboot (no-op
      # en test où gatekeeper_autoboot=false ; no-op si le path RAM l'a déjà booté).
      {:ok, state, {:continue, :ensure_gatekeeper}}
    else
      {:error, missing} -> {:stop, {:missing_required_opt, missing}}
    end
  end

  @impl GenServer
  def handle_continue(:ensure_gatekeeper, state) do
    case state.gatekeeper_boot_fun.() do
      {:ok, :disabled} ->
        :ok

      {:ok, pod_id} ->
        Logger.info("HopConsumer: gatekeeper permanent assuré (pod=#{pod_id})")

      {:error, reason} ->
        Logger.warning(
          "HopConsumer: ensure gatekeeper échoué (#{inspect(reason)}) — escalades KO"
        )
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    case maybe_complete(p, state) do
      # F067 : l'outcome est loggé par `run_completion` (dans la task en async), pas ici.
      {:ok, _outcome} ->
        {:noreply, state}

      # B (§L441) — gate non-tranchable : le mandat d'éval est enqueué au gatekeeper
      # permanent ; on tient le contexte de reprise jusqu'au `task_completed` corrélé.
      # L'issue reste verrouillée (in-flight) → le poller ne re-spawn pas (pas d'avance
      # à l'aveugle avant le verdict).
      {:escalate, corr, eval_ctx} ->
        Logger.info(
          "HopConsumer gate→gatekeeper: #{p["ticket_id"]} stage=#{eval_ctx.stage} corr=#{inspect(corr)}"
        )

        {:noreply, %{state | gate_evals: Map.put(state.gate_evals, corr, eval_ctx)}}

      {:skip, reason} ->
        Logger.debug("HopConsumer skip #{p["ticket_id"]} (#{reason})")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("HopConsumer fin-de-hop FAIL #{p["ticket_id"]}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # B (§L441) — décision du gatekeeper reçue : le mandat d'éval (corrélé par
  # `correlation_id` = task.id de l'enqueue) est complété. Jumeau forge-driven de
  # `Executor.handle_info(:task_completed)`. On ne traite QUE les corr qu'on a en
  # attente (les autres task_completed — autres stacks, autres pods — sont ignorés).
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :task_completed, correlation_id: corr} = ev,
        state
      )
      when is_binary(corr) do
    case Map.pop(state.gate_evals, corr) do
      {nil, _} ->
        {:noreply, state}

      {eval_ctx, gate_evals} ->
        state = %{state | gate_evals: gate_evals}

        case resume_gate(eval_ctx, ev.payload, state) do
          # F067 : outcome loggé par `run_completion` ; ici on ne logge que l'erreur de DÉCISION (pré-complétion).
          {:ok, _outcome} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "HopConsumer gate resume FAIL corr=#{inspect(corr)}: #{inspect(reason)}"
            )
        end

        {:noreply, state}
    end
  end

  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Traduction event → hop (pure sauf l'appel HopCompleter / enqueue mandat)
  # ============================================================

  @doc false
  # Exposé pour test : décide skip/complete/escalade sans passer par le GenServer.
  # Retourne `{:ok, outcome}` | `{:skip, reason}` | `{:escalate, corr, eval_ctx}` |
  # `{:error, reason}`.
  def maybe_complete(payload, state) do
    cond do
      Map.has_key?(payload, "pipeline_id") ->
        {:skip, :pipeline_pod}

      not project_payload?(payload) ->
        {:skip, :no_project}

      true ->
        case parse_issue_number(payload["ticket_id"]) do
          {:ok, n} -> run_hop(payload, n, state)
          :error -> {:skip, {:bad_ticket_id, payload["ticket_id"]}}
        end
    end
  end

  defp run_hop(payload, n, state) do
    role = payload["role"]

    # A2 : si le payload porte le contexte carte (pipeline+stage), le stage suivant
    # est calculé par CarteNav (reassign vers le rôle suivant, ou close si terminal).
    # Sans contexte carte (A1 1-stage) → next_assignee nil → close. Une erreur de carte
    # (DAG, stage inconnu) NE misroute PAS : elle remonte (le système n'avance pas à l'aveugle).
    case resolve_next(payload, n, state) do
      {:error, reason} ->
        {:error, reason}

      # B (§L441) — escalade gatekeeper : remonte au handle_info qui stocke `gate_evals`.
      {:escalate, corr, eval_ctx} ->
        {:escalate, corr, eval_ctx}

      {:ok, intent, {next_assignee, next_stage}} ->
        complete_business_hop(payload, n, role, intent, next_assignee, next_stage, state)
    end
  end

  # F067 : exécute la complétion d'un hop via le seam `hop_runner`. SYNC (défaut) → exécute, logge
  # l'outcome, et le REND (seams `maybe_complete`/`resume_gate` + tous les tests le reçoivent). ASYNC
  # (prod, Task.Supervisor) → offload : le git push ≤30s + writes forge ne bloquent PAS le singleton,
  # l'outcome est loggé DANS la task, le runner rend `{:ok, :offloaded}`. Ordering préservé (lock
  # lcars-in-flight + writes idempotentes, per finding F067). Un `.complete` qui crash en async est
  # isolé par la task supervisée (ne tue plus le HopConsumer).
  defp run_completion(state, label, fun) do
    exec = fn ->
      outcome = fun.()

      case outcome do
        {:error, reason} ->
          Logger.warning("HopConsumer fin-de-hop FAIL #{label}: #{inspect(reason)}")

        _ ->
          Logger.info("HopConsumer fin-de-hop #{label} → #{inspect(outcome)}")
      end

      outcome
    end

    (state.hop_runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()

  # Corr.3 — construit + applique le hop PR-natif. Classe le role qui FINIT (producteur git_native
  # → ouvre la PR ; juge payload → review la PR du producteur) puis delegue le routage selon
  # l'`intent` de gate a `HopCompleter.complete_pr`. `next_stage` ne sert plus (la route §5 disparait
  # avec le pari Gitea). `comment_body` (trace verdict gatekeeper sur continue) est porte mais pas
  # encore materialise sur la PR — gap transitionnel note (la trace vit dans le resultat de tache du
  # gatekeeper ; PR-trace = increment ulterieur).
  defp complete_business_hop(
         payload,
         n,
         role,
         intent,
         next_assignee,
         next_stage,
         state,
         comment_body \\ nil
       ) do
    {pr_role, producer_branch} = classify_pr_role(payload, n, role, state)

    hop =
      %{
        repo: state.repo,
        issue_number: n,
        role: role,
        pr_role: pr_role,
        intent: intent,
        next_assignee: next_assignee,
        # Pont transitionnel : pipeline+next_stage gravent la route que le StageDispatcher lit
        # pour spawner le stage suivant (retire a l'increment 4, switch sur la review-request).
        next_stage: next_stage,
        pipeline: payload["pipeline"],
        producer_branch: producer_branch,
        base_branch: "main"
      }
      |> put_unless_nil(:comment_body, comment_body)
      |> maybe_put_deliverable(pr_role, role, payload, n, state)
      |> maybe_put_review_event(pr_role, intent, payload)
      |> maybe_put_eng_summary(pr_role, payload)

    hc_opts =
      [forge_opts: state.forge_opts]
      |> maybe_put(:forge_client, state.forge_client)
      |> maybe_put(:deliverable, state.deliverable)

    run_completion(state, "##{n}", fn ->
      state.hop_completer.complete_pr(hop, hc_opts)
    end)
  end

  # Le producteur (engineer) porte sa `deliverable_opts` (publish vers sa feature-branch) ; le juge
  # review (il ne pousse pas — son verdict est une review native), pas de livrable git.
  defp maybe_put_deliverable(hop, :producer, role, payload, n, state),
    do: Map.put(hop, :deliverable_opts, build_deliverable_opts(role, payload, n, state))

  defp maybe_put_deliverable(hop, :judge, _role, _payload, _n, _state), do: hop

  # ②.1d — pour un JUGE no-carte (intent `:reviewed`), le verdict de review (APPROVE/REQUEST_CHANGES)
  # est lu du gate-decision rendu par le pod (GateBrief : `continue`/`abandon`). On le mappe ici et on
  # le porte dans le hop (`:review_event`) → `HopCompleter.record_review` poste la review correspondante.
  # `continue`→approve ; tout le reste (`abandon`/redirect/escalate/halt/illisible)→**request_changes**
  # (fail-closed DÉCISIF). PAS `:comment` : une review COMMENT n'est pas décisive → le juge resterait
  # « non tranché » et serait re-jugé en boucle (vérifié live #6). Un verdict non-`continue` = pas vert
  # → on bloque le merge (rework), jamais un merge sur verdict douteux. (escalade-gatekeeper d'un verdict
  # non-trivial = backlog DN §1.5 ; ici fail-closed strict.)
  defp maybe_put_review_event(hop, :judge, :reviewed, payload) do
    result = unwrap_worker_envelope(payload["result"] || %{})
    event = review_event_for_decision(gate_decision(result))
    hop = Map.put(hop, :review_event, event)

    # Le juge PRODUIT un `reason`/`details`/`chain` dans sa gate-decision → on le REND sur la review
    # (visu humaine + rework actionnable). Sinon `HopCompleter.record_review` retombe sur le corps
    # générique (« la brique ne satisfait pas son critère »), inactionnable — pour l'humain comme pour
    # le producteur en rework (live #8). On ne pose `:review_body` QUE s'il y a de la substance (sans
    # quoi `Map.get(hop, :review_body, default)` renverrait `nil` au lieu du défaut).
    case judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(hop, :review_body, body)
      _ -> hop
    end
  end

  defp maybe_put_review_event(hop, _pr_role, _intent, _payload), do: hop

  # VOIX DE L'ENG (info SORTANTE) : le PRODUCTEUR peut rendre un `summary` markdown dans submit_result
  # (ce qu'il a fait / réponse à la review / motif blocked). On l'extrait du résultat (déplié de
  # l'enveloppe worker) → `HopCompleter` le poste en commentaire PR (`as_role` engineer). Coercé par
  # `safe_str` (#8 : l'eng peut rendre un non-binaire → ne pas crasher le singleton). Absent/vide → rien
  # posé. Jumeau SORTANT de la famine d'info ENTRANTE — complète la « panne bidirectionnelle de substance ».
  defp maybe_put_eng_summary(hop, :producer, payload) do
    case eng_summary(payload) do
      "" -> hop
      summary -> Map.put(hop, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(hop, _pr_role, _payload), do: hop

  defp eng_summary(payload) do
    case unwrap_worker_envelope(payload["result"] || %{}) do
      m when is_map(m) -> m |> Map.get("summary") |> safe_str() |> String.trim()
      _ -> ""
    end
  end

  defp review_event_for_decision("continue"), do: :approve
  defp review_event_for_decision(_other), do: :request_changes

  # Compose le corps de review depuis la gate-decision du juge. `nil` si aucune substance (→ le
  # défaut générique de `record_review`, qui porte au moins l'instruction de rework).
  defp judge_review_body(event, result) when is_map(result) do
    reason = result |> Map.get("reason") |> safe_str() |> String.trim()
    details = format_review_details(Map.get(result, "details"))
    chain = format_review_chain(Map.get(result, "chain"))
    substance = Enum.reject([reason, details, chain], &(&1 in [nil, ""]))

    if substance == [] do
      nil
    else
      verdict = if event == :approve, do: "APPROUVÉ", else: "CHANGEMENTS DEMANDÉS"

      ["**#{verdict}** — verdict du juge.", reason, details, chain]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    end
  end

  defp judge_review_body(_event, _), do: nil

  # Coercion sûre des sorties LLM : un juge peut rendre `reason`/`details`/`chain` en objets ou listes
  # imbriqués → interpoler/`to_string` brut crashe (String.Chars non implémenté pour Map/List). Tout
  # non-binaire est `inspect`é. CRITIQUE : la construction du corps NE DOIT PAS crasher le HopConsumer
  # (SINGLETON) — sinon la fin-de-hop est perdue, le verrou jamais levé, le pipe wedgé (régression live #8).
  defp safe_str(nil), do: ""
  defp safe_str(s) when is_binary(s), do: s
  defp safe_str(other), do: inspect(other)

  defp format_review_details(d) when is_map(d) and map_size(d) > 0,
    do:
      "**Détails**\n" <>
        Enum.map_join(d, "\n", fn {k, v} -> "- **#{safe_str(k)}** : #{safe_str(v)}" end)

  defp format_review_details(_), do: nil

  defp format_review_chain(c) when is_list(c) and c != [],
    do: "**Raisonnement**\n" <> Enum.map_join(c, "\n", fn item -> "- #{safe_str(item)}" end)

  defp format_review_chain(_), do: nil

  # Corr.3 (engineer-first) — classe le role qui finit. Producteur = role git_native (engineer) →
  # pousse le code, ouvre la PR (head = sa propre branche). Juge = role payload (qualifier/reviewer
  # en AVAL) → review la PR du producteur (head = le head.ref de la PR ouverte de l'issue, résolu
  # sans carte via `parse_feature_branch`, ②.1c). Un juge sans producteur resoluble → `producer_branch`
  # nil → `complete_pr` fail-loud `:no_producer_branch` (jamais un mauvais merge). Les stages design
  # AMONT du producteur (architect) sont hors-scope Corr.3 (decision engineer-first, mapping PR).
  defp classify_pr_role(payload, n, role, state) do
    if producer?(role, state) do
      {:producer, branch_for(n, role)}
    else
      {:judge, judge_producer_branch(payload, n, state)}
    end
  end

  defp branch_for(n, role), do: "lcars/issue-#{n}-#{role}"

  defp producer?(role, state) when is_binary(role),
    do: state.deliverable_mode_fun.(role) == "git_native"

  defp producer?(_role, _state), do: false

  # Sans carte (forge-state-machine ②.1c) : le producteur = celui qui a OUVERT la PR de l'issue N.
  # Sa branche = le `head.ref` de cette PR (`lcars/issue-N-<producteur>`), retrouvée en listant les PR
  # ouvertes + `parse_feature_branch` (même pattern que le Poller). Le modèle 1-brique=1-producteur
  # a retiré la carte (plus de `payload["pipeline"]` → l'ancienne résolution carte rendait nil → merge
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

      case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
        {:ok, {^n, _role}} -> head
        _ -> false
      end
    end)
  end

  # Defaut du seam : resout le deliverable_mode du role via le catalogue cap-profile (source unique,
  # meme mecanique que l'Executor). Irresoluble → `"payload"` (fail-safe : un role non chargeable
  # n'est pas traite comme producteur).
  defp default_deliverable_mode(role) do
    case Fleet.CapProfile.load(role) do
      {:ok, cap} -> Fleet.CapProfile.deliverable_mode(cap)
      _ -> "payload"
    end
  end

  # Livrable d'un hop métier : `:git_native`. Le pod a commité dans son workspace
  # (barrière §4), le système vérifie (gate F-01/F-03) + pousse. En B il n'existe PAS
  # de stage `role: gatekeeper` → plus de branche `:payload`/verdict.json ici (le verdict
  # du gatekeeper est tracé par `resume_gate`, pas matérialisé comme livrable de stage).
  defp build_deliverable_opts(role, payload, n, state) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      base_sha: payload["base_sha"],
      allowed_emails: state.role_emails.(role),
      # Z4 (A.2) — F-01 vérifie le trailer `Co-authored-by: LCARS-<role>` (signature rôle).
      coauthor_role: role,
      remote: state.remote,
      target_branch: "lcars/issue-#{n}-#{role}",
      push?: true,
      local_ref: "HEAD"
    }
  end

  # Résout le prochain assignee depuis la carte (A2.4). Le contexte carte arrive dans le
  # payload `pod.completed` : `pipeline` (nom de carte) + `stage` (nom du stage courant —
  # le NOM, pas le rôle, cf. CarteNav wrinkle DN §8). Absent → 1-stage terminal (A1).
  defp resolve_next(payload, n, state) do
    case {payload["pipeline"], payload["stage"]} do
      {pipeline, stage} when is_binary(pipeline) and is_binary(stage) ->
        with {:ok, carte} <- load_carte(state, pipeline) do
          gate_decide(carte, stage, payload, n, state)
        end

      _ ->
        # ②.1d — pas de carte (single-brique) : l'intent dépend du RÔLE qui finit, plus de
        # `:promote` direct (l'ancien terminal mergeait SANS juge). Le merge est piloté par
        # l'état-PR (dispatch_review), pas par l'intent d'un pod isolé.
        no_carte_resolve(payload, state)
    end
  end

  # ②.1d — résolution single-brique (sans carte) :
  #   producteur (git_native) → `:review` : `complete_pr` ouvre la PR + met les juges en
  #     `requested_reviewers` + assigne l'humain + unlock l'issue ;
  #   juge (payload) → `:reviewed` : `complete_pr` poste la review native (verdict lu du gate-decision,
  #     porté plus loin via `:review_event`) + unlock la PR. Le merge/rework = poller (dispatch_review).
  defp no_carte_resolve(payload, state) do
    if producer?(payload["role"], state) do
      {:ok, :review, {nil, nil}}
    else
      {:ok, :reviewed, {nil, nil}}
    end
  end

  # A2.3 — la gate du stage FINI décide AVANT d'avancer (DN forge-state-machine §9).
  # `Gates.evaluate/3` est PUR (gate nil/absente → :pass) ; on lui passe la spec du
  # stage qui vient de finir + le `result` du pod (outputs → prédicats hard).
  #
  #   :pass                     → avance dans la carte (next_stage)
  #   {:fail, _}                → REBOND vers le 1er stage (rework), BORNÉ (anti-runaway,
  #                               I-CBC : une boucle de rework infinie ne doit pas être
  #                               représentable).
  #   {:dispatch_gatekeeper, _} → B (§L441) : enqueue un mandat d'éval au gatekeeper
  #                               permanent + `{:escalate, corr, eval_ctx}` (reprise async
  #                               sur `task_completed`). Enqueue raté → fail-loud (l'issue
  #                               reste verrouillée, pas d'avance à l'aveugle).
  defp gate_decide(carte, stage, payload, n, state) do
    spec =
      case Fleet.Pilot.CarteNav.stage_spec(carte, stage) do
        {:ok, s} -> s
        # stage inconnu : pas de gate → next_stage tranchera ({:error,:unknown_stage}),
        # pas de misroute silencieux.
        :error -> %{}
      end

    # Z3 #2 : déplie l'enveloppe worker `%{"status","result"}` AVANT d'évaluer la gate —
    # sinon la gate voit l'enveloppe au lieu des outputs (hard-gate à tort).
    result = unwrap_worker_envelope(payload["result"] || %{})

    case Fleet.Pipeline.Gates.evaluate(spec, result, %{}) do
      :pass ->
        # Corr.3 — tag l'intent PR : `:advance` (stage suivant) | `:promote` (terminal).
        tag_advance(advance(carte, stage))

      {:fail, reason} ->
        Logger.info("HopConsumer gate FAIL repo=#{state.repo}##{n} stage=#{stage}: #{reason}")
        tag(:rework, rebound(carte, n, state))

      {:dispatch_gatekeeper, _info} ->
        case dispatch_gatekeeper(carte, stage, result, state) do
          {:ok, corr} ->
            {:escalate, corr,
             %{n: n, role: payload["role"], payload: payload, carte: carte, stage: stage}}

          {:error, reason} ->
            {:error, {:gatekeeper_dispatch, reason}}
        end
    end
  end

  # Corr.3 — tag l'intent PR sur le routage de la carte. `:pass` → `:advance` si un stage suit,
  # `:promote` si terminal (next_assignee nil). Préserve `{:error,_}` tel quel.
  defp tag_advance({:ok, {nil, nil}}), do: {:ok, :promote, {nil, nil}}
  defp tag_advance({:ok, routing}), do: {:ok, :advance, routing}
  defp tag_advance(other), do: other

  defp tag(intent, {:ok, routing}), do: {:ok, intent, routing}
  defp tag(_intent, other), do: other

  # B (§L441) — jumeau forge-driven de `Fleet.Pipeline.Executor.do_dispatch_gatekeeper`.
  # Enqueue un mandat d'éval au gatekeeper PERMANENT (work-session, adressé par pod_id —
  # l'overseer n'est PAS spawné/possédé ici), le kick (best-effort), et retourne le
  # `correlation_id` (= task.id) pour la corrélation `task_queue.task_completed`. Pas de
  # gatekeeper booté / enqueue raté → `{:error, _}` (l'appelant fail-loud ; jamais un pass
  # silencieux).
  defp dispatch_gatekeeper(carte, stage, outputs, state) do
    case state.gatekeeper_pod_id_fun.() do
      pod_id when is_binary(pod_id) ->
        gate = get_in(carte, ["stages", stage, "gate"])
        pipeline = Map.get(carte, "name")

        brief =
          Fleet.Pipeline.GateBrief.build(%{
            stage: stage,
            pipeline_id: pipeline,
            gate: gate,
            outputs: outputs
          })

        attrs = %{
          role: "gatekeeper",
          brief: brief,
          metadata: %{
            "gate_eval" => true,
            "stage" => stage,
            "pipeline" => pipeline,
            "gate" => gate,
            "outputs" => outputs
          }
        }

        case state.task_queue.enqueue(pod_id, attrs) do
          {:ok, %{id: corr}} ->
            kick_gatekeeper(state, pod_id)
            {:ok, corr}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_gatekeeper}
    end
  end

  # KICK le gatekeeper après l'enqueue. Pod PERMANENT déjà booté+idle (:monitoring) : son
  # kick-loop de boot est fini, ce mandat arrive APRÈS → sans wake il ne pull jamais (gate
  # qui stalle). Best-effort (jumeau Executor) : le mandat est enqueué quoi qu'il arrive ;
  # wake raté → warn (le gatekeeper, déjà ready, le reçoit normalement).
  defp kick_gatekeeper(state, pod_id) do
    case state.spawner.wake_pod(pod_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "HopConsumer gate kick gatekeeper=#{inspect(pod_id)} failed: #{inspect(reason)}"
        )
    end
  end

  @doc false
  # B (§L441) — reprise après le verdict du gatekeeper. Exposé pour test (le GenServer
  # appelle via handle_info(:task_completed)). `raw_payload` = payload brut du
  # `task_completed` (déplié ici par `gate_result/1` : enveloppe TaskQueue + enveloppe
  # worker). Vocab canon `gate-decision-v1.json` :
  #   continue → avance (push livrable métier + reassign) ;
  #   abandon  → close (trace verdict, PAS de push : travail rejeté) ;
  #   redirect|escalate_user|halt_wait_input|invalide → await_human (fail-closed).
  # La TRACE du verdict est durable : portée dans le comment signé du hop (continue/abandon)
  # ou du await_human — c'est ce dont l'absence a coulé la v1.
  def resume_gate(
        %{n: n, role: role, payload: payload, carte: carte, stage: stage},
        raw_payload,
        state
      ) do
    result = gate_result(raw_payload)
    decision = gate_decision(result)
    trace = verdict_comment(decision, result)

    case decision do
      "continue" ->
        case advance(carte, stage) do
          {:ok, {next_assignee, next_stage}} ->
            intent = if is_nil(next_assignee), do: :promote, else: :advance

            complete_business_hop(
              payload,
              n,
              role,
              intent,
              next_assignee,
              next_stage,
              state,
              trace
            )

          {:error, reason} ->
            {:error, reason}
        end

      "abandon" ->
        close_with_trace(n, role, trace, state)

      other ->
        # `comment_body: trace` → la trace verdict (attribuée au gatekeeper, halt_invalid
        # distingué) est portée sur le comment await_human, parité continue/abandon.
        hop = %{
          repo: state.repo,
          issue_number: n,
          role: role,
          decision: other,
          comment_body: trace
        }

        hc_opts = [forge_opts: state.forge_opts] |> maybe_put(:forge_client, state.forge_client)

        run_completion(state, "##{n}", fn ->
          state.hop_completer.await_human(hop, hc_opts)
        end)
    end
  end

  # Verdict `abandon` : close terminal forge, SANS push (le travail métier est rejeté).
  # NB : l'Executor (RAM, pipeline-centric) n'a PAS de notion "close issue" — il fait
  # `broadcast_pipeline_failed` + stop ; ici (forge-driven) l'équivalent est close_issue.
  # Point commun : aucun des deux n'extrait/pousse le livrable sur un verdict non-continue.
  # `deliverable_opts: nil` + `hop_sha` → HopCompleter saute l'étape publish, garde la
  # séquence idempotente (comment trace → state → close → unlock).
  defp close_with_trace(n, role, trace, state) do
    hop = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      deliverable_opts: nil,
      hop_sha: "gate-abandon",
      next_assignee: nil,
      state_label: Fleet.Pilot.Labels.delivered(),
      comment_body: trace
    }

    hc_opts = [forge_opts: state.forge_opts] |> maybe_put(:forge_client, state.forge_client)

    run_completion(state, "##{n}", fn ->
      state.hop_completer.complete(hop, hc_opts)
    end)
  end

  # Trace lisible du verdict (portée dans le comment du hop → durable en forge).
  # `halt_invalid` n'est PAS une décision du gatekeeper : c'est le fallback fail-closed
  # interne (verdict absent/malformé) → message distinct pour ne pas faire croire à un
  # verdict gatekeeper "halt_invalid".
  defp verdict_comment("halt_invalid", _result) do
    "Verdict du **gatekeeper** illisible ou absent (fail-closed) → escalade humaine."
  end

  defp verdict_comment(decision, result) do
    reason = if is_map(result), do: Map.get(result, "reason")

    base =
      "Verdict du **gatekeeper** (juge d'exception §L441) — décision : `#{decision}`."

    if is_binary(reason) and reason != "", do: base <> "\nMotif : #{reason}", else: base
  end

  # Extrait la décision du payload `task_completed`. DEUX enveloppes : (1) TaskQueue pose
  # `:result` (clé atom) ; (2) enveloppe worker `%{"status","result"}` (clés string).
  # Jumeau de `Executor.gate_result/1`.
  defp gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || Map.get(payload, "result"))
    |> unwrap_worker_envelope()
  end

  defp gate_result(_), do: nil

  # Vocab canon gate-decision-v1.json. Fail-closed : nil/inconnu → "halt_invalid" (jamais
  # "continue" sur décision absente/malformée → route en await_human). Jumeau Executor.
  @gate_decisions ~w(continue abandon redirect escalate_user halt_wait_input)
  defp gate_decision(result) when is_map(result) do
    case result["decision"] do
      d when d in @gate_decisions -> d
      _ -> "halt_invalid"
    end
  end

  defp gate_decision(_), do: "halt_invalid"

  # Déplie l'enveloppe worker `%{"status","result"}` (jumeau de
  # `Fleet.Pipeline.Executor.unwrap_worker_envelope`). Le worker rend soit directement
  # `%{"decision"=>...}` / les outputs, soit l'enveloppe `%{"status"=>"ok","result"=>...}`.
  # Sans dépliage : decision/outputs enfouis → fausse escalade / hard-gate à tort (#2/#11).
  defp unwrap_worker_envelope(%{"decision" => _} = direct), do: direct
  defp unwrap_worker_envelope(%{"status" => _, "result" => inner}) when is_map(inner), do: inner
  defp unwrap_worker_envelope(other), do: other

  defp advance(carte, stage) do
    case Fleet.Pilot.CarteNav.next_stage(carte, stage) do
      {:ok, {next_stage, next_role}} -> {:ok, {next_role, next_stage}}
      :terminal -> {:ok, {nil, nil}}
      {:error, reason} -> {:error, {:carte_nav, reason}}
    end
  end

  # Rebond borné. Budget = nb_stages * (max_rework_rounds + 1) hops signés. Le compteur
  # forge-natif = les comments `[hop:role:sha]` déjà postés (monotone). Lu UNIQUEMENT ici
  # (branche fail) → zéro I/O sur le happy path. Budget illisible → on NE rebondit PAS à
  # l'aveugle (un rebond non vérifiable pourrait boucler) : on surface.
  defp rebound(carte, n, state) do
    budget = stage_count(carte) * (state.max_rework_rounds + 1)

    case count_hops(state, n) do
      {:ok, hops} when hops >= budget ->
        {:error, {:rework_exhausted, %{hops: hops, budget: budget}}}

      {:ok, _hops} ->
        case Fleet.Pilot.CarteNav.first_stage(carte) do
          {:ok, {first_stage, first_role}} -> {:ok, {first_role, first_stage}}
          {:error, reason} -> {:error, {:carte_nav, reason}}
        end

      {:error, reason} ->
        {:error, {:rework_budget_unreadable, reason}}
    end
  end

  # Budget rework = tous les stages de la carte. En B il n'existe PAS de stage
  # `role: gatekeeper` (le juge est dispatché par gate, pas un stage) → plus d'exclusion
  # à câbler (l'ancienne N-05 excluait les gatekeeper-stages A2.3b, retirés).
  defp stage_count(carte) do
    carte |> Map.get("stages", %{}) |> map_size()
  end

  defp count_hops(state, n) do
    forge = state.forge_client || Fleet.Pilot.ForgeClient
    forge.count_signed_hops(state.repo, n, state.forge_opts)
  end

  # B (§L441) — plus de `validate_explicit_stage` (biconditionnelle soft⟺gatekeeper,
  # A2.3b) : une gate soft sur un stage métier est LÉGITIME (→ escalade gatekeeper), pas
  # une carte malformée. La carte est juste chargée (le Loader valide le schema).
  defp load_carte(state, pipeline) do
    {:ok, state.loader.load!(pipeline)}
  rescue
    e -> {:error, {:carte_load, Exception.message(e)}}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp project_payload?(p) do
    is_binary(p["workspace"]) and is_binary(p["base_sha"]) and p["base_sha"] != "" and
      is_binary(p["role"])
  end

  # F071 : le format ticket_id "issue-<n>" a une SOURCE UNIQUE (Fleet.Pilot.TicketId) — writer
  # (StageDispatcher) et parser ne peuvent plus dériver. `parse_issue_number` reste l'API publique
  # (appelée l.243 + testée hop_consumer_test) mais délègue.
  @doc false
  defdelegate parse_issue_number(ticket_id), to: Fleet.Pilot.TicketId, as: :parse

  # Z4 (forge-identité B') — F-01 `allowed_emails` = l'HUMAIN du mandat (le pod git_native
  # commite EN TANT QUE l'humain, cf. `bwrap_launch.sh`/`ForgeIdentity`), PLUS le rôle. Même
  # catalogue que le spawn → cohérent (commit humain ⟺ F-01 allows humain). Irrésoluble →
  # `[]` fail-closed (F-01 rejette tout). Le rôle est vérifié via le trailer (A.2), pas l'email.
  defp default_role_emails(role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} ->
        Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, id.author_email)

      {:error, reason} ->
        Logger.warning(
          "HopConsumer: identité forge irrésoluble (role=#{role}): #{inspect(reason)} — " <>
            "allowed_emails=[] (F-01 rejettera le push, fail-closed)"
        )

        []
    end
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, key}
    end
  end
end
