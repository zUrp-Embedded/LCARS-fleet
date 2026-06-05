defmodule Fleet.Pipeline.GateBriefTest do
  @moduledoc "R4 sous-lot D — brief d'éval gatekeeper (pur)."
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.GateBrief

  test "brief porte contexte + livrable + question + options canon + contrat JSON" do
    brief =
      GateBrief.build(%{
        stage: "spec-review",
        pipeline_id: "pipe-42",
        gate: %{"type" => "terminal", "rules" => ["severity_max != critical"]},
        outputs: %{"result" => %{"severity_max" => "important"}}
      })

    # Contexte
    assert brief =~ "Stage : spec-review"
    assert brief =~ "pipe-42"
    assert brief =~ "type terminal"
    # Livrable à juger (rendu JSON)
    assert brief =~ "severity_max"
    assert brief =~ "important"
    # Vocabulaire de décision canon (les 5)
    for d <- ~w(continue abandon redirect escalate_user halt_wait_input) do
      assert brief =~ d
    end

    # Contrat de sortie
    assert brief =~ "gate-decision-v1.json"
    assert brief =~ "Question à trancher"
  end

  test "gate nil + outputs vides → rendu défensif (pas de crash)" do
    brief = GateBrief.build(%{stage: "audit", pipeline_id: "p", gate: nil, outputs: %{}})
    assert brief =~ "Stage : audit"
    assert brief =~ "type —"
    assert brief =~ "(aucun)"
  end

  test "outputs non-JSON-encodable → fallback inspect (défensif)" do
    brief =
      GateBrief.build(%{
        stage: "s",
        pipeline_id: "p",
        gate: nil,
        outputs: %{"pid" => self()}
      })

    assert is_binary(brief)
    assert brief =~ "Stage : s"
  end
end
