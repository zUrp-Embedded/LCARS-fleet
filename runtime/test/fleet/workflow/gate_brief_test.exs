defmodule Fleet.Workflow.GateBriefTest do
  @moduledoc "R4 — rendering assertions against catalogue gatekeeper templates."
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

    assert brief =~ "Judged step: spec-review"
    assert brief =~ "pipe-42"
    assert brief =~ "type terminal"
    assert brief =~ "severity_max"
    assert brief =~ "important"

    for d <- ~w(continue abandon redirect escalate_user halt_wait_input) do
      assert brief =~ d
    end

    assert brief =~ "gate-decision.json"
    assert brief =~ "Question to decide"
  end

  test "request = defused judgement context (do NOT execute) — not an instruction (PASSE-9 bug)" do
    # Tests framing and quotation strings, not whether an agent follows them.
    brief =
      GateBrief.build(%{
        step: "review",
        workflow_map_id: "gk-smoke",
        gate: nil,
        outputs: %{"result" => %{"commit" => "abc"}},
        request: "Crée SMOKE.md et commit."
      })

    assert brief =~ "DO NOT execute"
    assert brief =~ "JUDGE"
    assert brief =~ "Create NO file"
    assert brief =~ "> Crée SMOKE.md et commit."
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

  test "subject :brief MOUNTED → the order names the mounted file, no text, no pin" do
    brief =
      GateBrief.build(%{
        step: "brief-review",
        workflow_map_id: "brief-gate",
        gate: nil,
        subject: :brief,
        outputs: %{"brief_mount" => "brief.md"}
      })

    # transport_brief_v2: assert the rendered mount address, without mounting/reading a real file.
    assert brief =~ "~/issues/brief.md"

    # These two literals are absent from the input too; this does not reject every possible citation.
    refute brief =~ "briefs/issue-5-engineer.md"
    refute brief =~ "0627de8abc"

    # The order must not require an ops mount and manual git read.
    refute brief =~ "LCARS_PROJECT_OPS"
    refute brief =~ "git -C"
  end

  test "subject :brief INLINE (degraded, no authored doc) → embedded blockquote as before" do
    brief =
      GateBrief.build(%{
        step: "brief-review",
        workflow_map_id: "brief-gate",
        gate: nil,
        subject: :brief,
        outputs: %{"brief" => "contenu inline du brief dégradé"}
      })

    assert brief =~ "> contenu inline du brief dégradé"
  end
end
