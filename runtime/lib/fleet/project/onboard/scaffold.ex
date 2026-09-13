defmodule Fleet.Project.Onboard.Scaffold do
  require Logger

  @moduledoc """
  Projects template files for onboarding, expanding supported dollar-brace placeholders.
  Resolves the catalogue via opts[:org], omits .gitea/template control files and writes
  regular source files. Unknown placeholders survive. Missing template trees can yield
  a successful empty write; source read failures raise.

  Destination mkdir/write failures return scaffold_write at the first attempted failure.
  Earlier writes remain; file enumeration order is not a publication transaction.
  """

  @doc """
  Writes the `main` template face. `:pitch` falls back to `:description`, then
  `"(à compléter)"`; `:today` overrides the current UTC date.
  """
  @spec main(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def main(dir, name, opts), do: write_face(dir, "main", name, opts, "(à compléter)")

  @doc """
  Selects the named catalogue's project_template tree if present, otherwise the bundled tree.

  User-approved fallback applies to templates, not named roles/cards whose catalogue
  determines identity. Selection checks the whole template directory, not each face:
  a missing subtree in an own template does not trigger per-face fallback.

  This resolver is silent; writing entry points announce named fallback at info level
  and missing org at warning level.
  """
  @spec template_root(String.t() | nil) :: {Path.t(), :own | :fallback}
  def template_root(org) do
    root = org && Fleet.Catalogue.root_for(org)

    if root && File.dir?(Path.join(root, Fleet.Catalogue.rel(:project_template))) do
      {Path.join(root, Fleet.Catalogue.rel(:project_template)), :own}
    else
      {Fleet.Catalogue.project_template_root(), :fallback}
    end
  end

  defp write_face(dir, face, name, opts, pitch_default) do
    vars = template_vars(name, opts, pitch_default)
    root = face_root(face, opts)

    files =
      for path <- face_files(root), into: %{} do
        {Path.relative_to(path, root), expand(File.read!(path), vars)}
      end

    write_all(dir, files)
  end

  defp face_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.ends_with?(&1, ".gitea/template"))
  end

  defp face_root(face, opts) do
    org = Keyword.get(opts, :org)
    {root, origin} = template_root(org)

    announce_fallback(origin, org)
    Path.join(root, face)
  end

  # Named fallback is allowed; absent org is warned because the caller may have lost its scope.
  # Do not suppress bundled-name fallback: a damaged release can lack its own template tree.
  defp announce_fallback(:own, _org), do: :ok

  defp announce_fallback(:fallback, org) when is_binary(org) do
    Logger.info(
      "Scaffold: #{org} scaffolde depuis le catalogue LIVRE — le sien ne porte pas d arbre " <>
        "`project_template`. Legitime (un squelette ne nomme rien et n est nomme par rien), et DIT " <>
        "parce qu un catalogue bati en silence sur le materiel d un voisin est le defaut que cette " <>
        "resolution existe pour fermer."
    )
  end

  defp announce_fallback(:fallback, _nil) do
    Logger.warning(
      "Scaffold: squelette lu dans le catalogue LIVRE parce que l appelant n a pas nomme son " <>
        "catalogue (`opts[:org]` absent). Si ce projet appartient a un catalogue qui livre son " <>
        "propre `project_template`, il vient de naitre avec le materiel d un voisin."
    )
  end

  # Full-face and workflow-only writes share placeholder expansion.
  defp template_vars(name, opts, pitch_default) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, pitch_default)
    [year, month, day] = opts |> today() |> String.split("-", parts: 3)

    %{
      "REPO_NAME" => name,
      "CI_STANCE" => ci_stance_line(Keyword.get(opts, :ci_stance, :required)),
      "REPO_DESCRIPTION" => pitch,
      "YEAR" => year,
      "MONTH" => month,
      "DAY" => day
    }
  end

  # CI stance changes the template's explanation, not the required forge status glob.
  # Ignore describes a receipt; the default asks the project to replace the placeholder with tests.
  # Neither template stance guarantees runner success.
  defp ci_stance_line(:ignore),
    do:
      "Cette carte declare n'avoir RIEN a prouver (ci: ignore) : ce vert est le recu du plancher " <>
        "CI / *, pas une preuve. N'y pose pas de suite — elle gaterait un livrable que personne n'attend."

  defp ci_stance_line(_required),
    do:
      "Remplace ce step par ta commande de test (## Test du CLAUDE.md), dans CE job — l'image porte " <>
        "deja ta toolchain. Renommer le job EST le signal que ce projet a pose sa suite."

  defp expand(content, vars) do
    Enum.reduce(vars, content, fn {k, v}, acc -> String.replace(acc, "${#{k}}", v) end)
  end

  @doc """
  Adds missing template files under .gitea/workflows, returning sorted added paths.
  Existing destination paths are skipped after an existence check; there is no exclusive-create
  protection against concurrent writers.

  Imported repositories need CI and probe workflows without replacing their README or other
  project content, which main's full-face projection would overwrite.
  """
  @spec ci_workflows(Path.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, {:scaffold_write, String.t(), term()}}
  def ci_workflows(dir, name, opts) do
    root = face_root("main", opts)
    vars = template_vars(name, opts, "")

    missing =
      for path <- face_files(root),
          rel = Path.relative_to(path, root),
          String.starts_with?(rel, ".gitea/workflows/"),
          not File.exists?(Path.join(dir, rel)),
          into: %{},
          do: {rel, expand(File.read!(path), vars)}

    case write_all(dir, missing) do
      :ok -> {:ok, missing |> Map.keys() |> Enum.sort()}
      {:error, _} = err -> err
    end
  end

  @doc """
  Overwrites template-named CI workflow files and returns their sorted paths.
  Workflows not named by the template are retained. A separate entry point keeps destructive
  repair distinct from adoption's add-missing behavior; no justification is checked here.
  """
  @spec reset_ci_workflows(Path.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, {:scaffold_write, String.t(), term()}}
  def reset_ci_workflows(dir, name, opts) do
    root = face_root("main", opts)
    vars = template_vars(name, opts, "")

    rail =
      for path <- face_files(root),
          rel = Path.relative_to(path, root),
          String.starts_with?(rel, ".gitea/workflows/"),
          into: %{},
          do: {rel, expand(File.read!(path), vars)}

    case write_all(dir, rail) do
      :ok -> {:ok, rail |> Map.keys() |> Enum.sort()}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes a writer template subtree (ops or workshop).
  Pitch falls back to description, then an empty string; today overrides the UTC date.
  The subtree is a parameter because writing semantics are shared across faces.
  """
  @spec face(Path.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def face(dir, template, name, opts), do: write_face(dir, template, name, opts, "")

  defp today(opts) do
    Keyword.get(opts, :today) || Date.to_iso8601(Date.utc_today())
  end

  defp write_all(dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)

      with :ok <- ensure_dir(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:cont, :ok}
      else
        {:error, {:scaffold_write, _, _}} = err -> {:halt, err}
        {:error, reason} -> {:halt, {:error, {:scaffold_write, rel, reason}}}
      end
    end)
  end

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:scaffold_write, path, reason}}
    end
  end
end
