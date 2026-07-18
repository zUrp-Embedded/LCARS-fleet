defmodule Fleet.CoordTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord
  alias Fleet.Decision
  alias Fleet.EventRouter.Bus

  setup do
    Bus.subscribe()
    :ok
  end

  describe "delegator API" do
    test "handle_decision/2 delegated to Policies" do
      decision = %Decision{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert :ok = Coord.handle_decision(decision, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.notification_routed"
                     },
                     500
    end

    test "handle_escalation/3 delegated to Policies" do
      assert :ok = Coord.handle_escalation(:pod_drift, %{"pod_id" => "p1"}, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.escalation_triggered"
                     },
                     500
    end
  end
end
