defmodule Fleet.Project.TemplateWorkflowsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Ce que le template LIVRE en `.gitea/workflows/`, et la seule propriété de ces fichiers qui soit
  vraiment portante.

  ## Pourquoi un test sur du YAML que ce dépôt n'exécute jamais

  Ces workflows tournent chez le RUNNER d'un projet, des semaines plus tard. Rien ici ne les joue,
  donc rien ici ne les casse — et c'est précisément la forme d'artefact qui dérive sans bruit. Une
  suite verte ne prouve rien d'un fichier qu'elle ne lit pas.

  On n'essaie pas de simuler un runner. On épingle ce qui, s'il bougeait, transformerait un
  MÉCANISME DE MESURE EN MUR — et qui ne se verrait nulle part ailleurs.
  """

  @workflows_dir "priv/catalogue/project_template/main/.gitea/workflows"
  @template_md "priv/catalogue/project_template/main/CLAUDE.md"

  defp wf_dir, do: Path.join(File.cwd!(), @workflows_dir)
  defp read_wf(name), do: wf_dir() |> Path.join(name) |> File.read!()

  defp workflow_name(content) do
    [_, name] = Regex.run(~r/^name:\s*(\S+)/m, content)
    name
  end

  # Le glob de la protection, tel que Gitea le comprend : `CI / *` matche tout contexte qui commence
  # par `CI / `. Un contexte vaut `<workflow> / <job> (<déclencheur>)`, donc la question se ramène
  # au NOM DU WORKFLOW.
  defp glob_prefix(glob), do: glob |> String.split("/") |> List.first() |> String.trim()
  defp matches_glob?(workflow_name, glob), do: workflow_name == glob_prefix(glob)

  describe "la garde de nommage — la seule chose qui empêche une sonde de devenir un mur" do
    test "AUCUN workflow `probe-*` ne matche les contextes exigés sur main" do
      # ⚠ LE GLOB EST LU CHEZ SON PROPRIÉTAIRE, JAMAIS RECOPIÉ. Si `Onboard` durcit un jour sa
      # protection, ce test doit BOUGER AVEC — un `"CI / *"` en dur ici resterait vert en décrivant
      # une protection qui n'existe plus, et c'est exactement le mode de panne qu'on traque.
      globs = Fleet.Project.Onboard.Faces.main_status_check_contexts()

      # Garde d'instrument n°1 : un glob dont on ne saurait pas extraire le préfixe rendrait
      # `matches_glob?/2` faux pour tout le monde, et ce test vert sans rien mesurer.
      prefixes = Enum.map(globs, &glob_prefix/1)
      refute Enum.any?(prefixes, &(&1 == "")), "glob non interprétable : #{inspect(globs)}"

      probes = wf_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "probe-"))

      # Garde d'instrument n°2 : zéro sonde et tout passe, en ne prouvant rien.
      assert probes != [], "aucun workflow `probe-*` trouvé — l'instrument mesure le vide"

      for file <- probes, glob <- globs do
        name = workflow_name(read_wf(file))

        refute matches_glob?(name, glob),
               "#{file} s'appelle #{inspect(name)} et matche #{inspect(glob)} : sa sonde " <>
                 "deviendrait un statut REQUIS de la protection de main, donc un mur qui bloque " <>
                 "le merge — l'inverse exact de son objet."
      end
    end

    test "TÉMOIN — `ci.yml`, lui, matche : sans ça la garde ci-dessus passerait pour rien" do
      # Le contre-test. Si `matches_glob?/2` rendait toujours `false`, le test précédent serait vert
      # quel que soit le nom des sondes. Ici on prouve que l'instrument SAIT dire oui.
      [glob | _] = Fleet.Project.Onboard.Faces.main_status_check_contexts()
      assert matches_glob?(workflow_name(read_wf("ci.yml")), glob)
    end
  end

  describe "probe-test-relevance.yml — le contrat de dispatch" do
    setup do: %{wf: read_wf("probe-test-relevance.yml")}

    test "déclenchable HORS push, et seulement comme ça", %{wf: wf} do
      # `workflow_dispatch` est la seule porte qui s'ouvre sans commit — c'est toute la raison
      # d'être de `Fleet.Forge.Client.Actions`. Et pas de `push:`/`pull_request:` : une sonde qui
      # part toute seule à chaque poussée mesure sans qu'on lui demande et facture le runner.
      assert wf =~ ~r/^\s+workflow_dispatch:/m
      refute wf =~ ~r/^\s+push:/m
      refute wf =~ ~r/^\s+pull_request:/m
    end

    test "les quatre entrées que le rail doit fournir sont déclarées", %{wf: wf} do
      # Une entrée manquante côté workflow rend un 422 nommant le schéma, pas la clé — le rail
      # chercherait au mauvais étage.
      for input <- ~w(base_sha head_sha harness test_cmd) do
        assert wf =~ ~r/^\s+#{input}:/m, "entrée `#{input}` absente du workflow_dispatch"
      end
    end

    test "`harness` est la seule entrée FACULTATIVE — l'absence est un cas, pas une panne", %{
      wf: wf
    } do
      # Un projet qui n'a pas déclaré ses chemins de preuve doit obtenir « inapplicable », pas une
      # erreur de dispatch : la dégradation est honnête, le refus serait une panne inventée.
      assert wf =~ ~r/harness:\s*\n\s+description:.*\n\s+required:\s*false/m
    end

    test "sort TOUJOURS en 0 : la sonde rapporte, elle ne tranche pas", %{wf: wf} do
      # Un run rouge serait indiscernable d'un runner cassé ou d'une image sans interpréteur — le
      # fait le plus utile deviendrait le plus ambigu. Et échouer quand la suite est aveugle serait
      # DÉCIDER : le mécanisme est un GAIN, jamais une précondition.
      refute wf =~ ~r/exit\s+1/
      assert wf =~ "exit 0"
    end

    test "le fait sort sous un préfixe stable, lisible dans les logs du JOB", %{wf: wf} do
      # Le rail lit ce marqueur via `Actions.run_logs/3` — qui descend par les jobs, parce que les
      # logs d'un run n'existent pas comme endpoint.
      assert wf =~ "LCARS-PROBE"

      for verdict <- ~w(relevant blind inapplicable) do
        assert wf =~ "verdict=#{verdict}", "le verdict `#{verdict}` n'est émis nulle part"
      end
    end

    test "le TÉMOIN existe : une suite déjà rouge rend `inapplicable`, pas `relevant`", %{wf: wf} do
      # SANS LUI, LA SONDE EST UN TIRAGE AU SORT. Si la suite est déjà rouge sur la tête livrée, son
      # rouge sur le code de base ne prouve rien — on mesurerait une panne et on l'appellerait une
      # couverture.
      assert wf =~ "verdict=inapplicable reason=head-suite-red"
    end
  end

  describe "le CLAUDE.md du template — la huitième section" do
    setup do: %{md: File.cwd!() |> Path.join(@template_md) |> File.read!()}

    test "`## Harness` est documentée et NE PEUT PAS être confondue avec `## Test`", %{md: md} do
      assert md =~ "## Harness"

      # ⚠ LE PIÈGE QUE LE PLAN PORTAIT. `Fleet.SPBuilder.RepoSections` reconnaît `## Test` sur une
      # FRONTIÈRE DE MOT : `## Test paths` matcherait donc, partirait au pod comme une seconde
      # section `## Test`, et le producteur y lirait des chemins là où son contrat promet « la
      # commande EXACTE, et rien d'autre ». On le prouve au lieu de le croire.
      refute md =~ ~r/^##\s+Test paths/m
    end

    test "PREUVE du piège : `## Test paths` serait bien extraite comme une section `## Test`" do
      # Le contre-test qui donne son poids au `refute` ci-dessus. Sans lui, « pas de `## Test
      # paths` » serait une préférence de style ; avec lui, c'est une nécessité mesurée.
      assert Fleet.SPBuilder.RepoSections.extract("## Test paths\n\ntests/\n") =~ "Test paths",
             "le parseur ignore ce titre : le piège n'existe pas, ce test non plus"
    end

    test "et `## Harness`, elle, NE voyage PAS au pod — même quand des sections voyagent", %{
      md: md
    } do
      # ⚠ LE TEMPLATE NE PRÉ-REMPLIT AUCUNE DES SEPT, DÉLIBÉRÉMENT. Extraire son CLAUDE.md tel quel
      # rend donc `""`, et un `refute extrait =~ "Harness"` y serait vert POUR LA MAUVAISE RAISON —
      # il ne prouverait que le vide. On ajoute donc une section qui, elle, DOIT voyager : le test
      # ne peut passer que si le parseur a réellement tourné.
      rempli = md <> "\n## Test\n\nsh test.sh\n"
      extrait = Fleet.SPBuilder.RepoSections.extract(rempli)

      assert extrait =~ "sh test.sh",
             "le parseur n'a rien extrait : la mesure suivante ne vaut rien"

      # C'est la propriété qui justifie ce nom-là : un fait que le rail lit, pas une directive que
      # l'agent tient pour vraie sans recours.
      refute extrait =~ "Harness"
    end
  end
end
