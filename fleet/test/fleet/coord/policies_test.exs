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
    test "halt + gatekeeper.refuse → canonical notify_dashboard broadcast" do
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

    test "decision without table match → {:error, {:no_policy_match, {decision, reason}}}" do
      decision = %Decision{decision: "allow", reason: "unknown", details: %{}, chain: []}

      # STRUCTURED tuple (D1): the consumer can pattern-match the miss AND recover the
      # faulty lookup key — a bare "no policy match for …" string would not allow it.
      assert {:error, {:no_policy_match, {"allow", "unknown"}}} =
               Policies.handle_decision(decision, nil)
    end

    test "raw map (not a %Decision{}) → {:error, {:invalid_decision, _}} (boundary refuses the unvalidated)" do
      # BND-002: the boundary ONLY accepts the validated verdict `%Fleet.Decision{}`. A 2-key map
      # (Starfleet schema bypassed) is REFUSED, typed — never routed as a verdict.
      raw = %{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert {:error, {:invalid_decision, ^raw}} = Policies.handle_decision(raw, nil)
    end

    test "escalate + audit_verdict → notify_dashboard (last link of the Q2 audit.verdict draft producer)" do
      # The draft producer `StepRunConsumer.emit_audit_verdict_draft` emits EXACTLY this decision_json
      # (decision "escalate", reason "audit_verdict"); DriftMonitor routes it to handle_decision → key
      # "escalate.audit_verdict" (coord-policies.yaml). This test locks that the chain blinks all the way to coord.
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
    test "pod_drift → canonical escalate_human broadcast" do
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

    test "workflow_map_failed → canonical notify_dashboard broadcast" do
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

    test "binary source (string) accepted" do
      assert :ok = Policies.handle_escalation("pod_drift", %{"pod_id" => "p2"}, nil)

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.escalation_triggered"
                     },
                     500
    end

    test "unknown source → {:error, {:no_escalation_policy, source}}" do
      # STRUCTURED tuple (D1) — source normalized as string (the lookup key).
      assert {:error, {:no_escalation_policy, "totally_unknown"}} =
               Policies.handle_escalation(:totally_unknown, %{}, nil)
    end
  end

  describe "open action dispatch (no action/target registry — extensible without recompile)" do
    test "a non-standard action dispatches generically as coord.action_dispatched, never a load/validation error" do
      # The schema is structural-only and NOTHING validates action names (by design): a custom/typo'd
      # action is not rejected — it dispatches as the generic coord.action_dispatched (action in the
      # payload). This backs the corrected contract wording (no false "handlers verified at runtime").
      assert :ok =
               Fleet.Coord.Emitter.dispatch_action(
                 "some_unregistered_custom_action",
                 ["dashboard", "operator"],
                 %{"decision" => "x", "reason" => "y"},
                 "corr-1"
               )

      assert_receive %Fleet.Event{
                       source: :coord,
                       type: :"coord.action_dispatched",
                       correlation_id: "corr-1",
                       payload: %{"action" => "some_unregistered_custom_action"}
                     },
                     500
    end
  end
end
