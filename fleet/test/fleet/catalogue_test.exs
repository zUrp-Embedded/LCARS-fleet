defmodule Fleet.CatalogueTest do
  @moduledoc """
  The catalogue root: one knob brings one catalogue, and the boot refuses a root it cannot vouch for.

  `async: false` — every test here moves `:fleet_catalogue, :root` (and the image tests write
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
    File.write!(Path.join(root, "catalogue.yaml"), "api_version: #{api_version}\n")
    root
  end

  describe "the layout" do
    test "every tree derives from the root — one knob moves them all", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      trees = [
        Catalogue.cap_profiles_root(),
        Catalogue.modop_root(),
        Catalogue.subagent_templates_root(),
        Catalogue.monk_registry_root(),
        Catalogue.sp_drafts_root(),
        Catalogue.sp_templates_root(),
        Catalogue.workflow_maps_root(),
        Catalogue.brief_templates_root(),
        Catalogue.coord_policies_path(),
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

      assert File.regular?(Catalogue.coord_policies_path())
    end

    test "a nil root (a cross-test config leak) never reaches Path.join" do
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, nil)
      assert File.dir?(Catalogue.root())
    end
  end

  describe "fine overrides" do
    test "a per-tree key keeps precedence over the coarse root", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      fine = Path.join(tmp, "just-the-profiles")
      File.mkdir_p!(fine)

      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)
      Fleet.TestEnv.put_env_restoring(:fleet_cap_profile, :root_dir, fine)

      assert Fleet.CapProfile.root_dir() == fine
      # …and only that tree: panachage is allowed, silence about it is not.
      assert Fleet.SPBuilder.sp_drafts_root() == Catalogue.sp_drafts_root()
      assert String.starts_with?(Fleet.SPBuilder.sp_drafts_root(), root <> "/")
    end

    test "without a fine key, the domain resolvers read the catalogue root", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      assert Fleet.CapProfile.root_dir() == Catalogue.cap_profiles_root()
      assert Fleet.SPBuilder.sp_drafts_root() == Catalogue.sp_drafts_root()
    end
  end

  describe "search/1 — the N-root door" do
    test "orders the ACTIVE roots then the system default, dropping absent trees", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.mkdir_p!(Path.join(root, Catalogue.rel(:cap_profiles)))
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

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

      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)
      Fleet.TestEnv.put_env_restoring(:fleet_cap_profile, :root_dir, fine)

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
      Fleet.TestEnv.put_env_restoring(:fleet_cap_profile, :root_dir, fine)

      assert Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles)) in Catalogue.search(
               :cap_profiles
             )
    end

    test "find/2 answers the first existing file, then the first ACTIVE path", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      # Shipped by the system alone (the two protocols moved there).
      found = Catalogue.find(:sp_drafts, "protocole-user-worker.md")
      assert File.regular?(found)
      assert String.starts_with?(found, Catalogue.system_root())

      # Nowhere: the answer names the file the AUTHOR would create, in their own tree.
      absent = Catalogue.find(:sp_drafts, "agent-nobody-base.md")
      assert absent == Path.join([root, Catalogue.rel(:sp_drafts), "agent-nobody-base.md"])
    end
  end

  describe "catalogues.active — installed is not active" do
    # The declaration lives under the operator's `~/.lcars`, so these tests move HOME rather than
    # a config key: there is no knob, deliberately — changing what runs must not need a rebuild,
    # and it must not need an env var an image could bake either.
    # `HOME` is NOT the seam, and trying it is how this was found: `System.user_home!/0` is cached
    # by the VM and keeps answering the boot-time value, so a test moving HOME would silently
    # measure the real `~/.lcars` of whoever ran the suite.
    setup %{tmp_dir: tmp} do
      home = Path.join(tmp, "operator")
      File.mkdir_p!(Path.join(home, "catalogues"))

      Fleet.TestEnv.put_env_restoring(
        :fleet_catalogue,
        :active_declaration,
        Path.join(home, "catalogues.active")
      )

      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :install_dirs, [
        Path.join(home, "catalogues")
      ])

      {:ok, home: home}
    end

    defp install(home, name) do
      dir = Path.join([home, "catalogues", name])
      File.mkdir_p!(Path.join(dir, Catalogue.rel(:cap_profiles)))
      dir
    end

    defp declare(home, lines), do: File.write!(Path.join(home, "catalogues.active"), lines)

    test "no file: the shipped business catalogue alone — today's behaviour untouched", %{
      tmp_dir: tmp
    } do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      assert Catalogue.active_roots() == [root]
    end

    test "installed but NOT declared changes nothing", %{tmp_dir: tmp, home: home} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)
      install(home, "mobile")

      # The whole point of the target state, in one assertion: a catalogue sitting on disk is inert
      # until a line names it.
      assert Catalogue.active_roots() == [root]
    end

    test "the ORDER of the lines IS the precedence, and `fleet` names the shipped one", %{
      tmp_dir: tmp,
      home: home
    } do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)
      mobile = install(home, "mobile")
      sp_en = install(home, "sp-en")

      declare(home, """
      # l'ordre est la precedence
      sp-en     # les SP en anglais, devant tout
      mobile
      fleet     # le metier livre — retire cette ligne s'il ne sert plus
      """)

      assert Catalogue.active_roots() == [sp_en, mobile, root]

      # And the tree door inherits the order without knowing the list exists.
      assert Catalogue.search(:cap_profiles) == [
               Path.join(sp_en, Catalogue.rel(:cap_profiles)),
               Path.join(mobile, Catalogue.rel(:cap_profiles)),
               Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))
             ]
    end

    test "dropping the `fleet` line removes the shipped business catalogue", %{
      tmp_dir: tmp,
      home: home
    } do
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, fake_root(tmp))
      mobile = install(home, "mobile")
      declare(home, "mobile\n")

      assert Catalogue.active_roots() == [mobile]
    end

    test "the BUSINESS root follows the declaration — sinon les cartes et les roles divergent", %{
      tmp_dir: tmp,
      home: home
    } do
      # Trouve sur le banc lcars-d1, et c'est le defaut que ce test existe pour empecher de revenir.
      # `search/1` couvre les arbres PARTAGES ; les arbres purement metier (cartes, brief templates,
      # project_template) lisent `root/0` en direct. Tant que `root/0` ignorait la declaration,
      # activer un catalogue donnait ses ROLES et les CARTES du catalogue livre — la fleet a refuse
      # au boot sur un jury nommant un role que le catalogue actif ne porte pas.
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, fake_root(tmp))
      mobile = install(home, "mobile")
      declare(home, "mobile\n")

      assert to_string(Catalogue.root()) == mobile

      # Les arbres PUREMENT metier suivent, et ce sont eux qui divergeaient : ils n'ont pas de
      # defaut systeme, donc pas de `rel/1` ni de chemin de recherche — ils derivent de `root/0`.
      assert String.starts_with?(Catalogue.workflow_maps_root(), mobile <> "/")
      assert String.starts_with?(Catalogue.brief_templates_root(), mobile <> "/")
      assert String.starts_with?(Catalogue.project_template_root(), mobile <> "/")
    end

    test "sans declaration, la grosse molette reste la racine metier", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      assert to_string(Catalogue.root()) == root
    end

    test "a DECLARED catalogue installed nowhere RAISES, naming it and where it looked", %{
      home: home
    } do
      declare(home, "ghost\n")

      assert_raise RuntimeError, ~r/"ghost" and it is installed nowhere/, fn ->
        Catalogue.active_roots()
      end
    end

    test "the system catalogue is never in the list, and never dropped", %{
      tmp_dir: tmp,
      home: home
    } do
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, fake_root(tmp))
      install(home, "mobile")
      declare(home, "mobile\n")

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
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, Path.join(tmp, "nope"))

      assert_raise RuntimeError, ~r/LCARS_CATALOGUE_ROOT/, fn -> Catalogue.verify!() end
    end

    test "a directory without a manifest is not a catalogue", %{tmp_dir: tmp} do
      bare = Path.join(tmp, "bare")
      File.mkdir_p!(bare)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, bare)

      assert_raise RuntimeError, ~r/catalogue\.yaml.*unreadable/s, fn -> Catalogue.verify!() end
    end

    test "a foreign generation is refused, naming BOTH sides", %{tmp_dir: tmp} do
      root = fake_root(tmp, 99)
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      err = assert_raise RuntimeError, fn -> Catalogue.verify!() end
      assert err.message =~ "99"
      assert err.message =~ inspect(Catalogue.supported_api_versions())
    end

    test "a manifest with no api_version is refused like a foreign one", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "name: mine\n")
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

      assert_raise RuntimeError, ~r/api_version nil/, fn -> Catalogue.verify!() end
    end

    test "a manifest that is not a mapping is refused", %{tmp_dir: tmp} do
      root = fake_root(tmp)
      File.write!(Path.join(root, "catalogue.yaml"), "- 1\n- 2\n")
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, root)

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
      Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :root, copy)

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
