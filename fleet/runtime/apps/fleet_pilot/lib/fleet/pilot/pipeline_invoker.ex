defmodule Fleet.Pilot.PipelineInvoker do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Pipeline.start_pipeline/3`. Mêmes
  raisons que `Fleet.Pipeline.StageSpawner` (test stub
  synchrone, fallback futur).

  Default `Fleet.Pilot.PipelineInvoker.Default` délègue à
  `Fleet.Pipeline.start_pipeline/3`.
  """

  @callback start_pipeline(
              pipeline_name :: String.t(),
              mandate_context :: map(),
              opts :: keyword()
            ) :: {:ok, pipeline_id :: String.t()} | {:error, term()}
end

defmodule Fleet.Pilot.PipelineInvoker.Default do
  @moduledoc """
  Délégation directe à `Fleet.Pipeline.start_pipeline/3`.
  """

  @behaviour Fleet.Pilot.PipelineInvoker

  @impl Fleet.Pilot.PipelineInvoker
  def start_pipeline(pipeline_name, mandate_context, opts \\ []) do
    Fleet.Pipeline.start_pipeline(pipeline_name, mandate_context, opts)
  end
end
