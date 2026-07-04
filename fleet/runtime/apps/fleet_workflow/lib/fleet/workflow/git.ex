defmodule Fleet.Workflow.Git do
  @moduledoc """
  Mécanisme système-side de publication git post-EXTRACT. Composé par le rail
  d'orchestration sur `pod.completed`, lorsque la step déclare `post_extract.git`,
  pour transformer le travail du pod en commit (puis push) côté monde.

  Pure data → action :
    * input  : workspace path, identités auteur/committer, message, branch,
      add_paths, remote, push?
    * action : `git add <paths> → git commit → [git push <remote> <branch>]`
    * output : `{:ok, %{commit_sha, pushed?}}` ou `{:error, term()}`

  Fail-closed strict : `--force` et `--no-verify` ne sont **JAMAIS** composés
  par le module. Si un cas futur nécessite un override, ce sera une décision
  explicite avec audit, pas une option par défaut.

  Identités distinctes : `author_*` reflète l'identité du worker (role) ;
  `committer_*` reflète l'identité système. Natif git
  (`GIT_AUTHOR_*` ≠ `GIT_COMMITTER_*`).
  """

  require Logger

  @type opts :: %{
          required(:workspace) => Path.t(),
          required(:author_name) => String.t(),
          required(:author_email) => String.t(),
          required(:committer_name) => String.t(),
          required(:committer_email) => String.t(),
          required(:message) => String.t(),
          required(:branch) => String.t(),
          optional(:remote) => String.t(),
          optional(:add_paths) => [String.t()],
          optional(:push?) => boolean()
        }

  @required_keys [
    :workspace,
    :author_name,
    :author_email,
    :committer_name,
    :committer_email,
    :message,
    :branch
  ]

  # `commit/1` ne pousse pas → `:branch`/`:remote` sont des concerns de push,
  # absents ici. L'identité (author/committer) + message + workspace suffisent.
  @commit_required_keys @required_keys -- [:branch]

  # Le workspace est CO-ÉCRIT par un pod adversaire ; `.git/hooks/`, `.git/config` et un `.gitattributes`
  # in-tree y sont posables par le pod. `git add`/`git commit`/`git push` sont lancés ICI, côté MONDE
  # (runtime Elixir, HORS bwrap) → un hook (`pre-commit`/`pre-push`), un filtre `clean`, une `sshCommand`
  # ou un `diff.external` armé par le pod s'exécuterait avec les privilèges du runtime = exécution de
  # commande arbitraire hors sandbox. On compose la SOURCE UNIQUE de neutralisation config
  # (`Fleet.Credentials.Shell.git_safe_config_args/0` : hooks + fsmonitor + sshCommand + diff.external +
  # attributesFile global) sur chaque op qui peut exécuter du code config-driven : le monde REFUSE
  # d'exécuter le code du pod plutôt que d'espérer qu'il n'en arme pas (mauvais état rendu impossible).
  # N'affecte PAS la doctrine `--no-verify JAMAIS` (qui protège l'appelant du module ; ici on neutralise
  # le mécanisme adversaire, pas la vérif d'intégrité de l'appelant). LIMITE honnête : un `filter.<nom>.clean`
  # IN-TREE (armé par un `.gitattributes` + `.git/config` du repo) n'est PAS désactivable par `-c` — c'est
  # le CONTENU validé en amont (`Deliverable` refuse les payloads écrivant `.git/**` ou un `.gitattributes`
  # armant `filter=`) qui ferme ce vecteur-là ; ici on ferme les vecteurs config globale/système + hooks.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  @doc """
  Compose la séquence git système-side (add → commit → [push]) dans
  `workspace`. Pure data → action ; pas d'état conservé.
  """
  @spec publish(opts) :: {:ok, %{commit_sha: String.t(), pushed?: boolean()}} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate_opts(opts),
         :ok <- ensure_git_workspace(opts.workspace),
         :ok <- git_add(opts),
         {:ok, sha} <- git_commit(opts),
         {:ok, pushed?} <- maybe_push(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?}}
    end
  end

  @doc """
  Commit-only — `git add <paths> → git commit` dans `workspace`, **sans push**. Sépare le
  CONTENU (le système commite le payload) de la PUBLICATION (`push/3` après la gate de livrable). Utilisé
  par `Fleet.Workflow.Deliverable` en mode `payload` ; `publish/1` reste le chemin couplé legacy
  (add+commit+push en un). Pas de `:branch`/`:remote` requis (concerns de push). Retourne le SHA du HEAD commité.
  """
  @spec commit(opts) :: {:ok, String.t()} | {:error, term()}
  def commit(opts) when is_map(opts) do
    with :ok <- check_required_keys(opts, @commit_required_keys),
         :ok <- check_workspace_string(opts.workspace),
         :ok <- ensure_git_workspace(opts.workspace),
         :ok <- git_add(opts),
         {:ok, sha} <- git_commit(opts) do
      {:ok, sha}
    end
  end

  # ============================================================
  # Validation
  # ============================================================

  defp validate_opts(opts) do
    with :ok <- check_required_keys(opts),
         :ok <- check_workspace_string(opts.workspace),
         :ok <- check_branch(opts.branch),
         :ok <- check_push_remote(opts) do
      :ok
    end
  end

  defp check_required_keys(opts), do: check_required_keys(opts, @required_keys)

  defp check_required_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_workspace_string(ws) when is_binary(ws) and ws != "", do: :ok
  defp check_workspace_string(_ws), do: {:error, :invalid_workspace}

  # Validation de la branche déléguée à l'AUTORITÉ UNIQUE `Fleet.Workflow.GitRef` (la regex check-ref-format
  # vivait ici en double avec `Deliverable`). On garde la forme d'erreur typée propre à ce module.
  defp check_branch(branch) do
    if Fleet.Workflow.GitRef.valid?(branch), do: :ok, else: {:error, :invalid_branch}
  end

  defp check_push_remote(%{push?: true} = opts) do
    case Map.get(opts, :remote) do
      # Rejet leading-`-` au plus tôt (publish/maybe_push) — `push/3` re-valide aussi.
      r when is_binary(r) and r != "" ->
        if String.starts_with?(r, "-"), do: {:error, {:invalid_remote, r}}, else: :ok

      _ ->
        {:error, :push_requires_remote}
    end
  end

  defp check_push_remote(_opts), do: :ok

  defp ensure_git_workspace(ws) do
    case {File.dir?(ws), File.dir?(Path.join(ws, ".git"))} do
      {false, _} -> {:error, :workspace_missing}
      {true, false} -> {:error, :not_a_git_workspace}
      {true, true} -> :ok
    end
  end

  # ============================================================
  # Git ops
  # ============================================================

  defp git_add(opts) do
    paths = Map.get(opts, :add_paths, ["."])

    case validate_add_paths(paths) do
      :ok ->
        # `--` termine les options → un pathspec commençant par `-` (ex. `add_paths = ["--all"]`
        # depuis un input non fiable) est traité comme un CHEMIN littéral, pas une option git. `System.cmd`
        # n'utilise pas de shell, mais GIT parse ses propres options : un arg leading-`-` est une option.
        # `@hooks_off` (neutralisation config) AVANT `add` : `git add` exécute le filtre `clean` armé par
        # un `.gitattributes`+`.git/config` du pod = exécution de commande arbitraire côté monde. Le set
        # neutralise les vecteurs config globale/système ; le vecteur in-tree (filtre nommé) est fermé en
        # amont côté CONTENU par `Deliverable` (cf. le commentaire de `@hooks_off`).
        # Borné par Shell.git (setsid + SIGKILL du process-GROUP OS à la deadline) : un `index.lock`
        # stale ferait pendre `git add` indéfiniment sans timeout -> le completer n'atteint jamais
        # l'unlock, l'issue reste wedgée `lcars-in-flight` sans recovery. Même pattern que `run_push`.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["add", "--" | paths],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms()
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_add_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_add_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_add_exit, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  # `add_paths` doit être une liste non vide de chemins binaires non vides (belt-and-suspenders
  # avec le séparateur `--`).
  defp validate_add_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_add_paths}
  end

  defp validate_add_paths(_), do: {:error, :invalid_add_paths}

  defp git_commit(opts) do
    with :ok <- run_commit(opts),
         {:ok, sha} <- read_head_sha(opts.workspace) do
      {:ok, sha}
    end
  end

  defp run_commit(opts) do
    # Pas de classification par grep "nothing to commit" sur stderr : ce serait
    # i18n-dependent (LC_ALL=fr_FR → "rien à valider" → grep rate → mauvaise
    # classification). Pre-check via `git diff --cached --quiet` (codes RC stables
    # across locales : 0 = pas de diff staged, 1 = diff staged). Évite le commit
    # entièrement quand `:nothing_to_commit`.
    case has_staged_changes?(opts.workspace) do
      false ->
        {:error, :nothing_to_commit}

      true ->
        # Borné (idem git_add). `env` explicite = identité du commit (commit_env) MERGÉE avec
        # `ForgeAuth.git_env/0` (GIT_TERMINAL_PROMPT=0) : Shell.git n'injecte son env par défaut QUE
        # si `:env` est absent -> on compose les deux (aucun chevauchement de clés : AUTHOR/COMMITTER
        # vs TERMINAL_PROMPT). Pas de régression, + la borne anti-prompt en cohérence.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["commit", "-m", opts.message],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms(),
               env: Fleet.Credentials.ForgeAuth.git_env() ++ commit_env(opts)
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_commit_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_commit_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_commit_exit, reason}}
        end
    end
  end

  defp has_staged_changes?(workspace) do
    # Borné + `@hooks_off` (uniformité : `diff` peut invoquer un `diff.external` armé par le pod ;
    # le set le désarme, cost nul — comme add/commit). Timeout/exit/code-inattendu → `true` (laisse
    # commit TENTER et reporter l'erreur avec contexte ; borne préservée : commit est lui aussi borné).
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["diff", "--cached", "--quiet"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      # Exit 0 = aucun diff staged → rien à commit.
      {:ok, {_, 0}} -> false
      # Exit 1 = diff staged présent (sémantique stable git).
      {:ok, {_, 1}} -> true
      # Autre code / timeout / exit = anomalie → laisse commit tenter et reporter.
      _ -> true
    end
  end

  defp commit_env(opts) do
    [
      {"GIT_AUTHOR_NAME", opts.author_name},
      {"GIT_AUTHOR_EMAIL", opts.author_email},
      {"GIT_COMMITTER_NAME", opts.committer_name},
      {"GIT_COMMITTER_EMAIL", opts.committer_email}
    ]
  end

  @doc """
  SHA de HEAD du `workspace`, **borné** (Shell.git : deadline + SIGKILL du process-group — un
  `rev-parse` pendu sur un FS malade ne bloque jamais l'appelant). Autorité UNIQUE du rev-parse
  système-side (X1/D4 2026-07-04 : `Deliverable` portait 2 copies via `System.cmd` BRUT non borné —
  un rev-parse pendu y bloquait la publication).
  """
  @spec read_head_sha(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read_head_sha(workspace) do
    # Borné + `@hooks_off` par uniformité (rev-parse ne lance aucun filtre/externe → les `-c` sont
    # inertes ici, mais tous les sites git système-side composent le set = invariant auditable).
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["rev-parse", "HEAD"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
      {:ok, {err, rc}} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
      {:error, {:timeout, ms}} -> {:error, {:rev_parse_timeout, ms}}
      {:error, {:exit, reason}} -> {:error, {:rev_parse_exit, reason}}
    end
  end

  @doc """
  Push-only — pousse `refspec` du `workspace` vers `remote`, **borné** (timeout). PAS d'add/commit :
  la branche est déjà commitée (par le pod en mode `git_native`, ou par `publish/1` en mode `payload`).
  `refspec` peut être `local_ref:target_branch` pour que la ref poussée soit **choisie par le système**.
  Partagé par `Fleet.Workflow.Deliverable` (les 2 modes) et `maybe_push/1` (compat `publish/1`).
  """
  @spec push(Path.t(), String.t(), String.t()) :: {:ok, true} | {:error, term()}
  def push(workspace, remote, refspec) do
    with :ok <- validate_cli_arg(remote, :invalid_remote),
         :ok <- validate_cli_arg(refspec, :invalid_refspec) do
      do_push(workspace, remote, refspec)
    end
  end

  # `remote`/`refspec` ne doivent PAS commencer par `-`. Sinon `git push` les lit comme des
  # OPTIONS (`--receive-pack=<cmd>` → exécution côté remote, `-c <config>`, `--exec=`) → injection
  # d'options via un input non fiable. `System.cmd` n'utilise pas de shell, mais git parse ses options :
  # un positional attendu qui commence par `-` est avalé comme option. On rejette fail-closed.
  defp validate_cli_arg(arg, err) when is_binary(arg) and arg != "" do
    if String.starts_with?(arg, "-"), do: {:error, {err, arg}}, else: :ok
  end

  defp validate_cli_arg(_arg, err), do: {:error, err}

  defp do_push(workspace, remote, refspec) do
    case run_push(workspace, remote, refspec, []) do
      {:ok, {_out, 0}} ->
        {:ok, true}

      {:ok, {out, rc}} ->
        # Une RÉSOLUTION DE CONFLIT rebase la feature-branch → historique réécrit → push rejeté
        # « non-fast-forward ». La feature-branch est SYSTÈME-owned (seul le système la pousse ; le pod
        # est forge-aveugle, pas de pousseur concurrent) → un retry `--force` est sûr : le système écrase
        # SA PROPRE branche avec le rebase. Sans ça, le rebase de résolution ne land JAMAIS.
        if non_fast_forward?(out),
          do: force_push(workspace, remote, refspec),
          else: {:error, {:git_push_failed, rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        {:error, {:git_push_timeout, push_timeout_ms()}}

      {:error, {:exit, reason}} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  defp force_push(workspace, remote, refspec) do
    case run_push(workspace, remote, refspec, ["--force"]) do
      {:ok, {_out, 0}} -> {:ok, true}
      {:ok, {out, rc}} -> {:error, {:git_push_failed, rc, String.trim(out)}}
      {:error, {:timeout, _ms}} -> {:error, {:git_push_timeout, push_timeout_ms()}}
      {:error, {:exit, reason}} -> {:error, {:git_push_exit, reason}}
    end
  end

  # `git push [extra] remote refspec` borné via `Fleet.Credentials.Shell` (source unique de la borne) —
  # `git push` n'a pas de timeout natif. Un push réseau hung (DNS, TLS, packfile interrompu) bloquerait le
  # GenServer appelant ; le wrapper lance dans un process-group dédié et, à la deadline MUR, tue le GROUPE
  # entier (le push ET ses helpers de transport) + ferme le port. Remplace le patron `Task.async` +
  # `shutdown(:brutal_kill)` qui ne tuait que le Task BEAM en laissant le process git (porteur du token
  # forge dans son environ) fuir. `core.hooksPath=/dev/null` conservé (durcissement hooks inchangé).
  defp run_push(workspace, remote, refspec, extra) do
    # Token forge via env (hors argv/cmdline) — source unique Fleet.Credentials.ForgeAuth, injectée
    # explicitement (Shell.git/2 l'injecterait par défaut, mais on est explicites au site sensible).
    Fleet.Credentials.Shell.git(@hooks_off ++ ["push"] ++ extra ++ [remote, refspec],
      cd: workspace,
      timeout_ms: push_timeout_ms(),
      env: Fleet.Credentials.ForgeAuth.git_env()
    )
  end

  # Rejet « non-fast-forward » SEUL (l'historique distant a divergé du local — ici un rebase de
  # résolution réécrit la feature-branch SYSTÈME-owned → `--force` sûr). Détecté sur la sortie git (stderr
  # fusionné) en se limitant aux DIAGNOSTICS PROPRES du non-fast-forward : `non-fast-forward` / `fetch first`.
  # On NE matche PAS le substring `rejected` NU : git l'émet AUSSI pour un rejet de HOOK (`[remote rejected]
  # … pre-receive hook declined`) ou de branche protégée — un retry `--force` y serait à tort une RÉÉCRITURE
  # FORCÉE par-dessus une protection serveur (perte de données / contournement de garde). On ne force que
  # quand la cause EST une divergence d'historique, jamais sur un refus de politique remote (fail-closed :
  # un rejet non-explicitement-NFF remonte tel quel `{:git_push_failed, …}`, pas de force aveugle).
  defp non_fast_forward?(out) do
    o = String.downcase(out)

    String.contains?(o, "non-fast-forward") or String.contains?(o, "fetch first")
  end

  defp maybe_push(%{push?: true} = opts),
    do: push(opts.workspace, Map.fetch!(opts, :remote), opts.branch)

  defp maybe_push(_opts), do: {:ok, false}

  # Timeout pour `git push` réseau. Default 30s (suffisant LAN/forge locale,
  # garde-fou contre hung indéfini WAN). Override via :fleet_workflow,
  # :git_push_timeout_ms (config app ou Application.put_env).
  defp push_timeout_ms do
    Application.get_env(:fleet_workflow, :git_push_timeout_ms, 30_000)
  end

  # Borne des ops git LOCALES (add/commit/diff-cached/rev-parse). Normalement <1 s ; un timeout ici =
  # `index.lock` stale / FS pendu (NFS). 30 s laisse une marge large avant de tuer le groupe OS.
  defp git_local_timeout_ms do
    Application.get_env(:fleet_workflow, :git_local_timeout_ms, 30_000)
  end

  # Pas de `forge_auth_args/0`. L'auth forge système-side est portée par
  # `Fleet.Credentials.ForgeAuth.git_env/0` (source unique, token via env hors argv/cmdline).
end
