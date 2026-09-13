defmodule Mix.Tasks.Lcars.Contracts.CatalogueFamilyCheckTest do
  @moduledoc """
  Synthetic-tree tests for role-index collisions, skill-error source shape,
  required addressing bundles and catalogue path defaults.

  The checks inspect source/YAML fixtures; they do not exercise pod termination,
  prompt composition or provisioning on a machine.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue

  defp depot(fichiers) do
    root = Fleet.TestEnv.tmp_path("murs_catalogue")
    on_exit(fn -> File.rm_rf!(root) end)

    runtime = Path.join(root, "runtime")
    File.mkdir_p!(Path.join(runtime, "priv/catalogue/cap_profile/cap-profiles"))
    File.mkdir_p!(Path.join(runtime, "priv/catalogue-system/cap_profile/cap-profiles"))
    File.mkdir_p!(Path.join(root, "deploy/lib"))

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    runtime
  end

  defp profil(nom, opts) do
    idx = Keyword.get(opts, :role_index)
    modops = Keyword.get(opts, :default, ["adresser-un-agent"])
    incompat = Keyword.get(opts, :incompatible)
    arbre = Keyword.get(opts, :arbre, "catalogue")

    yaml =
      "kind: #{Keyword.get(opts, :kind, "CapabilityProfile")}\n" <>
        "metadata:\n  name: #{nom}\n" <>
        if(idx, do: "  role_index: #{idx}\n", else: "") <>
        "spec:\n  modop_set:\n" <>
        "    default:\n" <>
        Enum.map_join(modops, "", &"      - #{&1}\n") <>
        if(incompat, do: "    incompatible:\n#{incompat}", else: "")

    {"runtime/priv/#{arbre}/cap_profile/cap-profiles/#{nom}.yaml", yaml}
  end

  # The bundle-presence check requires a regular file before inspecting profiles.
  defp bundle,
    do:
      {"runtime/priv/catalogue-system/cap_profile/modop-bundles/adresser-un-agent/sp.md",
       "# comment adresser un agent\n"}

  describe "roles.role_index_unique — un slot est une CLASSE DE KILL" do
    test "des index distincts → vert" do
      root = depot([profil("engineer", role_index: 3), profil("scribe", role_index: 5)])

      assert %{status: :pass, evidence: []} = Catalogue.check_roles_role_index_unique(root)
    end

    test "deux cartes sur le meme slot sont nommees, avec les deux noms" do
      root = depot([profil("engineer", role_index: 3), profil("scribe", role_index: 3)])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_roles_role_index_unique(root)
      assert ev =~ "role_index 3"
      assert ev =~ "engineer"
      assert ev =~ "scribe"
    end

    test "⚠ LES DEUX ARBRES SONT LUS — metier ET systeme partagent l'espace des slots" do
      root =
        depot([
          profil("engineer", role_index: 3),
          profil("chief", role_index: 3, arbre: "catalogue-system")
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_roles_role_index_unique(root)
      assert ev =~ "chief"
    end

    test "⚠ AUCUNE CARTE INDEXEE → INSTRUMENT CASSE, jamais « aucun doublon »" do
      root = depot([profil("engineer", [])])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_roles_role_index_unique(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "skills.declared_present — un pod qui reclame une skill inexistante" do
    test "le refus fail-loud present → vert" do
      root =
        depot([
          {"runtime/lib/fleet/sp_builder.ex",
           "defmodule Fleet.SPBuilder do\n  def filter_skills(s, d) do\n" <>
             "    if manquantes(s, d) != [] do\n" <>
             "      {:error, {:skills_missing, manquantes(s, d)}}\n" <>
             "    else\n      {:ok, s}\n    end\n  end\nend\n"}
        ])

      assert %{status: :pass, evidence: []} = Catalogue.check_skills_declared_present(root)
    end

    test "⚠ LE JETON EN PROSE NE SUFFIT PAS — la confirmation exige la FORME du tuple" do
      # A prose mention of the error atom must not satisfy the tuple-shape check.
      root =
        depot([
          {"runtime/lib/fleet/sp_builder.ex",
           "defmodule Fleet.SPBuilder do\n" <>
             "  @doc \"rend :skills_missing si une skill manque\"\n" <>
             "  def filter_skills(s, d), do: {:ok, Enum.filter(s, &(&1 in d))}\nend\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_skills_declared_present(root)
      assert ev =~ "silently filters"
    end
  end

  describe "sp.adresser_un_agent — un nom par carte, une seule source de prose" do
    test "toutes les cartes nomment le bundle → vert" do
      root = depot([bundle(), profil("engineer", []), profil("scribe", [])])

      assert %{status: :pass, evidence: []} = Catalogue.check_sp_adresser_un_agent(root)
    end

    test "une carte qui ne le nomme pas est nommee" do
      root = depot([bundle(), profil("engineer", []), profil("scribe", default: ["autre-chose"])])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_sp_adresser_un_agent(root)
      assert ev =~ "scribe"
      assert ev =~ "absent de modop_set.default"
    end

    test "⚠ L'ENTREE PLATE DANS `incompatible:` EST UNE MALFORMATION, ET ELLE COMPTE" do
      # Exercise malformed flat entries as well as the canonical pair form.
      root =
        depot([
          bundle(),
          profil("engineer", []),
          profil("scribe", incompatible: "      - adresser-un-agent\n")
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_sp_adresser_un_agent(root)
      assert ev =~ "scribe"
      assert ev =~ "incompatible"
    end

    test "la forme canonique en PAIRES est detectee aussi" do
      root =
        depot([
          bundle(),
          profil("engineer", []),
          profil("scribe", incompatible: "      - [adresser-un-agent, autre]\n")
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_sp_adresser_un_agent(root)
      assert ev =~ "scribe"
    end

    test "⚠ LA PROSE ABSENTE ARRETE LE MUR AVANT LES CARTES" do
      root = depot([profil("engineer", []), profil("scribe", [])])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_sp_adresser_un_agent(root)
      assert ev =~ "source introuvable"
    end

    test "un ReservedSeat est hors perimetre — il ne compose aucune prose" do
      root =
        depot([
          bundle(),
          profil("engineer", []),
          profil("vulcan", kind: "ReservedSeat", default: [])
        ])

      assert %{status: :pass, evidence: []} = Catalogue.check_sp_adresser_un_agent(root)
    end
  end

  describe "catalogue.install_paths_locked — provisionner un dossier que le runtime ne lit pas" do
    @layout """
    defmodule Fleet.Layout do
      @platform_root "/opt/lcars"
      @catalogues_dirname "catalogues"
      @installed_catalogues_root "/opt/lcars/var/catalogues"
    end
    """

    defp installe(dir, shipped, prov) do
      [
        {"runtime/lib/fleet/layout.ex", @layout},
        {"runtime/bin/lcars",
         "D=\"${LCARS_CATALOGUES_DIR:-#{dir}}\"\nS=\"${LCARS_CATALOGUES_SHIPPED:-#{shipped}}\"\n"},
        {"deploy/lib/provision-lib.sh", ": \"${PROV_CATALOGUES_DIR:=#{prov}}\"\n"}
      ]
    end

    @dir "/opt/lcars/var/catalogues"
    @shipped "/opt/lcars/catalogues"

    test "les trois faits d'accord → vert" do
      root = depot(installe(@dir, @shipped, @dir))
      assert %{status: :pass, evidence: []} = Catalogue.check_catalogue_paths_locked(root)
    end

    test "le CLI qui a derive est nomme, avec les deux valeurs" do
      root = depot(installe("/opt/lcars/cache", @shipped, @dir))

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_catalogue_paths_locked(root)
      assert ev =~ "LCARS_CATALOGUES_DIR"
      assert ev =~ "/opt/lcars/cache"
    end

    test "⚠ L'INSTALLEUR EST LU AUSSI — c'est LUI qui converge le dossier" do
      root = depot(installe(@dir, @shipped, "/opt/lcars/autre"))

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_catalogue_paths_locked(root)
      assert ev =~ "PROV_CATALOGUES_DIR"
      assert ev =~ "provision-lib.sh"
    end

    test "⚠ UN DEFAUT SHELL ABSENT SE DISTINGUE D'UN DEFAUT QUI A DERIVE" do
      root =
        depot([
          {"runtime/lib/fleet/layout.ex", @layout},
          {"runtime/bin/lcars", "D=\"${LCARS_CATALOGUES_DIR:-#{@dir}}\"\n"},
          {"deploy/lib/provision-lib.sh", ": \"${PROV_CATALOGUES_DIR:=#{@dir}}\"\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_catalogue_paths_locked(root)
      assert ev =~ "no shell default"
      assert ev =~ "LCARS_CATALOGUES_SHIPPED"
    end

    test "⚠ UNE AUTORITE DISPARUE → INSTRUMENT CASSE, jamais un accord" do
      sans = String.replace(@layout, "  @catalogues_dirname \"catalogues\"\n", "")

      root =
        depot([
          {"runtime/lib/fleet/layout.ex", sans},
          {"runtime/bin/lcars",
           "D=\"${LCARS_CATALOGUES_DIR:-#{@dir}}\"\nS=\"${LCARS_CATALOGUES_SHIPPED:-#{@shipped}}\"\n"},
          {"deploy/lib/provision-lib.sh", ": \"${PROV_CATALOGUES_DIR:=#{@dir}}\"\n"}
        ])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_catalogue_paths_locked(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end
end
