defmodule Fleet.Pipeline.StageSpawnerStub do
  @moduledoc """
  Stub `StageSpawner` pour tests.

  N'invoque pas Fleet.Spawner réel. Au lieu de bwrap, broadcast un
  event `pipeline.stage.completed` sur le Bus avec outputs canned
  configurés via `Application.put_env(:fleet_pipeline,
  :stub_outputs, %{stage_name => outputs_map})`.

  Si `:stub_failure` (atom) → renvoie `{:error, :stub_failure}` sans
  broadcast.

  Toutes les fonctions sont synchrones — broadcast direct dans le
  caller process (qui est l'Executor).
  """

  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod(_role, _profile, stage_ctx) do
    cond do
      Application.get_env(:fleet_pipeline, :stub_failure, false) ->
        {:error, :stub_failure}

      true ->
        stage = stage_ctx.stage
        pipeline_id = stage_ctx.pipeline_id
        outputs = Application.get_env(:fleet_pipeline, :stub_outputs, %{})[stage] || %{}

        spawn(fn ->
          # broadcast async post-spawn (simule l'EXTRACT du pod). Mi14 : pas de sleep — l'Executor
          # (GenServer) sérialise : il finit do_run_stage avant de traiter ce stage.completed
          # (FIFO mailbox). Ordering garanti sans délai arbitraire.
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
