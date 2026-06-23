defmodule Fleet.Pipeline.Git do
  @moduledoc """
  Mécanisme système-side de publication git post-EXTRACT (face 2 décision
  archi git, 2026-05-24). Composé par `Fleet.Pipeline.Executor` sur
  `pod.completed` lorsque la stage déclare `post_extract.git`.

  Pure data → action :
    * input  : workspace path, identités auteur/committer, message, branch,
      add_paths, remote, push?
    * action : `git add <paths> → git commit → [git push <remote> <branch>]`
    * output : `{:ok, %{commit_sha, pushed?}}` ou `{:error, term()}`

  Fail-closed strict : `--force` et `--no-verify` ne sont **JAMAIS** composés
  par le module. Si un cas futur nécessite override, ce sera une décision
  explicite avec audit, pas une option par défaut.

  D-04 préservée : `author_*` reflète l'identité du worker (role) ;
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

  # `commit/1` (O5) ne pousse pas → `:branch`/`:remote` sont des concerns de push,
  # absents ici. L'identité (author/committer) + message + workspace suffisent.
  @commit_required_keys @required_keys -- [:branch]

  # F-07 (re-audit O5, consultant fire-mode) — le workspace est CO-ÉCRIT par un pod adversaire ;
  # `.git/hooks/` y est inscriptible par le pod. `git commit`/`git push` sont lancés ICI, côté MONDE
  # (runtime Elixir, HORS bwrap) → un `pre-push`/`pre-commit` posé par le pod s'exécuterait avec les
  # privilèges du runtime = RCE hors-pod. `core.hooksPath=/dev/null` neutralise TOUS les hooks du
  # workspace pour les ops système-side (flag git natif, tournevis). I-CBC : le monde REFUSE d'exécuter
  # le code du pod, plutôt que d'espérer que le pod n'en pose pas. N'affecte PAS la doctrine
  # `--no-verify JAMAIS` (qui protège l'appelant du module ; ici on neutralise le hook adversaire, pas
  # la vérif d'intégrité de l'appelant). Les ops read-only de la gate (log/diff/merge-base) n'exécutent
  # pas de hook → pas concernées.
  @hooks_off ["-c", "core.hooksPath=/dev/null"]

  # Refuse branches/refs avec caractères ambigus (espace, ..., leading `-`).
  # Pas une défense anti-injection (System.cmd n'utilise pas de shell), juste
  # un garde-fou contre des entrées catalogue manifestement cassées. Aligne
  # grosso-modo sur git check-ref-format : commence par alphanumérique, puis
  # `[A-Za-z0-9._/-]`, et rejette le substring `..`.
  @branch_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/\-]*$/

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
  Commit-only (O5) — `git add <paths> → git commit` dans `workspace`, **sans push**. Sépare le
  CONTENU (le système commite le payload) de la PUBLICATION (`push/3` après la gate I-CBC). Utilisé
  par `Fleet.Pipeline.Deliverable` en mode `payload` ; `publish/1` reste le chemin couplé legacy
  (PASSE-7). Pas de `:branch`/`:remote` requis (concerns de push). Retourne le SHA du HEAD commité.
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

  defp check_branch(branch) when is_binary(branch) do
    if Regex.match?(@branch_re, branch) and not String.contains?(branch, ".."),
      do: :ok,
      else: {:error, :invalid_branch}
  end

  defp check_branch(_branch), do: {:error, :invalid_branch}

  defp check_push_remote(%{push?: true} = opts) do
    case Map.get(opts, :remote) do
      # F-046 : rejet leading-`-` au plus tôt (publish/maybe_push) — `push/3` re-valide aussi.
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
        # F-014 : `--` termine les options → un pathspec commençant par `-` (ex. `add_paths = ["--all"]`
        # depuis un input non fiable) est traité comme un CHEMIN littéral, pas une option git. `System.cmd`
        # n'utilise pas de shell, mais GIT parse ses propres options : un arg leading-`-` est une option.
        case System.cmd("git", ["add", "--" | paths], cd: opts.workspace, stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, rc} -> {:error, {:git_add_failed, rc, String.trim(out)}}
        end

      {:error, _} = err ->
        err
    end
  end

  # F-014 : `add_paths` doit être une liste non vide de chemins binaires non vides (belt-and-suspenders
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
    # audit elixir #2 : ancienne classification grep "nothing to commit" sur
    # stderr → i18n-dependent (LC_ALL=fr_FR → "rien à valider" → grep rate →
    # mauvaise classification). Pre-check via `git diff --cached --quiet`
    # (codes RC stable across locales : 0 = pas de diff staged, 1 = diff
    # staged). Évite le commit entièrement quand `:nothing_to_commit`.
    case has_staged_changes?(opts.workspace) do
      false ->
        {:error, :nothing_to_commit}

      true ->
        case System.cmd("git", @hooks_off ++ ["commit", "-m", opts.message],
               cd: opts.workspace,
               env: commit_env(opts),
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, rc} -> {:error, {:git_commit_failed, rc, String.trim(out)}}
        end
    end
  end

  defp has_staged_changes?(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      # Exit 0 = aucun diff staged → rien à commit.
      {_, 0} -> false
      # Exit 1 = diff staged présent (sémantique stable git).
      {_, 1} -> true
      # Autre code = erreur git non-attendue (corruption repo, etc.) → laisse
      # commit tenter et reporter via {:git_commit_failed, ...}.
      {_, _} -> true
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

  defp read_head_sha(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {err, rc} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
    end
  end

  @doc """
  Push-only (O5) — pousse `refspec` du `workspace` vers `remote`, **borné** (timeout). PAS d'add/commit :
  la branche est déjà commitée (par le pod en mode `git_native`, ou par `publish/1` en mode `payload`).
  `refspec` peut être `local_ref:target_branch` pour que la ref poussée soit **choisie par le système**
  (F-04). Partagé par `Fleet.Pipeline.Deliverable` (les 2 modes) et `maybe_push/1` (compat `publish/1`).
  """
  @spec push(Path.t(), String.t(), String.t()) :: {:ok, true} | {:error, term()}
  def push(workspace, remote, refspec) do
    with :ok <- validate_cli_arg(remote, :invalid_remote),
         :ok <- validate_cli_arg(refspec, :invalid_refspec) do
      do_push(workspace, remote, refspec)
    end
  end

  # F-046 : `remote`/`refspec` ne doivent PAS commencer par `-`. Sinon `git push` les lit comme des
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
        # F-PARALLEL-PR-CONFLICT : une RÉSOLUTION DE CONFLIT rebase la feature-branch → historique réécrit →
        # push rejeté « non-fast-forward ». La feature-branch est SYSTÈME-owned (seul le système la pousse ; le
        # pod est forge-aveugle, pas de pousseur concurrent) → un retry `--force` est sûr : le système écrase
        # SA PROPRE branche avec le rebase. Sans ça, le rebase ne land JAMAIS (vu live, PR#4 arduino-morse).
        if non_fast_forward?(out),
          do: force_push(workspace, remote, refspec),
          else: {:error, {:git_push_failed, rc, String.trim(out)}}

      nil ->
        {:error, {:git_push_timeout, push_timeout_ms()}}

      {:exit, reason} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  defp force_push(workspace, remote, refspec) do
    case run_push(workspace, remote, refspec, ["--force"]) do
      {:ok, {_out, 0}} -> {:ok, true}
      {:ok, {out, rc}} -> {:error, {:git_push_failed, rc, String.trim(out)}}
      nil -> {:error, {:git_push_timeout, push_timeout_ms()}}
      {:exit, reason} -> {:error, {:git_push_exit, reason}}
    end
  end

  # `git push [extra] remote refspec` borné. audit elixir #1 BLOQUANT — `git push` n'a pas de timeout natif.
  # Push réseau hung (DNS, TLS, packfile interrompu) bloquerait l'Executor GenServer. Task.async + yield +
  # shutdown :brutal_kill : pas de retour dans `timeout_ms` → on tue le Task (port → process git via SIGKILL).
  defp run_push(workspace, remote, refspec, extra) do
    task =
      Task.async(fn ->
        System.cmd("git", @hooks_off ++ ["push"] ++ extra ++ [remote, refspec],
          cd: workspace,
          stderr_to_stdout: true,
          # F087/F095 : token forge via env (hors argv/cmdline) — source unique Fleet.Credentials.ForgeAuth.
          env: Fleet.Credentials.ForgeAuth.git_env()
        )
      end)

    Task.yield(task, push_timeout_ms()) || Task.shutdown(task, :brutal_kill)
  end

  # MA-05 — Rejet « non-fast-forward » SEUL (l'historique distant a divergé du local — ici un rebase de
  # résolution réécrit la feature-branch SYSTÈME-owned → `--force` sûr). Détecté sur la sortie git (stderr
  # fusionné) en se limitant aux DIAGNOSTICS PROPRES du non-fast-forward : `non-fast-forward` / `fetch first`.
  # Le substring `rejected` NU est RETIRÉ : git l'émet AUSSI pour un rejet de HOOK (`[remote rejected] …
  # pre-receive hook declined`) ou de branche protégée — un retry `--force` y serait à tort une RÉÉCRITURE
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
  # garde-fou contre hung indéfini WAN). Override via :fleet_pipeline,
  # :git_push_timeout_ms (config app ou Application.put_env).
  defp push_timeout_ms do
    Application.get_env(:fleet_pipeline, :git_push_timeout_ms, 30_000)
  end

  # F087/F095 — `forge_auth_args/0` RETIRÉ. L'auth forge système-side est désormais
  # `Fleet.Credentials.ForgeAuth.git_env/0` (source unique, token via env hors argv/cmdline).
end
