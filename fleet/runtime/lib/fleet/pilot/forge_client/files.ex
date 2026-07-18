defmodule Fleet.Pilot.ForgeClient.Files do
  @moduledoc """
  Read/write of **files** in a repo via the Gitea contents API — sub-domain of
  `Fleet.Pilot.ForgeClient`. Self-contained concern (neither seam nor coupling to the issues/PR core):
  callers use it directly (`Fleet.Pilot.IncidentRegistry`, which injects them as seams
  `:get_file_fun`/`:put_file_fun`). **The SYSTEM publishes** — forge-blind: the pod never pushes.

  **Last revised**: 2026-07-18
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [resolve_config: 1, http_get: 2, http_put: 3]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_path: 1]

  @doc """
  Writes a file `path` (text `content`) on `repo`/`branch` — Gitea
  `PUT /repos/{repo}/contents/{path}`. **The SYSTEM publishes** (forge-blind: the pod never
  pushes; this is the path that durably records an engineer's deliverable). Creation
  (no sha update): target a fresh `path` (issue-namespaced). Existing branch required
  (default `main`) — `opts[:new_branch]` to branch from `branch`.

  ## Returns
    * `{:ok, commit_sha}` — file written
    * `{:error, term()}` — HTTP/transport/config (422 = path already present on the branch)
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
        # Two-level attribution: `author` = the WORKER (who wrote it),
        # `committer` = the commissioning HUMAN (who put the fleet to work; the system does the I/O,
        # but the commit attributes both levels). forge-blind preserved (the pod never pushes).
        |> maybe_put_identity(:author, Keyword.get(opts, :author))
        |> maybe_put_identity(:committer, Keyword.get(opts, :committer))
        # `sha` present ⇒ UPDATE of the existing file (Gitea requires it); absent ⇒ CREATE.
        |> maybe_put_sha(Keyword.get(opts, :sha))

      case http_put(config, "/repos/#{encode_repo(repo)}/contents/#{encode_path(path)}", body) do
        {:ok, %{"commit" => %{"sha" => sha}}} -> {:ok, sha}
        # 2xx WITHOUT the commit envelope = unexpected shape → fail-loud, domain doctrine (same
        # stance as paginate :unexpected_page_shape). The old `{:ok, :written}` was a success of
        # UNDECLARED type (neither in @spec nor @doc) that hid a shape drift as a hollow green.
        {:ok, other} -> {:error, {:unexpected_put_shape, other}}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Reads a file from the repo (Gitea `GET /contents/{path}?ref=`). The returned `sha` feeds `put_file(.., sha:)`
  for an UPDATE (read-modify-write). `opts[:ref]` = branch/ref (default `main`).

  ## Returns
    * `{:ok, %{content: String.t(), sha: String.t()}}` — file read (content decoded)
    * `{:error, :not_found}` — 404 (file/branch absent)
    * `{:error, term()}` — HTTP/transport/config/decode
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

  defp maybe_put_new_branch(body, nil), do: body
  defp maybe_put_new_branch(body, nb) when is_binary(nb), do: Map.put(body, :new_branch, nb)

  defp maybe_put_sha(body, nil), do: body
  defp maybe_put_sha(body, sha) when is_binary(sha), do: Map.put(body, :sha, sha)

  defp maybe_put_identity(body, key, %{name: name, email: email})
       when is_binary(name) and is_binary(email),
       do: Map.put(body, key, %{name: name, email: email})

  defp maybe_put_identity(body, _key, _), do: body
end
