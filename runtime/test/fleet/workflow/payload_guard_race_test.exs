defmodule Fleet.Workflow.PayloadGuardRaceTest do
  @moduledoc """
  6-047 — LA FENETRE ENTRE LA VALIDATION ET L'ECRITURE, et pourquoi elle demande un seam pour etre
  prouvee.

  `apply_files/2` valide TOUT puis ecrit TOUT. La passe 1 constate qu'aucun composant du chemin
  n'est un lien ; la passe 2 ecrit. Entre les deux, le pod — qui tourne encore, et dont l'espace de
  travail est monte RW — pose le lien. `File.write` le SUIT : l'ecriture reputee confinee atterrit
  ou le lien pointe, `.git/` compris, que la garde `dotgit_component?` refuse justement par le
  chemin declare.

  ⚠ POURQUOI CES TESTS ONT BESOIN D'UN SEAM. Dans un monde sans concurrence, le correctif est
  OBSERVATIONNELLEMENT IDENTIQUE a l'ancien code : meme fichier, meme contenu, meme refus sur un
  lien pre-existant (couvert par `deliverable_test.exs`, F081). Un test ecrit sans provoquer la
  course serait vert avant comme apres — il ne prouverait rien (P-09). `:after_validate` place le
  lien exactement la ou le pod le poserait.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.PayloadGuard

  @moduletag :tmp_dir

  defp ws_with_victim(tmp) do
    ws = Path.join(tmp, "ws")
    File.mkdir_p!(ws)
    victime = Path.join(tmp, "hors-workspace")
    File.mkdir_p!(victime)
    {ws, victime}
  end

  test "un lien pose sur un REPERTOIRE parent apres la validation est REFUSE", %{tmp_dir: tmp} do
    {ws, victime} = ws_with_victim(tmp)

    assert {:error, {:symlink_escape, "out/livrable.txt"}} =
             PayloadGuard.apply_files(
               ws,
               [%{"path" => "out/livrable.txt", "content" => "contenu"}],
               after_validate: fn -> File.ln_s!(victime, Path.join(ws, "out")) end
             )

    refute File.exists?(Path.join(victime, "livrable.txt")),
           "l'ecriture a suivi le lien pose apres la validation — l'evasion 6-047"
  end

  test "un lien pose sur le FICHIER CIBLE apres la validation ne detourne rien", %{tmp_dir: tmp} do
    {ws, victime} = ws_with_victim(tmp)
    cible = Path.join(victime, "fichier-de-quelqu-un-d-autre")
    File.write!(cible, "CONTENU D'ORIGINE")

    resultat =
      PayloadGuard.apply_files(
        ws,
        [%{"path" => "livrable.txt", "content" => "charge utile"}],
        after_validate: fn -> File.ln_s!(cible, Path.join(ws, "livrable.txt")) end
      )

    # L'ETAT DU MONDE D'ABORD, et l'ordre est le test : meme si le refus disparaissait, la victime
    # doit rester intacte, parce que `rename` REMPLACE le lien au lieu de le suivre. C'est la
    # moitie STRUCTURELLE, celle qui ne depend d'aucune verification prealable — et l'asserter apres
    # le code de retour la rendrait invisible des que le refus tombe.
    assert File.read!(cible) == "CONTENU D'ORIGINE",
           "l'ecriture a suivi le lien du dernier composant — `rename` aurait du le remplacer"

    assert resultat == {:error, {:symlink_escape, "livrable.txt"}}
  end

  test "TEMOIN — sans lien, la passe 2 ecrit normalement et le fichier est REGULIER", %{
    tmp_dir: tmp
  } do
    # Sans ce temoin, un correctif qui refuserait TOUT passerait les deux tests ci-dessus (P-40).
    {ws, _victime} = ws_with_victim(tmp)

    assert :ok =
             PayloadGuard.apply_files(ws, [
               %{"path" => "sous/dossier/livrable.txt", "content" => "charge utile"}
             ])

    chemin = Path.join(ws, "sous/dossier/livrable.txt")
    assert File.read!(chemin) == "charge utile"
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(chemin)
  end

  test "TEMOIN — le seam est ABSENT en production : sans lui, rien ne s'insere", %{tmp_dir: tmp} do
    # Le seam ne doit pas devenir une porte : appele sans opts, le chemin est celui de la prod.
    {ws, _victime} = ws_with_victim(tmp)

    assert :ok = PayloadGuard.apply_files(ws, [%{"path" => "a.txt", "content" => "x"}])
    assert File.read!(Path.join(ws, "a.txt")) == "x"
  end

  test "aucun temporaire ne survit a une ecriture reussie", %{tmp_dir: tmp} do
    # Le remplacement passe par un temporaire dans LE MEME repertoire (rename n'est atomique qu'a
    # l'interieur d'un systeme de fichiers). Un temporaire laisse serait committe avec le livrable.
    {ws, _victime} = ws_with_victim(tmp)

    assert :ok = PayloadGuard.apply_files(ws, [%{"path" => "d/a.txt", "content" => "x"}])

    assert File.ls!(Path.join(ws, "d")) == ["a.txt"]
  end
end
