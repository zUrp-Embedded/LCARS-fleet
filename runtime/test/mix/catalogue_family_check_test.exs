defmodule Mix.Tasks.Lcars.Contracts.CatalogueFamilyCheckTest do
  @moduledoc """
  Les quatre murs de la famille `catalogue`, prouves contre des arbres FABRIQUES.

  `roles.role_index_unique`, `skills.declared_present`, `sp.adresser_un_agent`,
  `catalogue.install_paths_locked`.

  ## Ce que garde cette famille

  Le code porte la mecanique, le metier est une donnee de catalogue. Ces murs sont donc les seuls
  controles mecaniques sur des faits qui vivent en YAML, hors de portee du compilateur, de dialyzer
  et de boundary — et deux d'entre eux gardent une propriete que le systeme paie CHER si elle
  glisse : un slot `role_index` est une classe de kill (`pkill` atteint les deux roles qui le
  partagent), et un bundle de prose absent des cartes donne aux pods un nom qui ne compose rien.
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

  # La prose du bundle : sa source unique. Sans elle, le mur `sp.adresser_un_agent` s'arrete avant
  # de regarder les cartes — un nom sans prose ne compose rien.
  defp bundle,
    do:
      {"runtime/priv/catalogue-system/cap_profile/modop-bundles/adresser-un-agent/sp.md",
       "# comment adresser un agent\n"}

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "roles.role_index_unique — un slot est une CLASSE DE KILL" do
    test "des index distincts → vert" do
      root = depot([profil("engineer", role_index: 3), profil("scribe", role_index: 5)])

      assert %{status: :pass, evidence: []} = Catalogue.check_roles_role_index_unique(root)
    end

    test "deux cartes sur le meme slot sont nommees, avec les deux noms" do
      # `pkill` sur un slot atteint les DEUX roles qui le partagent : ce n'est pas une collision
      # d'identifiant, c'est un pod tue par la fin de vie d'un autre.
      root = depot([profil("engineer", role_index: 3), profil("scribe", role_index: 3)])

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_roles_role_index_unique(root)
      assert ev =~ "role_index 3"
      assert ev =~ "engineer"
      assert ev =~ "scribe"
    end

    test "⚠ LES DEUX ARBRES SONT LUS — metier ET systeme partagent l'espace des slots" do
      # Scanner le seul arbre metier laisserait une collision entre un role metier et un role
      # mecanique parfaitement invisible, alors que les deux tournent sur la meme machine.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # BND-111 plus une confirmation de forme : le `@doc` du builder nomme le meme atome. Un mur
      # satisfait par la prose atteste la documentation de ce qu'il verifie, et un filtrage
      # silencieux laisserait un pod reclamer une skill qui n'existe pas.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # `incompatible: [adresser-un-agent]` — des chaines au lieu de paires — fait echouer un
      # `is_list(pair)` : chaque element est une chaine, aucun n'est signale, et le mur passerait
      # au VERT sur un profil qui retire pourtant le bundle. Le schema doit refuser cette forme en
      # amont, mais un mur qui ne tient que si un AUTRE controle a fait son travail ne tient rien.
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
      # Toutes les cartes peuvent nommer le bundle : si sa prose n'existe pas, les pods recoivent
      # un nom qui ne compose rien. Le defaut est en amont des cartes, et le message le dit.
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

  # ══════════════════════════════════════════════════════════════════════════════════════════════
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
      # Provisionner un dossier que le runtime ne lit pas rapporte tous les catalogues installes et
      # n'en sert aucun. Le miroir `deploy/` est la moitie qui CREE, celle du CLI celle qui LIT.
      root = depot(installe(@dir, @shipped, "/opt/lcars/autre"))

      assert %{status: :fail, evidence: [ev]} = Catalogue.check_catalogue_paths_locked(root)
      assert ev =~ "PROV_CATALOGUES_DIR"
      assert ev =~ "provision-lib.sh"
    end

    test "⚠ UN DEFAUT SHELL ABSENT SE DISTINGUE D'UN DEFAUT QUI A DERIVE" do
      # Deux pannes opposees : « cette moitie ne porte plus le chemin » et « elle en porte un
      # autre ». Les confondre enverrait le lecteur chercher une divergence de valeur la ou il n'y
      # a plus de valeur du tout.
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
