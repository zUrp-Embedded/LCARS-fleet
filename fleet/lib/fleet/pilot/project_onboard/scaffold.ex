defmodule Fleet.Pilot.ProjectOnboard.Scaffold do
  @moduledoc """
  Filesystem projection of the project template used by `Fleet.Pilot.ProjectOnboard`.

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
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, pitch_default)
    [year, month, day] = opts |> today() |> String.split("-", parts: 3)

    vars = %{
      "REPO_NAME" => name,
      "REPO_DESCRIPTION" => pitch,
      "YEAR" => year,
      "MONTH" => month,
      "DAY" => day
    }

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

  defp expand(content, vars) do
    Enum.reduce(vars, content, fn {k, v}, acc -> String.replace(acc, "${#{k}}", v) end)
  end

  @doc """
  Writes the `work/ops` template face. `:pitch` falls back to `:description`, then `""`;
  `:today` overrides the current UTC date.
  """
  @spec work(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def work(dir, name, opts), do: write_face(dir, "work-ops", name, opts, "")

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
