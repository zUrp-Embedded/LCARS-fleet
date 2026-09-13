defmodule Fleet.Project.TemplateWorkflowsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Verifie les textes des workflows livres et leur accord avec les lecteurs Elixir.
  Les regex controlent des motifs, pas l'ensemble de la semantique YAML, les codes
  de sortie possibles ni les protections effectives d'un runner Gitea.
  """

  @workflows_dir "priv/catalogue/project_template/main/.gitea/workflows"
  @template_md "priv/catalogue/project_template/main/CLAUDE.md"

  defp wf_dir, do: Path.join(File.cwd!(), @workflows_dir)
  defp read_wf(name), do: wf_dir() |> Path.join(name) |> File.read!()

  defp workflow_name(content) do
    [_, name] = Regex.run(~r/^name:\s*(\S+)/m, content)
    name
  end

  # Comparateur local du nom avant /, adapte aux contextes actuels ; pas un moteur de glob Gitea.
  defp glob_prefix(glob), do: glob |> String.split("/") |> List.first() |> String.trim()
  defp matches_glob?(workflow_name, glob), do: workflow_name == glob_prefix(glob)

  describe "la garde de nommage — la seule chose qui empêche une sonde de devenir un mur" do
    test "AUCUN workflow `probe-*` ne matche les contextes exigés sur main" do
      # Lire les contextes chez Faces pour suivre les changements de protection.
      globs = Fleet.Project.Onboard.Faces.main_status_check_contexts()

      # Refuser un prefixe vide ; cela ne valide pas toute syntaxe de glob.
      prefixes = Enum.map(globs, &glob_prefix/1)
      refute Enum.any?(prefixes, &(&1 == "")), "glob non interprétable : #{inspect(globs)}"

      probes = wf_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "probe-"))

      # Exiger au moins une sonde pour eviter une verification vide.
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
      # Temoin positif : un comparateur toujours faux doit echouer ici.
      [glob | _] = Fleet.Project.Onboard.Faces.main_status_check_contexts()
      assert matches_glob?(workflow_name(read_wf("ci.yml")), glob)
    end
  end

  describe "probe-test-relevance.yml — le contrat de dispatch" do
    setup do: %{wf: read_wf("probe-test-relevance.yml")}

    test "déclenchable HORS push, et seulement comme ça", %{wf: wf} do
      # Verifier dispatch et absence des deux declencheurs push/PR ; les autres ne sont pas examines.
      assert wf =~ ~r/^\s+workflow_dispatch:/m
      refute wf =~ ~r/^\s+push:/m
      refute wf =~ ~r/^\s+pull_request:/m
    end

    test "les quatre entrées que le rail doit fournir sont déclarées", %{wf: wf} do
      # Les quatre noms d'entree attendus doivent figurer dans le texte.
      for input <- ~w(base_sha head_sha harness test_cmd) do
        assert wf =~ ~r/^\s+#{input}:/m, "entrée `#{input}` absente du workflow_dispatch"
      end
    end

    test "`harness` est la seule entrée FACULTATIVE — l'absence est un cas, pas une panne", %{
      wf: wf
    } do
      # Seule l'option required:false de harness est verifiee ici.
      assert wf =~ ~r/harness:\s*\n\s+description:.*\n\s+required:\s*false/m
    end

    test "sort TOUJOURS en 0 : la sonde rapporte, elle ne tranche pas", %{wf: wf} do
      # Cherche exit 0 et l'absence de exit 1 ; ne prouve pas que toute execution termine en zero.
      refute wf =~ ~r/exit\s+1/
      assert wf =~ "exit 0"
    end

    test "le fait sort sous LE préfixe QUE LE RAIL CHERCHE, lisible dans les logs du JOB", %{
      wf: wf
    } do
      # Extraire le prefixe du consommateur pour detecter une divergence avec le workflow.
      prefixe =
        "lib/fleet/mcp/pod_tools/probe.ex"
        |> File.read!()
        |> then(&Regex.run(~r/@fact_prefix\s+"([^"]+)"/, &1))
        |> Enum.at(1)

      assert is_binary(prefixe) and prefixe != ""

      assert wf =~ prefixe,
             "le workflow livré n'écrit pas le préfixe que `Probe` cherche (#{prefixe}) — " <>
               "la sonde tournerait et le rail ne lirait aucun fait"

      for verdict <- ~w(relevant blind inapplicable) do
        assert wf =~ "verdict=#{verdict}", "le verdict `#{verdict}` n'est émis nulle part"
      end
    end

    test "le TÉMOIN existe : une suite déjà rouge rend `inapplicable`, pas `relevant`", %{wf: wf} do
      # Une suite deja rouge doit rendre la mesure inapplicable ; ici on cherche le marqueur.
      assert wf =~ "verdict=inapplicable reason=head-suite-red"
    end
  end

  describe "le CLAUDE.md du template — la huitième section" do
    setup do: %{md: File.cwd!() |> Path.join(@template_md) |> File.read!()}

    test "`## Harness` est documentée et NE PEUT PAS être confondue avec `## Test`", %{md: md} do
      assert md =~ "## Harness"

      # La frontiere de mot de RepoSections ferait de Test paths une section Test.
      refute md =~ ~r/^##\s+Test paths/m
    end

    test "PREUVE du piège : `## Test paths` serait bien extraite comme une section `## Test`" do
      # Temoin positif du comportement d'extraction qui motive le nom Harness.
      assert Fleet.SPBuilder.RepoSections.extract("## Test paths\n\ntests/\n") =~ "Test paths",
             "le parseur ignore ce titre : le piège n'existe pas, ce test non plus"
    end

    test "et `## Harness`, elle, NE voyage PAS au pod — même quand des sections voyagent", %{
      md: md
    } do
      # Ajouter une section Test reconnue pour que l'absence de Harness ne soit pas un resultat vide.
      rempli = md <> "\n## Test\n\nsh test.sh\n"
      extrait = Fleet.SPBuilder.RepoSections.extract(rempli)

      assert extrait =~ "sh test.sh",
             "le parseur n'a rien extrait : la mesure suivante ne vaut rien"

      # Harness appartient au lecteur du rail, pas aux sections envoyees au pod.
      refute extrait =~ "Harness"
    end
  end
end
