defmodule Fleet.Pilot.StepRunConsumer.VerdictFindingsTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.Verdict

  # C1 2026-08-18 — the OPTIONAL machine payload `details.findings_v1` (findings-v1.json).
  # The contract under test has two load-bearing halves:
  #   1. the gate-decision-v1 ENVELOPE never moves — a legacy judge without the key walks
  #      today's path byte-for-byte;
  #   2. the failure DIRECTION is the opposite of the envelope's — an invalid findings_v1
  #      never flips a valid verdict (loud log + no machine object, never halt_invalid).

  defp envelope(details) do
    %{"decision" => "continue", "reason" => "criterion ok", "details" => details}
  end

  defp valid_findings do
    %{
      "verdict" => "partial",
      "score" => 7,
      "severity_max" => "important",
      "summary" => "one important divergence",
      "findings" => [
        %{
          "severity" => "important",
          "category" => "divergent",
          "description" => "the seam ignores its base_sha",
          "refs" => ["lib/demo.ex:42"],
          "task_id" => "3"
        }
      ]
    }
  end

  test "absent → {nil, result} UNTOUCHED: the legacy judge is the nominal case, not a fallback" do
    result = envelope(%{"critere" => "ok"})
    assert {nil, ^result} = Verdict.take_findings(result)

    no_details = %{"decision" => "continue", "reason" => "ok"}
    assert {nil, ^no_details} = Verdict.take_findings(no_details)

    # A garbage `details` (envelope-invalid elsewhere) does not crash the extraction either —
    # gate_decision/1 already owns THAT refusal; this function only answers "is the key here".
    garbage = %{"decision" => "continue", "reason" => "ok", "details" => "oops"}
    assert {nil, ^garbage} = Verdict.take_findings(garbage)
  end

  test "valid → {findings, stripped}: the key leaves `details`, the rest of the envelope does not move" do
    findings = valid_findings()
    result = envelope(%{"critere" => "ok", "findings_v1" => findings})

    assert {^findings, stripped} = Verdict.take_findings(result)
    assert stripped["details"] == %{"critere" => "ok"}
    assert stripped["decision"] == "continue"
    assert stripped["reason"] == "criterion ok"

    # And the prose body built from the stripped envelope carries NO machine dump: the human
    # matter of the findings lives in `reason` (SP contract), not in an inspect() of a map.
    body = Verdict.judge_review_body(:approve, stripped)
    refute body =~ "findings_v1"
  end

  test "an empty findings list is a legitimate report (nothing to signal, score 10)" do
    findings = %{"findings" => [], "score" => 10}
    result = envelope(%{"findings_v1" => findings})

    assert {^findings, stripped} = Verdict.take_findings(result)
    assert stripped["details"] == %{}
  end

  test "invalid → {nil, result} UNTOUCHED + loud log; gate_decision still crosses (the verdict NEVER flips)" do
    invalid = [
      # not a list
      %{"findings" => "oops"},
      # a third vocabulary — the schema reconciles two, it does not accept inventions
      %{"findings" => [%{"severity" => "blocker", "description" => "x"}]},
      # description missing on an item
      %{"findings" => [%{"severity" => "minor"}]},
      # off the 0-10 grid
      %{"findings" => [], "score" => 11},
      # the one required top-level field, absent
      %{"score" => 5}
    ]

    for bad <- invalid do
      result = envelope(%{"findings_v1" => bad})

      {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)
      assert {nil, ^result} = took
      # The refusal names the schema on the operator rail — same discipline as the envelope's.
      assert log =~ "findings_v1 refused"

      # THE failure direction, pinned: the envelope was already validated, so a broken OPTIONAL
      # payload never turns a valid `continue` into halt_invalid.
      assert "continue" == Verdict.gate_decision(result)
    end
  end
end
