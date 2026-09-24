defmodule Fleet.Project.GitOps do
  @moduledoc """
  Project-side adapter over bounded `Fleet.Credentials.Shell.git`: injects forge auth
  outside argv, applies commit identity, and returns typed failures.
  """

  alias Fleet.Credentials.ForgeAuth

  @doc """
  Runs Git through Shell with :auth (boolean, default false) and optional :author
  (%{name: ..., email: ...}). With an author, the committer is the resolved human, or the
  author itself with `committer: :author` (an act of the system, signed by it on both sides).
  An unresolvable human committer refuses the command: Git's own fallback is `login@hostname`,
  an address no account carries. Other options are not forwarded; use Git arguments
  such as -C to select the working directory. Success discards captured output.
  """
  @spec run([String.t()], keyword()) :: :ok | {:error, term()}
  def run(args, opts \\ []) do
    case exec(args, opts) do
      {:ok, _out} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Like run/2, returning trimmed captured output on success. The name does not
  restrict Git verbs to read-only operations.
  """
  @spec read([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def read(args, opts \\ []) do
    case exec(args, opts) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} = err -> err
    end
  end

  defp exec(args, opts) do
    with {:ok, forge_env} <- forge_env(Keyword.get(opts, :auth, false)),
         {:ok, identity} <-
           identity_env(Keyword.get(opts, :author), Keyword.get(opts, :committer)) do
      env = forge_env ++ identity

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

  # Request ForgeAuth only for auth: true; invalid credentials fail before Git runs.
  defp forge_env(true), do: ForgeAuth.git_env_result()
  defp forge_env(false), do: {:ok, []}

  defp identity_env(%{name: name, email: email} = author, committer) do
    with {:ok, %{name: cn, email: ce}} <- committer_of(author, committer) do
      {:ok,
       [
         {"GIT_AUTHOR_NAME", name},
         {"GIT_AUTHOR_EMAIL", email},
         {"GIT_COMMITTER_NAME", cn},
         {"GIT_COMMITTER_EMAIL", ce}
       ]}
    end
  end

  defp identity_env(_author, _committer), do: {:ok, []}

  defp committer_of(author, :author), do: {:ok, author}

  defp committer_of(_author, _human) do
    case Fleet.Credentials.ForgeIdentity.human_identity() do
      {:ok, %{name: _, email: _} = human} -> {:ok, human}
      other -> {:error, {:committer_unresolved, other}}
    end
  end
end
