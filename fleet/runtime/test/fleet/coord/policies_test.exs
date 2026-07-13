defmodule Fleet.Coord.PoliciesTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord.Policies
  alias Fleet.Decision
  alias Fleet.EventRouter.Bus

  setup do
    Bus.subscribe()
    :ok
  end

  describe "handle_decision/2" do
    test "halt + gatekeeper.refuse → notify_dashboard canon broadcast" do
      decision = %Decision{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

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

    test "decision sans match dans table → {:error, {:no_policy_match, {decision, reason}}}" do
      decision = %Decision{decision: "allow", reason: "unknown", details: %{}, chain: []}

      # Tuple STRUCTURÉ (D1) : le consommateur peut pattern-matcher le miss ET récupérer la
      # clé de lookup fautive — l'ancienne string "no policy match for …" ne le permettait pas.
      assert {:error, {:no_policy_match, {"allow", "unknown"}}} =
               Policies.handle_decision(decision, nil)
    end

    test "map brute (pas un %Decision{}) → {:error, {:invalid_decision, _}} (frontière refuse le non-validé)" do
      # BND-002 : la frontière n'accepte QUE le verdict validé `%Fleet.Decision{}`. Une map à 2 clés
      # (schema Starfleet court-circuité) est REFUSÉE, typée — jamais routée comme un verdict.
      raw = %{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert {:error, {:invalid_decision, ^raw}} = Policies.handle_decision(raw, nil)
    end

    test "escalate + audit_verdict → notify_dashboard (dernier maillon du producteur draft Q2 audit.verdict)" do
      # Le producteur draft `StepRunConsumer.emit_audit_verdict_draft` émet EXACTEMENT ce decision_json
      # (decision "escalate", reason "audit_verdict") ; DriftMonitor le route vers handle_decision → clé
      # "escalate.audit_verdict" (coord-policies.yaml). Ce test verrouille que la chaîne blink jusqu'à coord.
      decision = %Decision{
        decision: "escalate",
        reason: "audit_verdict",
        details: %{"verdict" => "halt_wait_input", "issue" => 42},
        chain: ["pilot.step_run_consumer.apply_verdict"]
      }

      assert :ok = Policies.handle_decision(decision, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.notification_routed",
                       payload: %{"target" => "dashboard"}
                     },
                     500
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

    test "source inconnu → {:error, {:no_escalation_policy, source}}" do
      # Tuple STRUCTURÉ (D1) — source normalisée en string (la clé de lookup).
      assert {:error, {:no_escalation_policy, "totally_unknown"}} =
               Policies.handle_escalation(:totally_unknown, %{}, nil)
    end
  end
end
