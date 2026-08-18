defmodule Fleet.Forge.JuryVerdictFunctionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.FindingsWire
  alias Fleet.Forge.Client.Jury

  @jury ["qualifier", "reviewer"]

  defp f(severities) when is_list(severities),
    do: %{"findings" => Enum.map(severities, &%{"severity" => &1, "category" => "tests"})}

  describe "C2 — la carte peut refuser ce qu'un juge a approuvé" do
    test "un finding AU-DESSUS du plancher refuse une PR pourtant approuvée" do
      # LE CAS QUI FAIT EXISTER LE MODÈLE : un juge documente un défaut critique et approuve quand
      # même. Sur un livrable qui peut blesser, c'est la carte qui dit non — et le finding qui le
      # justifie est celui que le juge a lui-même mesuré.
      verdicts = %{"qualifier" => :approved, "reviewer" => :approved}
      findings = %{"qualifier" => f(["critical"])}

      assert :changes_requested =
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

      assert :changes_requested =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "minor"})

      assert :approved =
               Jury.review_outcome(@jury, verdicts, findings, %{"block_at" => "important"})
    end

    test "les findings d'un relecteur HORS jury ne relèvent pas la barre" do
      # Un humain qui passe et laisse une review ne peut pas durcir une carte où il n'est pas
      # nommé — même discipline que le `Map.take(verdicts, jury)` déjà appliqué aux verdicts.
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
      # La règle qui rend tout le reste sûr, et le pendant exact de la correction CI de ce
      # chantier (`e005ad229` : une carte `ci: ignore` n'abroge pas le plancher de la forge). Un
      # juge qui refuse est un PLANCHER ; la tolérance d'une carte est un PLAFOND.
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

        assert with_policy in [:approved, :changes_requested]
      end
    end
  end

  describe "DÉGÉNÉRESCENCE — une carte sans courbe se comporte comme aujourd'hui" do
    property "policy nil ⟹ /4 rend EXACTEMENT ce que rend /2, pour tout état de jury" do
      # La condition qui autorise les huit cartes du canon à migrer une par une : tant qu'aucune ne
      # déclare de courbe, le rail ne bouge pas d'un octet.
      # Les générateurs construisent par LISTE puis `Map.new` : l'espace de clés tient en trois
      # rôles, et `map_of`/`uniq_list_of` y échouent à produire des clés distinctes (mesuré —
      # `TooManyDuplicatesError`). Une liste de paires déduplique sans contrainte d'unicité.
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
      # `:no_jury` et `{:pending, _}` se décident AVANT toute mesure : une carte stricte ne doit pas
      # transformer « il manque un juge » en « refusé », ce qui ferait retravailler un producteur
      # sur un verdict que personne n'a encore rendu.
      policy = %{"block_at" => "minor"}
      findings = %{"qualifier" => f(["critical"])}

      assert :no_jury = Jury.review_outcome([], %{}, findings, policy)

      assert {:pending, ["reviewer"]} =
               Jury.review_outcome(@jury, %{"qualifier" => :approved}, findings, policy)
    end
  end
end
