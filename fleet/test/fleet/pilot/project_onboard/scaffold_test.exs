defmodule Fleet.Project.Onboard.ScaffoldTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Fleet.Project.Onboard.Scaffold

  test "main/3: writes README/.gitignore/.editorconfig → :ok, and NO spec", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch")
    assert File.read!(Path.join(dir, "README.md")) =~ "monprojet"
    assert File.exists?(Path.join(dir, ".gitignore"))
    assert File.exists?(Path.join(dir, ".editorconfig"))

    # LA SPEC N'EST PLUS ICI, et son absence est le correctif. Elle vivait dans `main/docs/`, vide,
    # et personne ne pouvait l'ecrire : l'architecte produit sur la face `workshop`, et un
    # producteur n'ecrit que ce qu'un brief demande — or c'est la spec qui rend un brief ecrivable.
    # Mesure 2026-08-12 sur un projet reel : deux briefs renvoyes par le scoper faute de
    # contraintes, et la spec ecrite par l'engineer A LA LIVRAISON, apres le brief qu'elle fondait.
    refute File.exists?(Path.join(dir, "docs/spec.md"))
  end

  test "face/4 (workshop): la spec de cadrage est LA, expansee, la ou l architecte a la plume",
       %{tmp_dir: dir} do
    assert :ok =
             Scaffold.face(dir, "workshop", "monprojet", pitch: "un pitch", today: "2026-07-18")

    spec = File.read!(Path.join(dir, "spec.md"))
    refute spec =~ "${"
    assert spec =~ "monprojet"
    assert spec =~ "2026-07-18"
  end

  test "main/3 mirrors the NATIVE template semantics: ${VAR} fully expanded, control file never copied",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch", today: "2026-07-18")

    readme = File.read!(Path.join(dir, "README.md"))
    claude = File.read!(Path.join(dir, "CLAUDE.md"))
    # every variable of the priv template is expanded — none leaks into the output
    refute readme =~ "${"
    refute claude =~ "${"
    assert readme =~ "un pitch"
    assert claude =~ "monprojet"
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

    # 6-140 — LE NOM DU JOB EST UN CONTRAT, pas de la decoration. Gitea compose le contexte du
    # statut en `<workflow> / <job> (<declencheur>)`, donc ce nom-la est ce que la fleet lit pour
    # dire au juge que le vert vient du rail livre et non d'une suite. `ci` etait muet : un projet
    # fraichement onboarde produisait un contexte indistinguable d'un harnais reel.
    assert File.read!(workflow) =~ "no-harness-yet:"
    refute File.read!(workflow) =~ ~r/^  ci:$/m
  end

  test "face/4 on the DOC template: writes backlog/scratchpad/plans → :ok", %{tmp_dir: dir} do
    # The arch's planning material moved to the doc face with the three-face split: it is neither
    # product source nor runtime-written evidence, and the ops face now carries only the latter.
    assert :ok = Scaffold.face(dir, "workshop", "monprojet", [])
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
    assert :ok = Scaffold.face(dir, "workshop", "monprojet", [])
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
    assert :ok = Scaffold.face(dir, "ops", "monprojet", [])
    readme = File.read!(Path.join(dir, "README.md"))
    assert readme =~ "monprojet"
    assert readme =~ "face `ops`"
    refute File.exists?(Path.join(dir, "backlog.md"))
  end

  test "F-C087: generated files carry the onboard date (seam :today), not a hardcoded one",
       %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", today: "2026-07-11")
    claude = File.read!(Path.join(dir, "CLAUDE.md"))
    assert claude =~ "**Date** : 2026-07-11"
    refute claude =~ "2026-06-14"

    assert :ok = Scaffold.face(dir, "workshop", "monprojet", today: "2026-07-11")
    assert File.read!(Path.join(dir, "backlog.md")) =~ "**Date** : 2026-07-11"
  end

  test "F-C087: without :today → current UTC date", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "p", [])
    today = Date.to_iso8601(Date.utc_today())
    assert File.read!(Path.join(dir, "CLAUDE.md")) =~ "**Date** : #{today}"
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
