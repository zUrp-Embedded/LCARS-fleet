defmodule Fleet.Spawner.Pod.EventsTest do
  @moduledoc """
  Acte3 vague E (traçabilité) : les events de cycle-de-vie du pod portent `correlation_id = issue_id`
  (la clé end-to-end spawn→work→complete→review→merge). AVANT : tout le rail spawner émettait
  correlation_id=nil → aucun incident n'était tie-able au mandat qui l'a causé (rupture à la frontière).
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.Events

  setup do
    :ok = Fleet.EventRouter.Bus.subscribe()
    on_exit(fn -> Fleet.EventRouter.Bus.unsubscribe() end)
    :ok
  end

  describe "lossy_broadcast/2 (pod.failed / wake.failed)" do
    test "corrèle par issue_id" do
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

    test "issue_id absent → correlation_id nil (pas de crash, pod hors-projet)" do
      Events.lossy_broadcast("pod.failed", %{"pod_id" => "pod-y", "reason" => "boom"})

      assert_receive %Fleet.Event{type: :"pod.failed", correlation_id: nil}
    end
  end

  describe "required_broadcast/2 (pod.completed)" do
    test "corrèle par issue_id" do
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
