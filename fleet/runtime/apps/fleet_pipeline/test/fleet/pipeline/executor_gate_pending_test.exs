defmodule Fleet.Pipeline.GateMandateTaskQueueStub do
  @moduledoc """
  Stub TaskQueue pour R4/B : capture l'enqueue du mandat d'éval adressé au
  gatekeeper, rend un id de mandat déterministe (`= correlation_id`). Le test
  pilote ensuite l'event `task_queue.task_completed` pour rendre la décision.
  """
  def enqueue(pod_id, attrs) do
    # corr unique sans état global (le test le récupère via la probe → pas de
    # dépendance à un compteur partagé inter-tests).
    corr = "corr-#{System.unique_integer([:positive])}"
    send(:gate_probe, {:enqueued, corr, pod_id, attrs.metadata["stage"]})
    {:ok, %{id: corr}}
  end
end

defmodule Fleet.Pipeline.GateEnqueueFailStub do
  @moduledoc """
  Stub : l'enqueue échoue UNIQUEMENT pour le gatekeeper (le stage s'enqueue
  normalement — StageRunner partage le même seam). Teste le fail-loud de la gate.
  """
  def enqueue("gk-permanent", _attrs), do: {:error, :broker_down}
  def enqueue(_pod_id, _attrs), do: {:ok, %{id: "stage-task"}}
end

defmodule Fleet.Pipeline.GatePendingStageStub do
  @moduledoc "Stub StageSpawner : spawn le pod de stage no-emit (complétion pilotée à la main)."
  @behaviour Fleet.Pipeline.StageSpawner

  @impl Fleet.Pipeline.StageSpawner
  def spawn_stage_pod(_role, _profile, ctx) do
    send(:gate_probe, {:spawned, ctx.stage})
    {:ok, "pod-#{ctx.stage}"}
  end
end

