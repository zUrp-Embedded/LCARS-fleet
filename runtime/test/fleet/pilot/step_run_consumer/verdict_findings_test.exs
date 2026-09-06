defmodule Fleet.Pilot.StepRunConsumer.VerdictFindingsTest do
  use ExUnit.Case, async: true

  require Logger

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
    # ⚠ L'AIGUILLE EST ANCREE SUR L'EMETTEUR, ET C'EST LA CORRECTION. `capture_log` capte le
    # logger GLOBAL : sous `async: true`, tout module qui logge pendant cette fenetre atterrit dans
    # `log`. Le mot « ignored » seul est emis par 21 modules de `lib/` (mesure du 2026-09-06), et
    # ce temoin est tombe sur la ligne d'un voisin — `Fleet.SystemConfig: … carries unknown key(s)
    # … — ignored.` Un refute ne vaut que si son aiguille ne peut venir que du sujet.
    refute log =~ ~r/StepRunConsumer: details\.\S+ ignored/
  end

  # CE TEMOIN PROUVE L'ANCRAGE, PAS LE SUJET — et il existe parce que la course, elle, ne se rejoue
  # pas a la demande. Le refute ci-dessus a ete pris en flagrant delit dans un `mix gate` complet
  # (drdree, 2026-09-06) sur la ligne d'un VOISIN, reproduite ici mot pour mot. Sept passages de la
  # suite sur ma machine, dont trois a `--max-cases 24` sur le code d'AVANT, ne l'ont jamais
  # redeclenchee : une fenetre de quelques microsecondes ne s'invoque pas, elle se ferme.
  #
  # Ce qui se prouve donc ici est la PROPRIETE qui la ferme : l'aiguille ne peut venir que du sujet.
  test "l'aiguille du refute ne peut venir que du sujet — la ligne d'un voisin ne la declenche pas" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Logger.warning(
          "Fleet.SystemConfig: /x carries unknown key(s) [\"conflict_engin\"] — ignored."
        )
      end)

    # Le mot nu EST dans la capture : `capture_log` capte le logger global, et c'est exactement ce
    # qui faisait tomber un refute qui cherchait ce mot-la.
    assert log =~ "ignored"

    # L'aiguille ancree sur l'emetteur et sur la forme ne voit que ce que `Verdict` emet.
    refute log =~ ~r/StepRunConsumer: details\.\S+ ignored/
  end
end
