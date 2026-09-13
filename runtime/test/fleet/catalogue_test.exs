defmodule Fleet.CatalogueTest do
  @moduledoc """
  Checks catalogue paths, installation discovery, manifest verification and image provenance.
  Serial because tests mutate node-global application configuration and published images.
  """
  use ExUnit.Case, async: false

  alias Fleet.Catalogue
  alias Fleet.Workflow.Loader

  @moduletag :tmp_dir

  # A root the accessors can point at. Only the trees a test actually reads are populated; the
  # manifest is always there, because a directory without one is not a catalogue.
  defp fake_root(tmp, api_version \\ 1) do
    root = Path.join(tmp, "catalogue")
    File.mkdir_p!(root)

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

      # Check every accessor listed here for a root change and for accidental path aliases.
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
            # Subagent templates are optional; absence of that tree is a valid catalogue shape.
            Catalogue.sp_drafts_root(),
            Catalogue.sp_templates_root(),
            Catalogue.workflow_maps_root(),
            Catalogue.brief_templates_root(),
            Catalogue.project_template_root()
          ] do
        assert File.dir?(tree), "bundled catalogue is missing #{tree}"
      end
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

      refute Path.join(root, Catalogue.rel(:subagent_templates)) in Catalogue.search(
               :subagent_templates
             )
    end

    test "a fine override REPLACES the active list for its tree, and only that tree", %{
      tmp_dir: tmp
    } do
      # Isolation depends on replacing, not prepending to, bundled business roots.
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
      root = fake_root(tmp)
      scope = Catalogue.tree_scope(root, :sp_drafts)

      found = Catalogue.find_in(scope, "protocole-user-worker.md")
      assert found && File.regular?(found)
      assert String.starts_with?(found, Catalogue.system_root())

      assert Catalogue.find_in(scope, "agent-nobody-base.md") == nil
    end
  end

  describe "installed — the material is here, or it is not" do
    # Set installation config, not HOME: System.user_home!/0 caches the VM's original home.
    setup %{tmp_dir: tmp} do
      home = Path.join(tmp, "operator")
      File.mkdir_p!(Path.join(home, "catalogues"))

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [
        Path.join(home, "catalogues")
      ])

      {:ok, home: home}
    end

    defp install(home, name, manifest? \\ true) do
      dir = Path.join([home, "catalogues", name])
      File.mkdir_p!(Path.join(dir, Catalogue.rel(:cap_profiles)))

      if manifest?,
        do: File.write!(Path.join(dir, "catalogue.yaml"), "api_version: 1\nname: #{name}\n")

      dir
    end

    defp install_card(dir, name) do
      maps = Path.join(dir, Catalogue.rel(:workflow_maps))
      File.mkdir_p!(maps)

      File.write!(Path.join(maps, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
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
      # Exercise a second catalogue so publication limited to the default root cannot pass.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, fake_root(tmp))
      premier = install_card(install(home, "premier"), "carte-une")
      second = install_card(install(home, "second"), "carte-deux")

      on_exit(&Loader.unpublish_all_images/0)
      :ok = Loader.publish_image!()

      # Each root must publish its own cards without merging its neighbour's.
      for {dir, attendue, absente} <- [
            {premier, "carte-une", "carte-deux"},
            {second, "carte-deux", "carte-une"}
          ] do
        opts = [workflow_maps_root: Path.join(dir, Catalogue.rel(:workflow_maps))]
        assert Loader.canon_names!(opts) == [attendue]
        # `load!` rend la carte APLATIE (metadata + spec fusionnes), pas l'arbre du YAML.
        assert %{"name" => ^attendue, "steps" => %{"build" => _}} =
                 Loader.load!(attendue, opts)

        refute absente in Loader.canon_names!(opts),
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
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      mobile = install(home, "mobile")

      assert Catalogue.installed_roots() == [root, mobile]
    end

    test "un repertoire SANS manifeste n'est pas un catalogue", %{tmp_dir: tmp, home: home} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "moitie-de-clone", false)

      assert Catalogue.installed_roots() == [root]
    end

    test "`fleet` est TOUJOURS present et TOUJOURS en tete", %{tmp_dir: tmp, home: home} do
      # User-chosen default-first policy; this checks ordering, not default-root validity.
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "aaa-avant-tout-alphabetiquement")

      assert hd(Catalogue.installed_roots()) == root
    end

    test "l'ordre sous le livre est celui des NOMS — il n'appartient a personne", %{
      tmp_dir: tmp,
      home: home
    } do
      # Basename ordering makes discovery independent of installation order.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, fake_root(tmp))
      zoulou = install(home, "zoulou")
      mobile = install(home, "mobile")

      assert tl(Catalogue.installed_roots()) == [mobile, zoulou]
    end

    test "un repertoire nomme `fleet` dans le cache ne DOUBLE pas le catalogue livre", %{
      tmp_dir: tmp,
      home: home
    } do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)
      install(home, "fleet")

      assert Catalogue.installed_roots() == [root]
    end

    test "la grosse molette EST la racine metier, quoi qu'il y ait dans le cache", %{
      tmp_dir: tmp,
      home: home
    } do
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
      # A default must name this catalogue's own card, not a hardcoded bundled choice.
      root = fake_root(tmp)
      maps = Path.join(root, Catalogue.rel(:workflow_maps))
      File.mkdir_p!(maps)
      File.write!(Path.join(maps, "la-mienne.yaml"), "kind: WorkflowMap\n")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, root)

      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "declares no `default_card`"
      assert err.message =~ "la-mienne", "il doit NOMMER les cartes disponibles"

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
      assert err.message =~ "not of where it was installed"
    end

    test "a name carrying `_` is refused: it separates the halves of a role login", %{
      tmp_dir: tmp
    } do
      # Distinguish path-slug validity from catalogue/login-name validity.
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
    # A copy gives identical images with the same system fallback; mutations then prove
    # that the copied business material was actually read rather than the original root.
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

      # Dereference the build's priv symlink so the copy is independent of the original.
      File.cp_r!(Catalogue.root(), copy, dereference_symlinks: true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, copy)

      assert Catalogue.verify!()["api_version"] in Catalogue.supported_api_versions()

      Fleet.CapProfile.Image.publish!()
      Fleet.SPBuilder.Image.publish!()
      assert Fleet.CapProfile.Image.published().version == bundled_caps
      assert Fleet.SPBuilder.Image.published().version == bundled_sp

      # Remove parsed data: a YAML comment would not change the profile image hash.
      File.rm!(Path.join(Catalogue.cap_profiles_root(), "scoper.yaml"))

      # Mutate a business draft; shared protocols belong to the unchanged system fallback.
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
