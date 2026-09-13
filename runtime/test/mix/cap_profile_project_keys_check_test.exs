defmodule Mix.Tasks.Lcars.Contracts.CapProfileProjectKeysCheckTest do
  @moduledoc """
  Tests separation of catalogue project keys from runtime-injected keys.
  Synthetic schema/resolver inputs use the loaded CapProfile runtime-key declaration;
  a real-tree case checks current counts. These tests compare declarations, not
  dispatch overwrite behaviour or schema revalidation.
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

  # Every crafted resolver map carries repo_path, the extractor's anchor.
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

  # Runtime keys come from the loaded module, not the synthetic tree.
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
      r = check(%{"repo_path" => %{}}, ["repo_path" | runtime()] ++ ["cle_inventee"])

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ "cle_inventee"))
    end

    test "une cle declaree des DEUX cotes fait echouer — le slot n'a pas deux proprietaires" do
      # Schema/runtime overlap would let dispatch overwrite declared configuration.
      [first_runtime | _] = runtime()
      props = %{"repo_path" => %{}, first_runtime => %{}}

      r = check(props, ["repo_path" | runtime()])

      assert r.status == :fail
      assert Enum.any?(r.evidence, &(&1 =~ first_runtime))
    end
  end

  describe "ce qu'il doit LAISSER PASSER" do
    test "le partage nominal — schema d'un cote, runtime de l'autre, disjoints" do
      r = check(%{"repo_path" => %{}, "base_branch" => %{}}, ["repo_path" | runtime()])

      assert r.status == :pass
      assert r.evidence == []
    end

    test "une cle du SCHEMA que le resolveur n'ecrit pas reste legitime" do
      # Catalogue-only options need not be written by the resolver; inclusion is not equality.
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
