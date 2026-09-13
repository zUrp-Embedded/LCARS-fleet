defmodule Fleet.Pilot.StepRunConsumer.VerdictFindingsTest do
  use ExUnit.Case, async: true

  require Logger

  alias Fleet.Pilot.StepRunConsumer.Verdict

  # Optional findings failure preserves the decision while refusing its machine payload.

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

    # Findings extraction does not validate the decision envelope.
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

    # Valid machine findings leave prose details; this does not verify their substance is in reason.
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
      %{"findings" => "oops"},
      # Unknown severity must fail schema validation.
      %{"findings" => [%{"severity" => "blocker", "description" => "x"}]},
      %{"findings" => [%{"severity" => "minor"}]},
      %{"findings" => [], "score" => 11},
      %{"score" => 5}
    ]

    for bad <- invalid do
      result = envelope(%{"findings" => bad})

      {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)
      assert {nil, ^result} = took

      assert log =~ "findings refused"

      # Independently validate that the containing envelope still yields continue.
      assert "continue" == Verdict.gate_decision(result)
    end
  end

  test "a NEAR-MISS key (findings_v1, Findings) is named in the log, never aliased, never extracted" do
    for key <- ["findings_v1", "Findings", "machine_findings"] do
      result = envelope(%{"critere" => "ok", key => valid_findings()})

      {took, log} = ExUnit.CaptureLog.with_log(fn -> Verdict.take_findings(result) end)

      assert {nil, ^result} = took
      assert log =~ "details.#{key} ignored"
      assert log =~ "the machine payload key is `findings`"
      assert "continue" == Verdict.gate_decision(result)

      # Near-miss keys count as offered so diagnostics distinguish refusal from silence.
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
    # capture_log observes global logs; anchor the negative assertion to the emitter/shape
    # rather than the generic word ignored, which concurrent modules can also emit.
    refute log =~ ~r/StepRunConsumer: details\.\S+ ignored/
  end

  # A synthetic neighbor line tests the regex's discrimination, not a replay of the original race.
  test "l'aiguille du refute ne peut venir que du sujet — la ligne d'un voisin ne la declenche pas" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Logger.warning(
          "Fleet.SystemConfig: /x carries unknown key(s) [\"conflict_engin\"] — ignored."
        )
      end)

    assert log =~ "ignored"

    refute log =~ ~r/StepRunConsumer: details\.\S+ ignored/
  end
end
