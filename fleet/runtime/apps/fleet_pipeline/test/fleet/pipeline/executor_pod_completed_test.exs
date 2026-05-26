defmodule Fleet.Pipeline.PodCompletedCaptureStub do
  @moduledoc """
  Stub SpawnerBackend pour R1.3 (hole C1) : retourne `{:ok, pod_id}` SANS émettre
  `pipeline.stage.completed` (contrairement à SpawnerBackendStub) — pour tester le
  VRAI chemin où c'est `pod.completed` qui pilote l'avancement. Capture les spawn_opts
  reçus (preuve que StageRunner injecte pipeline_id+stage) vers le process `:r13_probe`.
  """
  @behaviour Fleet.Pipeline.SpawnerBackend

  @impl Fleet.Pipeline.SpawnerBackend
  def spawn_stage_pod(_role, _profile, stage_ctx) do
    send(:r13_probe, {:spawned, stage_ctx.stage, Map.get(stage_ctx, :spawn_opts)})
    {:ok, "pod-#{stage_ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.ExecutorPodCompletedTest do
  @moduledoc """
  R1.3 (hole C1) : bridge pod.completed → pipeline.stage.completed. Prouve que
  (a) StageRunner injecte pipeline_id+stage dans spawn_opts (→ le Pod les ré-émet),
  (b) l'Executor consomme `pod.completed` self-décrit et avance la stage jusqu'à
  `pipeline.completed`, (c) filtre pipeline_id (pod d'un autre pipeline = ignoré).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  setup %{tmp_dir: tmp_dir} do
    Process.register(self(), :r13_probe)

    File.write!(Path.join(tmp_dir, "r13.yaml"), """
    name: r13
    version: 1
    stages:
      only_stage:
        role: scout
        profile: empty
    """)

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.PodCompletedCaptureStub)
    Bus.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      Application.delete_env(:fleet_pipeline, :pipelines_root)
      Application.delete_env(:fleet_pipeline, :spawner_backend)
    end)

    :ok
  end

  test "pod.completed self-décrit → Executor avance la stage → pipeline.completed (bridge C1)" do
    {:ok, pipeline_id} = Pipeline.start_pipeline("r13", %{ticket_id: "r13#1"})

    # (a) StageRunner a injecté pipeline_id+stage dans les spawn_opts du pod.
    assert_receive {:spawned, "only_stage", spawn_opts}, 2_000
    assert spawn_opts[:pipeline_id] == pipeline_id
    assert spawn_opts[:stage] == "only_stage"

    # Le pod n'a PAS émis stage.completed (stub no-emit) → pipeline en attente.
    refute_receive {_a, %{"event_type" => "pipeline.completed"}}, 200

    # (b) Simule la complétion event-driven du pod : pod.completed self-décrit (cf. Pod.pod_completed_payload),
    # `result` = résultat structuré (R-CORE.comm 2.2, plus de livrable_path fichier).
    Bus.broadcast("pod.completed", %{
      "pod_id" => "pod-only_stage",
      "ticket_id" => "r13#1",
      "result" => %{"answer" => "r13-done"},
      "pipeline_id" => pipeline_id,
      "stage" => "only_stage"
    })

    assert_receive {_a,
                    %{
                      "event_type" => "pipeline.completed",
                      "payload" => %{"pipeline_id" => ^pipeline_id} = payload
                    }},
                   2_000

    # outputs de la stage = le résultat structuré du pod (R-CORE.comm 2.2).
    assert payload["outputs"]["only_stage"] == %{"result" => %{"answer" => "r13-done"}}
  end

  test "pod.completed d'un AUTRE pipeline → ignoré (filtre pipeline_id, pas d'avancement)" do
    {:ok, pipeline_id} = Pipeline.start_pipeline("r13", %{ticket_id: "r13#2"})
    assert_receive {:spawned, "only_stage", _}, 2_000

    Bus.broadcast("pod.completed", %{
      "pod_id" => "pod-foreign",
      "ticket_id" => "other",
      "result" => %{"answer" => "x"},
      "pipeline_id" => "#{pipeline_id}-DIFFERENT",
      "stage" => "only_stage"
    })

    refute_receive {_a, %{"event_type" => "pipeline.completed"}}, 500
  end
end
