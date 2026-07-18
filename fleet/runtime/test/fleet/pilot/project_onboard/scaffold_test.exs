defmodule Fleet.Pilot.ProjectOnboard.ScaffoldTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Fleet.Pilot.ProjectOnboard.Scaffold

  test "main/3: writes README/.gitignore/.editorconfig/docs/spec.md → :ok", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch")
    assert File.read!(Path.join(dir, "README.md")) =~ "monprojet"
    assert File.exists?(Path.join(dir, "docs/spec.md"))
    assert File.exists?(Path.join(dir, ".gitignore"))
    assert File.exists?(Path.join(dir, ".editorconfig"))
  end

  test "work/3: writes backlog/scratchpad/plans → :ok", %{tmp_dir: dir} do
    assert :ok = Scaffold.work(dir, "monprojet", [])
    assert File.exists?(Path.join(dir, "backlog.md"))
    assert File.dir?(Path.join(dir, "plans"))
  end

  test "F-C087: generated files carry the onboard date (seam :today), not a hardcoded one",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", today: "2026-07-11")
    spec = File.read!(Path.join(dir, "docs/spec.md"))
    assert spec =~ "**Date** : 2026-07-11"
    refute spec =~ "2026-06-14"

    assert :ok = Scaffold.work(dir, "monprojet", today: "2026-07-11")
    assert File.read!(Path.join(dir, "backlog.md")) =~ "**Date** : 2026-07-11"
  end

  test "F-C087: without :today → current UTC date", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "p", [])
    today = Date.to_iso8601(Date.utc_today())
    assert File.read!(Path.join(dir, "docs/spec.md")) =~ "**Date** : #{today}"
  end

  test "F-C086: mkdir failure (dir under a FILE) → {:error, {:scaffold_write}}, NO raise (honors the @spec)",
       %{tmp_dir: dir} do
    # main/3 runs mkdir_p(docs). If `dir` sits under a path that is a FILE, mkdir fails (:enotdir).
    # A raising `File.mkdir_p!` would violate the @spec `{:error, {:scaffold_write, _, _}}` → onboard
    # would crash (with without else) instead of returning the typed error. Now: typed tuple, like the
    # `File.write` twin right below.
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "I am a file, not a dir")
    bad_dir = Path.join(blocker, "proj")

    assert {:error, {:scaffold_write, _path, _reason}} = Scaffold.main(bad_dir, "proj", [])
  end
end
