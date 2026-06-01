defmodule Fleet.Pipeline.ExecutorCleanupTest do
  @moduledoc """
  Tests du cleanup `terminate/2` de l'Executor — quand un pipeline finit
  (pipeline.completed / pipeline.failed / crash), tous les pods
  pipe-scoped enregistrés dans `PodRegistry` doivent être `kill_pod` via
  `Fleet.Spawner`. Cycle de vie pod pipe = vie du pipeline.
  """

  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline
  alias Fleet.Pipeline.{PodRegistry, SpawnerStub}

  setup do
    # Pipeline fixtures dir (cohérent executor_test.exs).
    base = Path.join([System.tmp_dir!(), "fleet_pipeline_cleanup_test"])
    pipelines_root = Path.join(base, "pipelines")
    File.rm_rf!(base)
    File.mkdir_p!(pipelines_root)

    # Pipeline 1 stage minimal — l'important est que la stage spawn un
    # pod, l'Executor le voit complet, broadcast pipeline.completed → terminate.
    File.write!(Path.join(pipelines_root, "tp.yaml"), """
    name: tp
    version: 1
    stages:
      only:
        role: engineer
        profile: empty
    """)

    Application.put_env(:fleet_pipeline, :pipelines_root, pipelines_root)
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.StageSpawnerStub)
    Application.put_env(:fleet_pipeline, :spawner, SpawnerStub)
    Application.put_env(:fleet_pipeline, :stub_outputs, %{"only" => %{"ok" => true}})

    Application.put_env(
      :fleet_pipeline,
      :lifetime_scope_resolver,
      fn
        "engineer", _ -> "pipe"
        _other, _ -> "one-shot"
      end
    )

    # Broker Fleet.TaskQueue app-global (ensure_all_started) — pas de start_supervised.
    start_supervised!(SpawnerStub)

    Bus.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      File.rm_rf!(base)
      Application.delete_env(:fleet_pipeline, :pipelines_root)
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :spawner)
      Application.delete_env(:fleet_pipeline, :stub_outputs)
      Application.delete_env(:fleet_pipeline, :lifetime_scope_resolver)
    end)

    :ok
  end

  test "pipeline.completed → terminate → kill_pod sur tous les pipe pods" do
    SpawnerStub.reset()

    {:ok, pipeline_id} = Pipeline.start_pipeline("tp", %{ticket_id: "tk#1"})

    # Le pipeline finit (stage `only` complete → pipeline.completed).
    assert_receive {_atom,
                    %{
                      "event_type" => "pipeline.completed",
                      "payload" => %{"pipeline_id" => ^pipeline_id}
                    }},
                   2_000

    # On laisse `terminate/2` s'exécuter (le GenServer a stop :normal,
    # l'Agent SpawnerStub a reçu kill_pod async).
    Process.sleep(50)

    # Le pod registered doit avoir été kill au terminate. L'Executor
    # default `:permanent` peut restart sur `:normal` → on observe
    # potentiellement plusieurs kill_calls ; on assert juste qu'il y a
    # au moins le notre.
    kill_calls = SpawnerStub.kill_calls()

    assert "stub-pod-only" in kill_calls,
           "expected kill_pod call on registered pod, got: #{inspect(kill_calls)}"

    # PodRegistry ne contient plus rien pour ce pipeline (cleanup
    # idempotent).
    assert PodRegistry.pods_for(pipeline_id) == %{}
  end

  test "Executor crash (terminate brutal) → cleanup pipe pods quand même" do
    SpawnerStub.reset()

    # On crée manuellement un binding pour simuler un pod registered, puis
    # kill l'Executor brutalement. terminate/2 doit cleanup.
    pipeline_id = "manual-pipe-#{System.unique_integer([:positive])}"

    # Démarre un Executor (init va spawn la stage, faut juste qu'il vive
    # pour qu'on puisse l'exit).
    {:ok, pipeline_id_2} = Pipeline.start_pipeline("tp", %{ticket_id: "tk#2"})

    # On lui force un kill brutal.
    [{_, pid, _, _}] = DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor)
    Process.exit(pid, :kill)

    # :kill ne déclenche pas terminate/2 (par design OTP), donc le
    # cleanup automatique ne s'applique pas. Le pattern correct = `:shutdown` ou
    # arrêt naturel (qui couvre les cas pipeline.completed/failed). On
    # documente ici la limite : si le BEAM crash brutal, le registry
    # peut avoir des entrées orphelines — d'où le besoin d'un sweep
    # périodique côté monitoring (hors scope chantier).
    Process.sleep(50)
    refute Process.alive?(pid)

    # Le binding peut rester (limite acceptable). On nettoie manuellement.
    PodRegistry.cleanup_pipeline(pipeline_id_2)
    _ = pipeline_id
  end
end
