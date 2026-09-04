defmodule Mix.Tasks.Lcars.Contracts.ToolEffectsCheckTest do
  @moduledoc """
  The `mcp.tool_effects` wall, proven against CRAFTED trees — because it reports absences.

  What it guards (6-106): the acceptor protected FIVE tools out of ~17 against a double effect,
  from a list of bare words living far from the definitions it claimed to cover. Moving that list
  next to the `deftool`s makes a rename traverse it — which is the 2026-08-11 failure — but does
  NOT make it exhaustive: nothing forces whoever adds a tool to classify it. This wall does.

  Both directions matter, and the second is the first bug seen from the other side: an effect
  declared for a tool that no longer exists is the residue of a rename.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Tools

  @tools_rel "lib/fleet/mcp/pod_tools.ex"

  # 12 tools (the instrument floor) + a matching `@tool_effects`, plus whatever the caller adds.
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
      # La distinction porte : « je n'ai rien trouve » et « j'ai trouve une classification vide »
      # produisent la meme liste de manquants, et seule la premiere accuse l'instrument.
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

      # ⚠ ANCRE. Un `result.note =~ "0 tools"` — une SOUS-CHAINE — rougirait au 30e outil,
      # `"30 tools"` contenant `"0 tools"`, comme au 20e, au 40e et a tous les comptes ronds (mesure
      # du 2026-08-20, en ajoutant `run_probe` : le mur a mordu son propre depot sans qu'aucune
      # propriete soit violee). Une garde d'instrument qui tombe sur un COMPTE apprend a ignorer
      # les gardes d'instrument.
      refute result.note =~ ~r/\b0 tools\b/
    end

    test "un nom d'outil cite dans un COMMENTAIRE ne peut pas verdir ce mur" do
      # Lu depuis l'AST, jamais d'un grep : sinon un commentaire qui mentionne l'outil manquant
      # suffirait a le faire passer pour classe.
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
