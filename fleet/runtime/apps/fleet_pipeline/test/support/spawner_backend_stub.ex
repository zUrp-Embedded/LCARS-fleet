defmodule Fleet.Pipeline.SpawnerBackendStub do
  @moduledoc """
  Stub `SpawnerBackend` pour tests.

  N'invoque pas Fleet.Spawner réel. Au lieu de bwrap, broadcast un
  event `pipeline.stage.completed` sur le Bus avec outputs canned
  configurés via `Application.put_env(:fleet_pipeline,
  :stub_outputs, %{stage_name => outputs_map})`.

  Si `:stub_failure` (atom) → renvoie `{:error, :stub_failure}` sans
  broadcast.

  Toutes les fonctions sont synchrones — broadcast direct dans le
  caller process (qui est l'Executor).
  """

  @behaviour Fleet.Pipeline.SpawnerBackend

  @impl Fleet.Pipeline.SpawnerBackend
  def spawn_stage_pod(_role, _profile, stage_ctx) do
    cond do
      Application.get_env(:fleet_pipeline, :stub_failure, false) ->
        {:error, :stub_failure}

      true ->
        stage = stage_ctx.stage
        pipeline_id = stage_ctx.pipeline_id
        outputs = Application.get_env(:fleet_pipeline, :stub_outputs, %{})[stage] || %{}

        spawn(fn ->
          # broadcast async pour simuler le pod EXTRACT phase post-spawn
          Process.sleep(5)

          Fleet.EventRouter.Bus.broadcast(
            "pipeline.stage.completed",
            %{
              "pipeline_id" => pipeline_id,
              "stage" => stage,
              "outputs" => outputs
            },
            ticket_id: get_in(stage_ctx, [:mandate, :ticket_id])
          )
        end)

        {:ok, "stub-pod-#{stage}"}
    end
  end
end
