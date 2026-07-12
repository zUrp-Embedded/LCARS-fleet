defmodule Fleet.Pilot.GitOps do
  @moduledoc """
  Bounded git — single source of the `git` wrapper for the pilot's FS operations (onboarding a project,
  aligning a worktree). The real BOUND (dedicated process-group + WALL deadline that kills the group +
  anti-prompt) lives in `Fleet.Credentials.Shell.git`; this module adds three shared things to it:

    * auth injection (forge token in env, NEVER on the argv) for the network ops (clone/fetch/push);
    * the commit identity (author set by the caller, committer = the human for traceability);
    * a TYPED return `:ok | {:error, {:git_failed | :git_timeout | :git_exit, …}}`.

  Shared by `Fleet.Pilot.ProjectOnboard` (clone/scaffold/commit/push) and `Fleet.Pilot.WorktreeSync`
  (fetch/reset): a single place where a pilot `git` runs — not two wrappers to keep in sync.
  """

  alias Fleet.Credentials.ForgeAuth

  @doc """
  Runs bounded `git args`. `opts`:

    * `:auth` (default `false`) → forge token in env (`ForgeAuth.git_env`) for the network ops
      (clone/fetch/push). The local ops (reset/commit/worktree add) don't need it.
    * `:author` (`%{name, email}` | `nil`) → `GIT_AUTHOR_*`. The committer is left to the human
      identity resolution (traceability), not to the author.

  Return: `:ok` (exit 0) | `{:error, …}`. The args are truncated to 3 in the error (enough to
  identify the op: `git -C <dir> <verb>`, without dumping the rest).
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

  # Commit (author set): `GIT_AUTHOR` = what the caller declares; `GIT_COMMITTER` = the human,
  # resolved ROBUSTLY via `ForgeIdentity.human_identity` (git config → GECOS → login) — so it does NOT depend
  # on the human's `~/.gitconfig`. Without this committer, an unconfigured human would get "empty ident name" →
  # commit refused. Author absent (`nil`) → no identity env (the ops without commit don't care).
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
