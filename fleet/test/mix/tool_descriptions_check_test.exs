defmodule Mix.Tasks.Lcars.Contracts.ToolDescriptionsCheckTest do
  @moduledoc """
  Le mur `mcp.tool_descriptions_no_permuted_names`, prouvé contre des arbres FABRIQUÉS.

  Ce qu'il garde : les ids d'outils sont passés objet-d'abord le 2026-08-11
  (`create_project` → `project_create`). Le renommage a bougé les `deftool` et les citations
  `mcp__fleet__`. Il n'a PAS bougé les noms nus écrits DANS les chaînes de `description(...)` — or
  ces chaînes sont le catalogue d'outils qu'un agent lit. Treize occurrences, six descriptions,
  quatre outils inexistants, mesurées le 2026-08-21.

  ## Pourquoi ces témoins-ci, et pas la porte

  La porte tourne sur l'arbre RÉEL, qui est propre : elle ne peut prouver ni la normalisation du
  pluriel, ni le garde de collision de forme (aucune collision n'existe). Retirer la normalisation
  laissait la porte verte — mesuré le 2026-08-22. Un comportement qu'aucun témoin ne rougit est un
  comportement que le prochain lecteur supprimera en croyant simplifier.

  ## Ce qui est épinglé ICI comme angle mort ASSUMÉ

  Le mur ne voit que les PERMUTATIONS. Un nom inventé qui n'est pas une réordination passe. Ce n'est
  pas un oubli : une description porte légitimement du snake_case qui n'est pas un outil
  (`workflow_map`, `full_name`, `default_branch`), donc refuser tout jeton inconnu demanderait une
  liste tenue à la main — exactement ce que ce fichier existe pour éviter. Le témoin du bas grave
  cette limite, pour qu'un lecteur ne croie pas le mur plus large qu'il n'est.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  @tools_rel "lib/fleet/mcp/pod_tools.ex"

  # Le plancher d'instrument est de 12 outils. Les douze porteurs sont neutres ; l'appelant ajoute
  # ceux dont il veut parler.
  defp pod_tools(extra_tools \\ "") do
    filler =
      Enum.map_join(1..12, "\n", fn i ->
        "  deftool \"filler#{i}_get\" do\n    meta do\n      description(\"rien\")\n    end\n  end\n"
      end)

    "defmodule PodTools do\n#{filler}\n#{extra_tools}\nend\n"
  end

  defp tree(src) do
    root = Path.join(System.tmp_dir!(), "tool_desc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp"))
    File.write!(Path.join(root, @tools_rel), src)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(src), do: Check.check_tool_descriptions_no_permuted_names(tree(src))

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
      # ⚠ CE TEMOIN NE PEUT PAS EXISTER SUR L'ARBRE REEL — aucune collision n'y vit, donc le garde
      # y est inatteignable et la porte le laisse passer quoi qu'on lui fasse. Sans lui, l'indexation
      # par forme ecrase un outil, le survivant garde sa couverture, le perdant n'est plus jamais
      # mesure, et rien dans la sortie ne le dit.
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
      # ⚠ LE SEUL TEMOIN DE LA NORMALISATION DU `s`. Retirer `String.replace_suffix(&1, "s", "")`
      # laisse la porte VERTE (mesure du 2026-08-22, l'arbre reel n'en porte aucune) : la
      # simplification passerait pour gratuite.
      src = pod_tools(tool("project_list", "See list_projects for the disk inventory."))

      assert %{status: :fail, evidence: [ev]} = check(src)
      assert ev == "list_projects → the tool is project_list"
    end

    test "une description ecrite en chaine `<>` est UN texte, pas des lignes" do
      # C'est la forme qui a laisse treize occurrences sous un grep : le nom fautif peut vivre dans
      # un fragment que rien ne relie a son `deftool` a la lecture ligne a ligne.
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
      # ⚠ CE TEMOIN GRAVE UNE LIMITE, PAS UN SUCCES. Le mur s'appelait
      # `mcp.tool_descriptions_name_real_tools` et s'ouvrait sur « aucune description ne peut nommer
      # un outil qui n'existe pas » — une promesse plus large que le code, relevee par relecture
      # independante le 2026-08-22. Elargir demanderait une liste blanche tenue a la main des jetons
      # snake_case legitimes (`workflow_map`, `full_name`, `default_branch`), et une liste tenue a la
      # main est ce que ce fichier existe pour eviter.
      #
      # Si ce temoin ROUGIT un jour, ce n'est pas une regression : c'est que le mur s'est elargi, et
      # alors son nom et sa doc doivent s'elargir avec lui.
      src = pod_tools(tool("project_import", "Same forge gate as project_import_external."))

      assert %{status: :pass} = check(src)
    end

    test "un jeton snake_case legitime ne fait pas rougir la porte" do
      src = pod_tools(tool("project_create", "Pass `workflow_map`; `full_name` is owner/name."))

      assert %{status: :pass} = check(src)
    end
  end
end
