defmodule Fleet.Pipeline.StageRunner do
  @moduledoc """
  Orchestre l'exécution d'1 stage : prep `inputs` (résolution depuis
  outputs prior stages) → spawn ou wake pod via `SpawnerBackend` /
  `PodRegistry` → outputs collectés async par Executor via PubSub
  `:pipeline_stage_completed`.

  Pas de state local — pure fonction. Le pod broadcast l'event de
  complétion en EXTRACT phase (chantier 7 `fleet_pod_runtime` PROMOTED).

  ## Réutilisation pod pipe-scoped (chantier engineer long-lived)

  Si le `cap_profile` de la stage a `lifetime_scope: pipe`, le pod
  survit aux cycles audit/correction du pipeline (doctrine
  pipeline-implementation.md Phase III boucle renvoi-au-dev). Le
  `PodRegistry` mappe `{pipeline_id, role} → pod_id` :

    * 1er passage (spawn) → push task `TaskQueue` ciblée `_lcars_pod_id`,
      spawn via `SpawnerBackend`, register dans `PodRegistry`.
    * Passages suivants (wake) → push task corrective + `wake_pod` →
      le claude REPL reprend get_task/submit_result sur le même pod
      (contexte préservé).

  Pour les pods `one-shot` (cycle vie = cycle stage) le comportement
  reste inchangé : spawn classique sans registry.

  ## Format inputs résolution

      stage_spec["inputs"] = [
        %{"from_stage" => "stage_a", "key" => "result_id"},
        ...
      ]

      → résolu en %{"stage_a" => prior_outputs["stage_a"]["result_id"]}
  """

  alias Fleet.Pipeline.PodRegistry

  require Logger

  @spec run(
          stage_name :: String.t(),
          stage_spec :: map(),
          mandate_ctx :: map(),
          prior_outputs :: map(),
          pipeline_id :: term()
        ) :: {:ok, term()} | {:error, term()}
  def run(stage_name, stage_spec, mandate_ctx, prior_outputs, pipeline_id) do
    case missing_dependencies(stage_spec["inputs"], prior_outputs) do
      [] ->
        do_run(stage_name, stage_spec, mandate_ctx, prior_outputs, pipeline_id)

      missing ->
        Logger.error(
          "fleet_pipeline stage spawn refusé: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} inputs amont manquants=#{inspect(missing)}"
        )

        {:error, {:missing_inputs, missing}}
    end
  end

  # finding Vulcan : un input déclaré dont le stage source est ABSENT des outputs amont
  # était résolu en nil silencieux (`get_in/2` → nil) → stage lancé avec inputs incomplets
  # au lieu d'un échec explicite. On refuse l'absence du stage SOURCE (violation
  # d'ordonnancement). Une clé manquante dans un output présent reste tolérée (champ
  # potentiellement optionnel) — l'absence du stage amont, elle, est une vraie erreur.
  defp missing_dependencies(nil, _prior), do: []
  defp missing_dependencies([], _prior), do: []

  defp missing_dependencies(specs, prior) when is_list(specs) do
    specs
    |> Enum.filter(fn
      %{"from_stage" => s} -> not Map.has_key?(prior, s)
      _ -> false
    end)
    |> Enum.map(fn %{"from_stage" => s} = spec ->
      %{"from_stage" => s, "key" => Map.get(spec, "key")}
    end)
  end

  defp do_run(stage_name, stage_spec, mandate_ctx, prior_outputs, pipeline_id) do
    inputs = resolve_inputs(stage_spec["inputs"], prior_outputs)
    role = stage_spec["role"]
    profile = stage_spec["profile"]

    stage_ctx = %{
      mandate: mandate_ctx,
      stage: stage_name,
      inputs: inputs,
      pipeline_id: pipeline_id,
      ticket_id: Map.get(mandate_ctx, :ticket_id, "pipeline-#{pipeline_id}"),
      # R1.3 (hole C1) : pipeline_id+stage injectés dans les spawn_opts → le Pod les
      # stocke (state.opts) et les ré-émet dans `pod.completed` → l'Executor corrèle
      # le pod terminé à sa stage (bridge self-describing, sans mapping externe).
      spawn_opts:
        Keyword.merge(Map.get(mandate_ctx, :spawn_opts, []),
          pipeline_id: pipeline_id,
          stage: stage_name
        )
    }

    case lifetime_scope_for(role, profile) do
      "pipe" -> run_pipe_stage(stage_name, role, profile, stage_ctx, pipeline_id)
      _other -> run_one_shot_stage(stage_name, role, profile, stage_ctx, pipeline_id)
    end
  end

  # Stage pipe-scoped : si un pod du role existe déjà dans le pipeline,
  # on le réveille (push task ciblée + send-keys yop). Sinon spawn neuf
  # + register dans PodRegistry.
  defp run_pipe_stage(stage_name, role, profile, stage_ctx, pipeline_id) do
    case PodRegistry.lookup(pipeline_id, role) do
      {:ok, pod_id} ->
        wake_existing_pod(pod_id, stage_name, stage_ctx, pipeline_id)

      :not_found ->
        spawn_and_register_pipe(stage_name, role, profile, stage_ctx, pipeline_id)
    end
  end

  defp wake_existing_pod(pod_id, stage_name, stage_ctx, pipeline_id) do
    :ok = push_task_for_pod(pod_id, stage_ctx)

    case spawner().wake_pod(pod_id) do
      :ok ->
        Logger.debug(
          "fleet_pipeline stage wake ok: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} pod=#{inspect(pod_id)} (réutilisation pipe)"
        )

        {:ok, pod_id}

      {:error, reason} = err ->
        Logger.error(
          "fleet_pipeline stage wake fail: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} pod=#{inspect(pod_id)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp spawn_and_register_pipe(stage_name, role, profile, stage_ctx, pipeline_id) do
    case spawner_backend().spawn_stage_pod(role, profile, stage_ctx) do
      {:ok, pod_id} ->
        :ok = PodRegistry.register(pipeline_id, role, pod_id)
        :ok = push_task_for_pod(pod_id, stage_ctx)

        Logger.debug(
          "fleet_pipeline stage spawn ok (pipe, registered + task pushed): pipeline=#{inspect(pipeline_id)} stage=#{stage_name} role=#{role} pod=#{inspect(pod_id)}"
        )

        {:ok, pod_id}

      {:error, reason} = err ->
        Logger.error(
          "fleet_pipeline stage spawn fail (pipe): pipeline=#{inspect(pipeline_id)} stage=#{stage_name} role=#{role} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp run_one_shot_stage(stage_name, role, profile, stage_ctx, pipeline_id) do
    case spawner_backend().spawn_stage_pod(role, profile, stage_ctx) do
      {:ok, pod_id} ->
        # Push la task dans TaskQueue avec `_lcars_pod_id` ciblé : sans,
        # le claude REPL appelle get_task → empty → done:true et termine
        # sans traiter le stage. Le ticket file + brief mandate ne sont
        # pas suffisants — la voie canonique pod→fleet est MCP (PodTools
        # get_task / submit_result), pas Read fichier.
        :ok = push_task_for_pod(pod_id, stage_ctx)

        Logger.debug(
          "fleet_pipeline stage spawn ok: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} role=#{role} pod=#{inspect(pod_id)}"
        )

        {:ok, pod_id}

      {:error, reason} = err ->
        Logger.error(
          "fleet_pipeline stage spawn fail: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} role=#{role} reason=#{inspect(reason)}"
        )

        err
    end
  end

  # Push la task dans TaskQueue ciblée pod_id (le claude REPL pop via
  # mcp__fleet__get_task → TaskQueue.next_for filtré). Helper réutilisable
  # par spawn et wake.
  defp push_task_for_pod(pod_id, stage_ctx) do
    task_queue().push(build_pod_task(stage_ctx, pod_id))
  end

  # Construit la task à pousser dans la TaskQueue centrale (consommée par
  # le pod via mcp__fleet__get_task). `_lcars_pod_id` cible le pod éveillé
  # (filtré par PodTools.get_task → TaskQueue.next_for).
  defp build_pod_task(stage_ctx, pod_id) do
    %{
      "ticket_id" => Map.get(stage_ctx, :ticket_id),
      "stage" => Map.get(stage_ctx, :stage),
      "description" => build_mandate(stage_ctx),
      "inputs" => Map.get(stage_ctx, :inputs, %{}),
      "_lcars_pod_id" => pod_id
    }
  end

  defp build_mandate(stage_ctx) do
    stage = Map.get(stage_ctx, :stage)
    mandate = Map.get(stage_ctx, :mandate)
    inputs = Map.get(stage_ctx, :inputs, %{})

    [
      if(is_binary(stage), do: "Stage : #{stage}"),
      if(not is_nil(mandate), do: "Mandat : #{inspect(mandate)}"),
      if(is_map(inputs) and map_size(inputs) > 0,
        do: "Inputs (stages amont) : #{inspect(inputs)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Résolution lifetime_scope via Fleet.CapProfile (même chemin que
  # SpawnerBackend.Default). Fallback "one-shot" sur erreur de résolution
  # — c'est le comportement sûr (pas de pipe registry sur cap-profile
  # cassé).
  #
  # Override pour tests via `:fleet_pipeline, :lifetime_scope_resolver`
  # (anon fn (role, profile) -> "pipe" | "one-shot" | ...). Évite l'I/O
  # cap-profile YAML en tests.
  defp lifetime_scope_for(role, profile) do
    case Application.get_env(:fleet_pipeline, :lifetime_scope_resolver) do
      fun when is_function(fun, 2) -> fun.(role, profile)
      _ -> default_lifetime_scope(role, profile)
    end
  end

  defp default_lifetime_scope(role, nil), do: default_lifetime_scope(role, [])

  defp default_lifetime_scope(role, profile) when is_binary(profile),
    do: default_lifetime_scope(role, [profile])

  defp default_lifetime_scope(role, profile) when is_list(profile) do
    result =
      case profile do
        [] -> Fleet.CapProfile.load(role)
        modops -> Fleet.CapProfile.compose(role, modops)
      end

    case result do
      {:ok, cap} -> get_in(cap.spec, ["invocation", "lifetime_scope"]) || "one-shot"
      _ -> "one-shot"
    end
  end

  @doc """
  Résolution des inputs : chaque spec `%{"from_stage" => s, "key" => k}`
  pioche `prior_outputs[s][k]`. Renvoie une map keyed par `from_stage`.

  ## Examples

      iex> Fleet.Pipeline.StageRunner.resolve_inputs(
      ...>   [%{"from_stage" => "a", "key" => "id"}],
      ...>   %{"a" => %{"id" => 42}}
      ...> )
      %{"a" => 42}

      iex> Fleet.Pipeline.StageRunner.resolve_inputs(nil, %{})
      %{}
  """
  @spec resolve_inputs(list() | nil, map()) :: map()
  def resolve_inputs(nil, _prior), do: %{}
  def resolve_inputs([], _prior), do: %{}

  def resolve_inputs(specs, prior) when is_list(specs) do
    Enum.reduce(specs, %{}, fn %{"from_stage" => s, "key" => k}, acc ->
      Map.put(acc, s, get_in(prior, [s, k]))
    end)
  end

  defp spawner_backend do
    Application.get_env(
      :fleet_pipeline,
      :spawner_backend,
      Fleet.Pipeline.SpawnerBackend.Default
    )
  end

  # Seams config-driven pour les tests (stub TaskQueue / stub Spawner sans
  # spin-up infra réelle). Default = modules production.
  defp task_queue do
    Application.get_env(:fleet_pipeline, :task_queue, Fleet.MCP.TaskQueue)
  end

  defp spawner do
    Application.get_env(:fleet_pipeline, :spawner, Fleet.Spawner)
  end
end
