defmodule Fleet.Pipeline.Deliverable do
  @moduledoc """
  Publication unifiée du livrable d'un pod — **un seul** module, deux modes sélectionnés
  par `spec.deliverable_mode` au catalogue (condition d'entrée), PAS deux modules déguisés. Filtre
  unification : « différenciation par catalogue, pas par branche de code » (même règle que
  `lifetime_scope`).

  Frontière pod↔système. Le pod produit du CONTENU (un payload de fichiers, OU des commits git natifs) ;
  le système le transforme en livrable durable poussé sur la forge. Le pod n'a conscience NI des
  branches NI de la forge (forge-aveugle) — c'est le système qui choisit la branche cible et
  pousse. `git` donne l'isolation du livrable ; `bwrap` donne l'isolation du FS.

  ## Les trois temps (ordre fixe, identique aux 2 modes pour 2 et 3)

      1. CONTENU (seule branche du mode) :
         :payload    → `apply_payload` (écrit les fichiers) + `Git.commit` (le SYSTÈME commite)
         :git_native → l'agent a déjà commité → on vérifie juste qu'un commit existe (base != HEAD)
      2. GATE DURCIE — PARTAGÉE : `DeliverableGate.verify` (base ancêtre, identité, secrets).
         Un livrable invalide est rendu irreprésentable au push (pas rattrapé après).
      3. PUSH borné — `Git.push(remote, local_ref:target_branch)` sinon fail-loud.

  `base_sha` est verrouillée HORS du pod (capturée par le rail forge-driven, épinglée au clone par
  `ProjectBootstrap.pin_base_sha`) — le pod ne peut pas la falsifier. La gate lit le `.git` du
  workspace en read-only et ne croit AUCUNE assertion du pod.

  Garde-fou unification : la SEULE divergence de mode est le temps 1 (qui commite). Les temps 2 et 3
  sont strictement partagés. Si un jour le `case mode` métastase (un `if` qui sépare 80 % du tronc),
  l'unification est à reconsidérer.
  """

  require Logger

  alias Fleet.Pipeline.{DeliverableGate, Git}

  @type mode :: :payload | :git_native

  @type opts :: %{
          required(:mode) => mode(),
          required(:workspace) => Path.t(),
          required(:base_sha) => String.t(),
          required(:allowed_emails) => [String.t()],
          optional(:remote) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:push?) => boolean(),
          optional(:local_ref) => String.t(),
          # Rôle attendu pour le trailer `Co-authored-by` ; nil/absent → skip.
          optional(:coauthor_role) => String.t() | nil,
          # mode :payload uniquement
          optional(:files) => [map()],
          optional(:identity) => map(),
          optional(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  @type result :: %{commit_sha: String.t(), pushed?: boolean(), mode: mode()}

  # Neutralisation config (hooks/fsmonitor/sshCommand/diff.external/attributesFile global) — SOURCE
  # UNIQUE `Fleet.Credentials.Shell.git_safe_config_args/0`, composée sur toute invocation git côté monde
  # sur le workspace pod (défense en profondeur ; head_sha/head_advanced sont des rev-parse, mais coût nul
  # et on garde l'uniformité avec les ops qui, elles, exécuteraient du code config-driven).
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  @common_keys [:mode, :workspace, :base_sha, :allowed_emails]
  @payload_keys [:files, :identity, :message]
  @identity_keys [:author_name, :author_email, :committer_name, :committer_email]

  @doc """
  Publie le livrable : CONTENU (mode) → GATE (partagée) → PUSH. Retourne `{:ok, %{commit_sha,
  pushed?, mode}}` ou le PREMIER `{:error, reason}` (fail-loud à chaque temps ; aucun push si la gate
  refuse). `push?` défaut `true` ; `local_ref` défaut `"HEAD"`.
  """
  @spec publish(opts()) :: {:ok, result()} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate(opts),
         :ok <- materialize_content(opts),
         {:ok, :verified} <-
           DeliverableGate.verify(
             opts.workspace,
             opts.base_sha,
             opts.allowed_emails,
             Map.get(opts, :coauthor_role)
           ),
         {:ok, sha} <- head_sha(opts.workspace),
         {:ok, pushed?} <- push_deliverable(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?, mode: opts.mode}}
    end
  end

  # ============================================================
  # Validation (fail-closed)
  # ============================================================

  defp validate(opts) do
    with :ok <- check_keys(opts, @common_keys),
         :ok <- check_mode(opts.mode),
         :ok <- check_mode_keys(opts),
         :ok <- check_push_keys(opts) do
      :ok
    end
  end

  defp check_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_mode(m) when m in [:payload, :git_native], do: :ok
  defp check_mode(m), do: {:error, {:invalid_mode, m}}

  # Mode payload : les clés de contenu sont requises. Mode git_native : le contenu vient du pod, rien
  # à fournir (la présence du commit est vérifiée à `materialize_content`).
  defp check_mode_keys(%{mode: :payload} = opts) do
    with :ok <- check_keys(opts, @payload_keys),
         :ok <- check_keys(opts.identity, @identity_keys) do
      :ok
    end
  end

  defp check_mode_keys(_opts), do: :ok

  # Push (défaut true) requiert remote + target_branch + un refspec bien formé. Si push?
  # explicitement false (commit local), ils sont facultatifs.
  defp check_push_keys(opts) do
    if push?(opts) do
      with :ok <- check_keys(opts, [:remote, :target_branch]),
           :ok <- check_ref(opts.target_branch),
           :ok <- check_ref(local_ref(opts)) do
        :ok
      end
    else
      :ok
    end
  end

  # Validation du refspec (`<local_ref>:<target_branch>`) déléguée à l'AUTORITÉ UNIQUE
  # `Fleet.Pipeline.GitRef` (la regex check-ref-format vivait ici en double avec `Git`). On garde la
  # forme d'erreur typée propre à ce module (qui porte le `ref` fautif).
  defp check_ref(ref) do
    if Fleet.Pipeline.GitRef.valid?(ref), do: :ok, else: {:error, {:invalid_ref, ref}}
  end

  # ============================================================
  # Temps 1 — CONTENU (seule divergence de mode)
  # ============================================================

  defp materialize_content(%{mode: :payload} = opts) do
    with :ok <- apply_payload_files(opts.workspace, opts.files),
         {:ok, _sha} <- Git.commit(commit_opts(opts)) do
      :ok
    end
  end

  # git_native : l'agent a commité dans le pod. On NE crée rien — on vérifie juste qu'un livrable
  # existe (HEAD a avancé depuis base). Range vide = le brief n'a produit aucun commit → fail-loud
  # (la gate, elle, passe sur range vide par vacuité ; la présence d'un commit est un concern mode-side).
  # Le cas « HEAD != base mais historique réécrit » passe ici (avancé) et est rattrapé par la gate
  # (`base_not_ancestor`) — pas de double check ici.
  defp materialize_content(%{mode: :git_native} = opts) do
    if head_advanced?(opts.workspace, opts.base_sha),
      do: :ok,
      else: {:error, :no_deliverable_commit}
  end

  defp head_advanced?(workspace, base_sha) do
    case System.cmd("git", @hooks_off ++ ["-C", workspace, "rev-parse", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != base_sha
      _ -> false
    end
  end

  # Atomicité best-effort + sécu path traversal. 2 passes : (1) valide TOUS les paths avant toute
  # écriture ; (2) écrit. Source unique de l'application payload : une seule autorité de placement
  # du livrable (un placement divergent est rendu irreprésentable).
  defp apply_payload_files(workspace, files) when is_list(files) and files != [] do
    with :ok <- validate_payload_files(workspace, files) do
      write_validated_files(workspace, files)
    end
  end

  defp apply_payload_files(_workspace, _other), do: {:error, :no_files_in_payload}

  defp validate_payload_files(workspace, files) do
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

          # Un payload écrivant SOUS `.git/` (à n'importe quel niveau du chemin) réécrirait la config du
          # repo — `.git/config` (armer un `filter.<nom>.clean = <cmd>` exécuté par le `git add` système-side
          # qui suit), `.git/hooks/pre-commit`, etc. → exécution de commande arbitraire côté monde au commit.
          # Le pod ne pose JAMAIS sa propre plomberie git via le payload : on refuse fail-closed tout
          # composant `.git`. (Le commit système-side est ce qui transforme ce contenu en livrable, donc le
          # payload est consommé APRÈS écriture → la garde DOIT être ici, avant l'écriture.)
          dotgit_component?(rel_path) ->
            {:halt, {:error, {:dotgit_path, rel_path}}}

          # Un `.gitattributes` (à n'importe quel niveau) dont le contenu ARME un `filter=` ou un `diff=`
          # détourne `git add`/`git log -p` système-side vers une commande externe (le driver `clean`/
          # `textconv` correspondant). `core.attributesFile=/dev/null` ne neutralise QUE le fichier d'attributs
          # GLOBAL ; le `.gitattributes` IN-TREE reste honoré et n'est PAS désactivable par `-c` (git n'a aucun
          # « disable all filters »). Le SEUL verrou réel de ce vecteur est donc CE refus de contenu : on rejette
          # fail-closed le payload qui armerait un attribut de filtrage/diff exécutable.
          gitattributes_basename?(rel_path) and arms_filter_or_diff?(content) ->
            {:halt, {:error, {:dangerous_gitattributes, rel_path}}}

          # `Path.expand` est LEXICAL (résout `..`, PAS les symlinks). Un symlink checké-in
          # dans le repo cloné (`out -> /home/<human>/.claude`) passe le check de préfixe ci-dessus,
          # mais `File.write` SUIT le symlink → écriture HORS workspace. On rejette si un composant
          # EXISTANT du chemin (dossiers parents OU fichier cible déjà présent) est un symlink.
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

  defp commit_opts(opts) do
    opts.identity
    |> Map.take(@identity_keys)
    |> Map.merge(%{
      workspace: opts.workspace,
      message: opts.message,
      add_paths: Map.get(opts, :add_paths, ["."])
    })
  end

  # ============================================================
  # Temps 3 — PUSH (partagé)
  # ============================================================

  defp push_deliverable(opts) do
    if push?(opts) do
      refspec = "#{local_ref(opts)}:#{opts.target_branch}"
      Git.push(opts.workspace, opts.remote, refspec)
    else
      {:ok, false}
    end
  end

  defp push?(opts), do: Map.get(opts, :push?, true)
  defp local_ref(opts), do: Map.get(opts, :local_ref, "HEAD")

  defp head_sha(workspace) do
    case System.cmd("git", @hooks_off ++ ["-C", workspace, "rev-parse", "HEAD"],
           stderr_to_stdout: true
         ) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {err, rc} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
    end
  end
end
