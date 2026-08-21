defmodule Fleet.Project.Onboard.Scaffold do
  @moduledoc """
  Filesystem projection of the project template used by `Fleet.Project.Onboard`.

  `main/3` and `work/3` read their respective faces from
  `priv/catalogue/project_template`, expand the supported Gitea `${VAR}` placeholders, omit the
  `.gitea/template` control file, and fail with a typed `:scaffold_write` error at the first file
  that cannot be created.
  """

  @doc """
  Writes the `main` template face. `:pitch` falls back to `:description`, then
  `"(à compléter)"`; `:today` overrides the current UTC date.
  """
  @spec main(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def main(dir, name, opts), do: write_face(dir, "main", name, opts, "(à compléter)")

  defp write_face(dir, face, name, opts, pitch_default) do
    vars = template_vars(name, opts, pitch_default)
    root = face_root(face)

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

  defp face_root(face), do: Path.join(Fleet.Catalogue.project_template_root(), face)

  # Extracted so the workflow-only door expands the SAME placeholders as a full face: two expanders
  # would let a `${VAR}` reach a repository raw the day one of them learns a new one.
  defp template_vars(name, opts, pitch_default) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, pitch_default)
    [year, month, day] = opts |> today() |> String.split("-", parts: 3)

    %{
      "REPO_NAME" => name,
      "REPO_DESCRIPTION" => pitch,
      "YEAR" => year,
      "MONTH" => month,
      "DAY" => day
    }
  end

  defp expand(content, vars) do
    Enum.reduce(vars, content, fn {k, v}, acc -> String.replace(acc, "${#{k}}", v) end)
  end

  @doc """
  Adds the template's CI workflows to `dir` — and ONLY the ones it does not already have.

  ⚠ **`main/3` CANNOT BE USED HERE.** It writes the whole face — `README.md`, `CLAUDE.md`,
  `.gitignore` — which is right for a repository the fleet just created and destructive for one it
  imported: the project's own README would be replaced by a template. This door writes the
  workflows and nothing else.

  **WHY AN IMPORTED REPOSITORY NEEDS THEM.** `main` protection requires a `CI / *` status, and a
  repository that ships no `.gitea/workflows/` produces none — ever. No check appears, no pull
  request can merge, and the delivery rail is dead before its first ticket. `CIGate` already reads
  that dead end and names it (`{:ci_impossible, :no_workflow}`, measured 2026-08-12 on a repository
  imported from GitHub), but naming it leaves the human to write the file — which is how one of
  them landed with a `runs-on:` no runner served, waiting forever instead of failing.

  `probe-test-relevance.yml` travels with it, and not as a bonus: without it `run_probe` — the
  judges' only way to MEASURE a deliverable instead of opining on it — cannot run on that project.
  Same absence, second victim.

  **NEVER OVERWRITES.** An imported repository may carry its own CI, and a human may have written
  one by hand after hitting the dead end. Both are answers, and replacing them with a placeholder
  would be worse than the gap this closes.
  """
  @spec ci_workflows(Path.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, {:scaffold_write, String.t(), term()}}
  def ci_workflows(dir, name, opts) do
    root = face_root("main")
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
  Writes a WRITER face's template subtree (`"ops"`, `"workshop"`). `:pitch` falls back to
  `:description`, then `""`; `:today` overrides the current UTC date.

  The subtree name is a PARAMETER and not a per-face function because nothing about the writing
  differs between faces — only which directory of the template is read. A face is added by shipping
  its subtree under `project_template/`, not by growing this module.
  """
  @spec face(Path.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def face(dir, template, name, opts), do: write_face(dir, template, name, opts, "")

  # F-C087
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

  # F-C086
  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:scaffold_write, path, reason}}
    end
  end
end
