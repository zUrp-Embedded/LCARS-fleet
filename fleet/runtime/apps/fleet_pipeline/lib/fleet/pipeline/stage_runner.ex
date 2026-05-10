defmodule Fleet.Pipeline.StageRunner do
  @moduledoc """
  Orchestre l'exécution d'1 stage : prep `inputs` (résolution depuis
  outputs prior stages) → spawn pod via `SpawnerBackend` → outputs
  collectés async par Executor via PubSub `:pipeline_stage_completed`.

  Pas de state local — pure fonction de spawn. Le pod broadcast
  l'event de complétion en EXTRACT phase (chantier 7
  `fleet_pod_runtime` PROMOTED).

  ## Format inputs résolution

      stage_spec["inputs"] = [
        %{"from_stage" => "stage_a", "key" => "result_id"},
        ...
      ]

      → résolu en %{"stage_a" => prior_outputs["stage_a"]["result_id"]}
  """

  require Logger

  @spec run(
          stage_name :: String.t(),
          stage_spec :: map(),
          mandate_ctx :: map(),
          prior_outputs :: map(),
          pipeline_id :: term()
        ) :: {:ok, term()} | {:error, term()}
  def run(stage_name, stage_spec, mandate_ctx, prior_outputs, pipeline_id) do
    inputs = resolve_inputs(stage_spec["inputs"], prior_outputs)

    stage_ctx = %{
      mandate: mandate_ctx,
      stage: stage_name,
      inputs: inputs,
      pipeline_id: pipeline_id,
      ticket_id: Map.get(mandate_ctx, :ticket_id, "pipeline-#{pipeline_id}")
    }

    case spawner_backend().spawn_stage_pod(
           stage_spec["role"],
           stage_spec["profile"],
           stage_ctx
         ) do
      {:ok, pod_id} ->
        Logger.debug(
          "fleet_pipeline stage spawn ok: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} pod=#{inspect(pod_id)}"
        )

        {:ok, pod_id}

      {:error, reason} = err ->
        Logger.error(
          "fleet_pipeline stage spawn fail: pipeline=#{inspect(pipeline_id)} stage=#{stage_name} reason=#{inspect(reason)}"
        )

        err
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
end