defmodule Fleet.Pipeline.ExecutorGatePendingTest do
  @moduledoc """
  R4/B — state-machine de gate via mandat MCP. Un stage à gate (soft / terminal
  non-tranchable) **enqueue un mandat d'éval au gatekeeper permanent** (adressé
  par `gatekeeper_pod_id`) ; le pipeline reste `:awaiting_gate` jusqu'au
  `task_queue.task_completed` (corrélé par `correlation_id`), puis ré-évalue avec
  le vocab canon `gate-decision-v1.json` (continue → avance ; reste → halt).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline

  setup %{tmp_dir: tmp_dir} do
    Process.register(self(), :gate_probe)

    write_pipeline(tmp_dir, "softgate", soft_gate_yaml())
    write_pipeline(tmp_dir, "termgate", terminal_gate_yaml())

    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)
    # Stage pods : spawn no-emit (la complétion de stage est pilotée à la main).
    Application.put_env(:fleet_pipeline, :spawner_backend, Fleet.Pipeline.GatePendingStageStub)
    # Gatekeeper permanent adressable (booté Type 3 dans la vraie vie ; ici fixe).
    Application.put_env(:fleet_pipeline, :gatekeeper_pod_id, "gk-permanent")
    Application.put_env(:fleet_pipeline, :task_queue, Fleet.Pipeline.GateMandateTaskQueueStub)
    Bus.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Fleet.Pipeline.ExecutorSupervisor) do
        DynamicSupervisor.terminate_child(Fleet.Pipeline.ExecutorSupervisor, pid)
      end

      for k <- [:pipelines_root, :spawner_backend, :gatekeeper_pod_id, :task_queue] do
        Application.delete_env(:fleet_pipeline, k)
      end
    end)

    :ok
  end

  defp write_pipeline(dir, name, yaml), do: File.write!(Path.join(dir, "#{name}.yaml"), yaml)

  defp soft_gate_yaml do
    """
    name: softgate
    version: 1
    stages:
      audit:
        role: scout
        profile: empty
        gate:
          type: soft
    """
  end

  defp terminal_gate_yaml do
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

  # Simule la complétion du mandat d'éval (gatekeeper submit_result → event canon
  # task_queue, corrélé par correlation_id). `result` = la décision JSON.
  defp complete_gate(corr, result) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      timestamp: DateTime.utc_now(),
      correlation_id: corr,
      payload: %{task_id: corr, result: result}
    })
  end

  defp complete_stage(pid, stage) do
    Bus.broadcast("fleet.events", %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      pod_id: "pod-#{stage}",
      payload: %{
        "pod_id" => "pod-#{stage}",
        "result" => %{"ok" => true},
        "pipeline_id" => pid,
        "stage" => stage
      }
    })
  end

  # Démarre + amène le stage `audit` jusqu'à l'enqueue du mandat au gatekeeper.
  defp start_to_gate(name) do
    {:ok, pid} = Pipeline.start_pipeline(name, %{ticket_id: "sg#{name}"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_stage(pid, "audit")
    assert_receive {:enqueued, corr, "gk-permanent", "audit"}, 2_000
    {pid, corr}
  end

  test "gate → mandat enqueué au gatekeeper, pipeline en attente (pas d'avancement)" do
    {pid, _corr} = start_to_gate("softgate")
    refute_receive %Fleet.Event{source: :pipeline, type: :"pipeline.completed"}, 200
    _ = pid
  end

  test "décision continue → pipeline.completed" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "continue", "reason" => "ok"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.completed",
                     payload: %{"pipeline_id" => ^pid}
                   },
                   2_000
  end

  test "décision abandon → pipeline.failed (halt)" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "abandon", "reason" => "not salvageable"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   2_000

    assert reason =~ "abandon"
  end

  test "décision redirect → pipeline.failed, décision portée pour le handoff" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"decision" => "redirect", "reason" => "mandate_too_big_needs_split"})

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   2_000

    assert reason =~ "redirect"
  end

  test "décision malformée (pas de :decision) → halt (fail-closed, jamais continue)" do
    {pid, corr} = start_to_gate("softgate")
    complete_gate(corr, %{"garbage" => true})

    assert_receive %Fleet.Event{source: :pipeline, type: :"pipeline.failed"}, 2_000
    refute_receive %Fleet.Event{type: :"pipeline.completed"}, 100
    _ = pid
  end

  test "terminal non-tranchable → mandat gatekeeper ; continue → completed" do
    {:ok, pid} = Pipeline.start_pipeline("termgate", %{ticket_id: "tg"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_stage(pid, "audit")
    assert_receive {:enqueued, corr, "gk-permanent", "audit"}, 2_000

    complete_gate(corr, %{"decision" => "continue", "reason" => "ok"})

    assert_receive %Fleet.Event{type: :"pipeline.completed", payload: %{"pipeline_id" => ^pid}},
                   2_000
  end

  test "aucun gatekeeper booté (gatekeeper_pod_id nil) → fail-loud (jamais silent pass)" do
    Application.delete_env(:fleet_pipeline, :gatekeeper_pod_id)
    {:ok, pid} = Pipeline.start_pipeline("softgate", %{ticket_id: "nogk"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_stage(pid, "audit")

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   2_000

    assert reason =~ "no gatekeeper"
  end

  test "enqueue du mandat échoue → fail-loud" do
    Application.put_env(:fleet_pipeline, :task_queue, Fleet.Pipeline.GateEnqueueFailStub)
    {:ok, pid} = Pipeline.start_pipeline("softgate", %{ticket_id: "enqfail"})
    assert_receive {:spawned, "audit"}, 2_000
    complete_stage(pid, "audit")

    assert_receive %Fleet.Event{
                     source: :pipeline,
                     type: :"pipeline.failed",
                     payload: %{"pipeline_id" => ^pid, "reason" => reason}
                   },
                   2_000

    assert reason =~ "enqueue failed"
  end
end
