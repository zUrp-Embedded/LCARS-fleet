defmodule Mix.Tasks.Lcars.Contracts.ProvenImageRegimeCheckTest do
  @moduledoc """
  The `boot.proven_image_regime` wall, proven against CRAFTED config trees.

  What it guards (6-026): `SPBuilder` renders its templates with `EEx.eval_string/2`. EEx evaluates
  arbitrary Elixir at render time, in the DAEMON's process, with the whole fleet's rights and not a
  confined pod's — and the source is catalogue DATA.

  Two regimes decide whose bytes get evaluated. Under a PUBLISHED image the bytes were read and
  sha256-fingerprinted at boot, after `Catalogue.verify!()`, and are served from `:persistent_term`:
  the provenance check happened long before the render. With NO image, the template is re-read from
  live disk at every render and verified by nothing.

  The second regime is declared and legitimate (the suites' hermetic default, tooling). What has no
  legitimate reason to exist is the switch being flipped ANYWHERE ELSE than `config/test.exs`: it
  moves a production daemon onto evaluate-whatever-is-on-disk, and nothing in the code looks any
  different afterwards.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  defp tree(files) do
    root = Path.join(System.tmp_dir!(), "image_regime_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "config"))
    for {name, src} <- files, do: File.write!(Path.join([root, "config", name]), src)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @hermetic """
  import Config
  config :lcars_fleet, cap_profile_publish_image: false
  config :lcars_fleet, sp_builder_publish_image: false
  """

  describe "the instrument answers for itself first" do
    test "no config file at all is BROKEN, never a pass" do
      r = Check.check_proven_image_regime(tree([]))
      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "measured nothing" or &1 =~ "BROKEN"))
    end

    test "config files but NO switch found is BROKEN too — the reader lost its subject" do
      # `config/test.exs` turns both off by design. Finding none means the extractor stopped seeing
      # the switch, and a wall that cannot see its subject passes everything.
      r = Check.check_proven_image_regime(tree([{"test.exs", "import Config\n"}]))
      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "measured nothing" or &1 =~ "BROKEN"))
    end
  end

  describe "le vecteur qu'il ferme" do
    test "le commutateur eteint dans runtime.exs fait ECHOUER" do
      src = """
      import Config
      config :lcars_fleet, sp_builder_publish_image: false
      """

      r = Check.check_proven_image_regime(tree([{"test.exs", @hermetic}, {"runtime.exs", src}]))

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "runtime.exs" and &1 =~ "sp_builder_publish_image"))
    end

    test "eteint dans config.exs aussi — le defaut compile-time n'est pas une exception" do
      src = """
      import Config
      config :lcars_fleet, cap_profile_publish_image: false
      """

      r = Check.check_proven_image_regime(tree([{"test.exs", @hermetic}, {"config.exs", src}]))

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "config.exs"))
    end
  end

  describe "ce qu'il doit LAISSER PASSER" do
    test "l'hermetisme des suites reste legitime" do
      # Sans ce temoin, un mur qui refuserait tout commutateur eteint passerait les deux tests
      # ci-dessus — et casserait l'hermetisme que les suites reposent dessus.
      r = Check.check_proven_image_regime(tree([{"test.exs", @hermetic}]))

      assert r.status == :pass
      assert r.evidence == []
      assert r.note =~ "2 switch"
    end

    test "le commutateur a TRUE ailleurs n'est pas un offenseur" do
      # Le mur mesure l'EXTINCTION, pas la mention. Un `true` explicite en prod dit la meme chose
      # que le defaut et doit rester ecrivable.
      src = """
      import Config
      config :lcars_fleet, sp_builder_publish_image: true
      """

      assert %{status: :pass} =
               Check.check_proven_image_regime(tree([{"test.exs", @hermetic}, {"prod.exs", src}]))
    end
  end

  describe "l'arbre REEL" do
    test "le depot passe son propre mur, et le compte n'est pas zero" do
      r = Check.check_proven_image_regime(File.cwd!())

      assert r.status == :pass
      assert r.note =~ "2 switch"
    end
  end
end
