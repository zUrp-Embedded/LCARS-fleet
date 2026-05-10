defmodule Fleet.Pipeline do
  @moduledoc """
  Exécuteur générique de pipelines YAML déclarés dans
  `pipelines/<name>.yaml` (Ring 2 — orchestration).

  Le module ne hardcode aucun pipeline particulier. Il lit le YAML
  référencé par le mandate et exécute les stages déclarés selon le
  DAG `needs` (Toposort), gates, coordHook.

  ## Sous-modules

    * `Fleet.Pipeline.Loader` — parse YAML + validate JSON schema
    * `Fleet.Pipeline.Toposort` — DAG sort (Kahn)
    * `Fleet.Pipeline.Executor` — GenServer per-run
    * `Fleet.Pipeline.Gates` — dispatch hard/soft/terminal
    * `Fleet.Pipeline.StageRunner` — spawn pod via SpawnerBackend
    * `Fleet.Pipeline.Gate` — behaviour 1 callback `evaluate/3`
    * `Fleet.Pipeline.SpawnerBackend` / `CoordBackend` — seams ch6/ch14

  ## Public API

      Fleet.Pipeline.start_pipeline("intensity-low", %{ticket_id: "fleet/lcars#42"})
      # => {:ok, pipeline_id}

  Le pipeline_id retourné est un binaire UUID-like utilisable pour
  lookup via Registry `Fleet.Pipeline.Registry`.
  """

  alias Fleet.Pipeline.Executor

  @doc """
  Démarre un pipeline run sous le DynamicSupervisor.

  ## Inputs

    * `pipeline_name` — string, résolu en `pipelines/<name>.yaml`
    * `mandate_context` — map `%{ticket_id, intensity_json_path?, ...}`
    * `opts` :
      * `:pipeline_id` — override id (default UUID-like généré)

  ## Returns

    * `{:ok, pipeline_id}` — Executor démarré, monitorable via Registry
    * `{:error, reason}` — schema invalide / introuvable / déjà démarré
  """
  @spec start_pipeline(String.t(), map(), keyword()) ::
          {:ok, pipeline_id :: String.t()} | {:error, term()}
  def start_pipeline(pipeline_name, mandate_context, opts \\ [])
      when is_binary(pipeline_name) and is_map(mandate_context) do
    pipeline_id = Keyword.get(opts, :pipeline_id, generate_pipeline_id())

    spec =
      {Executor,
       [
         pipeline_id: pipeline_id,
         pipeline_name: pipeline_name,
         mandate_context: mandate_context
       ]}

    case DynamicSupervisor.start_child(Fleet.Pipeline.ExecutorSupervisor, spec) do
      {:ok, _pid} -> {:ok, pipeline_id}
      {:ok, _pid, _info} -> {:ok, pipeline_id}
      {:error, {:already_started, _pid}} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_pipeline_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
