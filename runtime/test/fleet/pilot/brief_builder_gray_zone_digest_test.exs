defmodule Fleet.Pilot.BriefBuilderGrayZoneDigestTest do
  use ExUnit.Case, async: true

  # An explicit empty findings list is a measurement, not an unreadable or missing report.
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
