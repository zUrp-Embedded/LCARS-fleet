defmodule Fleet.CatalogueStoreAddressTest do
  @moduledoc """
  L'adresse du magasin est écrite dans TROIS runtimes — et une désynchronisation EFFACE du matériel.

  `Fleet.Catalogue.store_repo/0` la déclare. `forge-gestures.sh` y POUSSE (`push_store`) et clone
  depuis elle (`install_material`). `45-catalogues.sh` l'y cherche — et quand il ne trouve pas le
  catalogue qu'il attendait, il **supprime** le matériel local.

  Renommer d'un seul côté donne la séquence suivante : `push_store` écrit en A, le convergeur
  cherche en B, la liste signée revient VIDE, et le balayage efface tous les catalogues de la boîte
  en annonçant qu'il converge. C'est la dérive la plus chère que ce dépôt puisse produire, et elle
  coûte un fichier oublié.

  Les deux relectures indépendantes du 2026-08-21 l'ont nommée toutes les deux. Ce témoin est ce qui
  fait de « trois défauts dans trois runtimes, pas trois autorités » un fait plutôt qu'un
  commentaire.

  ## Pourquoi ici et pas dans `lcars.contracts.check`

  C'est la forme de `toolchain.branch_single_source`, qui vit là-bas — mais qui a dû s'inscrire sur
  la liste d'exemptions de `NoCheckPassesOnNothingTest`, parce que son sujet (`deploy`) est
  absent de l'artefact runtime et qu'un mur y rendrait `:pass` sur un ensemble vide.

  Un témoin `mix test` n'a pas ce problème : il tourne sur le DÉPÔT, où `deploy/` existe toujours.
  Le fichier absent y est un échec légitime et non un cas à exempter. Une exemption de moins vaut
  mieux qu'un mur de plus.
  """
  use ExUnit.Case, async: true

  # Les deux écrivains shell. `forge-gestures.sh` pousse et clone ; `45-catalogues.sh` cherche et
  # supprime. Ce sont les deux seuls fichiers qui portent l'adresse hors du BEAM.
  # ⚠ LE SECOND EST DANS UN ARBRE FRERE DEPUIS QUE L'INSTALLEUR EST SORTI DE `fleet/`. Ces chemins
  # sont relatifs au root Mix, qui EST `fleet/` : `services/…` y est, `deploy/…` n'y est plus. Le
  # `..` dit exactement ce qui a change — l'installeur est a COTE du runtime, plus dedans.
  @mirrors [
    "services/forge-gestures.sh",
    "../deploy/modules.d/45-catalogues.sh"
  ]

  test "l'autorite est un litteral GELE — sinon il n'y a rien a comparer" do
    # ⚠ FAIL-CLOSED. Une autorité illisible n'est pas « rien à comparer » : c'est le seul cas où
    # tous les miroirs passeraient par défaut.
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
               "le balayage efface le materiel de TOUS les catalogues de la boite."
    end
  end

  test "TEMOIN de non-vacuite : les fichiers existent et portent bien la ligne" do
    # Sans lui, ce fichier resterait vert le jour ou les deux scripts disparaissent ou perdent leur
    # declaration — un mur qui ne mesure plus rien et qui ne le dit pas.
    for rel <- @mirrors do
      assert File.exists?(rel), "#{rel} a disparu — ce temoin ne mesure plus l'adresse"
      assert File.read!(rel) =~ ~r/^STORE_REPO=/m, "#{rel} ne declare plus `STORE_REPO`"
    end
  end
end
