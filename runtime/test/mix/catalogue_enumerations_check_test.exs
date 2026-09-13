defmodule Mix.Tasks.Lcars.Contracts.CatalogueEnumerationsCheckTest do
  @moduledoc """
  Tests catalogue tool-enumeration checks on synthetic trees.

  Comma/slash inventories are rejected while ordered worker sequences remain
  allowed. Empty inputs and missing catalogue trees exercise coverage guards.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @tools_rel "lib/fleet/mcp/pod_tools.ex"

  defp pod_tools do
    named = ~w(project_create project_list issue_create issue_list get_work_item submit_result)

    filler =
      Enum.map_join(1..8, "\n", &"  deftool \"filler#{&1}_get\" do\n    :schema\n  end\n")

    tools = Enum.map_join(named, "\n", &"  deftool \"#{&1}\" do\n    :schema\n  end\n")
    "defmodule PodTools do\n#{filler}\n#{tools}\nend\n"
  end

  # Put content in the business tree while keeping the system tree present.
  defp tree(content, opts) do
    root = Fleet.TestEnv.tmp_path("cat_enum")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp"))
    File.write!(Path.join(root, @tools_rel), Keyword.get(opts, :tools, pod_tools()))

    for t <- Keyword.get(opts, :trees, ["priv/catalogue", "priv/catalogue-system"]) do
      File.mkdir_p!(Path.join(root, t))
    end

    if content do
      File.write!(Path.join(root, "priv/catalogue/brief.md"), content)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(content, opts \\ []),
    do: Tools.check_catalogue_enumerates_no_tools(tree(content, opts))

  describe "l'instrument repond de lui-meme d'abord" do
    test "moins de 12 deftool : INSTRUMENT BROKEN" do
      tools = "defmodule PodTools do\n  deftool \"project_create\" do\n    :s\n  end\nend\n"
      assert %{status: :fail, evidence: [ev]} = check("rien", tools: tools)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "UN SEUL des deux arbres : INSTRUMENT BROKEN, jamais un vert propre" do
      assert %{status: :fail, evidence: [ev]} = check("rien", trees: ["priv/catalogue"])
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "1 of 2"
    end

    test "les arbres existent mais sont VIDES : INSTRUMENT BROKEN" do
      assert %{status: :fail, evidence: [ev]} = check(nil)
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  describe "l'INVENTAIRE est refuse — c'est la liste qui ment" do
    test "deux noms separes par une virgule" do
      assert %{status: :fail, evidence: [ev]} =
               check("la forge (`issue_create`, `issue_list`) porte le reste")

      assert ev =~ "brief.md:1"
      assert ev =~ "issue_create and issue_list"
    end

    test "deux noms separes par une barre" do
      assert %{status: :fail, evidence: [ev]} =
               check("via MCP get_work_item/submit_result, cote runtime")

      assert ev =~ "get_work_item and submit_result"
    end

    test "le refus NOMME le fichier, la ligne et les deux outils" do
      assert %{status: :fail, evidence: [ev], remediation: rem} =
               check("ligne un\nligne deux\ntes skills (`project_create`, `project_list`)")

      assert ev =~ "brief.md:3"
      assert rem =~ "tools/list"
    end
  end

  describe "la SEQUENCE est autorisee — c'est l'ordre des gestes, pas un catalogue" do
    test "deux noms joints par une FLECHE passent" do
      # Worker protocols may name ordered actions without duplicating tools/list.
      assert %{status: :pass} = check("le cycle : `get_work_item` → traite → `submit_result`")
      assert %{status: :pass} = check("direct execution (get_work_item -> work -> submit_result)")
    end

    test "un renvoi en prose entre deux noms passe" do
      assert %{status: :pass} = check("  - mcp__fleet__project_list  # twin of project_create")
    end

    test "UN nom par ligne passe — c'est la forme d'une grant" do
      assert %{status: :pass} =
               check("      - mcp__fleet__issue_create\n      - mcp__fleet__issue_list\n")
    end

    test "un outil nomme SEUL passe" do
      assert %{status: :pass} = check("Appelle `submit_result` quand ta tache est close.")
    end
  end
end
