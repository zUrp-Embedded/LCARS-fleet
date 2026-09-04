defmodule Mix.Tasks.Lcars.Contracts.CapProfileProjectKeysCheckTest do
  @moduledoc """
  The `cap_profile.project_keys_declared` wall, proven against CRAFTED trees.

  What it guards (6-077): `spec.project` carries TWO populations in one slot. The catalogue schema
  declares four keys with `additionalProperties: false`; the pilot injects four MORE at dispatch
  (`repo`, `base_sha`, `gate_base_sha`, `pr_base_branch`) through `with_project/2`, which does not
  re-validate. The contradiction was silent in both directions — a reader of the schema concluded a
  catalogue could not pin a base, a reader of the code concluded the schema allowed one.

  The two halves stay APART on purpose: a card that set `base_sha` would validate and then be
  overwritten at every dispatch, i.e. a knob that reads as configuration and does nothing. What must
  not happen is the lists DRIFTING, and that is the only thing this wall measures.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @schema_rel "priv/cap_profile/schema/cap-profile.json"
  @resolver_rel "lib/fleet/pilot/step_dispatcher/project_resolver.ex"

  defp schema(props) do
    Jason.encode!(%{
      "properties" => %{
        "spec" => %{"properties" => %{"project" => %{"properties" => props}}}
      }
    })
  end

  # The resolver's shape: a function returning `{:ok, %{...}}`. `repo_path` is the anchor the
  # extractor keys on, so every crafted map carries it.
  defp resolver(keys) do
    pairs = Enum.map_join(keys, ",\n", &~s|      "#{&1}" => v|)

    """
    defmodule ProjectResolver do
      def resolve(v) do
        {:ok,
         %{
    #{pairs}
         }}
      end
    end
    """
  end

  defp tree(props, keys) do
    root = Fleet.TestEnv.tmp_path("project_keys")
    File.mkdir_p!(Path.join(root, "priv/cap_profile/schema"))
    File.mkdir_p!(Path.join(root, "lib/fleet/pilot/step_dispatcher"))
    File.write!(Path.join(root, @schema_rel), schema(props))
    File.write!(Path.join(root, @resolver_rel), resolver(keys))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(props, keys), do: Tools.check_cap_profile_project_keys(tree(props, keys))

  # The four the pilot really injects — the check reads them from the live module, not from the
  # crafted tree, so a test that renamed them would be measuring itself.
  defp runtime, do: Fleet.CapProfile.runtime_project_keys()

  describe "the instrument answers for itself first" do
    test "an empty schema is BROKEN, never a pass — a wall that read nothing declares nothing" do
      r = check(%{}, ["repo_path"])
      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "measured nothing" or &1 =~ "BROKEN"))
    end

    test "a resolver whose map it cannot find is BROKEN too" do
      root = Fleet.TestEnv.tmp_path("project_keys")
      File.mkdir_p!(Path.join(root, "priv/cap_profile/schema"))
      File.mkdir_p!(Path.join(root, "lib/fleet/pilot/step_dispatcher"))
      File.write!(Path.join(root, @schema_rel), schema(%{"repo_path" => %{}}))
      File.write!(Path.join(root, @resolver_rel), "defmodule R do\n  def f, do: :ok\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)

      r = Tools.check_cap_profile_project_keys(root)
      assert r.status == :fail
    end
  end

  describe "the drift it exists for" do
    test "une cle ecrite par le resolveur et declaree NULLE PART fait echouer" do
      # Le cas concret : quelqu'un ajoute une cinquieme cle au resolveur. Sans ce mur, elle est
      # lue par du code vivant et validee par rien, exactement comme `base_sha` l'etait.
      r = check(%{"repo_path" => %{}}, ["repo_path" | runtime()] ++ ["cle_inventee"])

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "cle_inventee"))
    end

    test "une cle declaree des DEUX cotes fait echouer — le slot n'a pas deux proprietaires" do
      # `base_sha` au schema ET en runtime : la carte valide, puis se fait ecraser a chaque
      # dispatch. Le bouton se lit comme de la configuration et ne fait rien.
      [first_runtime | _] = runtime()
      props = %{"repo_path" => %{}, first_runtime => %{}}

      r = check(props, ["repo_path" | runtime()])

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ first_runtime))
    end
  end

  describe "ce qu'il doit LAISSER PASSER" do
    test "le partage nominal — schema d'un cote, runtime de l'autre, disjoints" do
      # Sans ce temoin, un mur qui refuserait tout passerait les deux tests ci-dessus.
      r = check(%{"repo_path" => %{}, "base_branch" => %{}}, ["repo_path" | runtime()])

      assert r.status == :pass
      assert r.evidence == []
    end

    test "une cle du SCHEMA que le resolveur n'ecrit pas reste legitime" do
      # `branch_isolation` et `reference_repo_path` sont declarees par une carte et jamais injectees.
      # Le mur mesure ce que le resolveur ECRIT, pas une egalite des deux listes — l'exiger
      # interdirait a une carte de porter une option que le pilote n'a pas a poser.
      props = %{"repo_path" => %{}, "branch_isolation" => %{}, "reference_repo_path" => %{}}

      assert %{status: :pass} = check(props, ["repo_path" | runtime()])
    end
  end

  describe "l'arbre REEL" do
    test "le depot passe son propre mur, et le compte n'est pas zero" do
      r = Tools.check_cap_profile_project_keys(File.cwd!())

      assert r.status == :pass
      assert r.note =~ "4 catalogue keys"
      assert r.note =~ "4 runtime-injected"
    end
  end
end
