defmodule Fleet.Pilot.GitOps do
  @moduledoc """
  Git borné — source unique du wrapper `git` pour les opérations FS du pilot (onboarding d'un projet,
  alignement d'un worktree). La BORNE réelle (process-group dédié + deadline MUR qui tue le groupe +
  anti-prompt) vit dans `Fleet.Credentials.Shell.git` ; ce module y ajoute trois choses partagées :

    * l'injection d'auth (token forge en env, JAMAIS sur l'argv) pour les ops réseau (clone/fetch/push) ;
    * l'identité de commit (author posé par l'appelant, committer = l'humain pour la traça) ;
    * un retour TYPÉ `:ok | {:error, {:git_failed | :git_timeout | :git_exit, …}}`.

  Partagé par `Fleet.Pilot.ProjectOnboard` (clone/scaffold/commit/push) et `Fleet.Pilot.WorktreeSync`
  (fetch/reset) : un seul endroit où un `git` du pilot s'exécute — pas deux wrappers à garder en phase.
  """

  alias Fleet.Credentials.ForgeAuth

  @doc """
  Lance `git args` borné. `opts` :

    * `:auth` (défaut `false`) → token forge en env (`ForgeAuth.git_env`) pour les ops réseau
      (clone/fetch/push). Les ops locales (reset/commit/worktree add) n'en ont pas besoin.
    * `:author` (`%{name, email}` | `nil`) → `GIT_AUTHOR_*`. Le committer est laissé à la résolution
      d'identité humaine (traça), pas à l'author.

  Retour : `:ok` (exit 0) | `{:error, …}`. Les args sont tronqués à 3 dans l'erreur (assez pour
  identifier l'op : `git -C <dir> <verbe>`, sans déverser le reste).
  """
  @spec run([String.t()], keyword()) :: :ok | {:error, term()}
  def run(args, opts \\ []) do
    env =
      if(Keyword.get(opts, :auth, false), do: ForgeAuth.git_env(), else: []) ++
        identity_env(Keyword.get(opts, :author))

    case Fleet.Credentials.Shell.git(args, env: env) do
      {:ok, {_out, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:git_failed, Enum.take(args, 3), code, String.slice(out, 0, 500)}}

      {:error, {:timeout, ms}} ->
        {:error, {:git_timeout, Enum.take(args, 3), ms}}

      {:error, {:exit, reason}} ->
        {:error, {:git_exit, Enum.take(args, 3), reason}}
    end
  end

  # Commit (author posé) : `GIT_AUTHOR` = ce que l'appelant déclare ; `GIT_COMMITTER` = l'humain,
  # résolu ROBUSTE via `ForgeIdentity.human_identity` (git config → GECOS → login) — ne dépend donc PAS
  # du `~/.gitconfig` humain. Sans ce committer, un humain non-configuré ferait « empty ident name » →
  # commit refusé. Author absent (`nil`) → aucun env d'identité (les ops sans commit s'en moquent).
  defp identity_env(%{name: name, email: email}) do
    committer =
      case Fleet.Credentials.ForgeIdentity.human_identity() do
        {:ok, %{name: cn, email: ce}} -> [{"GIT_COMMITTER_NAME", cn}, {"GIT_COMMITTER_EMAIL", ce}]
        _ -> []
      end

    [{"GIT_AUTHOR_NAME", name}, {"GIT_AUTHOR_EMAIL", email}] ++ committer
  end

  defp identity_env(_), do: []
end
