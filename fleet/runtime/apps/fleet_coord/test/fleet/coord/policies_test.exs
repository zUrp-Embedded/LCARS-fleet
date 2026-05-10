defmodule Fleet.Coord.PoliciesTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord.Policies
  alias Fleet.EventRouter.Bus

  setup do
    Bus.subscribe()
    :ok
  end

  describe "handle_decision/1" do
    test "halt + gatekeeper.refuse → notify_dashboard broadcast" do
      decision = %{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert :ok = Policies.handle_decision(decision)

      assert_receive {_atom,
                      %{
                        "event_type" => "coord.notify.dashboard",
                        "payload" => %{
                          "path" => ["dashboard", "ticket_comment"],
                          "payload" => payload
                        }
                      }},
                     500

      assert payload[:decision] == "halt" or payload["decision"] == "halt"
    end

    test "decision sans match dans table → {:error, _}" do
      decision = %{decision: "allow", reason: "unknown", details: %{}, chain: []}

      assert {:error, msg} = Policies.handle_decision(decision)
      assert msg =~ "no policy match"
    end
  end

  describe "handle_escalation/2" do
    test "pod_drift → escalate_human broadcast" do
      assert :ok = Policies.handle_escalation(:pod_drift, %{"pod_id" => "p1"})

      assert_receive {_atom,
                      %{
                        "event_type" => "coord.escalate.human",
                        "payload" => %{
                          "path" => ["dashboard", "starfleet_alert"],
                          "payload" => %{"pod_id" => "p1"}
                        }
                      }},
                     500
    end

    test "pipeline_failed → notify_dashboard broadcast" do
      assert :ok = Policies.handle_escalation(:pipeline_failed, %{"pipeline_id" => "pl1"})

      assert_receive {_atom,
                      %{
                        "event_type" => "coord.notify.dashboard",
                        "payload" => %{"payload" => %{"pipeline_id" => "pl1"}}
                      }},
                     500
    end

    test "oauth_refresh_failed → escalate_human sysadmin_alert" do
      assert :ok = Policies.handle_escalation(:oauth_refresh_failed, %{"account" => "u@x.com"})

      assert_receive {_atom,
                      %{
                        "event_type" => "coord.escalate.human",
                        "payload" => %{"path" => ["sysadmin_alert"]}
                      }},
                     500
    end

    test "source binaire (string) accepté" do
      assert :ok = Policies.handle_escalation("pod_drift", %{"pod_id" => "p2"})

      assert_receive {_atom, %{"event_type" => "coord.escalate.human"}},
                     500
    end

    test "source inconnu → {:error, _}" do
      assert {:error, msg} = Policies.handle_escalation(:totally_unknown, %{})
      assert msg =~ "no escalation policy"
    end
  end
end
