defmodule Fleet.Pipeline.GatePendingSpawnerStub do
  @moduledoc """
  Stub StageSpawner pour R06 : distingue le spawn du pod de stage du spawn du
  pod **gatekeeper** (gate async). Aucun n'émet de complétion — le test pilote
  les `pod.completed` à la main pour exercer la state-machine `:awaiting_gate`.
  Le pod_id du gatekeeper est distinct par round (re-dispatch sur retry).
  """
  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod("gatekeeper", _profile, ctx) do
    n = Application.get_env(:fleet_pipeline, :gk_spawn_count, 0) + 1
    Application.put_env(:fleet_pipeline, :gk_spawn_count, n)
    send(:gate_probe, {:gatekeeper_spawned, ctx.stage, n})
    {:ok, "gk-#{ctx.stage}-#{n}"}
  end

  def spawn_stage_pod(_role, _profile, ctx) do
    send(:gate_probe, {:spawned, ctx.stage})
    {:ok, "pod-#{ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.GateFailSpawnerStub do
  @moduledoc "Stub : le spawn du gatekeeper échoue (test fail-loud)."
  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod("gatekeeper", _profile, _ctx), do: {:error, :spawn_refused}

  def spawn_stage_pod(_role, _profile, ctx) do
    send(:gate_probe, {:spawned, ctx.stage})
    {:ok, "pod-#{ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.ExecutorGatePendingTest do
  @moduledoc """
  R06 — state-machine de gate async. Un stage à gate (soft ou terminal
  non-tranchable) dispatche un gatekeeper (juge unique) ; le pipeline reste en
  attente (`:awaiting_gate`) jusqu'au `pod.completed` du gatekeeper, puis
  ré-évalue (pass → avance ; fail → halt ; retry → re-dispatch si rounds).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  setup %{tmp_dir: tmp_dir} do
    Process.register(self(), :gate_probe)
    Application.put_env(:fleet_pipeline, :gk_spawn_count, 0)

    write_pipeline(tmp_dir, "softgate", soft_gate_yaml(1))
    write_pipeline(tmp_dir, "softgate2", soft_gate_yaml(2))
    write_pipeline(tmp_dir, "termgate", terminal_gate_yaml())

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.GatePendingSpawnerStub)
    Bus.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      Application.delete_env(:fleet_pipeline, :pipelines_root)
      Application.delete_env(:fleet_pipeline, :spawner_backend)
      Application.delete_env(:fleet_pipeline, :gk_spawn_count)
    end)

    :ok
  end

  defp write_pipeline(dir, name, yaml), do: File.write!(Path.join(dir, "#{name}.yaml"), yaml)

  defp soft_gate_yaml(max_rounds) do
    """
    name: softgate
    version: 1
    stages:
      audit:
        role: scout
        profile: empty
        gate:
          type: soft
          max_rounds: #{max_rounds}
    """
  end

  defp terminal_gate_yaml do
    # Rule non-required + outputs sans la clé → :nontranchable → gatekeeper.
    """
    name: termgate
    version: 1
    stages:
      audit:
        role: scout
        profile: empty
        gate:
          type: terminal
          rules:
            - name: soft_check
              required: false
              match:
                clean: true
    """
  end

  defp complete_pod(pod_id, pipeline_id, stage, result) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      pod_id: pod_id,
      payload: %{
        "pod_id" => pod_id,
        "result" => result,
        "pipeline_id" => pipeline_id,
        "stage" => stage
      }
    })
  end

  # Démarre le pipeline + amène le stage `audit` jusqu'à son 1er gatekeeper.
  defp start_to_gatekeeper(name) do
    {:ok, pid} = Pipeline.start_pipeline(name, %{ticket_id: "sg#{name}"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_pod("pod-audit", pid, "audit", %{"ok" => true})
    assert_receive {:gatekeeper_spawned, "audit", 1}, 2_000
    pid
  end

  test "soft gate : stage complété → gatekeeper dispatché, pipeline en attente" do
    pid = start_to_gatekeeper("softgate")
    refute_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 200
    _ = pid
  end

  test "décision gatekeeper pass → pipeline.completed" do
    pid = start_to_gatekeeper("softgate")
    complete_pod("gk-audit-1", pid, "audit", %{"decision" => "pass"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.completed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   2_000
  end

  test "décision gatekeeper abort → pipeline.failed (fail-closed)" do
    pid = start_to_gatekeeper("softgate")
    complete_pod("gk-audit-1", pid, "audit", %{"decision" => "abort"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   2_000
  end

  test "décision malformée (pas de :decision) → :fail (fail-closed, pas de pass)" do
    pid = start_to_gatekeeper("softgate")
    complete_pod("gk-audit-1", pid, "audit", %{"garbage" => true})

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.failed"}, 2_000
  end

  test "soft retry (max_rounds 2) → re-dispatch round 2 (round counter), puis pass → completed" do
    pid = start_to_gatekeeper("softgate2")

    # round 1 dit retry → re-dispatch d'un gatekeeper round 2 (pod_id distinct).
    complete_pod("gk-audit-1", pid, "audit", %{"decision" => "retry"})
    assert_receive {:gatekeeper_spawned, "audit", 2}, 2_000

    # round 2 dit pass → le pipeline avance.
    complete_pod("gk-audit-2", pid, "audit", %{"decision" => "pass"})

    assert_receive %Fleet.Event{type: :"pipeline.completed", payload: %{"pipeline_id" => ^pid}},
                   2_000
  end

  test "soft retry exhausted (max_rounds 1) → pipeline.failed (pas de boucle infinie)" do
    pid = start_to_gatekeeper("softgate")

    # round 1 == max_rounds → retry épuisé → halt (aucun re-dispatch).
    complete_pod("gk-audit-1", pid, "audit", %{"decision" => "retry"})

    assert_receive %Fleet.Event{type: :"pipeline.failed", payload: %{"pipeline_id" => ^pid}},
                   2_000

    refute_receive {:gatekeeper_spawned, "audit", 2}, 200
  end

  test "terminal non-tranchable → gatekeeper ; decision revision (retry) → halt (non-retryable)" do
    {:ok, pid} = Pipeline.start_pipeline("termgate", %{ticket_id: "tg"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_pod("pod-audit", pid, "audit", %{"ok" => true})
    assert_receive {:gatekeeper_spawned, "audit", 1}, 2_000

    # Terminal n'a pas de compteur de rounds → retry/revision = halt.
    complete_pod("gk-audit-1", pid, "audit", %{"decision" => "revision"})

    assert_receive %Fleet.Event{type: :"pipeline.failed", payload: %{"pipeline_id" => ^pid}},
                   2_000
  end

  test "spawn gatekeeper échoue → pipeline.failed immédiat (fail-loud)" do
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.GateFailSpawnerStub)
    {:ok, pid} = Pipeline.start_pipeline("softgate", %{ticket_id: "sgfail"})
    assert_receive {:spawned, "audit"}, 2_000

    complete_pod("pod-audit", pid, "audit", %{"ok" => true})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   2_000
  end
end
