defmodule Fleet.Project.GitOps do
  @moduledoc """
  Project-side adapter over bounded `Fleet.Credentials.Shell.git`: injects forge auth
  outside argv, applies commit identity, and returns typed failures.
  """

  alias Fleet.Credentials.ForgeAuth

  @doc """
  Runs bounded git, optionally with forge auth and an explicit author.
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

        # TOTAL over the Shell error union (output_overflow, bad_opt, future members).
        {:error, reason} ->
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
