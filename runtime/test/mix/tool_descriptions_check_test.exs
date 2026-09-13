defmodule Mix.Tasks.Lcars.Contracts.ToolDescriptionsCheckTest do
  @moduledoc """
  Tests permutation detection, trailing-s normalisation and shape-collision guards
  on synthetic tool descriptions. A name wholly within a later concatenated
  fragment remains detectable.

  Invented names with different shapes are deliberately accepted; these tests
  do not establish that every tool name mentioned by a description exists.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @tools_rel "lib/fleet/mcp/pod_tools.ex"

  # Neutral fillers meet the twelve-tool population floor.
  defp pod_tools(extra_tools) do
    filler =
      Enum.map_join(1..12, "\n", fn i ->
        "  deftool \"filler#{i}_get\" do\n    meta do\n      description(\"rien\")\n    end\n  end\n"
      end)

    "defmodule PodTools do\n#{filler}\n#{extra_tools}\nend\n"
  end

  defp tree(src) do
    root = Fleet.TestEnv.tmp_path("tool_desc")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp"))
    File.write!(Path.join(root, @tools_rel), src)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(src), do: Tools.check_tool_descriptions_no_permuted_names(tree(src))

  defp tool(name, description) do
    "  deftool \"#{name}\" do\n    meta do\n      description(\"#{description}\")\n    end\n  end\n"
  end

  describe "l'instrument repond de lui-meme d'abord" do
    test "moins de 12 deftool : INSTRUMENT BROKEN, jamais un vert propre" do
      src = "defmodule PodTools do\n" <> tool("project_create", "rien") <> "end\n"
      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "DEUX outils de meme forme : l'indexation en perdrait un EN SILENCE" do
      # Shape collisions must fail before the index overwrites one tool.
      src = pod_tools(tool("project_list", "rien") <> tool("list_projects", "rien"))
      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "collide"
    end
  end

  describe "ce que le mur ATTRAPE" do
    test "une permutation de l'ordre : le defaut mesure du 2026-08-21" do
      src = pod_tools(tool("project_create", "Use it BEFORE create_project, which starts fresh."))

      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev == "create_project → the tool is project_create"
    end

    test "une permutation au PLURIEL — `list_projects` pour `project_list`" do
      src = pod_tools(tool("project_list", "See list_projects for the disk inventory."))

      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev == "list_projects → the tool is project_list"
    end

    test "une description ecrite en chaine `<>` est UN texte, pas des lignes" do
      src =
        pod_tools("""
          deftool "project_create" do
            meta do
              description(
                "premier fragment, sans rien de fautif — " <>
                  "et le nom mort arrive dans le second : create_project."
              )
            end
          end
        """)

      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev =~ "create_project"
    end
  end

  describe "ce que le mur NE VOIT PAS, et c'est ecrit" do
    test "un nom INVENTE qui n'est pas une reordination passe — angle mort assume" do
      # This passing case records limited coverage, not the validity of the invented name.
      src = pod_tools(tool("project_import", "Same forge gate as project_import_external."))

      assert %{status: :pass} = check(src)
    end

    test "un jeton snake_case legitime ne fait pas rougir la porte" do
      src = pod_tools(tool("project_create", "Pass `workflow_map`; `full_name` is owner/name."))

      assert %{status: :pass} = check(src)
    end
  end
end
