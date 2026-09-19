defmodule Mix.Tasks.Lcars.Contracts.CheckTest do
  @moduledoc """
  Runs the aggregate checks against this checkout and exercises individual checks with
  fixture roots. Regressions cover empty/unreadable targets, nested doc declarations,
  sibling artifact scope and selected source patterns. Doc-block filtering is tested
  for the heredoc forms below, not all possible documentation syntax.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Artifact
  alias Mix.Tasks.Lcars.Contracts.Check.Boot
  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue
  alias Mix.Tasks.Lcars.Contracts.Check.Runtime
  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource
  alias Mix.Tasks.Lcars.Contracts.Check.Support
  alias Mix.Tasks.Lcars.Contracts.Check.Tests
  alias Mix.Tasks.Lcars.Contracts.Check.Types

  # JG-097 — LE PERIMETRE ETAIT GARDE, LA POPULATION NON. La population vient de DEUX racines
  # (`deploy/modules.d` et `etc`), une seule etait scopee, et `Path.wildcard` sur un chemin absent
  # rend `[]` en silence : un `modules.d/` vide donnait `:pass` sans ouvrir un fichier. Parade deja
  # au depot (`measured_nothing?/1` + `broken_result/2`, BL-6-70). Les deux tests vont par paire :
  # sans le second, supprimer la mesure rendrait le premier vert.
  describe "shell.sourcers_set_strict — la POPULATION fait partie du contrat" do
    # Deploy must be a sibling of the fixture runtime, matching the artifact layout.
    defp fixture_root!(ctx) do
      base = Fleet.TestEnv.tmp_path("jg097-#{ctx}")
      root = Path.join(base, "fleet")
      File.mkdir_p!(Path.join([base, "deploy", "modules.d"]))
      File.mkdir_p!(Path.join(root, "etc"))
      on_exit(fn -> File.rm_rf(base) end)
      root
    end

    test "aucun fichier lu → INSTRUMENT BROKEN, jamais un vert" do
      root = fixture_root!("vide")

      result = Artifact.check_sourcers_set_strict(root)

      assert result.status == :fail,
             "un contrat qui n'a ouvert aucun fichier a rendu #{result.status}"

      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end

    test "population NON vide et conforme → pass (le garde n'a pas rendu le contrat impossible)" do
      root = fixture_root!("conforme")

      File.write!(Path.join([root, "..", "deploy", "modules.d", "10-x.sh"]), """
      #!/usr/bin/env bash
      set -euo pipefail
      . "$(dirname "$0")/../lib/provision-lib.sh"
      """)

      result = Artifact.check_sourcers_set_strict(root)

      assert result.status == :pass
      assert result.note =~ "1 shell file(s) scanned"
    end
  end

  # Les trois faces sont trois branches ORPHELINES d'un seul depot : rien ne traverse par le graphe,
  # mais un refspec LARGE rapatrie les objets des deux autres au premier fetch nu. Le defaut ne
  # casse rien — il fait juste grossir la face que les pods clonent. D'ou un mur.
  describe "project.faces_single_branch — une face ne ramene QUE sa branche" do
    defp faces_root!(nom, corps) do
      root = Fleet.TestEnv.tmp_path("faces-#{nom}")
      dir = Path.join([root, "lib", "fleet", "project", "onboard"])
      File.mkdir_p!(dir)
      if corps, do: File.write!(Path.join(dir, "faces.ex"), corps)
      on_exit(fn -> File.rm_rf(root) end)
      root
    end

    defp faces_source(clone_args) do
      """
      defmodule Fleet.Project.Onboard.Faces do
        def clone_main(url, dir), do: GitOps.run(#{clone_args}, auth: true)

        def init_face(dir, url, branch) do
          GitOps.run(["-C", dir, "remote", "add", "-t", branch, "origin", url], auth: false)
        end

        def set_origin(dir, url, branch \\\\ nil) do
          GitOps.run(["-C", dir, "config", "remote.origin.fetch", refspec(branch)], auth: false)
        end
      end
      """
    end

    test "les trois gardes en place → pass" do
      root =
        faces_root!(
          "ok",
          faces_source(~s(["clone", "--single-branch", "--branch", "main", url, dir]))
        )

      result = Runtime.check_faces_single_branch(root)

      assert result.status == :pass
      assert result.evidence == []
    end

    test "un clone SANS --single-branch → fail qui nomme l'argv" do
      root = faces_root!("large", faces_source(~s(["clone", "--branch", "main", url, dir])))

      result = Runtime.check_faces_single_branch(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "WIDE refspec"))
    end

    test "init_face qui ne suit plus une seule branche → fail nomme" do
      corps =
        faces_source(~s(["clone", "--single-branch", "--branch", "main", url, dir]))
        |> String.replace(~s("add", "-t", branch, "origin"), ~s("add", "origin"))

      root = faces_root!("remote-large", corps)

      result = Runtime.check_faces_single_branch(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "init_face does not track a single branch"))
    end

    test "la fonction disparue → INSTRUMENT BROKEN, jamais un vert par absence" do
      corps =
        faces_source(~s(["clone", "--single-branch", "--branch", "main", url, dir]))
        |> String.replace("def set_origin", "def point_origin")

      root = faces_root!("disparue", corps)

      result = Runtime.check_faces_single_branch(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "set_origin NOT FOUND"))
    end

    test "source ABSENTE → INSTRUMENT BROKEN, pas un pass" do
      root = faces_root!("vide", nil)

      result = Runtime.check_faces_single_branch(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end
  end

  # Sans mode explicite une face d'écriture naît sous l'umask du BEAM : l'atelier cesse d'être
  # écrivable par le groupe et un dépôt humain s'y refuse, sans message. Deux des trois chemins qui
  # bâtissent une face l'oubliaient ; un littéral recopié est la forme que reprendrait ce défaut.
  describe "layout.face_mode_single_source — le mode d'une face se déclare UNE fois" do
    defp modes_root!(nom, declaration, autre) do
      root = Fleet.TestEnv.tmp_path("modes-#{nom}")
      File.mkdir_p!(Path.join([root, "lib", "fleet", "project"]))
      if declaration, do: File.write!(Path.join([root, "lib", "fleet", "layout.ex"]), declaration)
      if autre, do: File.write!(Path.join([root, "lib", "fleet", "project", "faces.ex"]), autre)
      on_exit(fn -> File.rm_rf(root) end)
      root
    end

    defp declaration_conforme,
      do: """
      defmodule Fleet.Layout do
        @writer_face_modes %{"workshop" => 0o2775, "ops" => 0o2755}
        def writer_face_mode(face), do: Map.get(@writer_face_modes, face)
      end
      """

    test "le mode lu de Layout, aucune copie → pass" do
      root =
        modes_root!("ok", declaration_conforme(), """
        defmodule Fleet.Project.Onboard.Faces do
          def mode(branch), do: Fleet.Layout.writer_face_mode(Fleet.Layout.face_of(branch))
        end
        """)

      result = SingleSource.check_face_mode_single_source(root)

      assert result.status == :pass
      assert result.evidence == []
    end

    test "un littéral recopié ailleurs → fail qui nomme le fichier et la ligne" do
      root =
        modes_root!("copie", declaration_conforme(), """
        defmodule Fleet.Project.Onboard.Faces do
          def mode(_branch), do: 0o2775
        end
        """)

      result = SingleSource.check_face_mode_single_source(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "lib/fleet/project/faces.ex:2"))
    end

    test "le même littéral dans un COMMENTAIRE n'est pas une copie" do
      root =
        modes_root!("commentaire", declaration_conforme(), """
        defmodule Fleet.Project.Onboard.Faces do
          # l'atelier vaut 0o2775, l'ops 0o2755 — dit ici, décidé dans Layout
          def mode(branch), do: Fleet.Layout.writer_face_mode(branch)
        end
        """)

      result = SingleSource.check_face_mode_single_source(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    test "la déclaration réduite à un seul mode → INSTRUMENT BROKEN, pas un vert" do
      root =
        modes_root!(
          "declaration",
          """
          defmodule Fleet.Layout do
            @writer_face_modes %{"workshop" => 0o2775}
          end
          """,
          "defmodule A do\nend\n"
        )

      result = SingleSource.check_face_mode_single_source(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end

    test "aucune source lue → INSTRUMENT BROKEN, jamais un vert par corpus vide" do
      root = modes_root!("vide", declaration_conforme(), nil)

      result = SingleSource.check_face_mode_single_source(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end
  end

  # ⚠ UN TÉMOIN ASYNC QUI POSE UNE CLEF GLOBALE FAIT ROUGIR LE VOISIN, ET JAMAIS LUI-MÊME. Trois
  # fois en une soirée le 2026-09-19 : `role_token_unavailable` dans la chaîne du pilote,
  # `forge_auth_malformed` dans WorktreeSync. `test_helper.exs` le disait en prose ; ceci le tient.
  describe "tests.async_no_global_env — l'env de l'application est GLOBAL" do
    defp temoins_root!(nom, fichiers) do
      root = Fleet.TestEnv.tmp_path("async-env-#{nom}")
      File.mkdir_p!(Path.join(root, "test"))

      for {rel, corps} <- fichiers do
        chemin = Path.join([root, "test", rel])
        File.mkdir_p!(Path.dirname(chemin))
        File.write!(chemin, corps)
      end

      on_exit(fn -> File.rm_rf(root) end)
      root
    end

    defp module_async(corps),
      do: "defmodule A do\n  use ExUnit.Case, async: true\n#{corps}end\n"

    defp module_serial(corps),
      do: "defmodule B do\n  use ExUnit.Case, async: false\n#{corps}end\n"

    test "async et sans clef globale → pass" do
      root =
        temoins_root!("ok", [
          {"a_test.exs", module_async("  test \"x\" do\n    assert 1 == 1\n  end\n")}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :pass
      assert result.evidence == []
    end

    test "async ET Application.put_env(:lcars_fleet, …) → fail qui nomme le fichier et la ligne" do
      root =
        temoins_root!("coupable", [
          {"a_test.exs",
           module_async("  setup do\n    Application.put_env(:lcars_fleet, :x, 1)\n  end\n")}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "a_test.exs:4"))
    end

    test "la MÊME mutation dans un module serial → pass (c'est la fenêtre qui nuit)" do
      root =
        temoins_root!("serial", [
          {"a_test.exs", module_async("  test \"x\" do\n    assert 1 == 1\n  end\n")},
          {"b_test.exs",
           module_serial("  setup do\n    Application.put_env(:lcars_fleet, :x, 1)\n  end\n")}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    test "la couture de test compte aussi : TestEnv.put_env_restoring est une mutation" do
      root =
        temoins_root!("testenv", [
          {"a_test.exs",
           module_async("  setup do\n    TestEnv.put_env_restoring(:lcars_fleet, :x, 1)\n  end\n")}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "a_test.exs:4"))
    end

    test "la mutation en COMMENTAIRE n'en est pas une" do
      root =
        temoins_root!("commentaire", [
          {"a_test.exs",
           module_async(
             "  # jadis : Application.put_env(:lcars_fleet, :x, 1)\n  test \"x\" do\n    assert 1 == 1\n  end\n"
           )}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    test "aucun témoin lu → INSTRUMENT BROKEN" do
      root = temoins_root!("vide", [])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end

    test "des témoins mais AUCUN async → INSTRUMENT BROKEN, le lecteur a perdu la forme" do
      root =
        temoins_root!("forme", [
          {"b_test.exs", module_serial("  test \"x\" do\n    assert 1 == 1\n  end\n")}
        ])

      result = Tests.check_async_no_global_env(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "lost the form"))
    end
  end

  # Use a directory as the unreadable target (:eisdir): unlike chmod 000, it also fails as root.
  describe "residue_check — un mur ne rend pas compte d'un fichier qu'il n'a pas lu" do
    setup do
      root = Fleet.TestEnv.tmp_path("jg088")
      File.mkdir_p!(Path.join([root, "lib", "fleet"]))
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, target: Path.join([root, "lib", "fleet", "sp_builder.ex"])}
    end

    test "cible ABSENTE → fail nomme (temoin : la garde d'origine tient toujours)", %{root: root} do
      result = Runtime.check_capprofile_lifetime_scope_path(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "MISSING(enoent)"))
    end

    test "cible ILLISIBLE → fail, pas un vert", %{root: root, target: target} do
      File.mkdir_p!(target)

      result = Runtime.check_capprofile_lifetime_scope_path(root)

      assert result.status == :fail,
             "un contrat a declare l'absence de residu sur un fichier qu'il n'a pas pu lire " <>
               "(rendu #{result.status})"

      assert Enum.any?(result.evidence, &(&1 =~ "MISSING(eisdir)"))
    end

    test "cible LISIBLE et sans residu → pass (la garde n'a pas rendu le contrat impossible)", %{
      root: root,
      target: target
    } do
      File.write!(target, """
      defmodule Fleet.SPBuilder do
        def compose_claude_md(cap_profile) do
          get_in(cap_profile.spec, ["invocation", "lifetime_scope"])
        end
      end
      """)

      result = Runtime.check_capprofile_lifetime_scope_path(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    # grep_lines must raise on read errors; returning no matches would conceal unmeasured files.
    test "grep_lines : illisible ≠ zero ligne — l'instrument refuse de repondre", %{
      root: root,
      target: target
    } do
      File.mkdir_p!(target)

      assert_raise RuntimeError, ~r/INSTRUMENT BROKEN/, fn ->
        Support.code_match?(
          root,
          "lib/fleet/sp_builder.ex",
          ~r/anything/
        )
      end
    end

    test "grep_lines : ABSENT rend toujours [] — l'appelant modelise ce cas lui-meme", %{
      root: root
    } do
      refute Support.code_match?(
               root,
               "lib/fleet/nowhere.ex",
               ~r/anything/
             )
    end
  end

  # Nested modules must be scanned without inheriting documentation from a parent's homonym.
  describe "docs.public_functions_documented — les modules imbriques sont dans la population" do
    setup do
      root = Fleet.TestEnv.tmp_path("jg090")
      File.mkdir_p!(Path.join([root, "lib", "fleet"]))
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, src: Path.join([root, "lib", "fleet", "nested.ex"])}
    end

    test "fonction publique NON documentee dans un module imbrique → fail nomme", %{
      root: root,
      src: src
    } do
      File.write!(src, """
      defmodule Fleet.Outer do
        @moduledoc "outer"

        defmodule Inner do
          @moduledoc "inner"

          def undocumented_here(x), do: x
        end

        @doc "documented"
        def top_level(x), do: x
      end
      """)

      result = Types.check_public_functions_documented(root)

      assert result.status == :fail
      assert result.evidence == ["lib/fleet/nested.ex: Inner.undocumented_here"]
    end

    test "un homonyme documente dans le module parent ne couvre pas celui du module imbrique", %{
      root: root,
      src: src
    } do
      File.write!(src, """
      defmodule Fleet.Outer do
        @moduledoc "outer"

        defmodule Inner do
          @moduledoc "inner"

          def same_name(x), do: x
        end

        @doc "documented"
        def same_name(x), do: x
      end
      """)

      result = Types.check_public_functions_documented(root)

      assert result.status == :fail,
             "la doc du parent a couvert l'homonyme imbrique (rendu #{result.status})"

      assert result.evidence == ["lib/fleet/nested.ex: Inner.same_name"]
    end

    test "documentee dans le module imbrique → pass ; un @doc ne franchit pas un defmodule", %{
      root: root,
      src: src
    } do
      File.write!(src, """
      defmodule Fleet.Outer do
        @moduledoc "outer"

        defmodule Inner do
          @moduledoc "inner"

          @doc "the nested contract"
          def documented_here(x), do: x
        end
      end
      """)

      assert Types.check_public_functions_documented(root).status ==
               :pass

      File.write!(src, """
      defmodule Fleet.Outer do
        @moduledoc "outer"

        @doc "this belongs to nothing below a defmodule"
        defmodule Inner do
          @moduledoc "inner"

          def leaked(x), do: x
        end
      end
      """)

      result = Types.check_public_functions_documented(root)
      assert result.status == :fail
      assert result.evidence == ["lib/fleet/nested.ex: Inner.leaked"]
    end
  end

  # Include extensionless and nonstandard source suffixes in the scanned directories.
  describe "vocab.sanctuary_contained — la population, c'est le repertoire, pas trois suffixes" do
    setup do
      root = Fleet.TestEnv.tmp_path("jg085")
      File.mkdir_p!(Path.join(root, "bin"))
      File.mkdir_p!(Path.join([root, "lib", "fleet"]))
      File.mkdir_p!(Path.join(root, "etc"))

      # Keep the population nonempty so a failure identifies the residue, not the empty-tree guard.
      File.write!(Path.join([root, "lib", "fleet", "ok.ex"]), "defmodule Ok do\nend\n")
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    test "un porteur a extension non-source est vu — c'est le fichier qui compte, pas son suffixe",
         %{root: root} do
      File.write!(
        Path.join([root, "bin", "launcher.egress"]),
        "# the sanctuary is vendor-aware\n"
      )

      result = Artifact.check_sanctuary_contained(root)

      assert result.status == :fail, "un porteur a echappe par son extension"
      assert result.evidence == ["bin/launcher.egress"]
    end

    test "un lanceur SANS extension est vu aussi", %{root: root} do
      File.write!(Path.join([root, "bin", "fleet"]), "#!/bin/sh\n# le sanctuaire du pod\n")

      result = Artifact.check_sanctuary_contained(root)

      assert result.status == :fail
      assert result.evidence == ["bin/fleet"]
    end

    # Non-UTF-8 build artifacts must not reach the regex.
    test "un fichier non-texte ne fait ni echouer ni planter le mur", %{root: root} do
      File.write!(Path.join([root, "bin", "bytecode.pyc"]), <<0xC3, 0x28, 0xA0, 0xA1, 0x00>>)

      result = Artifact.check_sanctuary_contained(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    test "INVERSE TWIN — un fichier de la liste blanche reste silencieux", %{root: root} do
      File.mkdir_p!(Path.join([root, "lib", "fleet", "cap_profile"]))

      File.write!(
        Path.join([root, "lib", "fleet", "cap_profile", "invariants.ex"]),
        "# sanctuary, et l'anticorps juste a cote\n"
      )

      assert Artifact.check_sanctuary_contained(root).status ==
               :pass
    end

    test "la note dit COMBIEN de fichiers ont gagne le vert", %{root: root} do
      note = Artifact.check_sanctuary_contained(root).note

      assert note =~ "1 fichier(s) de lib/, bin/ et etc/ balayes"
      assert note =~ "corpus SP"
    end
  end

  # Check both container and provision declarations: provisioning serves wsl/linux as well.
  # Fixtures compare source text; they do not create directories or validate ownership/modes.
  describe "layout.face_roots_provisioned — DEUX miroirs, et chacun doit tenir" do
    setup do
      base = Fleet.TestEnv.tmp_path("jg070")
      root = Path.join(base, "fleet")
      File.mkdir_p!(Path.join([root, "lib", "fleet"]))
      File.mkdir_p!(Path.join([root, "services", "container"]))
      File.mkdir_p!(Path.join([base, "deploy", "modules.d"]))

      File.write!(Path.join([root, "lib", "fleet", "layout.ex"]), """
      defmodule Fleet.Layout do
        @code_root "/home/projects"
        @ops_root "/home/projects.ops"
        def face_root("code"), do: @code_root
        def face_root("ops"), do: @ops_root
      end
      """)

      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    # 25-directories lists paths only; modes and owners live in deploy/system.manifest.
    defp write_mirrors!(root, entrypoint_zones, module_zones, manifest_rows \\ nil) do
      File.write!(
        Path.join([root, "services", "container", "init.sh"]),
        "install -d -m 2775 -g fleet #{Enum.join(entrypoint_zones, " ")}\n"
      )

      rows = Enum.map_join(module_zones, " \\\n", &~s|    "$(prov_decor #{&1})"|)

      File.write!(Path.join([root, "..", "deploy", "modules.d", "25-directories.sh"]), """
      prov_dirs() {
        printf '%s\\n' \\
          "$PROV_ROOT" \\
          "$(prov_decor '/run/lcars/console/<human>')" \\
      #{rows}
      }
      """)

      manifest_rows =
        manifest_rows ||
          Enum.map(
            Enum.uniq(entrypoint_zones ++ module_zones),
            &"dir       #{&1}                               2775  root:fleet          any"
          )

      File.write!(Path.join([root, "..", "deploy", "system.manifest"]), """
      # <classe>[:<trait>]  <objet>  <mode>  <propriétaire>  <substrat>
      dir       /opt/lcars                                   0755  root:root           any
      #{Enum.join(manifest_rows, "\n")}
      """)
    end

    test "les deux miroirs complets, déclarés 2775 root:fleet → pass", %{root: root} do
      zones = ["/home/projects", "/home/projects.ops"]
      write_mirrors!(root, zones, zones)

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end

    test "une racine de face déclarée avec un mode faux, ou sans ligne, dans le manifeste → fail",
         %{
           root: root
         } do
      zones = ["/home/projects", "/home/projects.ops"]

      write_mirrors!(root, zones, zones, [
        "dir       /home/projects      0755  root:fleet   any",
        "dir       /home/projects.ops  2775  root:root    any"
      ])

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :fail

      assert result.evidence == [
               "/home/projects: 0755 root:fleet dans deploy/system.manifest, attendu 2775 root:fleet",
               "/home/projects.ops: 2775 root:root dans deploy/system.manifest, attendu 2775 root:fleet"
             ]

      write_mirrors!(root, zones, zones, ["dir       /home/projects  2775  root:fleet  any"])

      assert Catalogue.check_face_roots_provisioned(root).evidence == [
               "/home/projects.ops: aucune ligne dir dans deploy/system.manifest"
             ]
    end

    test "manifeste sans ligne dir lisible → fail-closed", %{root: root} do
      zones = ["/home/projects", "/home/projects.ops"]
      write_mirrors!(root, zones, zones)
      File.write!(Path.join([root, "..", "deploy", "system.manifest"]), "# vide\n")

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :fail
      assert result.note =~ "deploy/system.manifest has no readable `dir` row"
    end

    test "face absente du MODULE provision → fail nommant wsl et linux", %{root: root} do
      write_mirrors!(root, ["/home/projects", "/home/projects.ops"], ["/home/projects"])

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :fail,
             "une face absente du seul createur commun aux trois substrats est passee au vert"

      assert result.evidence == [
               "/home/projects.ops: absent du module provision (donc absent sur wsl et linux)"
             ]
    end

    test "face citée hors de prov_dirs() → fail : seul le corps de la liste pose une zone", %{
      root: root
    } do
      write_mirrors!(root, ["/home/projects", "/home/projects.ops"], ["/home/projects"])

      zone_elsewhere = """
      prov_runtime_dirs() {
        printf '%s\\n' \\
          "$(prov_decor /home/projects.ops)"
      }
      """

      File.write!(
        Path.join([root, "..", "deploy", "modules.d", "25-directories.sh"]),
        zone_elsewhere,
        [:append]
      )

      assert Catalogue.check_face_roots_provisioned(root).evidence == [
               "/home/projects.ops: absent du module provision (donc absent sur wsl et linux)"
             ]
    end

    test "face absente de container/init.sh → fail, l'ancien mur tient toujours", %{root: root} do
      write_mirrors!(root, ["/home/projects"], ["/home/projects", "/home/projects.ops"])

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :fail
      assert result.evidence == ["/home/projects.ops: absent de container/init.sh (conteneur)"]
    end

    test "table du module illisible → fail-closed, jamais un vert sur rien", %{root: root} do
      write_mirrors!(root, ["/home/projects", "/home/projects.ops"], [])
      File.write!(Path.join([root, "..", "deploy", "modules.d", "25-directories.sh"]), "# vide\n")

      result = Catalogue.check_face_roots_provisioned(root)

      assert result.status == :fail
      assert result.note =~ "unreadable"
      assert result.note =~ "container/init.sh only covers the container volumes"
    end
  end

  # An empty event registry permits emission; catalogue loading must precede child setup.
  # These fixtures check textual ordering, not execution of the supervision tree.
  describe "boot.event_registry_before_children — l'ordre qui rend le defaut permissif sur" do
    setup do
      root = Fleet.TestEnv.tmp_path("jg009")
      File.mkdir_p!(Path.join([root, "lib", "fleet", "event_router"]))
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, src: Path.join([root, "lib", "fleet", "event_router", "application.ex"])}
    end

    test "load!/0 AVANT la liste des enfants → pass", %{root: root, src: src} do
      File.write!(src, """
      def init(_arg) do
        Fleet.EventRouter.Catalog.load!()
        children = base_children()
        Supervisor.init(children, strategy: :one_for_one)
      end
      """)

      assert Boot.check_event_registry_loaded_before_children(root).status ==
               :pass
    end

    test "load!/0 APRES la liste des enfants → fail, avec les deux offsets", %{
      root: root,
      src: src
    } do
      File.write!(src, """
      def init(_arg) do
        children = base_children()
        Fleet.EventRouter.Catalog.load!()
        Supervisor.init(children, strategy: :one_for_one)
      end
      """)

      result =
        Boot.check_event_registry_loaded_before_children(root)

      assert result.status == :fail,
             "la fenetre permissive a ete elargie a tout le boot sans que rien ne rougisse"

      assert hd(result.evidence) =~ "Catalog.load!="
    end

    test "l'appel disparu → fail-closed, jamais un vert sur une absence", %{root: root, src: src} do
      File.write!(src, """
      def init(_arg) do
        children = base_children()
        Supervisor.init(children, strategy: :one_for_one)
      end
      """)

      result =
        Boot.check_event_registry_loaded_before_children(root)

      assert result.status == :fail
      assert hd(result.evidence) =~ "fail-closed"
    end
  end

  test "run_checks passes on the real repo + all checks green (hollow-green guards without false-red)" do
    assert {:pass, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()

    ids = Enum.map(checks, & &1.id)

    assert "events.handlers.exist" in ids
    # Boundary now checks module layering; boot.order_f8 checks root-child ordering.
    assert "boot.order_f8" in ids

    fails = Enum.filter(checks, &(&1.status != :pass))
    assert fails == [], "non-green checks: #{inspect(Enum.map(fails, &{&1.id, &1.evidence}))}"
  end

  # Runtime-only artifacts omit deploy; sibling-list checks must report their reduced scope.
  test "sibling-tree lists: checked when the trees are here, SKIPPED-and-NAMED when they are not" do
    {status, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()
    lock = Enum.find(checks, &(&1.id == "roles.provisioning_locked"))

    failed = Enum.filter(checks, &(&1.status != :pass))

    assert status == :pass,
           "run_checks a rendu #{status}. Checks non-pass : " <>
             Enum.map_join(failed, " · ", fn c ->
               "#{c.id}=#{c.status} (#{String.slice(to_string(c.note || "—"), 0, 120)})"
             end)

    assert lock.status == :pass

    # Derive deploy as runtime's sibling, or check and test can agree on the same wrong topology.
    runtime_root = Path.expand("../..", __DIR__)

    if File.dir?(Path.expand("../deploy", runtime_root)) do
      refute lock.note =~ "NOT CHECKED"
    else
      assert lock.note =~ "NOT CHECKED"
      assert lock.note =~ "forge.tf"
    end
  end

  # A symlink to the real runtime under a new parent exercises the no-deploy branch on any checkout.
  describe "tree_scope — un arbre SANS deploy/ passe en NOMMANT ce qu'il ne verifie pas (DI-09)" do
    setup do
      base = Fleet.TestEnv.tmp_path("di09-sans-deploy")
      File.rm_rf(base)
      File.mkdir_p!(base)
      root = Path.join(base, "fleet")
      File.ln_s!(Path.expand("../..", __DIR__), root)
      on_exit(fn -> File.rm_rf(base) end)
      refute File.dir?(Path.join(base, "deploy"))
      {:ok, root: root}
    end

    test "roles.provisioning_locked : pass, et la note nomme la liste non lue", %{root: root} do
      r = Catalogue.check_roles_provisioning_locked(root)
      assert r.status == :pass, "status=#{r.status} note=#{inspect(r.note)}"
      assert to_string(r.note) =~ "NOT CHECKED"
    end

    test "layout.face_roots_provisioned : pass, et la note dit que deploy/ est absent", %{
      root: root
    } do
      r = Catalogue.check_face_roots_provisioned(root)
      assert r.status == :pass, "status=#{r.status} note=#{inspect(r.note)}"
      assert to_string(r.note) =~ "NOT CHECKED"
    end

    test "layout.private_dir_single_source et catalogue roots : pass sans le miroir installeur",
         %{root: root} do
      for fun <- [:check_private_dir_single_source, :check_catalogue_roots_single_source] do
        r = apply(Mix.Tasks.Lcars.Contracts.Check.SingleSource, fun, [root])

        assert r.status == :pass,
               "#{fun}: status=#{r.status} note=#{inspect(r.note)} evidence=#{inspect(r.evidence)}"
      end
    end
  end

  describe "code_match?/4 — anti-hollow-green: a marker in PROSE does not count (BND-111)" do
    @tag :tmp_dir
    test "a marker present ONLY in a @moduledoc/@doc → false (no false-green)", %{
      tmp_dir: tmp
    } do
      # Documentation of a guard's tuple must not satisfy the check after the guard is removed.
      File.write!(Path.join(tmp, "prose_only.ex"), """
      defmodule ProseOnly do
        @moduledoc \"\"\"
        Returns:
          * `{:error, :brief_required}` — one-shot pod without a brief
        \"\"\"

        @doc \"\"\"
        Otherwise `{:error, :brief_required}`.
        \"\"\"
        def spawn_pod(_), do: :ok
      end
      """)

      refute Support.code_match?(
               tmp,
               "prose_only.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*\{:error, :brief_required\}/
               ]
             ),
             "a tuple present only in @moduledoc/@doc must NOT count as code"
    end

    @tag :tmp_dir
    test "the SAME marker on an EXECUTABLE line → true (the real guard counts)", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "real_guard.ex"), """
      defmodule RealGuard.Doc do
        @moduledoc \"\"\"
        Returns `{:error, :brief_required}` in prose here.
        \"\"\"
      end

      defmodule RealGuard do
        def spawn_pod(opts) do
          if opts[:brief], do: :ok, else: {:error, :brief_required}
        end
      end
      """)

      assert Support.code_match?(
               tmp,
               "real_guard.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*.*\{:error, :brief_required\}/
               ]
             ),
             "the tuple on the guard's executable line must count"
    end
  end

  describe "labels.awaits_arch_clears_in_flight — the wall that makes the registry irrelevant" do
    defp lib_file(tmp, name, body) do
      dir = Path.join([tmp, "lib", "fleet"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name), body)
    end

    defp verdict(tmp),
      do: Runtime.check_awaits_arch_clears_in_flight(tmp)

    @tag :tmp_dir
    test "a writer that sets the brake WITHOUT releasing the lock is named", %{tmp_dir: tmp} do
      # Leaving in-flight behind lets reconciliation reclaim it as orphaned and redispatch the ticket.
      lib_file(tmp, "brake.ex", """
      defmodule Brake do
        def apply(repo, n), do: forge().add_label(repo, n, Fleet.Labels.awaits_arch(), [])
      end
      """)

      v = verdict(tmp)
      assert v.status == :fail
      assert Enum.any?(v.evidence, &(&1 =~ "brake.ex"))
    end

    @tag :tmp_dir
    test "a writer that releases the lock passes — and the note SAYS what it measured", %{
      tmp_dir: tmp
    } do
      lib_file(tmp, "disciplined.ex", """
      defmodule Disciplined do
        def apply(repo, n) do
          forge().add_label(repo, n, @awaits_arch_label, [])
          forge().remove_label(repo, n, @in_flight_label, [])
        end
      end
      """)

      v = verdict(tmp)
      assert v.status == :pass

      assert v.note =~ "1 writer(s) measured"
    end

    @tag :tmp_dir
    test "a file that only READS the label is NOT a writer — the false positive that shipped", %{
      tmp_dir: tmp
    } do
      # A label read plus an unrelated add_label call must not count as a writer.
      lib_file(tmp, "inbox.ex", """
      defmodule Inbox do
        @awaits_arch_label Fleet.Labels.awaits_arch()
        def list(issues), do: Enum.filter(issues, &(@awaits_arch_label in &1.labels))
        def tag(repo, n), do: forge().add_label(repo, n, Fleet.Labels.destination_workshop(), [])
      end
      """)

      v = verdict(tmp)
      assert v.status == :fail
      assert v.note == "population empty"
      assert Enum.any?(v.evidence, &(&1 =~ "no site setting awaits-arch found"))
      refute Enum.any?(v.evidence, &(&1 =~ "sets awaits-arch without clearing"))
    end

    @tag :tmp_dir
    test "delegating to unlock/6 counts as releasing the lock", %{tmp_dir: tmp} do
      # Recognize delegation to unlock, which handles label removal, timing and the event.
      # The check recognizes its call shape without inspecting that implementation.
      lib_file(tmp, "completer.ex", """
      defmodule Completer do
        def apply(repo, n) do
          forge().add_label(repo, n, @awaits_arch_label, [])
          unlock(forge(), repo, n, [], "engineer", :awaiting_arch)
        end
      end
      """)

      assert verdict(tmp).status == :pass
    end
  end

  describe "roles.provisioning_locked hors de son perimetre" do
    @tag :tmp_dir
    test "un arbre SANS `deploy/` : pass, et la note DIT que les placements sont sautes", %{
      tmp_dir: tmp
    } do
      # This minimal artifact exercises the skip path; the assertion permits either verdict
      # and checks only that the task returns and reports the skipped placement defaults.
      root = Path.join(tmp, "sans-deploy")
      File.mkdir_p!(Path.join(root, "priv/catalogue/cap_profile/cap-profiles"))
      File.mkdir_p!(Path.join(root, "priv/catalogue-system/cap_profile/cap-profiles"))

      File.write!(
        Path.join(root, "priv/catalogue/catalogue.yaml"),
        "api_version: 1\nname: fleet\n"
      )

      res = Catalogue.check_roles_provisioning_locked(root)

      assert res.status in [:pass, :fail], "la verification doit RENDRE, pas exploser"

      assert res.note =~ "placement defaults SKIPPED",
             "une couverture bornee qui ne se dit pas se lit comme une couverture complete"
    end
  end
end
