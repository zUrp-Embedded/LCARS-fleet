defmodule Fleet.CatalogueStoreAddressTest do
  @moduledoc """
  Compares the Elixir store address with declarations in the two shell scripts below.
  Writer/converger drift can make a catalogue store appear absent and trigger local cleanup.
  Missing files are test failures, not skipped checks.

  This is a source-text check: the regex requires the expected substring after STORE_REPO=,
  not exact shell-value equality or agreement under environment overrides.
  """
  use ExUnit.Case, async: true

  @mirrors [
    "services/forge-gestures.sh",
    "services/forge.d/catalogues.sh"
  ]

  test "l'autorite est un litteral GELE — sinon il n'y a rien a comparer" do
    # Require a readable literal so the authority cannot silently escape the comparison.
    src = File.read!("lib/fleet/catalogue.ex")

    assert [_, _name] = Regex.run(~r/def\s+store_repo,\s*do:\s*"([^"]+)"/, src),
           "`Fleet.Catalogue.store_repo/0` ne se lit plus comme un litteral gele — sans autorite " <>
             "lisible, ce temoin ne compare rien et les trois maisons peuvent diverger en silence"
  end

  test "les DEUX ecrivains shell portent exactement l'adresse que le BEAM declare" do
    expected = Fleet.Catalogue.store_repo()

    for rel <- @mirrors do
      body = File.read!(rel)

      assert Regex.match?(~r/^STORE_REPO=.*#{Regex.escape(expected)}/m, body),
             "#{rel} : son `STORE_REPO` ne porte pas #{inspect(expected)}. L'ecrivain et le " <>
               "convergeur doivent viser la meme adresse — sinon la liste signee revient vide et " <>
               "le balayage efface le materiel de TOUS les catalogues du conteneur."
    end
  end

  test "TEMOIN de non-vacuite : les fichiers existent et portent bien la ligne" do
    # Explicit fixture-presence check; File.read! and the comparison also fail if files vanish.
    for rel <- @mirrors do
      assert File.exists?(rel), "#{rel} a disparu — ce temoin ne mesure plus l'adresse"
      assert File.read!(rel) =~ ~r/^STORE_REPO=/m, "#{rel} ne declare plus `STORE_REPO`"
    end
  end
end
