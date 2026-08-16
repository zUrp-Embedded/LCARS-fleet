defmodule Fleet.Project.TemplateMaterialTest do
  @moduledoc """
  Le MATERIEL des `project_template/` livres — pas leur resolution, deja temoignee ailleurs.

  ## Le defaut que ce fichier garde, et il a ete rendu VIVANT par un correctif

  `catalogues/web-demo/project_template/` portait des placeholders en PROSE (`# <nom du projet>`,
  `**Date** : a remplir`) sans fichier de controle `.gitea/template`. Tant que la resolution etait
  globale, ce materiel etait du poids mort : tout projet partait de `fleet/project-template`,
  correctement cable. Le jour ou la resolution est devenue per-catalogue (2026-08-16), les projets
  `web-demo/*` se sont mis a en partir — et a naitre avec `# <nom du projet>` grave, pour toujours,
  puisque rien ne demande a personne de le remplir. Trouve par l'audit croise, verifie ici.

  Un placeholder est soit une VARIABLE que la forge expanse (`${REPO_NAME}`…, declaree dans
  `.gitea/template`), soit il n'est pas.
  """
  use ExUnit.Case, async: true

  # Les CINQ variables a nous. Les `${GITHUB_*}` d'un ci.yml sont celles du JOB de CI, pas les
  # notres : les lister dans `.gitea/template` tendrait a Gitea des noms qu'il ne connait pas.
  @our_variables ~w(REPO_NAME REPO_DESCRIPTION YEAR MONTH DAY)

  # La prose qui a mordu, et ses formes voisines. La forme du defaut est le SLOT DE VALEUR rempli
  # de prose (`**Date** : à remplir`), pas la locution : le premier jet de cette liste portait
  # « à remplir » nu et a mordu la REFERENCE sur deux phrases legitimes — une consigne au lecteur
  # (« les sections naissent vides et sont à remplir ») et une cicatrice qui CITE l'ancien en-tete
  # fautif. Un motif qui interdit la phrase interdirait d'ecrire la regle.
  @prose_placeholders [
    "<nom du projet>",
    ": à remplir",
    "<project name>",
    "TO BE FILLED"
  ]

  # Les racines livrees : le catalogue de reference (priv) et les graines du depot (../catalogues).
  # La seconde est un ARBRE FRERE : le stage de build d'image copie `fleet` seul, donc son absence
  # est un contexte legitime — SAUTEE ET NOMMEE, jamais un vert silencieux sur un terrain non
  # mesure (meme idiome que les verrous de listes de provisionnement).
  defp shipped_template_roots do
    priv = Path.join(Fleet.Catalogue.root(), "project_template")

    seeds =
      case Path.wildcard("../catalogues/*/project_template") do
        [] -> {:skipped, "../catalogues absent de cet artefact (contexte build d'image)"}
        dirs -> {:ok, dirs}
      end

    {priv, seeds}
  end

  test "AUCUN placeholder en prose dans un template livre — une variable ou rien" do
    {priv, seeds} = shipped_template_roots()

    roots =
      case seeds do
        {:ok, dirs} ->
          [priv | dirs]

        {:skipped, why} ->
          IO.puts("template_material: graines NON MESUREES ici — #{why}") && [priv]
      end

    offenders =
      for root <- roots,
          file <- Path.wildcard(Path.join(root, "**/*.{md,html,yml,yaml,css,js}")),
          content = File.read!(file),
          prose <- @prose_placeholders,
          String.contains?(content, prose),
          do: "#{file}: #{inspect(prose)}"

    assert offenders == [],
           "des placeholders en PROSE dans du materiel livre — un projet genere les portera " <>
             "litteralement, pour toujours :\n" <> Enum.join(offenders, "\n")
  end

  test "un fichier de `main/` qui porte une de NOS variables est declare dans .gitea/template" do
    {priv, seeds} = shipped_template_roots()

    roots =
      case seeds do
        {:ok, dirs} -> [priv | dirs]
        {:skipped, _} -> [priv]
      end

    for root <- roots do
      main = Path.join(root, "main")
      control_path = Path.join(main, ".gitea/template")

      declared =
        case File.read(control_path) do
          {:ok, c} -> c |> String.split("\n", trim: true) |> MapSet.new()
          _ -> MapSet.new()
        end

      undeclared =
        for file <- Path.wildcard(Path.join(main, "**/*.{md,html,css,js}")),
            content = File.read!(file),
            Enum.any?(@our_variables, &String.contains?(content, "${#{&1}}")),
            rel = Path.relative_to(file, main),
            not MapSet.member?(declared, rel),
            do: rel

      assert undeclared == [],
             "#{root}: ces fichiers portent une variable a nous et #{control_path} ne les " <>
               "declare pas — la forge ne les expansera JAMAIS, le projet naitra avec `${…}` " <>
               "grave :\n" <> Enum.join(undeclared, "\n")
    end
  end

  test "TEMOIN de non-vacuite : la graine web-demo est bien mesuree quand l'arbre est la" do
    # Sans lui, un chemin de glob casse rendrait les deux tests verts sur zero fichier — la
    # couverture annoncee sans la mesure.
    case elem(shipped_template_roots(), 1) do
      {:ok, dirs} ->
        assert Enum.any?(dirs, &String.contains?(&1, "web-demo"))

        assert File.read!("../catalogues/web-demo/project_template/main/README.md") =~
                 "${REPO_NAME}"

      {:skipped, _} ->
        :ok
    end
  end
end
