defmodule Fleet.CatalogueStoreAddressTest do
  @moduledoc """
  Compares the Elixir store address with declarations in the two shell scripts below.
  Writer/converger drift can make a catalogue store appear absent and trigger local cleanup.
  Missing files are test failures, not skipped checks.

  The address is a PAIR since 2026-09-16: one repository in the system org, one branch per
  catalogue. The repository NAME is the frozen literal compared here; its org is derived, so an
  org the installer renamed takes its store along (MUR 19 holds the derivations).

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

    assert [_, _name] = Regex.run(~r/@store_name\s+"([^"]+)"/, src),
           "`Fleet.Catalogue.store_name/0` ne se lit plus comme un litteral gele — sans autorite " <>
             "lisible, ce temoin ne compare rien et les trois maisons peuvent diverger en silence"
  end

  test "l'adresse est une PAIRE : un depot de l'org systeme, une branche par catalogue" do
    assert Fleet.Catalogue.store_repo() ==
             "#{Fleet.Catalogue.system_org()}/#{Fleet.Catalogue.store_name()}"

    assert Fleet.Catalogue.store_branch("web-demo") == "web-demo"
  end

  test "les DEUX ecrivains shell portent exactement le nom de depot que le BEAM declare" do
    expected = Fleet.Catalogue.store_name()

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
