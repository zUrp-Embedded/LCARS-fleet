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

  test "face/4 on the DOC template: writes backlog/scratchpad/plans → :ok", %{tmp_dir: dir} do
    # The arch's planning material moved to the doc face with the three-face split: it is neither
    # product source nor runtime-written evidence, and the ops face now carries only the latter.
    assert :ok = Scaffold.face(dir, "work-doc", "monprojet", [])
    assert File.exists?(Path.join(dir, "backlog.md"))
    assert File.dir?(Path.join(dir, "plans"))
  end

  test "the atelier door TRAVELS: its rule sits under a heading RepoSections carries", %{
    tmp_dir: dir
  } do
    # The doc face is the only one whose CLAUDE.md states a rule that is true by CONSTRUCTION for
    # every project — nothing here ships. But a door is only a door if a pod opens it, and
    # `RepoSections` carries SIX level-two headings and drops everything else. A rule written under
    # a heading of its own would be a page nobody ever receives: the file would exist, the test
    # would pass on its existence, and no producer would ever be told.
    assert :ok = Scaffold.face(dir, "work-doc", "monprojet", [])
    path = Path.join(dir, "CLAUDE.md")

    assert {:ok, carried} = Fleet.SPBuilder.RepoSections.read(path)
    assert carried =~ "## Conventions"
    assert carried =~ "jamais livré"
    # The operative half: a producer handed a SHIPPING deliverable here must say so instead of
    # writing it on a branch nobody opens. That sentence has to survive the filter too.
    assert carried =~ "docs/"

    # And the six other headings stay CLOSED, for the reason the code face states: a hollow title
    # makes the fleet believe it has context and the agent believe it has a command. `## Doc` in
    # particular has no business here — it names the documentation that SHIPS, and this tree ships
    # nothing.
    for absent <- ["## Stack", "## Build", "## Test", "## Doc", "## Commands", "## Gotchas"] do
      refute carried =~ absent, "#{absent} should not be pre-opened on the doc face"
    end
  end

  test "face/4 on the OPS template: writes the README that states who writes there", %{
    tmp_dir: dir
  } do
    # The ops face ships ONE file and it is not decoration: an empty tree cannot be committed, and
    # the branch has to exist before the first brief is materialized onto it. That the one file
    # states the read-only invariant is what makes it worth shipping rather than a `.gitkeep`.
    assert :ok = Scaffold.face(dir, "work-ops", "monprojet", [])
    readme = File.read!(Path.join(dir, "README.md"))
    assert readme =~ "monprojet"
    assert readme =~ "face `ops`"
    refute File.exists?(Path.join(dir, "backlog.md"))
  end

  test "F-C087: generated files carry the onboard date (seam :today), not a hardcoded one",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", today: "2026-07-11")
    spec = File.read!(Path.join(dir, "docs/spec.md"))
    assert spec =~ "**Date** : 2026-07-11"
    refute spec =~ "2026-06-14"

    assert :ok = Scaffold.face(dir, "work-doc", "monprojet", today: "2026-07-11")
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
