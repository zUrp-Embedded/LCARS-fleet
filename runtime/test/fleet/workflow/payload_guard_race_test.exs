defmodule Fleet.Workflow.PayloadGuardRaceTest do
  @moduledoc """
  Injects symlinks after whole-payload validation and before per-file checks.
  The seam makes this inter-pass regression deterministic. It does not exercise
  the remaining interval between the second check and rename.
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

    # Check victim bytes before the error assertion. Here the second symlink check
    # rejects the write; this case does not independently exercise rename replacement.
    assert File.read!(cible) == "CONTENU D'ORIGINE",
           "l'ecriture a suivi le lien du dernier composant — `rename` aurait du le remplacer"

    assert resultat == {:error, {:symlink_escape, "livrable.txt"}}
  end

  test "TEMOIN — sans lien, la passe 2 ecrit normalement et le fichier est REGULIER", %{
    tmp_dir: tmp
  } do
    # Positive control rules out an implementation that refuses every payload.
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
    # Two-argument call exercises the default path without an injected hook.
    {ws, _victime} = ws_with_victim(tmp)

    assert :ok = PayloadGuard.apply_files(ws, [%{"path" => "a.txt", "content" => "x"}])
    assert File.read!(Path.join(ws, "a.txt")) == "x"
  end

  test "aucun temporaire ne survit a une ecriture reussie", %{tmp_dir: tmp} do
    # A leftover temporary could be staged with the deliverable.
    {ws, _victime} = ws_with_victim(tmp)

    assert :ok = PayloadGuard.apply_files(ws, [%{"path" => "d/a.txt", "content" => "x"}])

    assert File.ls!(Path.join(ws, "d")) == ["a.txt"]
  end
end
