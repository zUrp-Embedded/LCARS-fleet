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

  test "subject :brief with a SOURCE pointer → the brief is POINTED, never re-embedded (dedup)" do
    # User 2026-07-19: gate-briefs/issue-N-consultant.md duplicated briefs/<slug>.md verbatim.
    # The pointer path renders ref + pinned sha + the RO-mount read instruction — no copy.
    brief =
      Fleet.Workflow.GateBrief.build(%{
        step: "brief-review",
        workflow_map_id: "brief-gate",
        gate: nil,
        subject: :brief,
        outputs: %{"brief_ref" => "briefs/issue-5-engineer.md", "brief_sha" => "0627de8abc"}
      })

    assert brief =~ "briefs/issue-5-engineer.md"
    assert brief =~ "0627de8abc"

    # ONE address, and it is the PIN. The judge used to be given the working-tree path first, with
    # `git show` offered only "if the file changed since the pin" — a condition that requires its
    # own answer: knowing whether it changed means already holding the pinned version. And the path
    # is not a fallback: `LCARS_PROJECT_OPS` is a live `--ro-bind` of the worktree the project
    # architect holds in RW at the same path, so it moves under the judge mid-session.
    assert brief =~ "git -C $LCARS_PROJECT_OPS show 0627de8abc:briefs/issue-5-engineer.md"
    refute brief =~ "$LCARS_PROJECT_OPS/briefs/issue-5-engineer.md"

    # No embedded blockquote of a brief body: the pointer instruction replaces the copy.
    refute brief =~ "> "
  end

  test "subject :brief INLINE (degraded, no authored doc) → embedded blockquote as before" do
    brief =
      Fleet.Workflow.GateBrief.build(%{
        step: "brief-review",
        workflow_map_id: "brief-gate",
        gate: nil,
        subject: :brief,
        outputs: %{"brief" => "contenu inline du brief dégradé"}
      })

    assert brief =~ "> contenu inline du brief dégradé"
  end
end
