defmodule Fleet.Coord.PoliciesTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord.Policies
  alias Fleet.EventRouter.Bus

  setup do
    Bus.subscribe()
    :ok
  end

  describe "handle_decision/2" do
    test "halt + gatekeeper.refuse → notify_dashboard canon broadcast" do
      decision = %{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert :ok = Policies.handle_decision(decision, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.notification_routed",
                       payload: %{
                         "target" => "dashboard",
                         "path" => ["dashboard", "issue_comment"],
                         "message" => message
                       }
                     },
                     500

      assert message[:decision] == "halt" or message["decision"] == "halt"
    end

    test "decision sans match dans table → {:error, _}" do
      decision = %{decision: "allow", reason: "unknown", details: %{}, chain: []}

      assert {:error, msg} = Policies.handle_decision(decision, nil)
      assert msg =~ "no policy match"
    end
  end

  describe "handle_escalation/3" do
    test "pod_drift → escalate_human canon broadcast" do
      assert :ok = Policies.handle_escalation(:pod_drift, %{"pod_id" => "p1"}, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.escalation_triggered",
                       payload: %{
                         "target" => "operator",
                         "path" => ["dashboard", "starfleet_alert"],
                         "message" => %{"pod_id" => "p1"}
                       }
                     },
                     500
    end

    test "workflow_map_failed → notify_dashboard canon broadcast" do
      assert :ok =
               Policies.handle_escalation(
                 :workflow_map_failed,
                 %{"workflow_map_id" => "pl1"},
                 nil
               )

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.notification_routed",
                       payload: %{"message" => %{"workflow_map_id" => "pl1"}}
                     },
                     500
    end

    test "oauth_refresh_failed → escalate_human starfleet_alert" do
      assert :ok =
               Policies.handle_escalation(:oauth_refresh_failed, %{"account" => "u@x.com"}, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.escalation_triggered",
                       payload: %{"path" => ["starfleet_alert"]}
                     },
                     500
    end

    test "source binaire (string) accepté" do
      assert :ok = Policies.handle_escalation("pod_drift", %{"pod_id" => "p2"}, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.escalation_triggered"
                     },
                     500
    end

    test "source inconnu → {:error, _}" do
      assert {:error, msg} = Policies.handle_escalation(:totally_unknown, %{}, nil)
      assert msg =~ "no escalation policy"
    end
  end
end
