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
  Sends base64 content by PUT, branch default main, and returns the response's commit.sha
  without validating its type. :sha supplies the existing blob id for an update; omission
  still uses PUT and leaves acceptance to the forge. :new_branch requests a branch from :branch.
  :author/:committer are included only as atom-keyed maps with binary name/email; other identity
  shapes are ignored. A successful write with unexpected response shape returns an error afterward.
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
  Reads at :ref (default main), decodes base64 ignoring whitespace and returns content plus
  the unvalidated blob SHA. HTTP 404 maps to not_found; invalid base64 to decode_failed.
  Unexpected 2xx shapes or nonbinary content can raise instead of returning a typed error.
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
          decoded_file(Base.decode64(b64, ignore: :whitespace), sha)

        {:error, {:http, 404, _}} ->
          {:error, :not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  # An undecodable file must not be mistaken for an absent file by a subsequent writer.
  defp decoded_file({:ok, content}, sha), do: {:ok, %{content: content, sha: sha}}
  defp decoded_file(:error, _sha), do: {:error, :decode_failed}

  @doc """
  Reads directory entry names at :ref (default main), without downloading file contents, e.g.
  to distinguish declared workflows from runs not yet seen. No pagination or entry validation:
  missing names yield nil and non-map entries raise. A map body returns not_a_directory,
  HTTP 404 returns not_found, and other successful body shapes have no fallback clause.
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
