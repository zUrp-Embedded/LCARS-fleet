defmodule Fleet.Pipeline.Executor do
  @moduledoc """
  GenServer per-pipeline-run.

  ## State

      %__MODULE__{
        pipeline_id: term(),
        pipeline: map(),                # YAML déclaratif loaded
        stages_status: %{stage => :pending | :running | :completed},
        current_stage: String.t() | nil,
        outputs: %{stage => map()},
        mandate_context: map()
      }

  ## Cycle de vie

  1. `init/1` → load pipeline via `Loader`, subscribe `fleet.events`,
     `{:continue, :start_first_stage}`
  2. `handle_continue(:start_first_stage, _)` → toposort + run first stage
  3. `handle_info` consomme les `%Fleet.Event{}` canon `:"pipeline.stage.completed"`
     (source `:pipeline`) et `:"pod.completed"` (source `:spawner`, bridge C1)
     pour le `pipeline_id` courant → store outputs → dispatch gate :
     - `:pass` → stage suivant ou `pipeline.completed` broadcast + stop
     - `{:fail, reason}` → `pipeline.failed` broadcast + stop
     - `{:dispatch_gatekeeper, info}` (R4/B) → **enqueue un mandat d'éval au
       gatekeeper permanent** (work-session, adressé par `gatekeeper_pod_id`, MCP
       via TaskQueue) ; état `:awaiting_gate` (corrélation `gate_evals[correlation_id]`).
       La décision revient via `%Fleet.Event{source: :task_queue, type: :task_completed}`
       → `handle_gate_decision/3` : vocab canon `gate-decision-v1.json`
       (`continue` → stage suivant ; `abandon|redirect|escalate_user|halt_wait_input`
       / inconnu → `pipeline.failed`, halt). L'Executor **ne spawn ni ne possède**
       le gatekeeper.

  ## Process raison runtime

  GenServer = state machine async pipeline + collect events PubSub.
  Plain function impossible (events PubSub asynchrones, stages spawn
  pod async). Cohérent OTP Iron Law.
  """

  # `:transient` : pas de restart sur arrêt normal (pipeline.completed
  # → terminate :normal) ni :shutdown. Restart UNIQUEMENT si crash
  # anormal — évite le restart loop infini observé en prod (gate live
  # 600 : pod.completed → Executor :stop :normal → permanent default
  # restart → re-spawn pod → loop). Cohérent avec doctrine pipeline.md
  # §lifecycle Executor (1 pipeline_id = 1 run).
  use GenServer, restart: :transient

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline.{Gates, Loader, PodRegistry, StageRunner, Toposort, WorkspaceProvisioner}

  require Logger

  defstruct pipeline_id: nil,
            pipeline: nil,
            stages_status: %{},
            current_stage: nil,
            outputs: %{},
            mandate_context: %{},
            # R06 — gates async : pod_id du gatekeeper en attente → infos de la
            # gate (stage, kind, round, max_rounds). Le stage reste :completed
            # mais le pipeline n'avance pas tant que la décision n'est pas reçue.
            gate_evals: %{},
            # O5 (F-03) — `base_sha` capturée HORS-pod juste après provision (clone+checkout),
            # AVANT spawn. Verrou de la gate `DeliverableGate.check_base_ancestor` : le pod ne peut
            # pas la falsifier (il n'existe pas encore quand on la lit). Keyed par stage.
            base_shas: %{}

  @type t :: %__MODULE__{
          pipeline_id: term(),
          pipeline: map() | nil,
          stages_status: %{optional(String.t()) => atom()},
          current_stage: String.t() | nil,
          outputs: %{optional(String.t()) => map()},
          mandate_context: map(),
          gate_evals: %{optional(term()) => map()},
          base_shas: %{optional(String.t()) => String.t()}
        }

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(pipeline_id))
  end

  @doc """
  Tuple `:via` Registry pour lookup process par pipeline_id.
  """
  @spec via_tuple(term()) :: {:via, Registry, {Fleet.Pipeline.Registry, term()}}
  def via_tuple(pipeline_id) do
    {:via, Registry, {Fleet.Pipeline.Registry, pipeline_id}}
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    pipeline_name = Keyword.fetch!(opts, :pipeline_name)
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    mandate_context = Keyword.get(opts, :mandate_context, %{})

    pipeline = Loader.load!(pipeline_name)
    Bus.subscribe()

    state = %__MODULE__{
      pipeline_id: pipeline_id,
      pipeline: pipeline,
      mandate_context: mandate_context,
      stages_status: pipeline["stages"] |> Map.keys() |> Map.new(fn s -> {s, :pending} end)
    }

    {:ok, state, {:continue, :start_first_stage}}
  end

  @impl GenServer
  def handle_continue(:start_first_stage, state) do
    # F082 (+ review Finding 3) : `Toposort.sort` RAISE sur un graphe cyclique/dangling. Sous
    # `restart: :transient`, un exit ABNORMAL → restart → re-échec → RESTART STORM (tue les
    # pipelines voisins, borné par max_restarts mais épuise le budget). CONVENTION : tout échec
    # TERMINAL de pipeline (graphe invalide, gate_fail, gate_halt, provision_fail, spawn_fail)
    # broadcast `pipeline.failed` PUIS `{:stop, {:shutdown, reason}}` — `:transient` ne restart PAS
    # un `:shutdown` (vs un atom nu = abnormal) ET la reason reste visible dans les logs OTP.
    case safe_first_stage(state) do
      {:ok, first} ->
        do_run_stage(first, state)

      {:error, reason} ->
        broadcast_pipeline_failed(state, nil, reason)
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp safe_first_stage(state) do
    case Toposort.sort(state.pipeline["stages"]) do
      [] -> {:error, :empty_pipeline}
      [first | _] -> {:ok, first}
    end
  rescue
    e -> {:error, {:invalid_pipeline_graph, Exception.message(e)}}
  end

  # R2 (D1 schema unique) — consommation canon `%Fleet.Event{}` strict. Le tuple
  # legacy `{atom, %{"event_type" => ...}}` est RETIRÉ : tous les producteurs
  # émettent la struct (Spawner.Pod.safe_broadcast/2, StageSpawnerStub). La forme
  # tuple n'est plus représentable côté consommateur (I-CBC).
  @impl GenServer
  def handle_info(
        %Fleet.Event{source: :pipeline, type: :"pipeline.stage.completed", payload: payload},
        state
      ) do
    if payload["pipeline_id"] == state.pipeline_id do
      handle_stage_completed(payload["stage"], payload["outputs"] || %{}, state)
    else
      {:noreply, state}
    end
  end

  # R1.3 (hole C1) : bridge pod.completed → avancement de stage. Un pod de CE pipeline
  # a livré (pod.completed self-décrit pipeline_id+stage via spawn_opts, cf. StageRunner
  # + Pod). On le traduit en complétion de stage (= ce que `pipeline.stage.completed`
  # ferait). Outputs = le RÉSULTAT STRUCTURÉ du pod (R-CORE.comm 2.2 : completion event-driven,
  # `result` = payload submit_result ; plus de livrable fichier). Filtre pipeline_id : on ignore
  # les pods des autres pipelines (ou hors-pipeline, sans ces clés).
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.completed", payload: payload},
        state
      ) do
    # NB : c'est le chemin des pods de STAGE (workers normaux). Le **gatekeeper** ne
    # passe JAMAIS ici — sa décision de gate revient via `task_queue.task_completed`
    # (corrélée), pas via `pod.completed`. Donc le dépliage d'enveloppe worker
    # (`unwrap_worker_envelope`) est sur le chemin gate uniquement ; ici les outputs
    # de stage restent bruts (les hard/terminal gates écrivent leurs règles contre
    # cette forme).
    # BL-034 (dogfood F5) : le `payload["stage"]` est STALE sur réutilisation pipe-pod — il est figé au
    # spawn (`state.opts[:stage]` côté Pod) et `wake_existing_pod` réutilise le pod pour le stage suivant
    # SANS le mettre à jour → un engineer pipe build→verify rapporte toujours `stage=build` → l'Executor
    # re-traite build en boucle, n'avance jamais. Le stage AUTORITATIF est `state.current_stage` (le
    # pipeline est séquentiel : un seul stage court à la fois, posé par `run_stage_backend`). On l'utilise
    # pour l'attribution ; le `payload["stage"]` ne sert plus que de garde « c'est bien un pod de stage ».
    cond do
      payload["pipeline_id"] != state.pipeline_id or not is_binary(payload["stage"]) ->
        {:noreply, state}

      is_nil(state.current_stage) ->
        # Aucun stage en cours (complétion tardive/dupliquée après avancement) → ignore.
        {:noreply, state}

      true ->
        handle_stage_completed(state.current_stage, %{"result" => payload["result"]}, state)
    end
  end

  # R4/B — décision de gate du **gatekeeper** : elle revient via le mandat MCP
  # (`task_queue.task_completed`, `correlation_id` = task.id de l'éval), PAS via
  # un `pod.completed` (le gatekeeper est un pod permanent work-session, pas un
  # pod spawné par cette gate). Corrélation par `correlation_id`.
  def handle_info(
        %Fleet.Event{source: :task_queue, type: :task_completed, correlation_id: corr} = ev,
        state
      )
      when is_binary(corr) do
    if Map.has_key?(state.gate_evals, corr) do
      handle_gate_decision(corr, gate_result(ev.payload), state)
    else
      {:noreply, state}
    end
  end

  # Tout autre %Fleet.Event{} (autres sources/types) ou message non-event = ignoré.
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Extrait la décision de gate du payload `task_completed`. TROIS couches :
  #
  #   1. **enveloppe TaskQueue** (`event/3`) — pose `:result` en clé ATOM ;
  #   2. **enveloppe worker** — `agent-worker-base.md` impose à TOUT `submit_result`
  #      la forme `%{"status" => "ok"|"failed", "result" => <sortie>}` (clés STRING) ;
  #   3. **décision** — le GateBrief demande la décision DANS `result` →
  #      `%{"decision", "reason", ...}` (gate-decision-v1.json, lue par `gate_decision/1`).
  #
  # On déplie (1) puis (2) : sans le dépliage worker, l'Executor lisait
  # `result["decision"] = nil` → "halt_invalid" → le pipeline haltait alors que le
  # gatekeeper avait dit `continue`. Bug exposé LIVE par C4a (2026-06-06, vrai
  # gatekeeper) — invisible aux tests qui injectaient la décision sans enveloppe.
  defp gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || payload["result"])
    |> unwrap_worker_envelope()
  end

  defp gate_result(_), do: nil

  # Déplie l'enveloppe worker `%{"status","result"}`.
  #
  # INVARIANT de discrimination : une décision `gate-decision-v1.json` porte
  # TOUJOURS `"decision"` au top (les 5 décisions canon). La clause 1 s'appuie
  # dessus — donc une décision directe (forme des tests, ou worker qui n'enveloppe
  # pas) est rendue telle quelle, jamais confondue avec une enveloppe à déplier.
  # Cet invariant doit rester vrai si gate-decision-v1.json évolue.
  #
  # Clause 2 : enveloppe succès `%{"status"=>"ok", "result"=>map}` → on rend `result`
  # (la décision). Clause 3 : tout le reste rendu tel quel — dont le mode `failed`
  # (`%{"status"=>"failed", "reason"=>...}`, pas de `result` map) et `result: nil` →
  # pas de `"decision"` → `gate_decision/1` halt fail-closed (jamais continue sur un
  # échec/absence de jugement).
  defp unwrap_worker_envelope(%{"decision" => _} = direct), do: direct
  defp unwrap_worker_envelope(%{"status" => _, "result" => inner}) when is_map(inner), do: inner
  defp unwrap_worker_envelope(other), do: other

  # ============================================================
  # Terminate — cleanup pipe-scoped pods
  # ============================================================
  #
  # Le pipeline finit (normal, gate fail, spawn fail, workspace fail, ou
  # crash externe). Tous les pods pipe-scoped enregistrés pour ce
  # pipeline_id doivent être kill — leur cycle vie = vie du pipeline,
  # c'est le contrat `lifetime_scope: pipe` (cf. doctrine
  # pipeline-implementation.md Phase III + chantier engineer long-lived).
  #
  # `terminate/2` est appelé quoi qu'il arrive — y compris sur crash —
  # ce qui garantit qu'on ne laisse pas de pods orphelins (pas de pod
  # zombie qui consomme OAuth + RAM sans pipeline pour le piloter).

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_pipe_pods(state)
    :ok
  end

  defp cleanup_pipe_pods(%{pipeline_id: pid}) when not is_nil(pid) do
    case PodRegistry.cleanup_pipeline(pid) do
      {:ok, pod_ids} ->
        Enum.each(pod_ids, &kill_pod_safe(&1, pid))

      _ ->
        :ok
    end
  end

  defp cleanup_pipe_pods(_), do: :ok

  defp kill_pod_safe(pod_id, pipeline_id) do
    case spawner().kill_pod(pod_id) do
      :ok ->
        Logger.debug(
          "fleet_pipeline cleanup: killed pipe pod=#{inspect(pod_id)} (pipeline=#{inspect(pipeline_id)})"
        )

      {:error, :not_found} ->
        # Pod déjà mort (crash, deadline timeout, etc.) — pas une erreur,
        # le registry l'a juste pas vu disparaître. Pas de warn.
        :ok

      {:error, reason} ->
        Logger.warning(
          "fleet_pipeline cleanup: kill_pod failed pod=#{inspect(pod_id)} reason=#{inspect(reason)}"
        )
    end
  end

  # Seam config-driven pour les tests (stub Spawner sans spin-up infra
  # réelle, cohérent avec spawner_backend / task_queue dans StageRunner).
  defp spawner do
    Application.get_env(:fleet_pipeline, :spawner, Fleet.Spawner)
  end

  # Seam broker de mandats (même que StageRunner). Default = broker réel.
  defp task_queue do
    Application.get_env(:fleet_pipeline, :task_queue, Fleet.TaskQueue)
  end

  # R4 — pod_id du **gatekeeper permanent** (work-session) à adresser. Registré
  # par `Fleet.Pipeline.Gatekeeper` au boot Type 3 (sous-lot C). nil tant qu'aucun
  # gatekeeper n'est booté → une gate qui requiert le juge échoue fail-loud (pas
  # de pass silencieux). Override config/test via `:fleet_pipeline, :gatekeeper_pod_id`.
  defp gatekeeper_pod_id, do: Fleet.Pipeline.Gatekeeper.pod_id()

  # ============================================================
  # Internal
  # ============================================================

  defp handle_stage_completed(stage, outputs, state) do
    state = %{
      state
      | outputs: Map.put(state.outputs, stage, outputs),
        stages_status: Map.put(state.stages_status, stage, :completed),
        # Mi2 : la stage est terminée → plus "courante" (évite un current_stage stale).
        current_stage: nil
    }

    stage_spec = state.pipeline["stages"][stage]

    case Gates.evaluate(stage_spec, outputs, state.mandate_context) do
      :pass ->
        state = maybe_post_extract_git(stage, stage_spec, outputs, state)
        next_stage_or_done(state)

      {:fail, reason} ->
        Logger.warning(
          "fleet_pipeline gate fail: pipeline=#{inspect(state.pipeline_id)} stage=#{stage} reason=#{reason}"
        )

        broadcast_pipeline_failed(state, stage, reason)

        {:stop, {:shutdown, :gate_fail}, state}

      # R4/B — gate déléguée au gatekeeper (juge unique, pod permanent
      # work-session). L'Executor **n'avance pas** : il enqueue un mandat d'éval
      # au gatekeeper (MCP) et attend sa décision (`task_queue.task_completed`).
      {:dispatch_gatekeeper, info} ->
        do_dispatch_gatekeeper(stage, outputs, info, state)
    end
  end

  # R4/B — enqueue un mandat d'évaluation au **gatekeeper permanent** (work-session)
  # via la TaskQueue (MCP). L'Executor NE spawn PAS le gatekeeper (il ne le possède
  # pas — pod permanent partagé, booté Type 3) : il l'**adresse** par son pod_id.
  # `{:ok, task}` → corrélation `gate_evals[task.id]` (= correlation_id), on attend
  # `task_queue.task_completed`. Pas de gatekeeper adressable / enqueue raté →
  # fail-loud (jamais un pass silencieux).
  #
  # ⚠ Le boot/registration du gatekeeper permanent (Type 3) alimente `gatekeeper_pod_id`
  # (sous-lot C). Le contenu du brief d'éval = sous-lot D (ici : stage + gate + outputs).
  defp do_dispatch_gatekeeper(stage, outputs, info, state) do
    case gatekeeper_pod_id() do
      pod_id when is_binary(pod_id) ->
        gate = get_in(state.pipeline, ["stages", stage, "gate"])

        brief =
          Fleet.Pipeline.GateBrief.build(%{
            stage: stage,
            pipeline_id: state.pipeline_id,
            gate: gate,
            outputs: outputs
          })

        attrs = %{
          role: "gatekeeper",
          brief: brief,
          metadata: %{
            "gate_eval" => true,
            "stage" => stage,
            "pipeline_id" => state.pipeline_id,
            "gate" => gate,
            "outputs" => outputs
          }
        }

        case task_queue().enqueue(pod_id, attrs) do
          {:ok, %{id: corr}} ->
            # R3b / F-C4b-2 — KICK le gatekeeper après l'enqueue. Le gatekeeper est un
            # pod PERMANENT déjà booté+idle (:monitoring) : son kick-loop de boot est fini,
            # ce mandat de gate arrive APRÈS → sans wake il ne pull jamais (gate qui stalle,
            # observé C4b). Même mécanique que StageRunner.wake_existing_pod (push + wake).
            # Best-effort : le mandat est enqueué quoi qu'il arrive ; un wake raté → warn
            # (le gatekeeper, déjà ready, le reçoit normalement).
            case spawner().wake_pod(pod_id) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "fleet_pipeline gate kick gatekeeper=#{inspect(pod_id)} failed: #{inspect(reason)}"
                )
            end

            Logger.info(
              "fleet_pipeline gate pending: pipeline=#{inspect(state.pipeline_id)} " <>
                "stage=#{stage} kind=#{info.kind} gatekeeper=#{inspect(pod_id)} corr=#{inspect(corr)}"
            )

            gate_evals = Map.put(state.gate_evals, corr, Map.put(info, :stage, stage))
            {:noreply, %{state | gate_evals: gate_evals}}

          {:error, reason} ->
            broadcast_pipeline_failed(
              state,
              stage,
              "gatekeeper enqueue failed: #{inspect(reason)}"
            )

            {:stop, {:shutdown, :gate_fail}, state}
        end

      _ ->
        broadcast_pipeline_failed(state, stage, "no gatekeeper available (not booted)")
        {:stop, {:shutdown, :gate_fail}, state}
    end
  end

  # R4/B — décision du gatekeeper reçue (mandat MCP complété, corrélé par
  # `correlation_id`). Vocabulaire canon `gate-decision-v1.json` :
  # `continue` → avance ; `abandon|redirect|escalate_user|halt_wait_input` → halt
  # (le run s'arrête, la décision est portée dans le payload pour le handoff aval —
  # coord `escalate_gatekeeper`, gate-build). nil/inconnu → halt fail-closed.
  defp handle_gate_decision(corr, result, state) do
    {info, gate_evals} = Map.pop(state.gate_evals, corr)
    state = %{state | gate_evals: gate_evals}
    stage = info.stage
    decision = gate_decision(result)

    Logger.info(
      "fleet_pipeline gate decision: pipeline=#{inspect(state.pipeline_id)} " <>
        "stage=#{stage} kind=#{info.kind} decision=#{inspect(decision)}"
    )

    case decision do
      "continue" ->
        stage_spec = state.pipeline["stages"][stage]
        outputs = Map.get(state.outputs, stage, %{})
        state = maybe_post_extract_git(stage, stage_spec, outputs, state)
        next_stage_or_done(state)

      other ->
        broadcast_pipeline_failed(state, stage, gate_halt_reason(other, result))
        {:stop, {:shutdown, :gate_halt}, state}
    end
  end

  # Vocab canon gate-decision-v1.json. Fail-closed : nil/inconnu → "halt_invalid"
  # (jamais "continue" sur décision absente/malformée).
  @gate_decisions ~w(continue abandon redirect escalate_user halt_wait_input)
  defp gate_decision(result) when is_map(result) do
    case result["decision"] do
      d when d in @gate_decisions ->
        d

      other ->
        Logger.warning("fleet_pipeline gate decision inconnue/absente: #{inspect(other)}")
        "halt_invalid"
    end
  end

  defp gate_decision(result) do
    Logger.warning("fleet_pipeline gate result non-map (forme inattendue): #{inspect(result)}")
    "halt_invalid"
  end

  defp gate_halt_reason(decision, result) when is_map(result),
    do: "gate decision: #{decision} (#{inspect(Map.get(result, "reason"))})"

  defp gate_halt_reason(decision, _), do: "gate decision: #{decision}"

  defp next_stage_or_done(state) do
    sorted = Toposort.sort(state.pipeline["stages"])

    pending = Enum.filter(sorted, fn s -> Map.get(state.stages_status, s) != :completed end)

    case pending do
      [next | _] ->
        do_run_stage(next, state)

      [] ->
        broadcast_pipeline_completed(state)

        {:stop, :normal, state}
    end
  end

  defp do_run_stage(stage_name, state) do
    stage_spec = state.pipeline["stages"][stage_name]
    git_spec = get_in(stage_spec, ["post_extract", "git"])
    mode = deliverable_mode_for_stage(stage_name, git_spec, state)

    # #596 : la PRÉPARATION du workspace diverge par mode (autorité unique par côté de la frontière).
    #  · payload   → l'Executor provisionne `<workspaces_root>/...` (système-écrit) + capture base.
    #  · git_native → le POD provisionne `<pod_dir>/workspace` (ProjectBootstrap) ; l'Executor PIN la
    #    base hors-pod (ls-remote, F-03 R1) + l'injecte dans le spawn. Pas de WorkspaceProvisioner.
    case prepare_workspace(mode, stage_name, git_spec, state) do
      {:ok, state} ->
        run_stage_backend(stage_name, stage_spec, state)

      {:error, reason} ->
        broadcast_pipeline_failed(
          state,
          stage_name,
          "workspace provision fail: #{inspect(reason)}"
        )

        {:stop, {:shutdown, :provision_fail}, state}
    end
  end

  # Mode seulement pertinent si la stage a un post_extract.git. Sinon `:payload` (no-op provisioner).
  defp deliverable_mode_for_stage(_stage, nil, _state), do: :payload

  defp deliverable_mode_for_stage(stage, _git_spec, state) do
    resolve_deliverable_mode(
      role_for_stage(state.pipeline, stage),
      profile_for_stage(state.pipeline, stage)
    )
  end

  defp prepare_workspace(:payload, stage, git_spec, state) do
    case WorkspaceProvisioner.provision_for_stage(state.pipeline_id, stage, git_spec) do
      # F-03 (payload) : base = HEAD post-clone, lu hors-pod AVANT spawn (le pod n'écrit pas ce ws).
      {:ok, ws_or_nil} -> {:ok, maybe_capture_base_sha(state, stage, ws_or_nil)}
      {:error, _} = err -> err
    end
  end

  defp prepare_workspace(:git_native, stage, git_spec, state) do
    repo_url = git_spec["repo_url"]
    base_branch = git_spec["branch"]

    # F-03 R1 (verdict juge #636) : PIN la base via `ls-remote` HORS-pod, injectée au clone du pod
    # (`project.base_sha` → ProjectBootstrap `reset --hard`). Le pod commence garanti à `pinned` →
    # `base..HEAD` = uniquement ses commits. Élimine la course same-role (ls-remote seul = théâtre).
    case ls_remote_sha(repo_url, base_branch) do
      {:ok, pinned} ->
        project = %{
          "repo_path" => repo_url,
          "base_branch" => base_branch,
          "base_sha" => pinned,
          "reference_repo_path" => Map.get(git_spec, "reference_repo_path")
        }

        mc = state.mandate_context
        spawn_opts = mc |> Map.get(:spawn_opts, []) |> Keyword.put(:project, project)
        mc = Map.put(mc, :spawn_opts, spawn_opts)

        {:ok, %{state | mandate_context: mc, base_shas: Map.put(state.base_shas, stage, pinned)}}

      {:error, reason} ->
        {:error, {:ls_remote_failed, reason}}
    end
  end

  # `git ls-remote <repo_url> <branch>` borné → SHA du tip (1ère colonne, 1ère ligne). Capture
  # hors-pod de la base (sp-monde-invoque : le monde projette le SHA, le pod l'exécute mécaniquement).
  defp ls_remote_sha(repo_url, branch) do
    # F083 : auth runtime côté SYSTÈME (forge privée) — symétrique de `StageDispatcher.ls_remote_sha`.
    # Sans `forge_auth_args`, la résolution F-03 R1 du base_sha échouait l'auth sur un repo privé
    # (le chemin RAM Executor ne s'authentifiait pas, contrairement au chemin stage-driven).
    args = Fleet.Pipeline.Git.forge_auth_args() ++ ["ls-remote", repo_url, branch]

    task =
      Task.async(fn ->
        System.cmd("git", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case out |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :no_ref}
          line -> {:ok, line |> String.split() |> List.first()}
        end

      {:ok, {out, rc}} ->
        {:error, {rc, String.trim(out)}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  end

  defp run_stage_backend(stage_name, stage_spec, state) do
    case StageRunner.run(
           stage_name,
           stage_spec,
           state.mandate_context,
           state.outputs,
           state.pipeline_id
         ) do
      {:ok, _pod_id} ->
        new_state = %{
          state
          | current_stage: stage_name,
            stages_status: Map.put(state.stages_status, stage_name, :running)
        }

        {:noreply, new_state}

      {:error, reason} ->
        broadcast_pipeline_failed(state, stage_name, "spawn fail: #{inspect(reason)}")

        {:stop, {:shutdown, :spawn_fail}, state}
    end
  end

  # ============================================================
  # Broadcasts pipeline lifecycle — DN 10 C2.3-pipeline amendement
  # ============================================================
  #
  # BL-021 chantier 9 (B) — émetteur unique schema canon strict
  # %Fleet.Event{source: :pipeline, type, correlation_id, ...} via Bus.broadcast/2
  # (DN 11 C3.1+C3.2). Legacy tuple format retiré (subscribers migrés).

  defp broadcast_pipeline_failed(state, stage, reason) do
    pipeline_event(:"pipeline.failed", state, %{
      "pipeline_id" => state.pipeline_id,
      "stage" => stage,
      "reason" => reason
    })
  end

  defp broadcast_pipeline_completed(state) do
    pipeline_event(:"pipeline.completed", state, %{
      "pipeline_id" => state.pipeline_id,
      "outputs" => state.outputs
    })
  end

  defp pipeline_event(type, state, payload) do
    event = %Fleet.Event{
      source: :pipeline,
      type: type,
      timestamp: DateTime.utc_now(),
      correlation_id: extract_correlation_id(state.mandate_context),
      payload: payload
    }

    Bus.broadcast("fleet.events", event)
  rescue
    e ->
      # R7 verrou I-CBC : ne plus AVALER en silence. L'ancien rescue rendait
      # `:ok` muet sur UnregisteredError ET ArgumentError/FunctionClauseError —
      # ce dernier « parce que :pipeline n'est pas dans l'enum » : STALE,
      # `:pipeline` EST dans `Fleet.Event.canonical_sources/0`. Post-B2 le
      # registry est chargé au boot et `pipeline.*` y est inscrit → un échec
      # ici = un VRAI trou (type lifecycle absent du registry), plus un effet
      # de boot order. On le rend visible.
      Logger.error(
        "Fleet.Pipeline.Executor: broadcast #{inspect(type)} échoué " <>
          "(pipeline_id=#{state.pipeline_id}, source=:pipeline) : #{inspect(e)} — " <>
          "événement lifecycle NON émis"
      )

      # Fail-loud (re-raise) hors prod → le dev voit le trou immédiatement ;
      # en prod, log-only (ne pas perdre l'état du pipeline sur un échec de
      # simple notification lifecycle). Gate `:reraise_broadcast_errors`
      # (défaut true ; false en prod via runtime.exs).
      if Application.get_env(:fleet_pipeline, :reraise_broadcast_errors, true) do
        reraise(e, __STACKTRACE__)
      else
        :ok
      end
  end

  defp extract_correlation_id(%{correlation_id: cid}) when is_binary(cid), do: cid
  defp extract_correlation_id(%{"correlation_id" => cid}) when is_binary(cid), do: cid
  defp extract_correlation_id(_), do: nil

  # ============================================================
  # post_extract.git (face 2 décision archi git, 2026-05-24)
  #
  # Best-effort observable : succès ou échec sont broadcastés, mais
  # n'interrompent pas le pipeline. Le livrable a déjà passé la gate ;
  # post_extract est de la publication système-side aval. Si on veut un
  # jour rendre l'échec fatal, ce sera une option de la stage_spec.
  # ============================================================

  defp maybe_post_extract_git(stage, stage_spec, outputs, state) do
    case get_in(stage_spec, ["post_extract", "git"]) do
      nil -> :ok
      git_spec when is_map(git_spec) -> do_post_extract_git(stage, git_spec, outputs, state)
    end

    # Retour explicite : best-effort n'affecte pas le state (observable via
    # broadcasts git.published / git.publish_failed, pas via le pipeline).
    state
  end

  # O5 — route vers `Fleet.Pipeline.Deliverable.publish/1` (module unifié). Le mode (`payload` /
  # `git_native`) est une propriété du cap-profile du rôle (différenciation par catalogue). La gate
  # I-CBC (identité/secrets/base) tourne côté monde sur `base_sha..HEAD` ; un livrable invalide
  # n'est PAS poussé. Reste best-effort observable : succès/échec broadcastés, le pipeline avance.
  defp do_post_extract_git(stage, git_spec, outputs, state) do
    # Le vrai pod soumet une ENVELOPPE `%{"status"=>"ok", "result"=>%{files,message}}` (submit_result
    # MCP). Le chemin gate la déplie (`unwrap_worker_envelope`) ; ici il FAUT le même dépliage sinon
    # `result["files"]` est nil (files sous `result["result"]["files"]`) → `:no_files_in_payload`.
    # Trouvé en dogfood live (PASSE-8) : les tests unitaires envoyaient le `result` déjà déplié.
    result = outputs |> Map.get("result", %{}) |> unwrap_worker_envelope()
    role = role_for_stage(state.pipeline, stage)
    profile = profile_for_stage(state.pipeline, stage)
    mode = resolve_deliverable_mode(role, profile)
    base_sha = Map.get(state.base_shas, stage)

    # #596 : le workspace À GATER diverge par mode. payload → dir système-provisionné ; git_native →
    # workspace DU POD (`<pod_dir>/workspace`), résolu via PodRegistry+pod_workspace_dir (le monde lit
    # où IL a placé le pod, pas une assertion du pod — Q2). Échec de résolution = fail-loud (pas de gate
    # sur un chemin inventé).
    with {:ok, workspace} <- resolve_gate_workspace(mode, stage, role, state),
         {:ok, opts} <- build_deliverable_opts(mode, workspace, git_spec, result, role, base_sha) do
      publish_deliverable(stage, opts, state)
    else
      {:error, reason} -> broadcast_publish_failed(stage, reason, state)
    end
  end

  defp resolve_gate_workspace(:payload, stage, _role, state),
    do: {:ok, WorkspaceProvisioner.workspace_dir_for(state.pipeline_id, stage)}

  defp resolve_gate_workspace(:git_native, _stage, role, state) do
    # Seam test/config (mirroir `deliverable_mode_resolver`) : override la résolution du workspace pod
    # (un vrai pod claude n'existe qu'en e2e/dogfood). Défaut = PodRegistry → pod_workspace_dir.
    case Application.get_env(:fleet_pipeline, :git_native_workspace_resolver) do
      fun when is_function(fun, 2) ->
        fun.(state.pipeline_id, role)

      _ ->
        case Fleet.Pipeline.PodRegistry.lookup(state.pipeline_id, role) do
          {:ok, pod_id} ->
            case Fleet.Spawner.pod_workspace_dir(pod_id) do
              {:ok, ws} -> {:ok, ws}
              {:error, _} -> {:error, :pod_workspace_unresolved}
            end

          :not_found ->
            {:error, :pod_not_registered}
        end
    end
  end

  defp publish_deliverable(stage, opts, state) do
    case Fleet.Pipeline.Deliverable.publish(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?, mode: mode}} ->
        Logger.info(
          "fleet_pipeline post_extract.git ok: pipeline=#{inspect(state.pipeline_id)} " <>
            "stage=#{stage} mode=#{mode} sha=#{sha} pushed?=#{pushed?}"
        )

        pipeline_event(:"git.published", state, %{
          "pipeline_id" => state.pipeline_id,
          "stage" => stage,
          "commit_sha" => sha,
          "pushed?" => pushed?,
          "mode" => to_string(mode)
        })

      {:error, reason} ->
        broadcast_publish_failed(stage, reason, state)
    end
  end

  defp broadcast_publish_failed(stage, reason, state) do
    Logger.warning(
      "fleet_pipeline post_extract.git failed: pipeline=#{inspect(state.pipeline_id)} " <>
        "stage=#{stage} reason=#{inspect(reason)}"
    )

    pipeline_event(:"git.publish_failed", state, %{
      "pipeline_id" => state.pipeline_id,
      "stage" => stage,
      "reason" => inspect(reason)
    })
  end

  # Construit les opts `Deliverable` selon le mode. `base_sha` nil = fail-loud (sans base, pas de gate
  # F-03 → refus de publier). `remote` = `origin` (convention clone). `target_branch` = branche cible
  # système-choisie (F-04) : `git_spec["target_branch"]` si présent (git_native : le pod clone `branch`
  # comme base, le système pousse sur une cible distincte), sinon `git_spec["branch"]` (payload : la
  # branche provisionnée EST la cible). `push?` du git_spec (défaut false, préserve PASSE-7).
  defp build_deliverable_opts(_mode, _ws, _git_spec, _result, _role, nil),
    do: {:error, :base_sha_unavailable}

  defp build_deliverable_opts(mode, workspace, git_spec, result, role, base_sha) do
    common = %{
      mode: mode,
      workspace: workspace,
      base_sha: base_sha,
      allowed_emails: allowed_emails(mode, role),
      remote: "origin",
      target_branch: Map.get(git_spec, "target_branch") || Map.get(git_spec, "branch"),
      push?: Map.get(git_spec, "push", false)
    }

    {:ok, Map.merge(common, mode_specific_opts(mode, result, role))}
  end

  # payload : le système écrit les fichiers + commite. Z4 (B') — author = l'HUMAIN du mandat
  # (non-négo #1 : jamais aplati sur le rôle, même quand c'est le système qui commite),
  # committer = système (le système matérialise, D-04). Le rôle = trailer `Co-authored-by`
  # ajouté au message par le système → F-01 le vérifie (coauthor_role). Cohérent git_native.
  defp mode_specific_opts(:payload, result, role) do
    {author_name, author_email} = payload_author(role)

    %{
      files: Map.get(result, "files"),
      message: payload_message(result, role) <> "\n\n" <> coauthor_trailer(role),
      identity: %{
        author_name: author_name,
        author_email: author_email,
        committer_name: "LCARS System",
        committer_email: "system@lcars.local"
      },
      coauthor_role: role
    }
  end

  # Z4 (A.2) — git_native : F-01 vérifie le trailer `Co-authored-by: LCARS-<role>` (le pod
  # signe son rôle ; l'author git = l'humain). payload aussi (coauthor_role posé ci-dessus).
  defp mode_specific_opts(:git_native, _result, role), do: %{coauthor_role: role}

  # Author humain pour le commit système (payload). Irrésoluble → sentinelle hors-allowed →
  # F-01 rejette (fail-closed, jamais un author deviné qui passerait la gate).
  defp payload_author(role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} -> {id.author_name, id.author_email}
      {:error, _} -> {"LCARS-unresolved", "unresolved@invalid.local"}
    end
  end

  defp coauthor_trailer(role), do: Fleet.Credentials.ForgeIdentity.coauthor_trailer(role)

  # Identités acceptées par la gate (F-01). Z4 (B') — payload : author=HUMAIN (le système
  # commite au nom de l'humain du mandat) + committer=système → `[humain, système]`.
  # git_native : author=committer=humain (le pod commite EN TANT QUE l'humain). Irrésoluble →
  # fail-closed.
  defp allowed_emails(:payload, role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} ->
        Fleet.Credentials.ForgeIdentity.allowed_emails(:payload, id.author_email)

      # F086 : identité irrésoluble → `[]` FAIL-CLOSED (cohérent avec git_native + HopConsumer).
      # L'ancien `["system@lcars.local"]` laissait un commit système passer la gate F-01 SANS author
      # humain résolu → divergence de fallback (payload non-vide vs git_native vide).
      {:error, _} ->
        []
    end
  end

  # Z4 (A.1) — git_native : le pod commite EN TANT QUE l'humain (bwrap GIT_AUTHOR=humain) →
  # F-01 allows l'humain (via ForgeIdentity, même catalogue que le spawn). Irrésoluble → `[]`
  # fail-closed. (Le mode `payload` — système commite, author=LCARS-role — reste role-based en
  # A.1 : chemin Executor RAM mourant ; bascule humain = follow-up A.x.)
  defp allowed_emails(:git_native, role) do
    case Fleet.Credentials.ForgeIdentity.for_role(role) do
      {:ok, id} -> Fleet.Credentials.ForgeIdentity.allowed_emails(:git_native, id.author_email)
      {:error, _} -> []
    end
  end

  defp payload_message(result, role) do
    case Map.get(result, "message") do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> "feat: payload from #{role}"
    end
  end

  # Seam (mirroir `lifetime_scope_resolver` du StageRunner) : override test/config via
  # `:fleet_pipeline, :deliverable_mode_resolver` (fun/2 role,profile → "payload"|"git_native").
  # Défaut : charge le cap-profile et lit `spec.deliverable_mode` (source unique catalogue).
  defp resolve_deliverable_mode(role, profile) do
    case Application.get_env(:fleet_pipeline, :deliverable_mode_resolver) do
      fun when is_function(fun, 2) -> normalize_mode(fun.(role, profile))
      _ -> normalize_mode(default_deliverable_mode(role, profile))
    end
  end

  defp default_deliverable_mode(role, nil), do: default_deliverable_mode(role, [])

  defp default_deliverable_mode(role, profile) when is_binary(profile),
    do: default_deliverable_mode(role, [profile])

  defp default_deliverable_mode(role, profile) when is_list(profile) do
    result =
      case profile do
        [] -> Fleet.CapProfile.load(role)
        modops -> Fleet.CapProfile.compose(role, modops)
      end

    case result do
      {:ok, cap} -> Fleet.CapProfile.deliverable_mode(cap)
      _ -> "payload"
    end
  end

  defp normalize_mode("git_native"), do: :git_native
  defp normalize_mode(:git_native), do: :git_native
  defp normalize_mode(_), do: :payload

  defp profile_for_stage(pipeline, stage), do: get_in(pipeline, ["stages", stage, "profile"])

  # F-03 — capture HEAD du workspace fraîchement provisionné (clone+checkout), AVANT spawn du pod.
  # Stocké dans `state.base_shas[stage]`, servira de borne `base..HEAD` à la gate. ws nil (pas de
  # post_extract.git) → no-op. Lecture ratée (workspace pas un repo ?) → pas de capture : à la
  # publication, base_sha absent → `:base_sha_unavailable` fail-loud (pas de gate aveugle).
  defp maybe_capture_base_sha(state, _stage, nil), do: state

  defp maybe_capture_base_sha(state, stage, workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        %{state | base_shas: Map.put(state.base_shas, stage, String.trim(sha))}

      {out, rc} ->
        Logger.warning(
          "fleet_pipeline base_sha capture fail: pipeline=#{inspect(state.pipeline_id)} " <>
            "stage=#{stage} rc=#{rc} out=#{String.trim(out)}"
        )

        state
    end
  end

  # `role` est REQUIS par stage au schéma `pipeline-v1.json` (`required: [role, profile]`),
  # validé fail-fast au `Loader.load!/2` (barrière I-CBC au LOAD). Donc tout pipeline qui
  # atteint l'Executor a `stages.<s>.role`. Plus de fallback silencieux "unknown" (qui
  # dispatcherait un pod role="unknown" = pire échec en aval) : si la clé manque, c'est
  # qu'un pipeline a contourné le Loader → crash loud (le bug remonte ICI, pas masqué).
  defp role_for_stage(pipeline, stage) do
    case get_in(pipeline, ["stages", stage, "role"]) do
      role when is_binary(role) and role != "" ->
        role

      other ->
        raise "fleet_pipeline: stage #{inspect(stage)} sans role valide (#{inspect(other)}) — " <>
                "viole pipeline-v1.json (role requis) ; pipeline non chargé via Loader.load!/2 ?"
    end
  end
end
