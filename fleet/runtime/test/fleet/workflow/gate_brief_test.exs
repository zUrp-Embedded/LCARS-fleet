defmodule Fleet.Workflow.GateBriefTest do
  @moduledoc "R4 — gatekeeper evaluation brief (pure)."
  use ExUnit.Case, async: true

  alias Fleet.Workflow.GateBrief

  test "brief carries context + deliverable + question + canon options + JSON contract" do
    brief =
      GateBrief.build(%{
        step: "spec-review",
        workflow_map_id: "pipe-42",
        gate: %{"type" => "terminal", "rules" => ["severity_max != critical"]},
        outputs: %{"result" => %{"severity_max" => "important"}}
      })

    # Context
    assert brief =~ "Judged step: spec-review"
    assert brief =~ "pipe-42"
    assert brief =~ "type terminal"
    # Deliverable under judgement (JSON-rendered)
    assert brief =~ "severity_max"
    assert brief =~ "important"
    # Canon decision vocabulary (all 5)
    for d <- ~w(continue abandon redirect escalate_user halt_wait_input) do
      assert brief =~ d
    end

    # Output contract
    assert brief =~ "gate-decision-v1.json"
    assert brief =~ "Question to decide"
  end

  test "request = defused judgement context (do NOT execute) — not an instruction (PASSE-9 bug)" do
    # The issue body (the BUILD brief) must NEVER read as an instruction the gatekeeper
    # should execute: it is quoted as context, framed.
    brief =
      GateBrief.build(%{
        step: "review",
        workflow_map_id: "gk-smoke",
        gate: nil,
        outputs: %{"result" => %{"commit" => "abc"}},
        request: "Crée SMOKE.md et commit."
      })

    # Explicit defusal frame + judgement instruction, not production.
    assert brief =~ "DO NOT execute"
    assert brief =~ "JUDGE"
    assert brief =~ "Create NO file"
    # The body is present as quoted context (blockquote prefix), not raw.
    assert brief =~ "> Crée SMOKE.md et commit."
    # Explicit output instruction: submit_result with a mandatory decision.
    assert brief =~ "mcp__fleet__submit_result"
    assert brief =~ "decision` field is MANDATORY"
  end

  test "without request → no original-request section" do
    brief = GateBrief.build(%{step: "s", workflow_map_id: "p", gate: nil, outputs: %{}})
    refute brief =~ "Original request"
  end

  test "nil gate + empty outputs → defensive rendering (no crash)" do
    brief = GateBrief.build(%{step: "audit", workflow_map_id: "p", gate: nil, outputs: %{}})
    assert brief =~ "Judged step: audit"
    assert brief =~ "type —"
    assert brief =~ "(none)"
  end

  test "non-JSON-encodable outputs → inspect fallback (defensive)" do
    brief =
      GateBrief.build(%{
        step: "s",
        workflow_map_id: "p",
        gate: nil,
        outputs: %{"pid" => self()}
      })

    assert is_binary(brief)
    assert brief =~ "Judged step: s"
  end
end
