defmodule Fleet.Pilot.StepRunConsumer.VerdictFindingsTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.Verdict

  # C1 2026-08-18 — the OPTIONAL machine payload `details.findings` (findings.json).
  # The contract under test has two load-bearing halves:
  #   1. the gate-decision ENVELOPE never moves — a legacy judge without the key walks
  #      today's path byte-for-byte;
  #   2. the failure DIRECTION is the opposite of the envelope's — an invalid findings
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
    result = envelope(%{"critere" => "ok", "findings" => findings})

    assert {^findings, stripped} = Verdict.take_findings(result)
    assert stripped["details"] == %{"critere" => "ok"}
    assert stripped["decision"] == "continue"
    assert stripped["reason"] == "criterion ok"

    # And the prose body built from the stripped envelope carries NO machine dump: the human
    # matter of the findings lives in `reason` (SP contract), not in an inspect() of a map.
    body = Verdict.judge_review_body(:approve, stripped)
    refute body =~ "findings"
  end

  test "an empty findings list is a legitimate report (nothing to signal, score 10)" do
    findings = %{"findings" => [], "score" => 10}
    result = envelope(%{"findings" => findings})

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
      result = envelope(%{"findings" => bad})

      {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)
      assert {nil, ^result} = took
      # The refusal names the schema on the operator rail — same discipline as the envelope's.
      assert log =~ "findings refused"

      # THE failure direction, pinned: the envelope was already validated, so a broken OPTIONAL
      # payload never turns a valid `continue` into halt_invalid.
      assert "continue" == Verdict.gate_decision(result)
    end
  end

  test "a NEAR-MISS key (findings_v1, Findings) is named in the log, never aliased, never extracted" do
    for key <- ["findings_v1", "Findings", "machine_findings"] do
      result = envelope(%{"critere" => "ok", key => valid_findings()})

      {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)
      # Untouched: the payload stays in the prose (noisy rather than lost), nothing is extracted.
      assert {nil, ^result} = took
      assert log =~ "details.#{key} ignored"
      assert log =~ "the machine payload key is `findings`"
      assert "continue" == Verdict.gate_decision(result)

      # And the builder can tell « sent under the wrong key » from « silent »: the completer
      # then says REFUSED upstream instead of accusing the judge of a silence it did not commit.
      assert Verdict.findings_offered?(result)
    end
  end

  test "findings_offered?/1: exact key (even refused) → true; nothing findings-like → false" do
    assert Verdict.findings_offered?(envelope(%{"findings" => "oops"}))
    refute Verdict.findings_offered?(envelope(%{"critere" => "ok"}))
    refute Verdict.findings_offered?(%{"decision" => "continue", "reason" => "ok"})
    refute Verdict.findings_offered?(%{"decision" => "continue", "details" => "oops"})
  end

  test "both keys present → the exact one is judged, the neighbour is left alone without a warning" do
    result = envelope(%{"findings" => valid_findings(), "findings_v1" => "old"})
    {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)
    assert {findings, stripped} = took
    assert findings == valid_findings()
    assert stripped["details"] == %{"findings_v1" => "old"}
    refute log =~ "ignored"
  end
end
