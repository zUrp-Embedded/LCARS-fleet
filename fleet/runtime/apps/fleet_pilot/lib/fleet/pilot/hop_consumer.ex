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
    :max_rework_rounds,
    # B (§L441) — seams d'escalade gatekeeper.
    :task_queue,
    :spawner,
    :gatekeeper_pod_id_fun,
    # B (§L441) — escalades en attente, keyées par correlation_id (= task.id du
    # mandat d'éval). Valeur = contexte de reprise `%{n, role, payload, carte, stage}`.
    gate_evals: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
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
        # A2.3 : bound anti-runaway du rebond de gate. Budget de hops = nb_stages *
        # (max_rework_rounds + 1) : la 1re passe + N rounds de rework. Au-delà → stuck
        # surfacé (pas de boucle). Défaut 2 rounds.
        max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2),
        # B (§L441) — seams d'escalade gatekeeper (défauts = broker/spawner/registry réels).
        task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
        spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
        gatekeeper_pod_id_fun:
          Keyword.get(opts, :gatekeeper_pod_id_fun, &Fleet.Pipeline.Gatekeeper.pod_id/0),
        gate_evals: %{}
      }

      Logger.info("fleet_pilot HopConsumer start repo=#{repo} remote=#{remote}")
      {:ok, state}
    else
      {:error, missing} -> {:stop, {:missing_required_opt, missing}}
    end
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    case maybe_complete(p, state) do
      {:ok, outcome} ->
        Logger.info("HopConsumer: #{p["ticket_id"]} → #{inspect(outcome)}")
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
          {:ok, outcome} ->
            Logger.info("HopConsumer gate resume: corr=#{inspect(corr)} → #{inspect(outcome)}")

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

      {:ok, {next_assignee, next_stage}} ->
        complete_business_hop(payload, n, role, next_assignee, next_stage, state)
    end
  end

  # Construit + applique le hop métier (livrable `:git_native` : le pod a commité dans
  # son workspace, le système vérifie gate F-01/F-03 + pousse). `comment_body` nil →
  # HopCompleter applique son comment par défaut ; non-nil → trace (ex. verdict gatekeeper).
  defp complete_business_hop(
         payload,
         n,
         role,
         next_assignee,
         next_stage,
         state,
         comment_body \\ nil
       ) do
    hop =
      %{
        repo: state.repo,
        issue_number: n,
        role: role,
        deliverable_opts: build_deliverable_opts(role, payload, n, state),
        next_assignee: next_assignee,
        # A2.1 : pipeline + stage suivant → HopCompleter grave la route avant le reassign.
        # nil/nil pour terminal ou 1-stage (pas de route, close).
        next_stage: next_stage,
        pipeline: payload["pipeline"],
        state_label: "state:delivered"
      }
      |> put_unless_nil(:comment_body, comment_body)

    hc_opts =
      [forge_opts: state.forge_opts]
      |> maybe_put(:forge_client, state.forge_client)
      |> maybe_put(:deliverable, state.deliverable)

    state.hop_completer.complete(hop, hc_opts)
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
        # pas de contexte carte → pod 1-stage (A1) → terminal close
        {:ok, {nil, nil}}
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
        advance(carte, stage)

      {:fail, reason} ->
        Logger.info("HopConsumer gate FAIL repo=#{state.repo}##{n} stage=#{stage}: #{reason}")
        rebound(carte, n, state)

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
            complete_business_hop(payload, n, role, next_assignee, next_stage, state, trace)

          {:error, reason} ->
            {:error, reason}
        end

      "abandon" ->
        close_with_trace(n, role, trace, state)

      other ->
        hop = %{repo: state.repo, issue_number: n, role: role, decision: other}
        hc_opts = [forge_opts: state.forge_opts] |> maybe_put(:forge_client, state.forge_client)
        state.hop_completer.await_human(hop, hc_opts)
    end
  end

  # Verdict `abandon` : close terminal, SANS push (le travail métier est rejeté ; parité
  # Executor qui n'extrait pas le livrable sur halt). `deliverable_opts: nil` + `hop_sha`
  # → HopCompleter saute l'étape publish, garde la séquence idempotente (comment trace →
  # state → close → unlock).
  defp close_with_trace(n, role, trace, state) do
    hop = %{
      repo: state.repo,
      issue_number: n,
      role: role,
      deliverable_opts: nil,
      hop_sha: "gate-abandon",
      next_assignee: nil,
      state_label: "state:delivered",
      comment_body: trace
    }

    hc_opts = [forge_opts: state.forge_opts] |> maybe_put(:forge_client, state.forge_client)
    state.hop_completer.complete(hop, hc_opts)
  end

  # Trace lisible du verdict (portée dans le comment du hop → durable en forge).
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

  @doc false
  def parse_issue_number("issue-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_issue_number(_), do: :error

  defp default_role_emails(role), do: [default_email(role)]
  defp default_email(role), do: "#{role}@lcars.local"

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, key}
    end
  end
end
