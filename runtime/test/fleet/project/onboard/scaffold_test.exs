defmodule Fleet.Project.Onboard.ScaffoldTest do
  # Global catalogue_install_dirs changes require synchronous tests.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Project.Onboard.Scaffold

  test "main/3: writes README/.gitignore/.editorconfig → :ok, and NO spec", %{tmp_dir: dir} do
    assert :ok = Scaffold.main(dir, "monprojet", pitch: "un pitch")
    assert File.read!(Path.join(dir, "README.md")) =~ "monprojet"
    assert File.exists?(Path.join(dir, ".gitignore"))
    assert File.exists?(Path.join(dir, ".editorconfig"))

    # Planning specs belong on writable workshop before briefing; main must not precreate one.
    refute File.exists?(Path.join(dir, "docs/spec.md"))
  end

  # Catalogue selection once regressed when the old template layer was removed; test its current owner.

  describe "le repli s'annonce, et le catalogue LIVRE ne s'annonce pas a lui-meme" do
    # Exercise a writing entry point: bare template_root resolution does not announce fallback.

    test "un catalogue nomme qui n'a pas d'arbre le DIT, en `info`", %{tmp_dir: dir} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Scaffold.ci_workflows(dir, "p", org: "un-catalogue-sans-arbre")
        end)

      assert log =~ "un-catalogue-sans-arbre"
      assert log =~ "[info]"
    end

    test "un appelant qui ne nomme AUCUN catalogue monte d'un cran : `warning`", %{tmp_dir: dir} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Scaffold.ci_workflows(dir, "p", [])
        end)

      assert log =~ "[warning]"
    end

    test "le catalogue LIVRE ne se replie PAS : il resout sur son propre arbre", %{tmp_dir: dir} do
      # Assert own-root selection, not a hardcoded log suppression for the bundled catalogue.
      assert {_root, :own} = Scaffold.template_root(Fleet.Catalogue.bundled_name())

      # Capture can include unrelated logs; exclude Scaffold announcements rather than all output.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} =
                   Scaffold.ci_workflows(dir, "p", org: Fleet.Catalogue.bundled_name())
        end)

      refute log =~ "Scaffold:"
    end
  end

  describe "template_root/1" do
    setup %{tmp_dir: dir} do
      # Installed catalogue discovery requires a manifest, not just a template directory.
      root = Path.join(dir, "cat-a-lui")
      File.mkdir_p!(Path.join(root, Fleet.Catalogue.rel(:project_template)))
      File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\nname: cat-a-lui\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      %{own_root: root}
    end

    test "un catalogue qui livre son arbre scaffolde depuis LE SIEN", %{own_root: root} do
      assert {path, :own} = Scaffold.template_root("cat-a-lui")
      assert path == Path.join(root, Fleet.Catalogue.rel(:project_template))
    end

    test "un catalogue SANS arbre se replie sur le livre — l arbitrage de 2026-08-16" do
      assert {path, :fallback} = Scaffold.template_root("cat-sans-arbre")
      assert path == Fleet.Catalogue.project_template_root()
    end

    test "un appelant qui ne nomme pas son catalogue se replie AUSSI, et c est le cas dangereux" do
      # This checks resolution only; writing-path tests above distinguish info and warning.
      assert {path, :fallback} = Scaffold.template_root(nil)
      assert path == Fleet.Catalogue.project_template_root()
    end
  end

  # Imported projects need workflow files without full-main scaffolding over their own content.

  test "ci_workflows/3: pose les DEUX workflows sur un depot qui n'en a aucun", %{tmp_dir: dir} do
    assert {:ok, added} = Scaffold.ci_workflows(dir, "importe", [])

    assert added == [".gitea/workflows/ci.yml", ".gitea/workflows/probe-test-relevance.yml"]
    assert File.exists?(Path.join(dir, ".gitea/workflows/ci.yml"))

    # run_probe needs the shipped probe workflow as well as the CI workflow.
    assert File.exists?(Path.join(dir, ".gitea/workflows/probe-test-relevance.yml"))
  end

  # Stance changes generated instructions; these tests do not execute CI or enforce forge protection.

  test "carte SANS CI : le vert est annonce comme un RECU, pas comme une preuve", %{tmp_dir: dir} do
    assert {:ok, _} = Scaffold.ci_workflows(dir, "poc", ci_stance: :ignore)
    ci = File.read!(Path.join(dir, ".gitea/workflows/ci.yml"))

    assert ci =~ "recu du plancher"

    refute ci =~ "Remplace ce step par ta commande de test"
  end

  test "carte AVEC CI : le vert est un placeholder, et le rail invite a poser la suite",
       %{tmp_dir: dir} do
    assert {:ok, _} = Scaffold.ci_workflows(dir, "serieux", ci_stance: :required)
    ci = File.read!(Path.join(dir, ".gitea/workflows/ci.yml"))

    assert ci =~ "Remplace ce step par ta commande de test"
    refute ci =~ "recu du plancher"
  end

  test "posture ABSENTE : le defaut est l'invitation a prouver, jamais la dispense",
       %{tmp_dir: dir} do
    # Missing stance only; this test does not exercise unreadable card/catalogue fallback.
    assert {:ok, _} = Scaffold.ci_workflows(dir, "inconnu", [])
    ci = File.read!(Path.join(dir, ".gitea/workflows/ci.yml"))

    assert ci =~ "Remplace ce step par ta commande de test"
    refute ci =~ "recu du plancher"
  end

  test "reset_ci_workflows/3 ECRASE, la ou ci_workflows/3 n'ecrase JAMAIS", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".gitea/workflows"))
    File.write!(Path.join(dir, ".gitea/workflows/ci.yml"), "casse: oui\n")

    assert {:ok, ajoutes} = Scaffold.ci_workflows(dir, "p", [])
    refute ".gitea/workflows/ci.yml" in ajoutes
    assert File.read!(Path.join(dir, ".gitea/workflows/ci.yml")) == "casse: oui\n"

    assert {:ok, ecrits} = Scaffold.reset_ci_workflows(dir, "p", [])
    assert ".gitea/workflows/ci.yml" in ecrits
    refute File.read!(Path.join(dir, ".gitea/workflows/ci.yml")) =~ "casse: oui"
  end

  test "ci_workflows/3: n'ecrit QUE le rail — ni README, ni CLAUDE.md, ni .gitignore",
       %{tmp_dir: dir} do
    # Check that workflow-only scaffolding does not create README or .gitignore.
    assert {:ok, _} = Scaffold.ci_workflows(dir, "importe", [])

    refute File.exists?(Path.join(dir, "README.md"))
    refute File.exists?(Path.join(dir, ".gitignore"))
  end

  test "ci_workflows/3: N'ECRASE PAS un workflow deja present", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".gitea/workflows"))
    mine = Path.join(dir, ".gitea/workflows/ci.yml")
    File.write!(mine, "name: CI\n# le mien\n")

    assert {:ok, added} = Scaffold.ci_workflows(dir, "importe", [])

    assert added == [".gitea/workflows/probe-test-relevance.yml"]
    assert File.read!(mine) == "name: CI\n# le mien\n"
  end

  test "ci_workflows/3: rien a poser -> {:ok, []}, ce que l appelant lit pour ne pas committer",
       %{tmp_dir: dir} do
    assert {:ok, _} = Scaffold.ci_workflows(dir, "importe", [])
    assert {:ok, []} = Scaffold.ci_workflows(dir, "importe", [])
  end

  test "ci_workflows/3: les placeholders sont expanses comme dans une face complete",
       %{tmp_dir: dir} do
    # Check known template variables only: runner placeholders such as GITHUB_REPOSITORY must survive.
    assert {:ok, _} = Scaffold.ci_workflows(dir, "monprojet", today: "2026-07-18")

    for f <- ["ci.yml", "probe-test-relevance.yml"],
        v <- ~w(REPO_NAME REPO_DESCRIPTION YEAR MONTH DAY) do
      refute File.read!(Path.join(dir, ".gitea/workflows/#{f}")) =~ "${#{v}}"
    end
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
    # Check these two files, not every template variable in every output.
    refute readme =~ "${"
    refute claude =~ "${"
    assert readme =~ "un pitch"
    assert claude =~ "monprojet"

    refute File.exists?(Path.join(dir, ".gitea/template"))
    # Omit the template control file while retaining the workflows under the same directory.
    workflow = Path.join(dir, ".gitea/workflows/ci.yml")
    assert File.exists?(workflow)
    # Runner variables expand at job time, not scaffold time.
    assert File.read!(workflow) =~ "${GITHUB_REPOSITORY}"

    # The placeholder job name lets readers distinguish shipped CI from a project's test harness.
    assert File.read!(workflow) =~ "no-harness-yet:"
    refute File.read!(workflow) =~ ~r/^  ci:$/m
  end

  test "face/4 on the DOC template: writes backlog/scratchpad/plans → :ok", %{tmp_dir: dir} do
    assert :ok = Scaffold.face(dir, "workshop", "monprojet", [])
    assert File.exists?(Path.join(dir, "backlog.md"))
    assert File.dir?(Path.join(dir, "plans"))
  end

  test "the atelier door TRAVELS: its rule sits under a heading RepoSections carries", %{
    tmp_dir: dir
  } do
    # Workshop instructions must survive RepoSections filtering, not merely exist in a file.
    assert :ok = Scaffold.face(dir, "workshop", "monprojet", [])
    path = Path.join(dir, "CLAUDE.md")

    assert {:ok, carried} = Fleet.SPBuilder.RepoSections.read(path)
    assert carried =~ "## Conventions"
    assert carried =~ "jamais livré"
    # Shipped docs belong on main; that distinction must survive the section filter.
    assert carried =~ "docs/"

    # Do not pre-open empty command/context headings on workshop.
    for absent <- ["## Stack", "## Build", "## Test", "## Doc", "## Commands", "## Gotchas"] do
      refute carried =~ absent, "#{absent} should not be pre-opened on the doc face"
    end
  end

  test "face/4 on the OPS template: writes the README that states who writes there", %{
    tmp_dir: dir
  } do
    # A README permits the initial ops commit before any runtime records exist.
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
    # A destination below a regular file exercises typed mkdir failure, not source-read exceptions.
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "I am a file, not a dir")
    bad_dir = Path.join(blocker, "proj")

    assert {:error, {:scaffold_write, _path, _reason}} = Scaffold.main(bad_dir, "proj", [])
  end
end
