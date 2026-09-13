defmodule Fleet.MCP.ResultEventTest do
  @moduledoc """
  Direct submit_result calls through PodTools must broadcast TaskQueue completion
  with pod identity, correlation and business payload. Spawner consumes that event
  without calling MCP; its handling and socket authentication are outside these tests.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  defp pod_state(pod), do: %{pod_id: pod}

  test "submit_result → broker broadcasts %Fleet.Event{work_item.completed} (pod_id + correlation_id)" do
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    # The pull is not decoration: a mandate is not closable before it is read, and a pod cannot
    # know the id without pulling anyway. Skipping it here modelled a call no pod makes.
    {:ok, _} = TaskQueue.get_for_pod(pod)
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    payload = %{"answer" => "42", "nonce" => "evt-#{System.unique_integer([:positive])}"}

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => payload, "work_item_id" => tid},
               pod_state(pod)
             )

    # The broadcast deliverable = the EXACT business `payload` (the work_item_id, a transport
    # correlator, is removed from the result stored by the broker → no deliverable pollution).
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :"work_item.completed",
                     pod_id: ^pod,
                     correlation_id: ^tid,
                     payload: %{result: ^payload}
                   },
                   2_000
  end

  test "submit_result without pod_id in the state → error (no broadcast)" do
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
    payload = %{"answer" => "anon-#{System.unique_integer([:positive])}"}

    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => payload}, %{})

    refute_receive %Fleet.Event{source: :task_queue, type: :"work_item.completed"}, 200
  end

  test "submit_result with work_item_id NESTED in the payload (not top-level) → accepted + closes the brief" do
    # Judges can place the correlator inside payload; accepting this shape prevents
    # repeated refusals from stalling completion. PodTools still requires an explicit id.
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    # The pull is not decoration: a mandate is not closable before it is read, and a pod cannot
    # know the id without pulling anyway. Skipping it here modelled a call no pod makes.
    {:ok, _} = TaskQueue.get_for_pod(pod)
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    # work_item_id ABSENT from the top level, present INSIDE the payload — the exact shape produced by
    # the judge in e2e.
    verdict = %{"decision" => "continue", "reason" => "ok", "work_item_id" => tid}

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => verdict},
               pod_state(pod)
             )

    # The transport correlator is removed from the STORED deliverable, even when nested in the payload
    # (no pollution).
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :"work_item.completed",
                     pod_id: ^pod,
                     correlation_id: ^tid,
                     payload: %{result: result}
                   },
                   2_000

    assert result == %{"decision" => "continue", "reason" => "ok"}
  end

  test "submit_result with work_item_id NEITHER top-level NOR in the payload → :work_item_id_required (guard held)" do
    # Placement tolerance must not fall back to the pod's latest active item.
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, _task} = TaskQueue.enqueue(pod, %{brief: "x"})
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    assert {:error, :work_item_id_required, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"decision" => "continue"}},
               pod_state(pod)
             )

    refute_receive %Fleet.Event{source: :task_queue, type: :"work_item.completed"}, 200
  end
end
