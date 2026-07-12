defmodule Fleet.Pilot.ProjectOnboard.ScaffoldTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Fleet.Pilot.ProjectOnboard.Scaffold

  test "main/3 : écrit README/.gitignore/.editorconfig/docs/spec.md → :ok", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch")
    assert File.read!(Path.join(dir, "README.md")) =~ "monprojet"
    assert File.exists?(Path.join(dir, "docs/spec.md"))
    assert File.exists?(Path.join(dir, ".gitignore"))
    assert File.exists?(Path.join(dir, ".editorconfig"))
  end

  test "work/3 : écrit backlog/scratchpad/plans → :ok", %{tmp_dir: dir} do
    assert :ok = Scaffold.work(dir, "monprojet", [])
    assert File.exists?(Path.join(dir, "backlog.md"))
    assert File.dir?(Path.join(dir, "plans"))
  end

  test "F-C087 : la date des fichiers générés = la date d'onboard (seam :today), pas hardcodée 2026-06-14",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", today: "2026-07-11")
    spec = File.read!(Path.join(dir, "docs/spec.md"))
    assert spec =~ "**Date** : 2026-07-11"
    refute spec =~ "2026-06-14"

    assert :ok = Scaffold.work(dir, "monprojet", today: "2026-07-11")
    assert File.read!(Path.join(dir, "backlog.md")) =~ "**Date** : 2026-07-11"
  end

  test "F-C087 : sans :today → date UTC courante", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "p", [])
    today = Date.to_iso8601(Date.utc_today())
    assert File.read!(Path.join(dir, "docs/spec.md")) =~ "**Date** : #{today}"
  end

  test "F-C086 : mkdir échec (dir sous un FICHIER) → {:error, {:scaffold_write}}, PAS de raise (honore le @spec)",
       %{tmp_dir: dir} do
    # main/3 fait mkdir_p(docs). Si `dir` est sous un chemin qui est un FICHIER, mkdir échoue (:enotdir).
    # Avant F-C086, `File.mkdir_p!` LEVAIT (viole le @spec `{:error, {:scaffold_write, _, _}}`) → onboard
    # crashait (with sans else) au lieu de retourner l'erreur typée. Maintenant : tuple typé, comme le
    # jumeau `File.write` juste en dessous.
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "je suis un fichier, pas un dir")
    bad_dir = Path.join(blocker, "proj")

    assert {:error, {:scaffold_write, _path, _reason}} = Scaffold.main(bad_dir, "proj", [])
  end
end
