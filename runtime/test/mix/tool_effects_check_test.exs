defmodule Mix.Tasks.Lcars.Contracts.ToolEffectsCheckTest do
  @moduledoc """
  Tests equality of tool names and effect-map keys, including missing and orphan
  entries. A real-tree case checks the current inventory.

  The scanner does not validate effect values or execute a tool, so these tests
  do not prove correct mutation classification or duplicate-call protection.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @tools_rel "lib/fleet/mcp/pod_tools.ex"

  defp pod_tools(extra_tools \\ "", extra_effects \\ "") do
    tools = Enum.map_join(1..12, "\n", &"  deftool \"t#{&1}\" do\n    :schema\n  end\n")
    effects = Enum.map_join(1..12, ",\n", &"    \"t#{&1}\" => :read")

    """
    defmodule PodTools do
    #{tools}
    #{extra_tools}
      @tool_effects %{
    #{effects}#{extra_effects}
      }
    end
    """
  end

  defp tree(tools_src) do
    root = Fleet.TestEnv.tmp_path("tool_effects")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp"))
    File.write!(Path.join(root, @tools_rel), tools_src)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(tools_src), do: Tools.check_mcp_tool_effects(tree(tools_src))

  describe "the instrument answers for itself first" do
    test "a tree it cannot parse into tools FAILS as broken — it never passes by measuring nothing" do
      result = check("defmodule PodTools do\nend\n")

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "tools present but NO `@tool_effects` at all is BROKEN, not merely unclassified" do
      tools = Enum.map_join(1..12, "\n", &"  deftool \"t#{&1}\" do\n    :schema\n  end\n")
      result = check("defmodule PodTools do\n#{tools}\nend\n")

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end
  end

  describe "the refusals" do
    test "un outil declare SANS effet est NOMME" do
      result = check(pod_tools("  deftool \"issue_retire\" do\n    :schema\n  end\n"))

      assert result.status == :fail
      assert hd(result.evidence) =~ "no declared effect"
      assert hd(result.evidence) =~ "issue_retire"
    end

    test "un effet declare pour un outil INEXISTANT est NOMME — le residu d'un renommage" do
      result = check(pod_tools("", ",\n    \"issue_create_OLD\" => :mutation"))

      assert result.status == :fail
      assert hd(result.evidence) =~ "names no tool declares"
      assert hd(result.evidence) =~ "issue_create_OLD"
    end
  end

  describe "et le silence, sans lequel un refus ne prouve rien" do
    test "chaque outil classe → pass" do
      result = check(pod_tools())

      assert result.status == :pass
      assert result.evidence == []
    end

    test "un outil AJOUTE et classe dans le meme geste → pass" do
      result =
        check(
          pod_tools(
            "  deftool \"issue_retire\" do\n    :schema\n  end\n",
            ",\n    \"issue_retire\" => :mutation"
          )
        )

      assert result.status == :pass
    end
  end

  describe "le depot lui-meme" do
    test "l'arbre reel passe, et l'instrument y voit bien quelque chose" do
      result = Tools.check_mcp_tool_effects(File.cwd!())

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"

      # Bound zero as a word so counts such as 20 or 30 do not match it.
      refute result.note =~ ~r/\b0 tools\b/
    end

    test "un nom d'outil cite dans un COMMENTAIRE ne peut pas verdir ce mur" do
      result =
        check(
          pod_tools("""
            # "issue_retire" => :mutation  (ce commentaire ne classe RIEN)
            deftool "issue_retire" do
              :schema
            end
          """)
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "issue_retire"
    end
  end
end
