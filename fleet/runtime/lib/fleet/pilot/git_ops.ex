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

  **Last revised**: 2026-07-21
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
    case exec(args, opts) do
      {:ok, _out} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `run/2` but RETURNS the captured (trimmed) stdout on exit 0 — for local READ ops
  (`config --get`, `rev-parse`…) where the output IS the answer. Same `opts`/bound/typed errors as `run/2`.
  """
  @spec read([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def read(args, opts \\ []) do
    case exec(args, opts) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} = err -> err
    end
  end

  # Single source of the bounded git call (auth/identity env + typed error mapping); `run/2` discards the
  # stdout, `read/2` keeps it. On exit 0 → `{:ok, raw_out}`.
  defp exec(args, opts) do
    with {:ok, forge_env} <- forge_env(Keyword.get(opts, :auth, false)) do
      env = forge_env ++ identity_env(Keyword.get(opts, :author))

      case Fleet.Credentials.Shell.git(args, env: env) do
        {:ok, {out, 0}} ->
          {:ok, out}

        {:ok, {out, code}} ->
          {:error, {:git_failed, Enum.take(args, 3), code, String.slice(out, 0, 500)}}

        {:error, {:timeout, ms}} ->
          {:error, {:git_timeout, Enum.take(args, 3), ms}}

        {:error, {:exit, reason}} ->
          {:error, {:git_exit, Enum.take(args, 3), reason}}
      end
    end
  end

  # `auth: true` → forge auth REQUIRED → fail-loud on a present-but-malformed credential (DR-024), never
  # run unauthenticated. `auth: false` → local op (reset/commit/worktree), no forge auth → empty env.
  defp forge_env(true), do: ForgeAuth.git_env_result()
  defp forge_env(false), do: {:ok, []}

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
