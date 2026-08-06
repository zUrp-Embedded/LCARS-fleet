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

      draft = Path.join(Catalogue.sp_drafts_root(), "protocole-user-worker.md")
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
