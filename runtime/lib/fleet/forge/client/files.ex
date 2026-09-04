defmodule Fleet.Forge.Client.Files do
  @moduledoc """
  Reads and writes repository files through the forge contents API.

  The system performs the publication; pods remain forge-blind. Callers may attribute the worker
  as author and the commissioning human as committer.
  """

  import Fleet.Forge.Client.Transport,
    only: [resolve_config: 1, http_get: 2, http_put: 3]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_path: 1]

  @doc """
  Writes text at `path` on a branch, returning the commit SHA.

  Omitting `:sha` creates a file; supplying it updates one. `:new_branch` creates a branch from
  `:branch`. Optional `:author` and `:committer` identities preserve two-level attribution.
  """
  @spec put_file(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, String.t()} | {:error, term()}
  def put_file(repo, path, content, opts \\ [])
      when is_binary(repo) and is_binary(path) and is_binary(content) do
    with {:ok, config} <- resolve_config(opts) do
      body =
        %{
          content: Base.encode64(content),
          message: Keyword.get(opts, :message, "feat(fleet): #{path}"),
          branch: Keyword.get(opts, :branch, "main")
        }
        |> maybe_put_new_branch(Keyword.get(opts, :new_branch))
        |> maybe_put_identity(:author, Keyword.get(opts, :author))
        |> maybe_put_identity(:committer, Keyword.get(opts, :committer))
        |> maybe_put_sha(Keyword.get(opts, :sha))

      case http_put(config, "/repos/#{encode_repo(repo)}/contents/#{encode_path(path)}", body) do
        {:ok, %{"commit" => %{"sha" => sha}}} -> {:ok, sha}
        {:ok, other} -> {:error, {:unexpected_put_shape, other}}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Reads and decodes a file at `:ref` (default `main`). Returns its content and SHA for an update,
  or `{:error, :not_found}` on a missing file or branch.
  """
  @spec get_file(String.t(), String.t(), Keyword.t()) ::
          {:ok, %{content: String.t(), sha: String.t()}} | {:error, term()}
  def get_file(repo, path, opts \\ []) when is_binary(repo) and is_binary(path) do
    with {:ok, config} <- resolve_config(opts) do
      ref = Keyword.get(opts, :ref, "main")

      case http_get(
             config,
             "/repos/#{encode_repo(repo)}/contents/#{encode_path(path)}?ref=#{URI.encode_www_form(ref)}"
           ) do
        {:ok, %{"content" => b64, "sha" => sha}} ->
          case Base.decode64(b64, ignore: :whitespace) do
            {:ok, content} -> {:ok, %{content: content, sha: sha}}
            :error -> {:error, :decode_failed}
          end

        {:error, {:http, 404, _}} ->
          {:error, :not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Names of the entries at `path` for `:ref` — `{:error, :not_found}` when the directory is absent.

  The listing half of `get_file/3`: the same `/contents` endpoint answers a LIST for a directory.
  It exists to let a caller ask whether a repository DECLARES something, without downloading it —
  the CI gate asks exactly that about `.gitea/workflows`, and the difference between "no run yet"
  and "no workflow at all" is the difference between waiting and knowing.
  """
  @spec list_dir(String.t(), String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_dir(repo, path, opts \\ []) when is_binary(repo) and is_binary(path) do
    with {:ok, config} <- resolve_config(opts) do
      ref = Keyword.get(opts, :ref, "main")

      case http_get(
             config,
             "/repos/#{encode_repo(repo)}/contents/#{encode_path(path)}?ref=#{URI.encode_www_form(ref)}"
           ) do
        {:ok, entries} when is_list(entries) ->
          {:ok, Enum.map(entries, &Map.get(&1, "name"))}

        # A FILE at that path is not a directory, and answering `[]` would read as "empty".
        {:ok, %{}} ->
          {:error, :not_a_directory}

        {:error, {:http, 404, _}} ->
          {:error, :not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  defp maybe_put_new_branch(body, nil), do: body
  defp maybe_put_new_branch(body, nb) when is_binary(nb), do: Map.put(body, :new_branch, nb)

  defp maybe_put_sha(body, nil), do: body
  defp maybe_put_sha(body, sha) when is_binary(sha), do: Map.put(body, :sha, sha)

  defp maybe_put_identity(body, key, %{name: name, email: email})
       when is_binary(name) and is_binary(email),
       do: Map.put(body, key, %{name: name, email: email})

  defp maybe_put_identity(body, _key, _), do: body
end
