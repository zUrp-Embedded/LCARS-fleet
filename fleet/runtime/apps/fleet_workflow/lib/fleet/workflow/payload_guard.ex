defmodule Fleet.Workflow.PayloadGuard do
  @moduledoc """
  Placement + validation-SÉCURITÉ d'un payload de fichiers NON FIABLE dans un
  workspace : « écrire ce que le pod a produit, sans qu'il puisse s'évader du
  workspace ni armer la plomberie git côté monde ». Filtre autonome, extrait
  de `Fleet.Workflow.Deliverable` (éclatement C4 2026-07-05) — il ne sait rien
  des modes de livrable, de la gate ni du push : il ne connaît qu'un workspace
  et une liste `%{"path" => …, "content" => …}` adverses.

  Source UNIQUE de l'application payload : une seule autorité de placement du
  livrable (un placement divergent est rendu irreprésentable). Atomicité
  best-effort en 2 passes : (1) valider TOUS les paths avant toute écriture ;
  (2) écrire — un payload partiellement invalide n'écrit RIEN.

  ## Les 4 vecteurs fermés (fail-closed, premier refus rendu)

    * **Path traversal** — `Path.expand` du join doit rester sous le workspace
      (un `../` résolu hors racine → `{:path_traversal, path}`).
    * **Composant `.git`** — un payload écrivant SOUS `.git/` (à n'importe quel
      niveau) réécrirait la config du repo : `.git/config` (armer un
      `filter.<nom>.clean` exécuté par le `git add` système-side qui suit),
      `.git/hooks/pre-commit`, etc. → exécution de commande arbitraire côté
      monde au commit. Le pod ne pose JAMAIS sa propre plomberie git via le
      payload → `{:dotgit_path, path}`. (Le commit système-side est ce qui
      transforme ce contenu en livrable, donc le payload est consommé APRÈS
      écriture → la garde DOIT être ici, avant l'écriture.)
    * **`.gitattributes` armé** — un `.gitattributes` dont le contenu ARME un
      `filter=` ou un `diff=` détourne `git add`/`git log -p` système-side vers
      une commande externe. `core.attributesFile=/dev/null` ne neutralise QUE
      le fichier GLOBAL ; le `.gitattributes` IN-TREE reste honoré et n'est PAS
      désactivable par `-c` (git n'a aucun « disable all filters »). Le SEUL
      verrou réel de ce vecteur est donc CE refus de contenu →
      `{:dangerous_gitattributes, path}`.
    * **Symlink dans la chaîne** — `Path.expand` est LEXICAL (résout `..`, PAS
      les symlinks) : un symlink checké-in dans le repo cloné
      (`out -> /home/<human>/.claude`) passe le check de préfixe, mais
      `File.write` SUIT le symlink → écriture HORS workspace. Refus si un
      composant EXISTANT du chemin est un symlink → `{:symlink_escape, path}`.

  L'entrée publique unique (`apply_files/2`) enchaîne validation puis écriture :
  écrire sans valider est impossible par construction (la validation n'est pas
  une étape optionnelle exposée).
  """

  @doc """
  Valide puis écrit `files` (liste de `%{"path" => rel, "content" => bin}`)
  sous `workspace`. 2 passes : TOUT est validé (cf. moduledoc — traversal,
  `.git`, `.gitattributes` armé, symlink) avant la MOINDRE écriture.

  ## Exit codes
    * `:ok` — tous les fichiers écrits
    * `{:error, :no_files_in_payload}` — liste vide ou pas une liste
    * `{:error, {:invalid_payload_file, repr}}` — entrée sans `path`/`content`
      binaires, ou `path` vide (un path `""` passerait les checks puis
      `File.write` sur le dir = `:eisdir` opaque — rejet propre en amont)
    * `{:error, {:path_traversal | :dotgit_path | :dangerous_gitattributes |
      :symlink_escape, rel_path}}` — vecteur refusé (rien n'est écrit)
    * `{:error, {:file_write_failed, rel_path, reason}}` — écriture KO en
      passe 2 (les fichiers déjà écrits restent — atomicité best-effort)
  """
  @spec apply_files(Path.t(), term()) :: :ok | {:error, term()}
  def apply_files(workspace, files) when is_list(files) and files != [] do
    with :ok <- validate_files(workspace, files) do
      write_validated_files(workspace, files)
    end
  end

  def apply_files(_workspace, _other), do: {:error, :no_files_in_payload}

  defp validate_files(workspace, files) do
    expanded_ws = Path.expand(workspace)

    Enum.reduce_while(files, :ok, fn
      # `rel_path` non-vide — un path "" passe les checks (Path.expand → workspace,
      # symlink_in_chain? sur [] → false) puis File.write sur le dir = :eisdir opaque. Rejet propre.
      %{"path" => rel_path, "content" => content}, :ok
      when is_binary(rel_path) and rel_path != "" and is_binary(content) ->
        full = Path.expand(Path.join(workspace, rel_path))

        cond do
          not (full == expanded_ws or String.starts_with?(full, expanded_ws <> "/")) ->
            {:halt, {:error, {:path_traversal, rel_path}}}

          dotgit_component?(rel_path) ->
            {:halt, {:error, {:dotgit_path, rel_path}}}

          gitattributes_basename?(rel_path) and arms_filter_or_diff?(content) ->
            {:halt, {:error, {:dangerous_gitattributes, rel_path}}}

          symlink_in_chain?(workspace, rel_path) ->
            {:halt, {:error, {:symlink_escape, rel_path}}}

          true ->
            {:cont, :ok}
        end

      bad, :ok ->
        {:halt, {:error, {:invalid_payload_file, inspect(bad)}}}
    end)
  end

  # Vrai si UN composant du chemin relatif est exactement `.git` (`.git/config`, `a/.git/hooks/x`, …).
  # Comparaison sur les COMPOSANTS (pas un substring) : un fichier nommé `.gitignore` ou `foo.git`
  # n'est PAS un composant `.git` et reste autorisé. Ferme la réécriture de la plomberie git du repo.
  defp dotgit_component?(rel_path) do
    rel_path |> Path.split() |> Enum.any?(&(&1 == ".git"))
  end

  # Vrai si le BASENAME du chemin est `.gitattributes` (à n'importe quel niveau : `.gitattributes`,
  # `sub/.gitattributes`). C'est ce fichier qui mappe un pattern de fichiers vers un `filter`/`diff` driver.
  defp gitattributes_basename?(rel_path) do
    Path.basename(rel_path) == ".gitattributes"
  end

  # Vrai si le CONTENU d'un `.gitattributes` arme un attribut `filter=<x>` ou `diff=<x>` — ce sont les deux
  # attributs qui détournent `git add` (`clean`) ou `git log -p`/`diff` (`textconv`) vers une commande
  # externe configurée. On reste large (ligne contenant `filter=`/`diff=`, non-vide), fail-closed : mieux
  # vaut refuser un `.gitattributes` bénin portant `diff=python` que laisser passer un armement. Les autres
  # attributs (`text`, `eol`, `binary`, `merge=`…) n'exécutent pas de commande externe → non bloqués.
  defp arms_filter_or_diff?(content) do
    Regex.match?(~r/(^|\s)(filter|diff)=\S/m, content)
  end

  # Vrai si un composant EXISTANT du chemin (de workspace au fichier) est un symlink. `lstat` ne
  # suit pas le lien (stat le lien lui-même) → on détecte le vecteur d'évasion avant tout write.
  defp symlink_in_chain?(workspace, rel_path) do
    rel_path
    |> Path.split()
    |> Enum.scan(workspace, fn part, acc -> Path.join(acc, part) end)
    |> Enum.any?(&symlink?/1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp write_validated_files(workspace, files) do
    Enum.reduce_while(files, :ok, fn
      %{"path" => rel_path, "content" => content}, :ok ->
        full_path = Path.join(workspace, rel_path)

        with :ok <- File.mkdir_p(Path.dirname(full_path)),
             :ok <- File.write(full_path, content) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:file_write_failed, rel_path, reason}}}
        end
    end)
  end
end
