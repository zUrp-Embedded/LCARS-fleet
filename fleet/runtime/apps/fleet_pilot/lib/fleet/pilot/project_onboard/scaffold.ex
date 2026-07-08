defmodule Fleet.Pilot.ProjectOnboard.Scaffold do
  @moduledoc """
  Scaffold of a new project, extracted from `Fleet.Pilot.ProjectOnboard`: the CONTENT of
  the initial files (pure templates) + their writing to disk. No dependency on the
  orchestration (forge, git, worktrees) — onboard calls `main/3` and `work/3` at the
  right moments of its sequence, this module knows nothing of the rest.

  ## The two faces of the dual-dir (replicated LCARS architecture)

    * `main/3` — `main` branch worktree (the deliverable): README, .gitignore,
      .editorconfig, docs/spec.md.
    * `work/3` — `work/ops` branch worktree (orphan — plans, backlog, ops):
      backlog.md, scratchpad.md, plans/.

  Templates « standard, state of the art — adjustable »: PURE generators (name+pitch →
  markdown), the only effect is `write_all` (mkdir_p + write, fail-loud per file).
  """

  @doc """
  Scaffold of the `main` worktree: README + .gitignore + .editorconfig + docs/spec.md.
  `opts`: `:pitch` (default `:description`, default `"(à compléter)"`).
  """
  @spec main(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def main(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "(à compléter)")
    File.mkdir_p!(Path.join(dir, "docs"))

    write_all(dir, %{
      "README.md" => readme(name, pitch),
      ".gitignore" => gitignore(),
      ".editorconfig" => editorconfig(),
      "docs/spec.md" => spec_md(name, pitch)
    })
  end

  @doc """
  Scaffold of the `work/ops` worktree: backlog.md + scratchpad.md + plans/.
  `opts`: `:pitch` (default `:description`, default `""`).
  """
  @spec work(Path.t(), String.t(), keyword()) ::
          :ok | {:error, {:scaffold_write, String.t(), term()}}
  def work(dir, name, opts) do
    pitch = Keyword.get(opts, :pitch) || Keyword.get(opts, :description, "")
    File.mkdir_p!(Path.join(dir, "plans"))

    write_all(dir, %{
      "backlog.md" => backlog_md(name, pitch),
      "scratchpad.md" => "",
      "plans/.gitkeep" => ""
    })
  end

  # Writes the manifest {relative path => content} under `dir` — fail-loud PER file
  # (the first failure stops and names the offending file).
  defp write_all(dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:scaffold_write, rel, reason}}}
      end
    end)
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

  defp spec_md(name, pitch) do
    """
    # #{name} — Spec

    **Date** : 2026-06-14
    **Dernière révision** : 2026-06-14
    **Statut** : draft v1
    **Référencé par** : work/ops:backlog.md
    **Dérivé de** : —

    ## Pitch

    #{pitch}

    ## Contraintes

    (à compléter)
    """
  end

  defp backlog_md(name, pitch) do
    """
    # #{name} — Backlog

    **Date** : 2026-06-14
    **Dernière révision** : 2026-06-14
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
