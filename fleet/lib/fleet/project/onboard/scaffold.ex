defmodule Fleet.Project.Onboard.Scaffold do
  require Logger

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

  @doc """
  La racine de catalogue d'où le squelette d'un projet de `org` est lu — la SIENNE, ou celle du
  catalogue livré si le sien n'en porte pas.

  ## Pourquoi ce n'est pas `Fleet.Catalogue.root/0`

  `root/0` rend TOUJOURS la racine livrée. Un `Scaffold.main` branché dessus scaffolde chaque
  projet depuis le catalogue de référence, quel que soit le sien — et c'est un défaut MESURÉ, le
  2026-08-16 : un projet `web-demo/*` naissait du template de `fleet` pendant que `web-demo`
  livrait treize fichiers à lui que rien ne lisait jamais. Un arbre présent dans un catalogue et
  inatteignable par tout appelant n'est pas une fonctionnalité en attente de câblage, c'est du
  poids mort qui a l'air câblé.

  La résolution vivait dans la couche template (`resolve_template`, retirée avec le dépôt modèle le
  2026-08-21). Elle descend ici, parce que c'est désormais ce chemin-ci qui peuple un projet neuf.

  ## Le repli, et pourquoi il est ANNONCÉ

  ⚖ user, 2026-08-16 : *« le template, on peut prendre celui de fleet par défaut s'il n'y en a pas,
  ça ne change rien »*. C'est le SEUL arbre qui puisse se replier, et la raison est structurelle :
  tout le reste d'un catalogue est nommé PAR SON NOM — une carte nomme un rôle, un rôle nomme son
  profil — donc se replier résoudrait un nom dans un catalogue qui ne l'a jamais déclaré. Un
  squelette de projet ne nomme rien et n'est nommé par rien.

  Il est DIT au moment où il arrive : un catalogue qui scaffolde silencieusement depuis le matériel
  d'un voisin est exactement la forme du défaut ci-dessus, une couche plus bas.
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

  # ⚠ LA RACINE SUIT LE CATALOGUE DU PROJET, PAS LA RACINE LIVREE. `opts[:org]` porte le catalogue ;
  # son absence (un appelant qui n'en a pas) retombe sur le livre, ce qui est le repli documente.
  defp face_root(face, opts) do
    org = Keyword.get(opts, :org)
    {root, origin} = template_root(org)

    announce_fallback(origin, org)
    Path.join(root, face)
  end

  # ⚠ TROIS ETATS, ET LE TROISIEME EST LE PLUS DANGEREUX. Un repli sur un catalogue NOMME est
  # legitime et se dit une fois. Un appelant SANS org, lui, ne sait pas de quel catalogue il parle :
  # il scaffolde depuis le livre sans que personne ne l ait decide, et c est exactement le defaut
  # mesure le 2026-08-16, avec une cause de plus — l absence d argument au lieu d une resolution
  # cablee en dur. Il monte donc d un cran : `warning`.
  # ⚠ IL Y AVAIT ICI UNE CLAUSE QUI TAISAIT LE REPLI DU CATALOGUE LIVRE, et elle etait morte.
  # `root_for(<nom livre>)` rend la racine livree, qui porte son propre `project_template/` — donc
  # `:own`, jamais `:fallback`. Le seul monde ou elle aurait pu tirer est celui d'un release dont le
  # catalogue livre n'a pas d'arbre : la racine de repli y est le MEME repertoire absent, rien n'est
  # ecrit, et taire cette ligne-la cacherait la seule trace du probleme.
  #
  # Elle portait en plus le nom du catalogue livre en dur — troisieme copie, dans la livraison meme
  # qui l'a recentre dans `Fleet.Catalogue`. La relecture independante du 2026-08-21 a vu la copie ;
  # la mutation a montre que le temoin ne rougissait pas, ce qui a montre la clause morte. Retirer
  # bat parametrer : un littereal qui n'existe plus ne peut pas deriver.
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
