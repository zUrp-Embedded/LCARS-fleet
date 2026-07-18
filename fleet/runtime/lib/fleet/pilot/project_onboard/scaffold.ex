defmodule Fleet.Pilot.ProjectOnboard.Scaffold do
  @moduledoc """
  Scaffold of a new project, for `Fleet.Pilot.ProjectOnboard`: the CONTENT of
  the initial files (pure templates) + their writing to disk. No dependency on the
  orchestration (forge, git, worktrees) — onboard calls `main/3` and `work/3` at the
  right moments of its sequence, this module knows nothing of the rest.

  ## The two faces of the dual-dir (replicated LCARS architecture)

    * `main/3` — `main` branch worktree (the deliverable): the FALLBACK writer of
      `priv/project_template/**` (the SSoT — the same files the forge TEMPLATE repo
      serves natively via `generate_repo`; run `mix lcars.project_template.sync` to
      project them onto the forge). Expands the Gitea `${VAR}` subset locally
      (REPO_NAME, REPO_DESCRIPTION, YEAR/MONTH/DAY — `${...}` form only) and never
      copies the `.gitea/template` control file — the exact native semantics, one
      source, two vehicles.
    * `work/3` — `work/ops` branch worktree (orphan — plans, backlog, ops): SAME
      mechanic over the `work-ops/` face of the template (the sync task pushes it as
      the template repo's `work/ops` branch — the WHOLE project blueprint lives in one
      forge repo; `generate` only copies the default branch, so the runtime writes this
      face itself, from the same source).

  The only effect is `write_all` (mkdir_p + write, fail-loud per file).

  **Last revised**: 2026-07-18
  """

  @doc """
  Scaffold of the `main` worktree: README + .gitignore + .editorconfig + docs/spec.md.
  `opts`: `:pitch` (default `:description`, default `"(à compléter)"`);
  `:today` (ISO8601 date string, default `Date.utc_today/0` — F-C087: the generated GO-7 header must
  carry the ONBOARD date, not a hard-coded one; the seam lets a test pin it).
  """
  @spec main(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def main(dir, name, opts), do: write_face(dir, "main", name, opts, "(à compléter)")

  # ONE mechanic per face: read the face's files under priv/project_template/<face>,
  # expand the Gitea `${VAR}` subset locally, write. The `.gitea/template` control file
  # (main face) is never copied — native semantics.
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

  defp face_root(face), do: Application.app_dir(:lcars_fleet, "priv/project_template/#{face}")

  # Local expansion of the Gitea variable subset — `${VAR}` form ONLY (our template files
  # never use the bare `$VAR` form; expanding it here could corrupt shell-looking content).
  defp expand(content, vars) do
    Enum.reduce(vars, content, fn {k, v}, acc -> String.replace(acc, "${#{k}}", v) end)
  end

  @doc """
  Scaffold of the `work/ops` worktree: backlog.md + scratchpad.md + plans/.
  `opts`: `:pitch` (default `:description`, default `""`); `:today` (see `main/3`).
  """
  @spec work(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def work(dir, name, opts), do: write_face(dir, "work-ops", name, opts, "")

  # F-C087 — the generated files' GO-7 date = the ONBOARD date, not a hard-coded past date. Seam
  # (`:today`) so a test can pin it; default is the real current UTC date.
  defp today(opts) do
    Keyword.get(opts, :today) || Date.to_iso8601(Date.utc_today())
  end

  # Writes the manifest {relative path => content} under `dir` — fail-loud PER file
  # (the first failure stops and names the offending file).
  defp write_all(dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)

      with :ok <- ensure_dir(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:cont, :ok}
      else
        # ensure_dir already wraps to {:scaffold_write, dir, _}; File.write returns a raw reason.
        {:error, {:scaffold_write, _, _}} = err -> {:halt, err}
        {:error, reason} -> {:halt, {:error, {:scaffold_write, rel, reason}}}
      end
    end)
  end

  # F-C086 — non-bang mkdir_p → the module's TYPED `{:scaffold_write}` contract (mirror of the `File.write`
  # handling above). A mkdir failure (`:enotdir`/permission) must fail-loud as a VALUE, not a raise: the
  # @spec promises `{:error, {:scaffold_write, _, _}}`, and `ProjectOnboard.onboard/2`'s `with` has NO
  # `else` → a raise would CRASH it instead of surfacing the typed error its `{:error, term()}` contract expects.
  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:scaffold_write, path, reason}}
    end
  end



end
