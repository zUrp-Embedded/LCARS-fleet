defmodule Fleet.Project.TemplateMaterialTest do
  @moduledoc """
  Scans shipped template text for known prose placeholders and undeclared files
  using the five listed template variables. The checks do not create a project or
  execute forge expansion. Missing sibling catalogue seeds are reported as unmeasured.
  """
  use ExUnit.Case, async: true

  # Project template variables are distinct from GITHUB_* values used by CI jobs.
  @our_variables ~w(REPO_NAME REPO_DESCRIPTION YEAR MONTH DAY)

  # Match value-slot placeholders rather than every occurrence of 'a remplir':
  # instructions and historical examples can legitimately contain those words.
  @prose_placeholders [
    "<nom du projet>",
    ": à remplir",
    "<project name>",
    "TO BE FILLED"
  ]

  # Build artifacts may contain runtime alone; absent sibling seeds are explicitly reported.
  # Globs cover the listed extensions and do not measure every hidden/template file.
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
    # When seeds are found, require web-demo and a known variable-bearing file.
    # A glob returning no seeds still takes the allowed skipped branch.
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
