defmodule Mix.Tasks.Lcars.Contracts.ProvenImageRegimeCheckTest do
  @moduledoc """
  Tests literal image-publication switches in synthetic config sources and the
  real tree. False is allowed in test.exs and rejected in other config files.
  Missing config or unobserved switches exercise population guards.

  These tests inspect AST; they do not publish images, render EEx or prove
  template provenance. Frozen bytes do not by themselves establish trusted authorship.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Artifact

  defp tree(files) do
    root = Fleet.TestEnv.tmp_path("image_regime")
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
      r = Artifact.check_proven_image_regime(tree([]))
      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "measured nothing" or &1 =~ "BROKEN"))
    end

    test "config files but NO switch found is BROKEN too — the reader lost its subject" do
      r = Artifact.check_proven_image_regime(tree([{"test.exs", "import Config\n"}]))
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

      r =
        Artifact.check_proven_image_regime(tree([{"test.exs", @hermetic}, {"runtime.exs", src}]))

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "runtime.exs" and &1 =~ "sp_builder_publish_image"))
    end

    test "eteint dans config.exs aussi — le defaut compile-time n'est pas une exception" do
      src = """
      import Config
      config :lcars_fleet, cap_profile_publish_image: false
      """

      r = Artifact.check_proven_image_regime(tree([{"test.exs", @hermetic}, {"config.exs", src}]))

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "config.exs"))
    end
  end

  describe "ce qu'il doit LAISSER PASSER" do
    test "l'hermetisme des suites reste legitime" do
      r = Artifact.check_proven_image_regime(tree([{"test.exs", @hermetic}]))

      assert r.status == :pass
      assert r.evidence == []
      assert r.note =~ "2 switch"
    end

    test "le commutateur a TRUE ailleurs n'est pas un offenseur" do
      src = """
      import Config
      config :lcars_fleet, sp_builder_publish_image: true
      """

      assert %{status: :pass} =
               Artifact.check_proven_image_regime(
                 tree([{"test.exs", @hermetic}, {"prod.exs", src}])
               )
    end
  end

  describe "l'arbre REEL" do
    test "le depot passe son propre mur, et le compte n'est pas zero" do
      r = Artifact.check_proven_image_regime(File.cwd!())

      assert r.status == :pass
      assert r.note =~ "2 switch"
    end
  end
end
