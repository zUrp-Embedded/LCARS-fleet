defmodule Fleet.Spawner.Pod.EventsTest do
  @moduledoc """
  Traceability: pod lifecycle events carry `correlation_id = issue_id` (the end-to-end key
  spawn→work→complete→review→merge). Without it the whole spawner rail emits
  correlation_id=nil → no incident can be tied to the mandate that caused it (break at the
  boundary).
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.Events

  setup do
    :ok = Fleet.EventRouter.Bus.subscribe()
    on_exit(fn -> Fleet.EventRouter.Bus.unsubscribe() end)
    :ok
  end

  describe "lossy_broadcast/2 (pod.failed / wake.failed)" do
    test "correlates by issue_id" do
      Events.lossy_broadcast("pod.failed", %{
        "pod_id" => "pod-x",
        "issue_id" => "fleet/repo#42",
        "reason" => "boom"
      })

      assert_receive %Fleet.Event{
        source: :spawner,
        type: :"pod.failed",
        pod_id: "pod-x",
        correlation_id: "fleet/repo#42"
      }
    end

    test "absent issue_id → nil correlation_id (no crash, off-project pod)" do
      Events.lossy_broadcast("pod.failed", %{"pod_id" => "pod-y", "reason" => "boom"})

      assert_receive %Fleet.Event{type: :"pod.failed", correlation_id: nil}
    end
  end

  describe "required_broadcast/2 (pod.completed)" do
    test "correlates by issue_id" do
      assert :ok =
               Events.required_broadcast("pod.completed", %{
                 "pod_id" => "pod-z",
                 "issue_id" => "fleet/repo#7",
                 "result" => %{}
               })

      assert_receive %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        correlation_id: "fleet/repo#7"
      }
    end
  end
end
