defmodule Fleet.Pipeline.DeliverableGate do
  @moduledoc """
  Gate de livrable (rend un état invalide irreprésentable au push) — vérifie MÉCANIQUEMENT, côté monde (Elixir), qu'un workspace
  de pod peut être poussé sur la forge. N'a PAS confiance dans le pod : lit son `.git` en read-only,
  ne lit aucune assertion du pod. Chaque check raté = fail-loud typé `{:error, reason}` (le push
  n'a PAS lieu). Partagé par les deux modes (`payload` / `git_native`) de `Fleet.Pipeline.Deliverable`.

  Les trois invariants vérifiés :

  - **base ancêtre** `check_base_ancestor/2` — la base SHA (capturée hors-pod au clone) DOIT être ancêtre
    de HEAD : pas de réécriture d'historique (`git reset --hard base~5` rejeté).
  - **identité** `check_identity/3` — tous les commits `base..HEAD` ont author ET committer ∈ identités
    autorisées (`LCARS-<role>`) : l'identité est vérifiée au boundary monde, pas crue depuis le pod.
  - **secrets** `scan_secrets/2` — aucun secret dans le diff `base..HEAD` (le pod a un token OAuth en env ;
    `env > t && git add -A && commit` doit être bloqué avant push).

  La branche cible système-choisie et l'isolation réseau forge sont hors de ce module
  (resp. `Fleet.Pipeline.Deliverable.publish` et le containment bwrap).
  """

  @git_timeout_ms 15_000

  # Patterns haut-signal (faible faux-positif). Le token OAuth du pod est un JWT `eyJ…`.
  @secret_patterns [
    {~r/sk-ant-[A-Za-z0-9_\-]{8,}/, "anthropic_key"},
    {~r/eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}/, "jwt_token"},
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private_key"},
    {~r/AKIA[0-9A-Z]{16}/, "aws_access_key"},
    {~r/ghp_[A-Za-z0-9]{36}/, "github_pat"}
  ]

  # Fichiers interdits dans un diff (creds/secrets par nom). Match sur basename.
  @secret_file_re ~r/(^|\/)(\.credentials\.json|\.env(\..+)?|\.netrc|\.tok|id_rsa.*|.*\.pem|.*\.key)$/

  @type reason ::
          {:base_not_ancestor, String.t()}
          | {:bad_identity, [String.t()]}
          | {:missing_coauthor_trailer, String.t(), [String.t()]}
          | {:secret_detected, String.t(), String.t()}
          | {:git_error, term()}
          # Timeout git distinct du diagnostic « pas ancêtre » et de l'erreur git dure.
          | {:git_timeout, term()}

  @doc """
  Composite : tous les checks sur `[base_sha..HEAD]` du `workspace`. `allowed_emails` = la liste
  des emails d'identité acceptés (typiquement `["<role>@lcars.local"]`). `{:ok, :verified}` ou le
  PREMIER `{:error, reason}`. Ordre : base → identité → secrets.
  """
  @spec verify(Path.t(), String.t(), [String.t()], String.t() | nil) ::
          {:ok, :verified} | {:error, reason()}
  def verify(workspace, base_sha, allowed_emails, expected_role \\ nil) do
    with :ok <- check_base_ancestor(workspace, base_sha),
         :ok <- check_identity(workspace, base_sha, allowed_emails),
         :ok <- maybe_check_trailer(workspace, base_sha, expected_role),
         :ok <- scan_secrets(workspace, base_sha) do
      {:ok, :verified}
    end
  end

  # Volet trailer-rôle de l'identité, opt-in par `expected_role`. nil → skip (mode
  # payload système / back-compat). Posé en `git_native` (le pod commite + signe son rôle).
  defp maybe_check_trailer(_workspace, _base_sha, nil), do: :ok

  defp maybe_check_trailer(workspace, base_sha, role) when is_binary(role),
    do: check_coauthor_trailer(workspace, base_sha, role)

  @doc "`base_sha` doit être un ancêtre de HEAD (pas de réécriture d'historique)."
  @spec check_base_ancestor(Path.t(), String.t()) :: :ok | {:error, reason()}
  def check_base_ancestor(workspace, base_sha) do
    case git(workspace, ["merge-base", "--is-ancestor", base_sha, "HEAD"]) do
      {_out, 0} ->
        :ok

      # RÉSULTAT GIT TYPÉ par rc (rc1/rc128/rc124 distincts) : mapper TOUT rc≠0 sur
      # `{:base_not_ancestor}` FAUX-DIAGNOSTIQUERAIT un sha-invalide (rc128, repo corrompu) ou un TIMEOUT
      # (rc124, rendu par le helper `git/2`) en « base pas ancêtre » → traque dans la mauvaise direction.
      # SEUL rc1 (la réponse PROPRE de `--is-ancestor` : « pas ancêtre ») est `:base_not_ancestor` ;
      # rc128 = `:git_error` (sha invalide/repo cassé) ; rc124 = `:git_timeout`.
      {_out, 1} ->
        # Message DIAGNOSTIQUE. `merge-base --is-ancestor` ne sort RIEN sur le cas nominal d'échec
        # (base valide mais pas ancêtre de HEAD, ex. un rebase a réécrit par-dessus) → un
        # `{:base_not_ancestor, ""}` nu est intraçable. On embarque le `base_sha` (court) : un seul log
        # dit « telle base ⊄ HEAD » → la cause (clone-base au lieu de la cible du rebase) saute aux yeux.
        {:error, {:base_not_ancestor, "#{String.slice(to_string(base_sha), 0, 12)} ⊄ HEAD"}}

      {_out, 124} ->
        {:error, {:git_timeout, "merge-base --is-ancestor timeout"}}

      {out, 128} ->
        {:error,
         {:git_error, "merge-base rc128 (sha invalide / repo corrompu) : #{String.trim(out)}"}}

      # Tout autre rc inattendu : fail-closed en `:git_error` (jamais un faux `base_not_ancestor`).
      {out, rc} ->
        {:error, {:git_error, "merge-base rc#{rc} : #{String.trim(out)}"}}
    end
  end

  @doc """
  Tous les commits `base..HEAD` ont author email ET committer email ∈ `allowed`.
  Range vide (aucun commit) → `:ok` (vacuité ; la présence d'un commit est gérée hors-gate, mode-side).
  """
  @spec check_identity(Path.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def check_identity(workspace, base_sha, allowed) do
    case git(workspace, ["log", "#{base_sha}..HEAD", "--format=%ae%n%ce"]) do
      {out, 0} ->
        # Un commit à author/committer email VIDE ne doit PAS contourner la gate : `String.split(…,
        # trim: true)` DROPPERAIT les lignes vides → l'email vide ne serait JAMAIS comparé à l'allow-list →
        # `Enum.reject([])` = `[]` → `:ok` (contournement). Un email VIDE est une identité ILLÉGALE (pas
        # `LCARS-<role>`) → il DOIT être rejeté, pas escamoté.
        #
        # ANTI-RÉGRESSION : ne PAS forcer un séparateur `%x00` qui produirait un faux positif terminal
        # `[""]` cassant TOUT livrable propre. La discrimination est NETTE :
        #   - range VIDE (aucun commit) → git rend `out == ""` (0 byte) → `:ok` (vacuité) ;
        #   - 1 commit à emails vides → git rend `"\n\n"` (2 bytes) → on retire le SEUL `\n` FINAL
        #     (`replace_suffix`, PAS `trim_trailing` qui mangerait AUSSI les lignes-emails-vides et
        #     re-confondrait avec le range vide) → `"\n"` → split → `["", ""]` → emails vides détectés.
        #   - livrable propre → emails non-vides → aucun `""` → :ok.
        case out do
          # Range vide (aucun nouveau commit) → `:ok` (vacuité ; présence d'un commit gérée mode-side).
          "" ->
            :ok

          _ ->
            emails =
              out
              |> String.replace_suffix("\n", "")
              |> String.split("\n")
              |> Enum.map(&String.trim/1)

            allowed_set = MapSet.new(allowed)

            # Un email vide (`""`) n'est JAMAIS dans l'allow-list (`<role>@lcars.local`) → rejeté par
            # `Enum.reject` au même titre qu'un email usurpé. On le rend EXPLICITE dans le diagnostic
            # (`<empty-email>`) pour ne pas afficher une chaîne vide illisible dans le `{:bad_identity}`.
            case Enum.reject(emails, &MapSet.member?(allowed_set, &1)) do
              [] -> :ok
              bad -> {:error, {:bad_identity, bad |> Enum.map(&label_email/1) |> Enum.uniq()}}
            end
        end

      {out, _rc} ->
        {:error, {:git_error, String.trim(out)}}
    end
  end

  # Rend un email vide LISIBLE dans le diagnostic `{:bad_identity}` (sinon `""` dans la liste passe
  # inaperçu). L'email reste rejeté par construction (pas dans l'allow-list) ; ceci ne change que l'affichage.
  defp label_email(""), do: "<empty-email>"
  defp label_email(e), do: e

  @doc """
  Volet trailer de l'identité — chaque commit `base..HEAD` porte le trailer
  `Co-authored-by: LCARS-<role>` ATTENDU (la signature machine du rôle est vérifiée au
  boundary monde, pas crue depuis le pod ; rôle ↔ stage = `expected_role`, posé par
  l'appelant). Range vide → `:ok` (vacuité). Un commit sans le trailer → fail-loud
  `{:missing_coauthor_trailer, expected_role, [sha…]}` (le push n'a pas lieu).

  Câblé dans `verify/4` via `expected_role` (opt-in). git_native → le pod signe
  son rôle (mandat instruit par `Pilot.MandateBuilder.build_mandate`) ; payload système → `nil` (skip).
  L'author git = l'humain ; le rôle = CE trailer, vérifié au boundary monde.
  """
  @spec check_coauthor_trailer(Path.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def check_coauthor_trailer(workspace, base_sha, expected_role) when is_binary(expected_role) do
    # Needle DÉRIVÉ du trailer canon (ForgeIdentity.coauthor_trailer = SOURCE UNIQUE) — on
    # prend le préfixe avant l'email (lenient sur l'adresse) tout en suivant tout changement de format
    # du owner ; pas de string inline qui se désaccorderait de l'instruction donnée au pod.
    needle =
      Fleet.Credentials.ForgeIdentity.coauthor_trailer(expected_role)
      |> String.split(" <")
      |> hd()

    # `%x00` (NUL) sépare les commits — un NUL ne peut pas apparaître dans un message git.
    case git(workspace, ["log", "#{base_sha}..HEAD", "--format=%H%x1f%B%x00"]) do
      {out, 0} ->
        missing =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.flat_map(fn chunk ->
            case String.split(chunk, <<0x1F>>, parts: 2) do
              [sha, body] -> if String.contains?(body, needle), do: [], else: [String.trim(sha)]
              _ -> []
            end
          end)

        case missing do
          [] -> :ok
          shas -> {:error, {:missing_coauthor_trailer, expected_role, shas}}
        end

      {out, _rc} ->
        {:error, {:git_error, String.trim(out)}}
    end
  end

  @doc """
  Scan PAR-COMMIT de `base..HEAD` : patterns secrets (tokens/keys) dans le CONTENU ajouté + noms de
  fichiers interdits. `:ok` si propre, sinon `{:error, {:secret_detected, kind, hint}}`.

  Le scan est PAR-COMMIT (`git log -p`/`--name-only`), PAS sur le diff NET `base..HEAD`. Le diff
  net est aveugle à un secret INTRODUIT puis RETIRÉ dans la chaîne (`env > t && commit` puis `rm t &&
  commit` → diff net VIDE), alors que le PUSH transfère TOUTE la chaîne → le secret resterait dans
  l'historique forge. Scanner chaque commit (miroir EXACT de ce que `check_identity`/
  `check_coauthor_trailer` font déjà sur la chaîne) ferme cette évasion : le commit qui a INTRODUIT le secret porte la ligne `+` fautive.
  """
  @spec scan_secrets(Path.t(), String.t()) :: :ok | {:error, reason()}
  def scan_secrets(workspace, base_sha) do
    with :ok <- scan_secret_filenames(workspace, base_sha),
         :ok <- scan_secret_content(workspace, base_sha) do
      :ok
    end
  end

  defp scan_secret_filenames(workspace, base_sha) do
    # `log --name-only` liste les fichiers touchés PAR CHAQUE commit de la chaîne (un fichier secret
    # ajouté puis supprimé apparaît dans le commit d'ajout), là où `diff --name-only base..HEAD` ne verrait
    # que le NET (fichier supprimé en bout de chaîne → invisible). `--pretty=format:` supprime les en-têtes
    # de commit (on ne veut que les noms de fichiers).
    #
    # `--diff-merges=first-parent` : SANS lui, `git log -p` n'émet AUCUN diff pour un commit de MERGE → un
    # fichier interdit introduit UNIQUEMENT dans l'arbre RÉSOLU d'un evil-merge (présent dans NI l'un NI
    # l'autre parent, base toujours ancêtre, auteur légitime) passerait le scan et serait poussé. L'option
    # fait émettre, pour chaque merge, le delta vs son PREMIER parent (= ce que le merge introduit dans la
    # mainline) → le fichier de l'arbre résolu redevient visible. N'altère PAS le scan linéaire (chaque
    # commit non-merge garde son diff par-commit).
    case git(workspace, [
           "log",
           "-p",
           "--name-only",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        files = String.split(out, "\n", trim: true)

        case Enum.find(files, &Regex.match?(@secret_file_re, &1)) do
          nil -> :ok
          f -> {:error, {:secret_detected, "blacklisted_file", f}}
        end

      {out, _rc} ->
        {:error, {:git_error, String.trim(out)}}
    end
  end

  defp scan_secret_content(workspace, base_sha) do
    # `git log -p --unified=0` rend le diff DE CHAQUE COMMIT individuellement (pas le net) → un
    # secret introduit-puis-retiré porte sa ligne `+` dans le commit d'introduction. Seules les lignes
    # AJOUTÉES (`+`) comptent — on ne bloque pas sur du contexte préexistant.
    #
    # `--diff-merges=first-parent` : SANS lui, `git log -p` n'émet AUCUN diff pour un commit de MERGE → un
    # secret introduit UNIQUEMENT dans l'arbre RÉSOLU d'un evil-merge (présent dans NI l'un NI l'autre
    # parent) passerait le scan et serait poussé dans l'historique forge. L'option fait émettre, pour
    # chaque merge, le delta vs son PREMIER parent (= ce que le merge introduit dans la mainline) → la
    # ligne `+` du secret de l'arbre résolu redevient visible. N'altère PAS le scan linéaire.
    case git(workspace, [
           "log",
           "-p",
           "--unified=0",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        added =
          out
          |> String.split("\n")
          |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
          |> Enum.join("\n")

        case Enum.find_value(@secret_patterns, fn {re, kind} ->
               if Regex.match?(re, added), do: kind, else: nil
             end) do
          nil -> :ok
          kind -> {:error, {:secret_detected, kind, "diff added lines"}}
        end

      {out, _rc} ->
        {:error, {:git_error, String.trim(out)}}
    end
  end

  # `git -C <ws> <args>` borné (push/diff réseau ou gros packfile ne bloquent pas le GenServer).
  # Neutralisation config — SOURCE UNIQUE `Fleet.Credentials.Shell.git_safe_config_args/0` (hooks +
  # fsmonitor + sshCommand + diff.external + attributesFile global), composée sur TOUTE invocation git côté
  # monde sur un workspace co-écrit par le pod. LOAD-BEARING ici : `scan_secrets` lance `git log -p`, qui
  # exécute un `diff.external`/textconv armé par le pod = exécution de commande arbitraire côté monde au
  # moment du scan de livrable. Le `diff.external=` du set le désarme (les autres flags ferment hooks et
  # consorts par uniformité, coût nul).
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  defp git(workspace, args) do
    task =
      Task.async(fn ->
        System.cmd("git", @hooks_off ++ ["-C", workspace] ++ args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"git timeout (#{@git_timeout_ms}ms)", 124}
    end
  end
end
