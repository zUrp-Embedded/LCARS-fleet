defmodule Fleet.Pipeline.ExecutorTest do
  @moduledoc """
  Integration test : pipeline 3 stages mock via SpawnerBackendStub.

  Vérifie le cycle complet :
    1. start_pipeline/2 → DynamicSupervisor spawn Executor
    2. Executor lance stage_a (no needs)
    3. Stub broadcast pipeline.stage.completed → Executor consume
    4. Gates.dispatch :pass → next stage_b
    5. Stub broadcast → next stage_c
    6. Toutes stages :completed → broadcast pipeline.completed +
       Executor stop :normal
  """

  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test_pipeline.yaml"), """
    name: test_pipeline
    version: 1
    stages:
      stage_a:
        role: scout
        profile: empty
      stage_b:
        role: archiviste
        profile: empty
        needs: [stage_a]
      stage_c:
        role: emissaire
        profile: empty
        needs: [stage_b]
    """)

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.StageSpawnerStub)

    Application.put_env(:fleet_pipeline, :stub_outputs, %{
      "stage_a" => %{"a_out" => 1},
      "stage_b" => %{"b_out" => 2},
      "stage_c" => %{"c_out" => 3}
    })

    start_supervised!(Fleet.MCP.TaskQueue)
    Bus.subscribe()

    on_exit(fn ->
      # Terminer tous les Executor restants pour éviter qu'un broadcast
      # async tardif ne pollue le test suivant via Bus partagé.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      Application.delete_env(:fleet_pipeline, :pipelines_root)
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :stub_outputs)
      Application.delete_env(:fleet_pipeline, :stub_failure)
    end)

    :ok
  end

  test "pipeline 3 stages séquentielles → pipeline.completed broadcast" do
    {:ok, pipeline_id} = Pipeline.start_pipeline("test_pipeline", %{ticket_id: "test#1"})

    assert is_binary(pipeline_id)

    assert_receive {_atom,
                    %{
                      "event_type" => "pipeline.completed",
                      "payload" => %{"pipeline_id" => ^pipeline_id} = payload
                    }},
                   2_000

    assert payload["outputs"]["stage_a"] == %{"a_out" => 1}
    assert payload["outputs"]["stage_b"] == %{"b_out" => 2}
    assert payload["outputs"]["stage_c"] == %{"c_out" => 3}
  end

  test "Mi3 : start_pipeline sans ticket_id (ou vide) → {:error, :ticket_id_required}" do
    assert {:error, :ticket_id_required} = Pipeline.start_pipeline("test_pipeline", %{})

    assert {:error, :ticket_id_required} =
             Pipeline.start_pipeline("test_pipeline", %{ticket_id: ""})
  end

  test "spawn_stage_pod failure → pipeline.failed broadcast" do
    Application.put_env(:fleet_pipeline, :stub_failure, true)

    {:ok, pipeline_id} = Pipeline.start_pipeline("test_pipeline", %{ticket_id: "test#2"})

    assert_receive {_atom,
                    %{
                      "event_type" => "pipeline.failed",
                      "payload" => %{"pipeline_id" => ^pipeline_id} = payload
                    }},
                   2_000

    assert payload["reason"] =~ "spawn fail"
  end

  test "Registry lookup retourne pid Executor vivant" do
    {:ok, pipeline_id} = Pipeline.start_pipeline("test_pipeline", %{ticket_id: "test#3"})

    [{pid, _}] = Registry.lookup(Fleet.Pipeline.Registry, pipeline_id)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end
