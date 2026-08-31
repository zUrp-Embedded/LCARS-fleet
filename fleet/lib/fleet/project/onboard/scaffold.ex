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
  projet depuis le catalogue de référence, quel que soit le sien : un projet naît du template de
  `fleet` pendant que son propre catalogue livre des fichiers que rien ne lit jamais. Un arbre
  présent dans un catalogue et inatteignable par tout appelant n'est pas une fonctionnalité en
  attente de câblage, c'est du poids mort qui a l'air câblé.

  La résolution vit ICI et pas dans une couche template, parce que c'est ce chemin-ci qui peuple un
  projet neuf.

  ## Le repli, et pourquoi il est ANNONCÉ

  ⚖ user : *« le template, on peut prendre celui de fleet par défaut s'il n'y en a pas,
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
  # il scaffolde depuis le livre sans que personne ne l ait decide — le meme defaut que ci-dessus,
  # avec une cause de plus : l absence d argument au lieu d une resolution cablee en dur. Il monte
  # donc d un cran : `warning`.
  # ⚠ PAS DE CLAUSE QUI TAIRAIT LE REPLI DU CATALOGUE LIVRE : elle serait MORTE, puisque
  # `root_for(<nom livre>)` rend la racine livree, qui porte son propre `project_template/` — donc
  # `:own`, jamais `:fallback`. Le seul monde ou elle tirerait est celui d'un release dont le
  # catalogue livre n'a pas d'arbre : la racine de repli y est le MEME repertoire absent, rien n'est
  # ecrit, et taire cette ligne-la cacherait la seule trace du probleme. Une telle clause porterait
  # en plus le nom du catalogue livre en dur, troisieme copie d'un nom qui vit dans
  # `Fleet.Catalogue` — et retirer bat parametrer : un litteral qui n'existe pas ne peut pas
  # deriver.
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
      "CI_STANCE" => ci_stance_line(Keyword.get(opts, :ci_stance, :required)),
      "REPO_DESCRIPTION" => pitch,
      "YEAR" => year,
      "MONTH" => month,
      "DAY" => day
    }
  end

  # LE RAIL LIVRE EST VERT DES DEUX COTES — `protect_main` exige `CI / *` pour TOUT LE MONDE, et ce
  # mur ne se negocie pas : c'est lui qui empeche une main humaine de passer a cote du rail. Ce qui
  # change avec la carte n'est donc PAS l'existence du statut, c'est ce que ce vert VEUT DIRE, et
  # personne ne le disait.
  #
  #   `required` — la carte a quelque chose a prouver : ce vert est un PLACEHOLDER, et le projet le
  #               remplace par sa suite le jour ou il sait ce qu'il est.
  #   `ignore`   — la carte declare n'avoir rien a prouver (PoC jetable, smoke technique, audit sans
  #               code) : ce vert est le RECU du plancher, pas une preuve. Y poser une suite
  #               gaterait un livrable que personne n'attend.
  #
  # Le defaut est `required` : une carte qu'on n'a pas su lire recoit l'invitation a prouver, jamais
  # la dispense.
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
  RÉÉCRIT le rail CI de `dir` depuis le template — celui-là écrase, et c'est tout ce qui le sépare
  de `ci_workflows/3`.

  **POURQUOI DEUX PORTES ET PAS UN DRAPEAU.** `ci_workflows/3` n'écrase JAMAIS, délibérément : un
  dépôt importé porte peut-être sa propre CI, et un humain en a peut-être écrit une à la main après
  s'être cogné au mur. Les deux sont des réponses, et les remplacer par un placeholder serait pire
  que le trou. Cette porte-ci fait exactement ce que l'autre refuse, donc elle ne peut pas être une
  option de l'autre : on ne se trompe pas de porte par défaut.

  **CE QU'ELLE EXISTE POUR DÉBLOQUER.** Un `ci.yml` cassé — image sans `node`, `runs-on:` qu'aucun
  runner ne sert, workflow renommé hors de `CI` — ne produit plus le statut que la protection de
  `main` exige. Aucune PR ne fusionne, et personne ne peut le réparer côté forge : les humains y
  sont en `read`. Le rail livré, lui, est vert par construction (`no-harness-yet` echo). Le
  remettre est la sortie de secours, et elle est EXPLICITE : personne ne l'appelle par accident.
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
