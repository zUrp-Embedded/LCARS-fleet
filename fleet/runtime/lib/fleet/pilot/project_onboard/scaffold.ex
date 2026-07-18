defmodule Fleet.Pilot.ProjectOnboard.Scaffold do
  @moduledoc """
  Scaffold of a new project, for `Fleet.Pilot.ProjectOnboard`: the CONTENT of
  the initial files (pure templates) + their writing to disk. No dependency on the
  orchestration (forge, git, worktrees) — onboard calls `main/3` and `work/3` at the
  right moments of its sequence, this module knows nothing of the rest.

  ## The two faces of the dual-dir (replicated LCARS architecture)

    * `main/3` — `main` branch worktree (the deliverable): README, .gitignore,
      .editorconfig, docs/spec.md.
    * `work/3` — `work/ops` branch worktree (orphan — plans, backlog, ops):
      backlog.md, scratchpad.md, plans/.

  Templates "standard, state of the art — adjustable": PURE generators (name+pitch →
  markdown), the only effect is `write_all` (mkdir_p + write, fail-loud per file).

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
  def main(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "(à compléter)")

    with :ok <- ensure_dir(Path.join(dir, "docs")) do
      write_all(dir, %{
        "README.md" => readme(name, pitch),
        ".gitignore" => gitignore(),
        ".editorconfig" => editorconfig(),
        "docs/spec.md" => spec_md(name, pitch, today(opts))
      })
    end
  end

  @doc """
  Scaffold of the `work/ops` worktree: backlog.md + scratchpad.md + plans/.
  `opts`: `:pitch` (default `:description`, default `""`); `:today` (see `main/3`).
  """
  @spec work(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def work(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "")

    with :ok <- ensure_dir(Path.join(dir, "plans")) do
      write_all(dir, %{
        "backlog.md" => backlog_md(name, pitch, today(opts)),
        "scratchpad.md" => "",
        "plans/.gitkeep" => ""
      })
    end
  end

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

  defp readme(name, pitch) do
    """
    # #{name}

    #{pitch}

    ## Installation

    (à compléter)

    ## Usage

    (à compléter)
    """
  end

  defp spec_md(name, pitch, today) do
    """
    # #{name} — Spec

    **Date** : #{today}
    **Dernière révision** : #{today}
    **Statut** : draft v1
    **Référencé par** : work/ops:backlog.md
    **Dérivé de** : —

    ## Pitch

    #{pitch}

    ## Contraintes

    (à compléter)
    """
  end

  defp backlog_md(name, pitch, today) do
    """
    # #{name} — Backlog

    **Date** : #{today}
    **Dernière révision** : #{today}
    **Statut** : actif
    **Référencé par** : —
    **Dérivé de** : docs/spec.md

    > #{pitch}

    ## Todo

    - [ ] Cadrer la spec (`docs/spec.md` sur `main`)

    ## Done

    (vide)
    """
  end

  defp gitignore do
    """
    # build / artefacts
    build/
    dist/
    *.log
    *.o
    *.obj

    # secrets / env
    .env
    .env.local

    # langages
    __pycache__/
    *.pyc
    node_modules/
    _build/
    deps/
    """
  end

  defp editorconfig do
    """
    root = true

    [*]
    charset = utf-8
    end_of_line = lf
    insert_final_newline = true
    indent_style = space
    indent_size = 4
    trim_trailing_whitespace = true
    """
  end
end
