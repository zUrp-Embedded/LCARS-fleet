defmodule Fleet.CatalogueTest do
  @moduledoc """
  The catalogue root: one knob brings one catalogue, and the boot refuses a root it cannot vouch for.

  `async: false` — every test here moves `:lcars_fleet, :catalogue_root` (and the image tests write
  `:persistent_term`), both process-global.
  """
  use ExUnit.Case, async: false

  alias Fleet.Catalogue

  @moduletag :tmp_dir

  # A root the accessors can point at. Only the trees a test actually reads are populated; the
  # manifest is always there, because a directory without one is not a catalogue.
  defp fake_root(tmp, api_version \\ 1) do
    root = Path.join(tmp, "catalogue")
    File.mkdir_p!(root)

    # The manifest carries a NAME as well as a generation: a catalogue that does not name itself is
    # refused, so a fixture standing for "a valid catalogue" declares one.
    File.write!(Path.join(root, "catalogue.yaml"), "api_version: #{api_version}\nname: fixture\n")
    root
  end

  describe "the layout" do
    test "every tree derives from the root — one knob moves them all", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      trees = [
        Catalogue.cap_profiles_root(),
        Catalogue.modop_root(),
        Catalogue.subagent_templates_root(),
        Catalogue.monk_registry_root(),
        Catalogue.sp_drafts_root(),
        Catalogue.sp_templates_root(),
        Catalogue.workflow_maps_root(),
        Catalogue.brief_templates_root(),
        Catalogue.project_template_root(),
        Catalogue.skills_root(),
        Catalogue.manifest_path()
      ]

      # The adverse form: not "some tree moved" but "no tree stayed behind". A tree still resolving
      # under the bundled priv IS the skew this module exists to make impossible.
      for tree <- trees do
        assert String.starts_with?(tree, root <> "/"),
               "#{tree} did not follow the catalogue root #{root}"
      end

      assert length(Enum.uniq(trees)) == length(trees), "two trees resolve to the same path"
    end

    test "the bundled default is a real catalogue, manifest included" do
      assert File.dir?(Catalogue.root())
      assert File.regular?(Catalogue.manifest_path())

      for tree <- [
            Catalogue.cap_profiles_root(),
            Catalogue.modop_root(),
            Catalogue.subagent_templates_root(),
            Catalogue.sp_drafts_root(),
            Catalogue.sp_templates_root(),
            Catalogue.workflow_maps_root(),
            Catalogue.brief_templates_root(),
            Catalogue.project_template_root()
          ] do
        assert File.dir?(tree), "bundled catalogue is missing #{tree}"
      end

      # (coord_policies_path est parti avec Fleet.Coord — brouette 2026-08-19.)
    end

    test "a nil root (a cross-test config leak) never reaches Path.join" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, nil)
      assert File.dir?(Catalogue.root())
    end
  end

  describe "fine overrides" do
    test "a per-tree key keeps precedence over the coarse root", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      fine = Path.join(tmp, "just-the-profiles")
      File.mkdir_p!(fine)

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :cap_profile_root_dir, fine)

      assert Fleet.CapProfile.root_dir() == fine
      # …and only that tree: panachage is allowed, silence about it is not.
      assert Fleet.SPBuilder.sp_drafts_root() == Catalogue.sp_drafts_root()
      assert String.starts_with?(Fleet.SPBuilder.sp_drafts_root(), root <> "/")
    end

    test "without a fine key, the domain resolvers read the catalogue root", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      assert Fleet.CapProfile.root_dir() == Catalogue.cap_profiles_root()
      assert Fleet.SPBuilder.sp_drafts_root() == Catalogue.sp_drafts_root()
    end
  end

  describe "search/1 — the N-root door" do
    test "orders the ACTIVE roots then the system default, dropping absent trees", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.mkdir_p!(Path.join(root, Catalogue.rel(:cap_profiles)))
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      path = Catalogue.search(:cap_profiles)

      assert List.first(path) == Path.join(root, Catalogue.rel(:cap_profiles))
      assert List.last(path) == Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))

      # A tree the business root does not ship simply is not in the path — that is what lets the
      # system catalogue carry only what its four roles need.
      refute Path.join(root, Catalogue.rel(:subagent_templates)) in Catalogue.search(
               :subagent_templates
             )
    end

    test "a fine override REPLACES the active list for its tree, and only that tree", %{
      tmp_dir: tmp
    } do
      # The property `Fleet.Test.CatalogueIsolation` rests on: a fixture must not inherit the
      # shipped business roles from behind. Putting the override in FRONT instead of in PLACE would
      # reopen exactly the false green that helper exists to close.
      root = fake_root(tmp)
      File.mkdir_p!(Path.join(root, Catalogue.rel(:cap_profiles)))
      File.mkdir_p!(Path.join(root, Catalogue.rel(:sp_drafts)))
      fine = Path.join(tmp, "just-the-profiles")
      File.mkdir_p!(fine)

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :cap_profile_root_dir, fine)

      assert Catalogue.search(:cap_profiles) == [
               fine,
               Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))
             ]

      refute Path.join(root, Catalogue.rel(:cap_profiles)) in Catalogue.search(:cap_profiles)

      # Untouched tree, untouched path.
      assert List.first(Catalogue.search(:sp_drafts)) ==
               Path.join(root, Catalogue.rel(:sp_drafts))
    end

    test "the system root is never dropped by an override — it is the contract", %{tmp_dir: tmp} do
      fine = Path.join(tmp, "only-mine")
      File.mkdir_p!(fine)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :cap_profile_root_dir, fine)

      assert Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles)) in Catalogue.search(
               :cap_profiles
             )
    end

    test "find_in/2 sur un tree_scope : le fichier du systeme, puis nil — jamais un voisin", %{
      tmp_dir: tmp
    } do
      # La porte qui a REMPLACE `find/2` (l'aplatie, tuee avec la dette `search/1`) : un scope
      # explicite d'UN catalogue + le systeme, et rien d'autre n'y entre par construction.
      root = fake_root(tmp)
      scope = Catalogue.tree_scope(root, :sp_drafts)

      found = Catalogue.find_in(scope, "protocole-user-worker.md")
      assert found && File.regular?(found)
      assert String.starts_with?(found, Catalogue.system_root())

      assert Catalogue.find_in(scope, "agent-nobody-base.md") == nil
    end
  end

  describe "installed — the material is here, or it is not" do
    # The cache lives under the operator's `~/.lcars`, so these tests point the config key at a
    # temporary directory rather than moving HOME. `HOME` is NOT the seam, and trying it is how
    # this was found: `System.user_home!/0` is cached by the VM and keeps answering the boot-time
    # value, so a test moving HOME would silently measure the real `~/.lcars` of whoever ran the
    # suite.
    setup %{tmp_dir: tmp} do
      home = Path.join(tmp, "operator")
      File.mkdir_p!(Path.join(home, "catalogues"))

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [
        Path.join(home, "catalogues")
      ])

      {:ok, home: home}
    end

    # A catalogue is material PLUS a manifest. `install/3` writes both, because that pairing is
    # exactly what `installed_roots/0` tests for.
    defp install(home, name, manifest? \\ true) do
      dir = Path.join([home, "catalogues", name])
      File.mkdir_p!(Path.join(dir, Catalogue.rel(:cap_profiles)))

      if manifest?,
        do: File.write!(Path.join(dir, "catalogue.yaml"), "api_version: 1\nname: #{name}\n")

      dir
    end

    # A minimal, schema-valid card. One step, no jury, CI ignored — the shape `workshop-direct` and
    # `quick-fix` already ship; enough for the loader to accept it and for the image to hold it.
    defp install_card(dir, name) do
      maps = Path.join(dir, Fleet.Catalogue.rel(:workflow_maps))
      File.mkdir_p!(maps)

      File.write!(Path.join(maps, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
        applicable_intensity: [C0]
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: engineer
            needs: []
            inputs:
              - ticket.body
      """)

      dir
    end

    test "publish_image! couvre CHAQUE catalogue installe — pas seulement le premier", %{
      tmp_dir: tmp,
      home: home
    } do
      # LE DEFAUT QUE CE TEST EXISTE POUR EMPECHER DE REVENIR : `publish_image!/0` publiait depuis
      # `workflow_maps_root([])`, c'est-a-dire la PREMIERE racine. Les cartes de tout catalogue
      # suivant existaient sur le disque et dans AUCUNE image — un projet servi par ce
      # catalogue-la ne trouvait pas de carte du tout, et le decouvrait au premier dispatch.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, fake_root(tmp))
      premier = install_card(install(home, "premier"), "carte-une")
      second = install_card(install(home, "second"), "carte-deux")

      on_exit(&Fleet.Workflow.Loader.unpublish_all_images/0)
      :ok = Fleet.Workflow.Loader.publish_image!()

      # Chaque racine porte SON image, et elle ne contient que ses cartes : les catalogues ne
      # fusionnent pas — une carte nomme des roles, et un role appartient au catalogue qui le declare.
      for {dir, attendue, absente} <- [
            {premier, "carte-une", "carte-deux"},
            {second, "carte-deux", "carte-une"}
          ] do
        opts = [workflow_maps_root: Path.join(dir, Fleet.Catalogue.rel(:workflow_maps))]
        assert Fleet.Workflow.Loader.canon_names!(opts) == [attendue]
        # `load!` rend la carte APLATIE (metadata + spec fusionnes), pas l'arbre du YAML.
        assert %{"name" => ^attendue, "steps" => %{"build" => _}} =
                 Fleet.Workflow.Loader.load!(attendue, opts)

        refute absente in Fleet.Workflow.Loader.canon_names!(opts),
               "les cartes ne doivent pas fusionner entre catalogues"
      end
    end

    test "cache vide : le catalogue livre dans le release, seul", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      assert Catalogue.installed_roots() == [root]
    end

    test "LE MATERIEL EST LA, DONC IL EST INSTALLE — plus aucune declaration a tenir", %{
      tmp_dir: tmp,
      home: home
    } do
      # L'INVERSION QUE CE LOT PORTE, EN UNE ASSERTION. Ce meme test affirmait le contraire jusqu'au
      # 2026-08-16 : « un catalogue pose sur le disque est inerte tant qu'une ligne ne le nomme
      # pas ». Cette ligne-la etait un second etat que quelqu'un tenait a la main a cote du premier,
      # et l'ecart entre les deux a tue une flotte au banc — declaree active, jamais installee.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      mobile = install(home, "mobile")

      assert Catalogue.installed_roots() == [root, mobile]
    end

    test "un repertoire SANS manifeste n'est pas un catalogue", %{tmp_dir: tmp, home: home} do
      # Un `git clone` interrompu, un `lost+found`, le repertoire de sauvegarde d'un editeur : sans
      # ce filtre ils entrent dans le roster et font tomber le boot sur une verification que
      # personne n'a demandee.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "moitie-de-clone", false)

      assert Catalogue.installed_roots() == [root]
    end

    test "`fleet` est TOUJOURS present et TOUJOURS en tete", %{tmp_dir: tmp, home: home} do
      # ⚖ user, 2026-08-16 : il est insupprimable PAR CHOIX, pour garantir qu'un catalogue valide
      # existe toujours. C'est une garantie de DISPONIBILITE, pas une autorite — il reste un pair.
      # En tete parce qu'un appelant sans projet en main doit resoudre quelque part, et que le
      # catalogue complet qui marche toujours est le defaut honnete.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "aaa-avant-tout-alphabetiquement")

      assert hd(Catalogue.installed_roots()) == root
    end

    test "l'ordre sous le livre est celui des NOMS — il n'appartient a personne", %{
      tmp_dir: tmp,
      home: home
    } do
      # Il n'y a plus de precedence a arbitrer : chaque catalogue porte SON image, un role et une
      # carte se resolvent dans le leur. Ce qui reste a decider est l'ordre de la liste, et un ordre
      # de systeme de fichiers ferait dependre le defaut d'un appelant sans projet de l'ordre
      # d'installation.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, fake_root(tmp))
      zoulou = install(home, "zoulou")
      mobile = install(home, "mobile")

      assert tl(Catalogue.installed_roots()) == [mobile, zoulou]
    end

    test "un repertoire nomme `fleet` dans le cache ne DOUBLE pas le catalogue livre", %{
      tmp_dir: tmp,
      home: home
    } do
      # Deux entrees sous un meme nom publieraient deux images pour un catalogue, et un lecteur
      # tomberait sur l'une ou l'autre selon la porte empruntee.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "fleet")

      assert Catalogue.installed_roots() == [root]
    end

    test "la grosse molette EST la racine metier, quoi qu'il y ait dans le cache", %{
      tmp_dir: tmp,
      home: home
    } do
      # `root/0` repond a « quel est le catalogue livre », pas a « lequel gagne » : il n'y a plus de
      # gagnant. Les arbres purement metier (cartes, brief templates, project_template) le lisent en
      # direct, et un projet resout dans le sien par sa racine, jamais par ce defaut.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "mobile")

      assert to_string(Catalogue.root()) == root
      assert String.starts_with?(Catalogue.workflow_maps_root(), root <> "/")
      assert String.starts_with?(Catalogue.brief_templates_root(), root <> "/")
      assert String.starts_with?(Catalogue.project_template_root(), root <> "/")
    end

    test "the system catalogue is never in the list, and never dropped", %{
      tmp_dir: tmp,
      home: home
    } do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, fake_root(tmp))
      install(home, "mobile")

      refute Catalogue.system_root() in Catalogue.installed_roots()

      assert List.last(Catalogue.search(:cap_profiles)) ==
               Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))
    end
  end

  describe "verify!" do
    test "the bundled catalogue passes and returns its manifest" do
      assert %{"api_version" => version} = Catalogue.verify!()
      assert version in Catalogue.supported_api_versions()
    end

    test "an absent root is refused, naming the variable to fix", %{tmp_dir: tmp} do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, Path.join(tmp, "nope"))

      assert_raise RuntimeError, ~r/LCARS_CATALOGUE_ROOT/, fn -> Catalogue.verify!() end
    end

    test "a directory without a manifest is not a catalogue", %{tmp_dir: tmp} do
      bare = Path.join(tmp, "bare")
      File.mkdir_p!(bare)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, bare)

      assert_raise RuntimeError, ~r/catalogue\.yaml.*unreadable/s, fn -> Catalogue.verify!() end
    end

    test "a foreign generation is refused, naming BOTH sides", %{tmp_dir: tmp} do
      root = fake_root(tmp, 99)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "99"
      assert err.message =~ inspect(Catalogue.supported_api_versions())
    end

    test "un catalogue qui livre des cartes SANS dire laquelle est son defaut est refuse", %{
      tmp_dir: tmp
    } do
      # Le defaut etait le litteral "brief-gate" dans Fleet.Project.Roles — la carte d'UN catalogue.
      # Tout catalogue livrant les siennes heritait donc en silence d'un defaut nommant une carte
      # qu'il n'a pas. Aucune propriete ne distingue la carte par defaut de ses soeurs : il faut le
      # dire, et le boot le verifie contre les cartes REELLES du catalogue.
      root = fake_root(tmp)
      maps = Path.join(root, Fleet.Catalogue.rel(:workflow_maps))
      File.mkdir_p!(maps)
      File.write!(Path.join(maps, "la-mienne.yaml"), "kind: WorkflowMap\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "declares no `default_card`"
      assert err.message =~ "la-mienne", "il doit NOMMER les cartes disponibles"

      # Et un defaut qui nomme une carte d'un AUTRE catalogue est refuse de la meme facon : c'est
      # exactement l'etat que le litteral produisait.
      File.write!(
        Path.join(root, "catalogue.yaml"),
        "api_version: 1\nname: fixture\ndefault_card: brief-gate\n"
      )

      err2 = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err2.message =~ "not one of its own cards"
    end

    test "a manifest with no NAME is refused — the name is the catalogue's, not its directory's",
         %{
           tmp_dir: tmp
         } do
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "declares no `name`"
      # It must say WHY the directory cannot stand in — that is the whole point of the field.
      assert err.message =~ "not of where it was installed"
    end

    test "a name carrying `_` is refused: it separates the halves of a role login", %{
      tmp_dir: tmp
    } do
      # `Fleet.Slug` admits `_`; a catalogue name may not. `<catalogue>_<role>` is the forge account
      # login, so `a_b_c` would split two ways. The refusal must NAME the underscore, or its author
      # reads it as an arbitrary charset.
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "api_version: 1\nname: my_cat\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      assert Fleet.Slug.valid?("my_cat"), "the premise of this test is that Slug ADMITS it"
      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "my_cat"
      assert err.message =~ "_"
    end

    test "a manifest with no api_version is refused like a foreign one", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "name: mine\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      assert_raise RuntimeError, ~r/api_version nil/, fn -> Catalogue.verify!() end
    end

    test "a manifest that is not a mapping is refused", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "- 1\n- 2\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      assert_raise RuntimeError, ~r/not a mapping/, fn -> Catalogue.verify!() end
    end
  end

  describe "the phase criterion — a catalogue COPY boots identically" do
    # This is the test the whole lot exists for. Two claims, and the second is what makes the first
    # mean anything: a copy of the catalogue produces the SAME proven-good images (nothing is
    # resolved outside the root), and mutating the copy MOVES them (they were really read from it,
    # not from the bundled priv all along).
    test "same content, same image version; changed content, changed version", %{tmp_dir: tmp} do
      on_exit(fn ->
        Fleet.CapProfile.Image.unpublish()
        Fleet.SPBuilder.Image.unpublish()
      end)

      Fleet.CapProfile.Image.publish!()
      Fleet.SPBuilder.Image.publish!()
      bundled_caps = Fleet.CapProfile.Image.published().version
      bundled_sp = Fleet.SPBuilder.Image.published().version

      copy = Path.join(tmp, "catalogue-copy")

      # `dereference_symlinks` — the build's `priv` is a symlink to the source tree; without it the
      # copy would BE that symlink and the test would prove nothing.
      File.cp_r!(Catalogue.root(), copy, dereference_symlinks: true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, copy)

      assert Catalogue.verify!()["api_version"] in Catalogue.supported_api_versions()

      Fleet.CapProfile.Image.publish!()
      Fleet.SPBuilder.Image.publish!()
      assert Fleet.CapProfile.Image.published().version == bundled_caps
      assert Fleet.SPBuilder.Image.published().version == bundled_sp

      # Withdraw a profile from the COPY while the bundled root keeps it: an image built from the
      # bundle cannot notice, an image built from the copy cannot miss it. (A YAML comment would not
      # do — the image hashes the PARSED profile, so a comment is invisible to it by construction.)
      File.rm!(Path.join(Catalogue.cap_profiles_root(), "scoper.yaml"))

      # Un draft du catalogue METIER : les deux protocoles vivent desormais dans le catalogue
      # systeme (ils servent les roles `interlocutor: both`, qui y sont tous), donc la copie n'en
      # porte aucun — les toucher ici reviendrait a editer un fichier que la copie n'a pas.
      draft = Path.join(Catalogue.sp_drafts_root(), "agent-engineer-base.md")
      File.write!(draft, File.read!(draft) <> "\n<!-- catalogue copy marker -->\n")

      Fleet.CapProfile.Image.publish!()
      Fleet.SPBuilder.Image.publish!()

      refute Fleet.CapProfile.Image.published().version == bundled_caps,
             "the cap-profile image ignored the copy — it is still reading the bundled priv"

      refute Fleet.SPBuilder.Image.published().version == bundled_sp,
             "the SP image ignored the copy — it is still reading the bundled priv"
    end
  end
end
