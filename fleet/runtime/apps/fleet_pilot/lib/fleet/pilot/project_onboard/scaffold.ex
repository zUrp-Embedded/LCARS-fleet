defmodule Fleet.Pilot.ProjectOnboard.Scaffold do
  @moduledoc """
  Scaffold d'un projet neuf, extrait de `Fleet.Pilot.ProjectOnboard` : le CONTENU des
  fichiers initiaux (templates purs) + leur écriture sur disque. Aucune dépendance à
  l'orchestration (forge, git, worktrees) — l'onboard appelle `main/3` et `work/3` aux
  bons moments de sa séquence, ce module ne sait rien du reste.

  ## Les deux faces du dual-dir (archi LCARS répliquée)

    * `main/3` — worktree branche `main` (le livrable) : README, .gitignore,
      .editorconfig, docs/spec.md.
    * `work/3` — worktree branche `work/ops` (orphan — plans, backlog, ops) :
      backlog.md, scratchpad.md, plans/.

  Templates « standard, état de l'art — ajustable » : générateurs PURS (name+pitch →
  markdown), le seul effet est `write_all` (mkdir_p + write, fail-loud par fichier).
  """

  @doc """
  Scaffold du worktree `main` : README + .gitignore + .editorconfig + docs/spec.md.
  `opts` : `:pitch` (défaut `:description`, défaut `"(à compléter)"`).
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
  Scaffold du worktree `work/ops` : backlog.md + scratchpad.md + plans/.
  `opts` : `:pitch` (défaut `:description`, défaut `""`).
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

  # Écrit le manifest {chemin relatif => contenu} sous `dir` — fail-loud PAR fichier
  # (le premier échec arrête et nomme le fichier fautif).
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
