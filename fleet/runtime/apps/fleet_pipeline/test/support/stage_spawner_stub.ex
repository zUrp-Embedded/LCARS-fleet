defmodule Fleet.Pipeline.StageSpawnerStub do
  @moduledoc """
  Stub `StageSpawner` pour tests.

  N'invoque pas Fleet.Spawner réel. Au lieu de bwrap, broadcast la struct
  canon `%Fleet.Event{source: :pipeline, type: :"pipeline.stage.completed"}`
  sur le Bus avec outputs canned configurés via
  `Application.put_env(:fleet_pipeline, :stub_outputs, %{stage_name => outputs_map})`.
  (R2 / D1 : enveloppe canon, plus de tuple legacy via broadcast/3.)

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
          # R2 (D1) : struct canon %Fleet.Event{} (plus de tuple legacy broadcast/3).
          Fleet.EventRouter.Bus.broadcast("fleet.events", %Fleet.Event{
            source: :pipeline,
            type: :"pipeline.stage.completed",
            timestamp: DateTime.utc_now(),
            payload: %{
              "pipeline_id" => pipeline_id,
              "stage" => stage,
              "outputs" => outputs
            }
          })
        end)

        {:ok, "stub-pod-#{stage}"}
    end
  end
end
