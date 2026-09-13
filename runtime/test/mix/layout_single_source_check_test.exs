defmodule Mix.Tasks.Lcars.Contracts.LayoutSingleSourceCheckTest do
  @moduledoc """
  Synthetic-repository tests for platform, runtime, face and catalogue root checks.
  Layout declarations live under runtime; sibling deploy fixtures exercise scoped
  mirrors. Named exemptions, prefix boundaries and composed authorities are tested.

  The authority files themselves enter corpus scans, so their path literals can
  satisfy occurrence guards without any independent consumer using them.
  The tests inspect sources; they do not create a deployed filesystem.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource

  # Literal attributes end their lines; composed values are tested separately.
  @layout """
  defmodule Fleet.Layout do
    @code_root "/home/projects"
    @ops_root "/home/projects.ops"
    @workshop_root "/home/projects.workshop"
    @platform_root "/opt/lcars"
    @catalogues_dirname "catalogues"
    @installed_catalogues_root "/opt/lcars/var/catalogues"
    @runtime_root "/run/lcars"

    def face_root("code"), do: @code_root
    def face_root("workshop"), do: @workshop_root
    def face_root("ops"), do: @ops_root
  end
  """

  # Assemble violating paths at fixture runtime because real-tree scans also inspect test text.
  @racine_opt_intruse "/opt/lcars" <> "2"
  @racine_run_intruse "/run/" <> "old-lcars"
  @racine_run_prefixe "/run/lcars" <> "x"

  defp depot(opts) do
    root = Fleet.TestEnv.tmp_path("layout_verrous")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "lib/fleet"))
    File.mkdir_p!(Path.join(root, "deploy/lib"))

    File.write!(
      Path.join(runtime, "lib/fleet/layout.ex"),
      Keyword.get(opts, :layout, @layout)
    )

    for {rel, contenu} <- Keyword.get(opts, :fichiers, []) do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  describe "layout.platform_root_single_source — une seconde racine sous /opt" do
    test "une racine LCARS inconnue est nommee" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "PREFIX=/opt/lcars\n"},
            {"runtime/services/x.sh", "AUTRE=#{@racine_opt_intruse}/var\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_platform_root_single_source(root)
      assert @racine_opt_intruse in ev
    end

    test "les racines ETRANGERES declarees passent, et les chaines VERSIONNEES aussi" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "PREFIX=/opt/lcars\n"},
            {"runtime/Dockerfile",
             "COPY x /opt/homebrew/bin\nENV P=/opt/bin:/opt/skills\n" <>
               "RUN ln -s /opt/elixir-1.18.4 /opt/node-20\nEXEC /opt/claude_launch\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_platform_root_single_source(root)
    end

    test "⚠ LE GARDE D'INSTRUMENT EST INATTEIGNABLE DEPUIS UN ARBRE BIEN FORME, et c'est mesure" do
      # Layout's own literal satisfies the occurrence guard even with no other path-bearing file.
      root = depot(fichiers: [{"runtime/bin/lcars", "rien du tout\n"}])

      assert %{status: :pass, note: note} = SingleSource.check_platform_root_single_source(root)
      assert note =~ "1 files carry a /opt path"
    end

    test "une autorite COMPOSEE rend le verrou illisible — pas un prefixe tronque" do
      root =
        depot(
          layout:
            String.replace(
              @layout,
              "@platform_root \"/opt/lcars\"",
              "@platform_root \"/opt/\" <> \"lcars\""
            ),
          fichiers: [{"runtime/bin/lcars", "PREFIX=/opt/lcars\n"}]
        )

      assert %{status: :fail} = SingleSource.check_platform_root_single_source(root)
    end
  end

  describe "layout.runtime_root_single_source — une socket ecrite la ou personne n'ecoute" do
    test "un second arbre /run qui nomme lcars est nomme" do
      # A hyphen suffix is allowed for flat siblings, so the rejected root must differ before it.
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars", "SOCK=/run/lcars/mcp.sock\n"},
            {"runtime/services/x.sh", "AUTRE=#{@racine_run_intruse}/egress.sock\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_runtime_root_single_source(root)
      assert Enum.any?(ev, &(&1 =~ @racine_run_intruse))
    end

    test "les freres plats du meme arbre passent — `-` et `.` sont des frontieres" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nRC=/run/lcars-provision.rc\nPID=/run/lcars.pid\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_runtime_root_single_source(root)
    end

    test "⚠ UN PREFIXE N'EST PAS UNE APPARTENANCE — l'autorite suivie d'une lettre est un autre arbre" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nPIEGE=#{@racine_run_prefixe}/mcp.sock\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_runtime_root_single_source(root)
      assert Enum.any?(ev, &(&1 =~ @racine_run_prefixe))
    end

    test "`/run` du systeme n'est pas accuse — la machine hote n'est pas notre corpus" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "SOCK=/run/lcars/mcp.sock\nXDG=/run/user/1000\nSD=/run/systemd/system\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_runtime_root_single_source(root)
    end
  end

  describe "layout.face_roots_single_source — un arbre que la declaration ne connait pas" do
    test "une quatrieme racine /home/projects est nommee" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "C=/home/projects\nW=/home/projects.workshop\nO=/home/projects.ops\n"},
            {"runtime/services/x.sh", "X=/home/projects.archive\n"}
          ]
        )

      assert %{status: :fail, evidence: ev} = SingleSource.check_face_roots_single_source(root)
      assert "/home/projects.archive" in ev
    end

    test "les trois faces et l'arbre HORS FACE declare passent" do
      root =
        depot(
          fichiers: [
            {"runtime/bin/lcars",
             "C=/home/projects\nW=/home/projects.workshop\nO=/home/projects.ops\n" <>
               "T=/home/projects.work\n"}
          ]
        )

      assert %{status: :pass, evidence: []} = SingleSource.check_face_roots_single_source(root)
    end

    test "⚠ MOINS DE TROIS CLAUSES `face_root/1` → rien n'a ete compare, et le mur le DIT" do
      sans_ops = String.replace(@layout, "  def face_root(\"ops\"), do: @ops_root\n", "")

      root =
        depot(
          layout: sans_ops,
          fichiers: [{"runtime/bin/lcars", "C=/home/projects\nW=/home/projects.workshop\n"}]
        )

      assert %{status: :fail, note: note} = SingleSource.check_face_roots_single_source(root)
      assert note =~ "nothing was compared"
    end

    test "⚠ ICI AUSSI le garde d'instrument est inatteignable depuis un arbre bien forme" do
      # Declared roots occur in Layout itself; missing declarations are tested separately.
      root = depot(fichiers: [{"runtime/bin/lcars", "C=/home/projects\n"}])

      assert %{status: :pass, note: note} = SingleSource.check_face_roots_single_source(root)
      assert note =~ "3 faces declared"
    end
  end

  describe "layout.catalogue_roots_single_source — la fleet lit ou l'image n'a jamais ecrit" do
    # Include both source creators and readers of the two catalogue roots.
    defp miroirs(shipped, installed) do
      [
        {"runtime/bin/lcars",
         "CAT_SHIPPED=\"${LCARS_CATALOGUES_SHIPPED:-#{shipped}}\"\n" <>
           "CAT_DIR=\"${LCARS_CATALOGUES_DIR:-#{installed}}\"\n"},
        {"runtime/services/forge-gestures.sh",
         "D=\"${LCARS_DEMO_CATALOGUE:-#{shipped}/web-demo}\"\n" <>
           "I=\"${LCARS_CATALOGUES_DIR:-#{installed}}\"\n"},
        {"deploy/system.manifest", "dir #{installed} 0755 root root\n"},
        {"deploy/lib/provision-lib.sh", ": \"${PROV_CATALOGUES_DIR:=#{installed}}\"\n"}
      ]
    end

    test "les six miroirs d'accord → vert, et la preuve NOMME les fichiers lus" do
      root = depot(fichiers: miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues"))

      assert %{status: :pass, evidence: ev, note: note} =
               SingleSource.check_catalogue_roots_single_source(root)

      # Le mur porte sa preuve meme au vert : les six miroirs vivent dans quatre arbres, dont deux
      # hors artefact — « vert » sans la liste ne dirait pas COMBIEN ont ete lus.
      assert Enum.any?(ev, &(&1 =~ "system.manifest"))
      assert Enum.any?(ev, &(&1 =~ "bin/lcars"))
      assert note =~ "6 checked copies"
    end

    test "⚠ LE CREATEUR QUI DERIVE — une ligne de manifeste qui ne suit pas l'autorite est nommee" do
      # LE MIROIR QUI COMPTE LE PLUS : si le manifeste cree l'arbre installe ailleurs, la forge
      # restaure dans un arbre que la fleet ne lit pas.
      fichiers =
        miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues")
        |> Keyword.new(fn {k, v} -> {String.to_atom(k), v} end)
        |> Keyword.put(:"deploy/system.manifest", "dir /opt/lcars/ailleurs 0755 root root\n")
        |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)

      root = depot(fichiers: fichiers)

      assert %{status: :fail, evidence: ev} =
               SingleSource.check_catalogue_roots_single_source(root)

      assert Enum.any?(ev, &(&1 =~ "system.manifest"))
    end

    test "une autorite illisible fait ECHOUER, elle ne fait pas « rien a comparer »" do
      root =
        depot(
          layout:
            String.replace(
              @layout,
              "@catalogues_dirname \"catalogues\"",
              "@catalogues_dirname @nom"
            ),
          fichiers: miroirs("/opt/lcars/catalogues", "/opt/lcars/var/catalogues")
        )

      assert %{status: :fail, note: note} =
               SingleSource.check_catalogue_roots_single_source(root)

      assert note =~ "nothing was compared"
    end
  end
end
