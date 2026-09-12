defmodule Fleet.Forge.JuryVerdictFunctionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.FindingsWire
  alias Fleet.Forge.Client.Jury

  @jury ["qualifier", "reviewer"]

  defp f(severities) when is_list(severities),
    do: %{"findings" => Enum.map(severities, &%{"severity" => &1, "category" => "tests"})}

  # C3 distingue la zone grise (jury approuve, politique bloque) d'un refus de juge.
  # Ces tests portent sur le verdict pur, pas le routage ni la convocation du gatekeeper.
  describe "C2/C3 — la carte peut refuser ce qu'un juge a approuvé (zone grise)" do
    test "un finding AU-DESSUS du plancher refuse une PR pourtant approuvée" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => f(["critical"])}

      assert :gray_zone =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "critical"})
    end

    test "un finding SOUS le plancher laisse passer" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => f(["minor", "important"])}

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "critical"})
    end

    test "l'échelle est ordonnée : `block_at: minor` refuse le moindre finding mesuré" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"reviewer" => f(["minor"])}

      assert :gray_zone =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "minor"})

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "important"})
    end

    test "les findings d'un relecteur HORS jury ne relèvent pas la barre" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"un-humain" => f(["critical"])}

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "minor"})
    end

    test "une sévérité inconnue ne bloque pas — on n'invente pas un refus depuis du hors-schéma" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => f(["catastrophique", "MINOR", ""])}

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "minor"})
    end

    test "un payload sans finding, ou de forme inattendue, ne prouve aucun défaut" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      policy = %{"block_at" => "minor"}

      for payload <- [%{"findings" => []}, %{}, %{"findings" => "pas une liste"}, nil] do
        assert :approved =
                 Jury.review_outcome(@jury, verdicts, %{"qualifier" => payload}, policy)
      end
    end
  end

  describe "LE PLANCHER — une carte n'annule jamais le refus d'un juge" do
    test "un REQUEST_CHANGES reste bloquant, quelle que soit la courbe" do
      # Une politique ne peut lever un refus deja rendu par le jury complet.
      verdicts = %{"qualifier" => :changes_requested, "reviewer" => :approved}

      for policy <- [nil, %{"block_at" => "critical"}, %{"block_at" => "minor"}, %{}] do
        assert :changes_requested = Jury.review_outcome(@jury, verdicts, %{}, policy)
      end
    end

    property "AUCUNE politique ne peut promouvoir ce que le ET booléen bloquait" do
      check all(
              verdicts <-
                StreamData.fixed_map(%{
                  "qualifier" => StreamData.member_of([:approved, :changes_requested]),
                  "reviewer" => StreamData.member_of([:approved, :changes_requested])
                }),
              block_at <- StreamData.member_of(FindingsWire.severities()),
              sev <- StreamData.list_of(StreamData.member_of(FindingsWire.severities()))
            ) do
        base = Jury.review_outcome(@jury, verdicts)

        with_policy =
          Jury.review_outcome(@jury, verdicts, %{"qualifier" => f(sev)}, %{"block_at" => block_at})

        if base == :changes_requested do
          assert with_policy == :changes_requested,
                 "une carte a promu une PR qu'un juge refusait — le plancher a cédé"
        end

        assert with_policy in [:approved, :changes_requested, :gray_zone]
      end
    end
  end

  describe "C3 — l'arbitre tranche la zone grise, et RIEN D'AUTRE" do
    @arbiter "gatekeeper"

    setup do
      %{
        verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
        findings: %{"qualifier" => f(["critical"])},
        policy: %{"block_at" => "critical"}
      }
    end

    test "sans arbitre nommé : zone grise", ctx do
      assert :gray_zone =
               Jury.review_outcome(@jury, ctx.verdicts, ctx.findings, ctx.policy, nil)
    end

    test "arbitre nommé mais qui n'a pas encore voté : zone grise", ctx do
      assert :gray_zone =
               Jury.review_outcome(@jury, ctx.verdicts, ctx.findings, ctx.policy, @arbiter)
    end

    test "l'arbitre approuve → la PR passe MALGRÉ la courbe", ctx do
      verdicts = Map.put(ctx.verdicts, @arbiter, :approved)

      assert :approved =
               Jury.review_outcome(@jury, verdicts, ctx.findings, ctx.policy, @arbiter)
    end

    test "l'arbitre refuse → rework, la contradiction est tranchée dans l'autre sens", ctx do
      verdicts = Map.put(ctx.verdicts, @arbiter, :changes_requested)

      assert :changes_requested =
               Jury.review_outcome(@jury, verdicts, ctx.findings, ctx.policy, @arbiter)
    end

    test "HORS zone grise, la voix de l'arbitre n'est pas lue — F-C061 tient", ctx do
      # L'arbitre hors jury ne rajoute pas un veto quand la politique ne bloque pas.
      assert :approved =
               Jury.review_outcome(
                 @jury,
                 Map.put(ctx.verdicts, @arbiter, :changes_requested),
                 %{},
                 nil,
                 @arbiter
               )

      # Son approbation ne leve pas le refus d'un jure.
      assert :changes_requested =
               Jury.review_outcome(
                 @jury,
                 %{
                   "qualifier" => :changes_requested,
                   "reviewer" => :approved,
                   @arbiter => :approved
                 },
                 ctx.findings,
                 ctx.policy,
                 @arbiter
               )
    end
  end

  describe "DÉGÉNÉRESCENCE — une carte sans courbe se comporte comme aujourd'hui" do
    property "policy nil ⟹ /4 rend EXACTEMENT ce que rend /2, pour tout état de jury" do
      # Liste puis Map.new evite TooManyDuplicatesError dans ce petit espace de roles.
      # L'equivalence porte sur les etats generes, pas sur tout terme Elixir possible.
      check all(
              jury <- StreamData.list_of(StreamData.member_of(@jury), max_length: 3),
              pairs <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.member_of(@jury ++ ["un-humain"]),
                     StreamData.member_of([:approved, :changes_requested])}
                  ),
                  max_length: 4
                ),
              sev <- StreamData.list_of(StreamData.member_of(FindingsWire.severities()))
            ) do
        jury = Enum.uniq(jury)
        verdicts = Map.new(pairs)

        assert Jury.review_outcome(jury, verdicts) ==
                 Jury.review_outcome(jury, verdicts, %{"qualifier" => f(sev)}, nil)
      end
    end

    test "les états non terminaux ne sont pas court-circuités par la courbe" do
      # Un juge manquant ne doit pas devenir un refus de politique.
      policy = %{"block_at" => "minor"}
      findings = %{"qualifier" => f(["critical"])}

      assert :no_jury = Jury.review_outcome([], %{}, findings, policy)

      assert {:pending, ["reviewer"]} =
               Jury.review_outcome(@jury, %{"qualifier" => :approved}, findings, policy)
    end
  end

  describe "F-3 — une charge ILLISIBLE ne s'échange pas contre un sceau" do
    test "sous une carte à courbe : zone grise, pas :approved" do
      # Regression du 2026-08-19 : perdre la sentinelle illisible effacait le blocage.
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => FindingsWire.unreadable()}

      assert :gray_zone =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "critical"})
    end

    test "sans courbe déclarée : rien ne change, l'illisible ne bloque pas" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => FindingsWire.unreadable()}

      assert :approved = Jury.review_outcome(@jury, verdicts, findings, nil)
      assert :approved = Jury.review_outcome(@jury, verdicts, findings, %{})
    end

    test "l'arbitre peut trancher ce trou comme il tranche un désaccord" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved, "gatekeeper" => :approved}
      findings = %{"qualifier" => FindingsWire.unreadable()}

      assert :approved =
               Jury.review_outcome(
                 @jury,
                 verdicts,
                 findings,
                 %{"block_at" => "minor"},
                 "gatekeeper"
               )
    end

    test "un juge illisible HORS jury ne bloque personne" do
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"un-humain" => FindingsWire.unreadable()}

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "minor"})
    end
  end
end
