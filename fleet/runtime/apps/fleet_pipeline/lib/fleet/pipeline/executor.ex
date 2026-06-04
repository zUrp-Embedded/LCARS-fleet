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
     - `:retry` → ré-exécute stage courant

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
  alias Fleet.Pipeline.Git, as: FleetGit
  alias Fleet.Pipeline.{Gates, Loader, PodRegistry, StageRunner, Toposort, WorkspaceProvisioner}

  require Logger

  defstruct pipeline_id: nil,
            pipeline: nil,
            stages_status: %{},
            current_stage: nil,
            outputs: %{},
            mandate_context: %{}

  @type t :: %__MODULE__{
          pipeline_id: term(),
          pipeline: map() | nil,
          stages_status: %{optional(String.t()) => atom()},
          current_stage: String.t() | nil,
          outputs: %{optional(String.t()) => map()},
          mandate_context: map()
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
    case Toposort.sort(state.pipeline["stages"]) do
      [] ->
        {:stop, :empty_pipeline, state}

      [first | _] ->
        do_run_stage(first, state)
    end
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
    if payload["pipeline_id"] == state.pipeline_id and is_binary(payload["stage"]) do
      handle_stage_completed(payload["stage"], %{"result" => payload["result"]}, state)
    else
      {:noreply, state}
    end
  end

  # Tout autre %Fleet.Event{} (autres sources/types) ou message non-event = ignoré.
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

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

        {:stop, :gate_fail, state}

      :retry ->
        Logger.info(
          "fleet_pipeline gate retry: pipeline=#{inspect(state.pipeline_id)} stage=#{stage}"
        )

        do_run_stage(stage, state)
    end
  end

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

    # Face 2 brique 2.4 : provisionne le workspace AVANT spawn si la stage
    # déclare post_extract.git. Clone repo_url + checkout branch. No-op si
    # post_extract.git absent. Échec = halt pipeline (clone/checkout = erreur
    # infrastructure, pas un livrable à juger).
    case WorkspaceProvisioner.provision_for_stage(state.pipeline_id, stage_name, git_spec) do
      {:ok, _ws_or_nil} ->
        run_stage_backend(stage_name, stage_spec, state)

      {:error, reason} ->
        broadcast_pipeline_failed(
          state,
          stage_name,
          "workspace provision fail: #{inspect(reason)}"
        )

        {:stop, :provision_fail, state}
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

        {:stop, :spawn_fail, state}
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
    # Boot order ou test sans Dispatch — registry pas peuplé. Silencieux.
    _e in Fleet.Event.UnregisteredError -> :ok
    # Source :pipeline pas dans enum closed list — pour l'instant pas dans
    # Fleet.Event canonical_sources(), donc on tolère un FunctionClauseError
    # éventuel sur la struct creation. À ajouter dans Fleet.Event chantier 3.
    _e in [ArgumentError, FunctionClauseError] -> :ok
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

  defp do_post_extract_git(stage, git_spec, outputs, state) do
    result = Map.get(outputs, "result", %{})
    workspace = WorkspaceProvisioner.workspace_dir_for(state.pipeline_id, stage)
    publish_opts = build_publish_opts(workspace, git_spec, result, state, stage)

    with :ok <- apply_payload_files(workspace, result),
         {:ok, %{commit_sha: sha, pushed?: pushed?}} <- FleetGit.publish(publish_opts) do
      Logger.info(
        "fleet_pipeline post_extract.git ok: pipeline=#{inspect(state.pipeline_id)} " <>
          "stage=#{stage} sha=#{sha} pushed?=#{pushed?}"
      )

      pipeline_event(:"git.published", state, %{
        "pipeline_id" => state.pipeline_id,
        "stage" => stage,
        "commit_sha" => sha,
        "pushed?" => pushed?
      })
    else
      {:error, reason} ->
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
  end

  # Atomicité best-effort + sécu path traversal (audit externe 2026-05-24 #3+#4).
  # 2 passes : (1) valide TOUS les paths avant toute écriture — refuse
  # path traversal `../`, refuse shapes invalides. (2) écrit en séquence si
  # validation OK. Si une écriture échoue après validation (disk error rare),
  # `git.publish_failed` est broadcasté → pas de commit → workspace dirty
  # mais pas pushé (atomicité au sens git préservée).
  defp apply_payload_files(workspace, %{"files" => files}) when is_list(files) and files != [] do
    with :ok <- validate_payload_files(workspace, files) do
      write_validated_files(workspace, files)
    end
  end

  defp apply_payload_files(_workspace, _other), do: {:error, :no_files_in_payload}

  # Refuse rel_path qui s'évadent du workspace (`..`, paths absolus, etc.).
  # `Path.expand/2` normalise `.`/`..` sans suivre symlinks → on compare le
  # préfixe canoniquement. Fail-closed strict : 1ère anomalie = halt.
  defp validate_payload_files(workspace, files) do
    expanded_ws = Path.expand(workspace)

    Enum.reduce_while(files, :ok, fn
      %{"path" => rel_path, "content" => content}, :ok
      when is_binary(rel_path) and is_binary(content) ->
        full = Path.expand(Path.join(workspace, rel_path))

        if full == expanded_ws or String.starts_with?(full, expanded_ws <> "/") do
          {:cont, :ok}
        else
          {:halt, {:error, {:path_traversal, rel_path}}}
        end

      bad, :ok ->
        {:halt, {:error, {:invalid_payload_file, inspect(bad)}}}
    end)
  end

  defp write_validated_files(workspace, files) do
    Enum.reduce_while(files, :ok, fn
      %{"path" => rel_path, "content" => content}, :ok ->
        case write_payload_file(workspace, rel_path, content) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:file_write_failed, rel_path, reason}}}
        end
    end)
  end

  # Non-bang : un disk error doit propager {:error, _} pour broadcast
  # git.publish_failed — pas crasher l'Executor GenServer (perte d'état pipeline).
  defp write_payload_file(workspace, rel_path, content) do
    full_path = Path.join(workspace, rel_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, content) do
      :ok
    end
  end

  defp build_publish_opts(workspace, git_spec, result, state, stage) do
    role = role_for_stage(state.pipeline, stage)

    %{
      workspace: workspace,
      author_name: role,
      author_email: "#{role}@lcars.local",
      committer_name: "LCARS System",
      committer_email: "system@lcars.local",
      # audit elixir #5 : `||` traitait `""` comme truthy (Elixir : seul `nil`
      # et `false` sont falsy). Un worker posant `message: ""` enverrait une
      # string vide à git commit qui la rejetterait → `{:git_commit_failed,
      # ...}` opaque. Pattern match strict : binary non-vide gardé tel quel,
      # tout autre cas (nil, "", non-string) → default informatif.
      message: commit_message(result, stage, role),
      branch: Map.fetch!(git_spec, "branch"),
      # `origin` est conventionné par WorkspaceProvisioner (git clone → remote
      # `origin` pointe vers repo_url). Le catalogue n'expose pas le nom du
      # remote — convention unique.
      remote: "origin",
      add_paths: Map.get(git_spec, "add_paths", ["."]),
      push?: Map.get(git_spec, "push", false)
    }
  end

  defp commit_message(result, stage, role) do
    case Map.get(result, "message") do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> "feat(#{stage}): payload from #{role}"
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
