defmodule Fleet.Pilot.BriefBuilderGrayZoneDigestTest do
  use ExUnit.Case, async: true

  # ⚠ MESURÉ EN PRODUCTION (banc, PR71, 2026-08-19). Le gatekeeper a été convoqué sur une vraie
  # zone grise et son brief lui a présenté le rapport du reviewer comme « aucune sévérité
  # lisible » — alors que ce juge avait rendu `{"findings": [], "severity_max": "none"}`, une
  # mesure VALIDE et EXPLICITE. Un arbitre convoqué pour trancher entre une approbation et une
  # mesure ne peut pas travailler si le rail lui décrit une mesure claire comme du bruit : il
  # conclurait que le jury est muet là où il a parlé.
  defp digest(findings) do
    ctx_opts = [gray_zone: %{findings: findings, policy: %{"block_at" => "minor"}}]
    Fleet.Pilot.BriefBuilder.gray_zone_line_for_test(ctx_opts)
  end

  test "les trois états d'un rapport sont distingués" do
    line =
      digest(%{
        "qualifier" => %{"findings" => [%{"severity" => "minor"}]},
        "reviewer" => %{"findings" => []},
        "scoper" => nil
      })

    assert line =~ "`qualifier` (1× minor)"

    assert line =~ "`reviewer` (a mesuré, aucun finding)",
           "une liste vide est une MESURE, pas une illisibilité"

    assert line =~ "`scoper` (pas de mesure)",
           "l'absence de charge n'est pas une charge vide"
  end
end
