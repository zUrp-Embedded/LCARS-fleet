defmodule Fleet.Pilot.ForgeProtocolPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Preuve property-based de l'invariant central de `ForgeProtocol` : chaque format
  # a son builder et son parseur/predicat co-localises, et `parse . build == identite`.
  # Les tests par exemple (forge_protocol_test.exs) fixent des cas nommes ; ici on
  # bombarde avec des role/sha/steps generes pour prouver que l'invariant tient sur
  # tout le charset REALISTE, pas seulement sur les exemples cables.
  alias Fleet.Pilot.ForgeProtocol

  # Charset realiste d'un token de wire-protocol (role, nom de workflow_map, step) :
  # lettres/chiffres + `_`/`-` (kebab et snake). Exclut par construction les
  # delimiteurs graves du marqueur (`:` et `]`) et le newline -> le token genere ne
  # peut pas casser le format lui-meme. (La robustesse a un token ADVERSARIAL contenant
  # ces delimiteurs est un concern distinct, hors de ce round-trip.)
  defp token do
    string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min_length: 1, max_length: 40)
  end

  # sha realiste : hex court-a-long (git short-sha jusqu'au full sha1).
  defp sha do
    string([?0..?9, ?a..?f], min_length: 1, max_length: 40)
  end

  property "step_run_marker?/1 reconnait TOUT marqueur produit par step_run_marker/2" do
    # Le module n'expose pas de parseur de step_run (seulement le predicat pour le
    # comptage forge-natif) : le round-trip prouvable est build -> predicat == true.
    check all(role <- token(), s <- sha()) do
      marker = ForgeProtocol.step_run_marker(role, s)
      assert ForgeProtocol.step_run_marker?(marker)
    end
  end

  property "feature_branch/2 + parse_feature_branch/1 : parse . build == identite" do
    check all(n <- positive_integer(), role <- token()) do
      assert {:ok, {^n, ^role}} =
               ForgeProtocol.parse_feature_branch(ForgeProtocol.feature_branch(n, role))
    end
  end

  # (Property route_marker/parse_route_marker retirée : la position vit dans le label stage/* — cf. ForgeClient.)
end
