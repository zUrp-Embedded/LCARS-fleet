defmodule Fleet.Pilot.StepRunConsumer.GateEngine do
  @moduledoc """
  Moteur de DÉCISION de gate du rail step, extrait de `Fleet.Pilot.StepRunConsumer` :
  à la fin d'un step_run, décide ce qui SUIT — avancer dans la workflow_map, rebondir
  en rework (borné), appliquer le verdict d'un juge, ou escalader au gatekeeper permanent.

  ## Pourquoi un module séparé

  Le StepRunConsumer est le singleton Bus (GenServer) : il porte l'état (gate_evals) et
  EXÉCUTE la complétion. La décision, elle, n'a pas d'état propre : `resolve_next/3` lit
  le payload + la workflow_map et rend une INTENTION (`{:ok, intent, routing}` /
  `{:judge_verdict, …}` / `{:escalate, …}` / `{:error, …}`) — c'est l'appelant qui agit.
  Séparer les deux rend le moteur testable sans GenServer et garde le consumer sur son
  concern (réagir au Bus, orchestrer la complétion).

  Deux effets assumés DANS le moteur (parties intégrantes de la décision, pas des à-côtés) :

    * le rebond lit le compteur forge de step_runs signés (budget anti-runaway) —
      branche fail UNIQUEMENT, zéro I/O sur le happy path ;
    * la branche `{:dispatch_gatekeeper, _}` enqueue le brief d'éval via
      `GatekeeperEscalation.dispatch` (seams async-out transmis via `Seams.escalation`).

  ## Frontière blindée

  Le moteur ne reçoit JAMAIS le state entier du consumer : `Seams` (struct étroit) porte
  les SEULES lectures autorisées. Ajouter une lecture = élargir consciemment le struct.

  ## Invariants portés ici

    * « un PRODUCTEUR ne merge JAMAIS seul » — l'intent terminal dépend du RÔLE qui finit
      (`advance_intent/3` : producteur → `:review`, juge-workflow_map → `:promote`).
    * route HÉRITÉE (juge no-workflow_map portant le step du producteur) → résolution
      no-workflow_map, JAMAIS la gate du step (sinon un qualifier portant `build`
      tomberait en terminal non-producteur → merge sur 1 juge, quorum court-circuité).
    * rebond BORNÉ : budget = nb_steps × (max_rework_rounds + 1) step_runs signés ;
      budget illisible → `{:error, {:rework_budget_unreadable, _}}` surfacé, JAMAIS un
      rebond aveugle (une boucle de rework infinie ne doit pas être représentable).
    * une erreur de workflow_map (DAG, step inconnu) REMONTE (le système n'avance pas à
      l'aveugle) — pas de misroute silencieux.
  """

  require Logger

  alias Fleet.Pilot.StepRunConsumer.GatekeeperEscalation
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Frontière blindée du moteur de gate : les SEULES lectures que `GateEngine` peut faire.
    Construit par le consumer depuis son state DÉRIVÉ per-step-run (`repo`/`forge_opts`
    viennent de l'event, multi-projet). `escalation` = le struct de seams async-out de
    `GatekeeperEscalation` (task_queue/spawner/gatekeeper_pod_id_fun/wake_recovery),
    transmis tel quel à `dispatch/7`.
    """
    @enforce_keys [:loader, :deliverable_mode_fun, :max_rework_rounds, :escalation]
    defstruct [
      # Loader de workflow_map (seam, défaut côté consumer = Fleet.Workflow.Loader).
      :loader,
      # Résout le deliverable_mode d'un rôle ("git_native" producteur / "payload" juge).
      :deliverable_mode_fun,
      # Bound anti-runaway du rebond de gate (nombre de rounds de rework autorisés).
      :max_rework_rounds,
      # Repo "owner/name" du step_run (per-step-run, dérivé de l'event) — compteur de budget + logs.
      :repo,
      # Opts forge (token…) passés au client pour le compteur de budget.
      :forge_opts,
      # Client forge injectable (nil → Fleet.Pilot.ForgeClient).
      :forge_client,
      # %GatekeeperEscalation.Seams{} — l'escalade gatekeeper async-out.
      :escalation
    ]

    @type t :: %__MODULE__{
            loader: module() | (String.t() -> map()),
            deliverable_mode_fun: (String.t() -> String.t()),
            max_rework_rounds: non_neg_integer(),
            repo: String.t() | nil,
            forge_opts: keyword(),
            forge_client: module() | nil,
            escalation: GatekeeperEscalation.Seams.t()
          }
  end

  @typedoc "Routage `{next_assignee | nil, next_step | nil}` — `{nil, nil}` = terminal."
  @type routing :: {String.t() | nil, String.t() | nil}

  @typedoc """
  Décision du moteur :
    * `{:ok, intent, routing}` — complète le step_run avec cet intent
      (`:advance`/`:review`/`:promote`/`:rework`/`:reviewed`) ;
    * `{:judge_verdict, decision, trace, ctx}` — le step qui finit EST un juge, son
      verdict gate-decision-v1 est à appliquer (`apply_verdict` côté consumer) ;
    * `{:escalate, corr, eval_ctx}` — brief d'éval enqueué au gatekeeper, reprise async ;
    * `{:error, reason}` — fail-loud (l'appelant décide escalade terminale ou remontée).
  """
  @type decision ::
          {:ok, atom(), routing()}
          | {:judge_verdict, String.t(), String.t(), map()}
          | {:escalate, term(), map()}
          | {:error, term()}

  @doc """
  Résout le prochain assignee depuis la workflow_map. Le contexte workflow_map arrive dans
  le payload `pod.completed` : `workflow_map` (nom de workflow_map) + `step` (nom du step
  courant — le NOM, pas le rôle, cf. `WorkflowMapNav` qui indexe par nom de step).
  Absent → résolution single-brique (1-step).
  """
  @spec resolve_next(map(), pos_integer(), Seams.t()) :: decision()
  def resolve_next(payload, n, %Seams{} = seams) do
    case {payload["workflow_map"], payload["step"]} do
      {workflow_map_name, step} when is_binary(workflow_map_name) and is_binary(step) ->
        with {:ok, workflow_map} <- load_workflow_map(seams, workflow_map_name) do
          # Un pod dont le RÔLE ≠ le rôle déclaré du step qu'il porte n'EST pas ce step : c'est un
          # juge NO-WORKFLOW_MAP (qualifier/reviewer dispatché par `dispatch_review`) ayant HÉRITÉ la route de
          # l'issue (le step du producteur). Le traiter via la workflow_map le ferait avancer/merger à tort :
          # un qualifier portant `build` tomberait en terminal non-producteur → `:promote`
          # → merge sur 1 juge, court-circuitant le quorum. → résolution no-workflow_map (`:reviewed`) : il
          # enregistre sa review native, et le merge revient au quorum `dispatch_by_verdicts` (qui attend
          # TOUS les juges). Un vrai step de workflow_map (rôle = rôle du step) passe par la gate.
          if inherited_route?(workflow_map, step, payload["role"]) do
            no_workflow_map_resolve(payload, seams)
          else
            gate_decide(workflow_map, step, payload, n, seams)
          end
        end

      _ ->
        # Pas de workflow_map (single-brique) : l'intent dépend du RÔLE qui finit, pas de
        # `:promote` direct (un terminal qui promeut mergerait SANS juge). Le merge est piloté par
        # l'état-PR (dispatch_review), pas par l'intent d'un pod isolé.
        no_workflow_map_resolve(payload, seams)
    end
  end

  @doc """
  Le rôle qui finit est-il un PRODUCTEUR (deliverable_mode `"git_native"`) ?
  Producteur = pousse du code, ouvre la PR. Juge (`"payload"`) = review, ne pousse pas.
  Rôle non-binaire → `false` (fail-safe : jamais traité producteur par accident).
  """
  @spec producer?(term(), (String.t() -> String.t())) :: boolean()
  def producer?(role, deliverable_mode_fun) when is_binary(role),
    do: deliverable_mode_fun.(role) == "git_native"

  def producer?(_role, _deliverable_mode_fun), do: false

  @doc """
  Avance dans la workflow_map + tague l'intent terminal selon le RÔLE qui finit.
  SOURCE UNIQUE de l'intent post-`continue`/`:pass`, partagée par le chemin gate
  (`:pass`) ET le chemin verdict (`apply_verdict "continue"` côté consumer) : sans ce
  partage, un producteur jugé « continue » sur un step terminal mergerait sans juges.
  """
  @spec advance_intent(map(), String.t(), boolean()) ::
          {:ok, atom(), routing()} | {:error, term()}
  def advance_intent(workflow_map, step, producer?),
    do: tag_advance(advance(workflow_map, step), producer?)

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
  defp no_workflow_map_resolve(payload, seams) do
    if producer?(payload["role"], seams.deliverable_mode_fun) do
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
  defp gate_decide(workflow_map, step, payload, n, seams) do
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
      # fonction, partagée avec le gatekeeper async) côté consumer. gate_decide reste un décideur PUR :
      # il rend l'intention `{:judge_verdict, …}`, c'est l'appelant qui agit.
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
          # L'intent terminal dépend du RÔLE qui finit (cf. advance_intent/3).
          advance_intent(
            workflow_map,
            step,
            producer?(payload["role"], seams.deliverable_mode_fun)
          )

        {:fail, reason} ->
          Logger.info(
            "StepRunConsumer: gate FAIL repo=#{seams.repo}##{n} step=#{step}: #{reason}"
          )

          tag(:rework, rebound(workflow_map, n, seams))

        {:human_approval, reason} ->
          # D2/G3 : un aval humain requis n'est PAS un échec de gate → on N'entre PAS en rework (qui
          # gaspillerait `budget` spawns avant d'escalader de toute façon). Erreur terminale ESCALÉE
          # DIRECTEMENT vers l'arch (via TerminalEscalation, même filet que rework_exhausted) :
          # comment + lcars-awaits-arch + unlock → poller skip → l'humain approuve.
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
                 seams.escalation
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
  defp rebound(workflow_map, n, seams) do
    budget = step_count(workflow_map) * (seams.max_rework_rounds + 1)

    case count_step_runs(seams, n) do
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

  defp count_step_runs(seams, n) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient
    forge.count_signed_step_runs(seams.repo, n, seams.forge_opts)
  end

  # Pas de `validate_explicit_step` (biconditionnelle soft⟺gatekeeper) :
  # une gate soft sur un step métier est LÉGITIME (→ escalade gatekeeper), pas
  # une workflow_map malformée. La workflow_map est juste chargée (le Loader valide le schema).
  # Délégué à l'autorité unique `WorkflowMapNav.safe_load` (tag unifié :workflow_map_load_failed).
  defp load_workflow_map(seams, workflow_map_name),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(seams.loader, workflow_map_name)
end
