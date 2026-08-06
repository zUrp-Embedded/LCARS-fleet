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

  test "main/3 mirrors the NATIVE template semantics: ${VAR} fully expanded, control file never copied",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch", today: "2026-07-18")

    readme = File.read!(Path.join(dir, "README.md"))
    spec = File.read!(Path.join(dir, "docs/spec.md"))
    # every variable of the priv template is expanded — none leaks into the output
    refute readme =~ "${"
    refute spec =~ "${"
    assert readme =~ "un pitch"
    assert spec =~ "2026-07-18"
    # `.gitea/template` is the template CONTROL file: never copied (native semantics)
    refute File.exists?(Path.join(dir, ".gitea/template"))
    # ...but `.gitea/` itself IS delivered — it carries the CI rail every project is born with.
    # The old form of this test refuted the whole directory, which held only the control file at
    # the time: an incidental truth, not the invariant. The invariant is the line above.
    workflow = Path.join(dir, ".gitea/workflows/ci.yml")
    assert File.exists?(workflow)
    # The workflow's `${GITHUB_*}` are the RUNNER's variables, expanded at job time. Neither the
    # local expansion (5 known vars) nor the forge's (`.gitea/template` lists README + spec only)
    # may touch them — a scaffold that emptied them would ship a rail that reports nothing.
    assert File.read!(workflow) =~ "${GITHUB_REPOSITORY}"
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
