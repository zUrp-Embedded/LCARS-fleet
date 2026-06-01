defmodule Fleet.MCP.ResultEventTest do
  @moduledoc """
  Completion event-driven (ADR-G) — sur `submit_result`, le **broker** `fleet_task_queue`
  broadcast `%Fleet.Event{source: :task_queue, type: :task_completed}` sur `fleet.events`.

  `pod.ex` (Ring 1) y souscrit pour déclencher sa complétion SANS lire fleet_mcp (Ring 4)
  en direct. Ici on prouve l'émission via le tool `submit_result` (PUR, pas de claude).
  `fleet_mcp` n'émet plus le string-topic `pod.result_submitted` — c'est le broker qui possède l'event.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  test "submit_result → broker broadcast %Fleet.Event{task_completed} (pod_id + correlation_id)" do
    pod = "pod-evt-#{System.unique_integer([:positive])}"
    {:ok, task} = TaskQueue.enqueue(pod, %{brief: "x"})
    tid = task.id
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")

    payload = %{"answer" => "42", "nonce" => "evt-#{System.unique_integer([:positive])}"}

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => payload, "_lcars_pod_id" => pod},
               %{}
             )

    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_completed,
                     pod_id: ^pod,
                     correlation_id: ^tid,
                     payload: %{result: ^payload}
                   },
                   2_000
  end

  test "submit_result sans _lcars_pod_id → erreur (pas de broadcast)" do
    Phoenix.PubSub.subscribe(Fleet.PubSub, "fleet.events")
    payload = %{"answer" => "anon-#{System.unique_integer([:positive])}"}

    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => payload}, %{})

    refute_receive %Fleet.Event{source: :task_queue, type: :task_completed}, 200
  end
end
