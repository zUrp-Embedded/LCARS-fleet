defmodule Fleet.Pilot.ForgeClient.Files do
  @moduledoc """
  Lecture/écriture de **fichiers** dans un repo via l'API contents Gitea — sous-domaine de
  `Fleet.Pilot.ForgeClient`. Concern autonome (ni seam ni couplage au cœur issues/PR) : les
  callers l'utilisent en direct (`Fleet.Pilot.IncidentRegistry`, qui les injecte comme seams
  `:get_file_fun`/`:put_file_fun`). **Le SYSTÈME publie** — forge-aveugle : le pod ne pousse jamais.
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [resolve_config: 1, http_get: 2, http_put: 3, encode_repo: 1, encode_path: 1]

  @doc """
  Écrit un fichier `path` (texte `content`) sur `repo`/`branch` — Gitea
  `PUT /repos/{repo}/contents/{path}`. **Le SYSTÈME publie** (forge-aveugle : le pod ne
  pousse jamais ; c'est ce chemin qui grave durablement le livrable d'un engineer). Création
  (pas d'update sha) : viser un `path` neuf (ticket-namespacé). Branche existante requise
  (défaut `main`) — `opts[:new_branch]` pour brancher depuis `branch`.

  ## Returns
    * `{:ok, commit_sha}` — fichier écrit
    * `{:error, term()}` — HTTP/transport/config (422 = path déjà présent sur la branche)
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
        # Traça à 2 niveaux : `author` = le WORKER (qui a écrit),
        # `committer` = l'HUMAIN commanditaire (qui a fait bosser la fleet ; le système fait l'I/O,
        # mais le commit attribue les deux niveaux). forge-aveugle préservé (le pod ne pousse jamais).
        |> maybe_put_identity(:author, Keyword.get(opts, :author))
        |> maybe_put_identity(:committer, Keyword.get(opts, :committer))
        # `sha` présent ⇒ UPDATE du fichier existant (Gitea l'exige) ; absent ⇒ CREATE.
        |> maybe_put_sha(Keyword.get(opts, :sha))

      case http_put(config, "/repos/#{encode_repo(repo)}/contents/#{encode_path(path)}", body) do
        {:ok, %{"commit" => %{"sha" => sha}}} -> {:ok, sha}
        {:ok, _other} -> {:ok, :written}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Lit un fichier du repo (Gitea `GET /contents/{path}?ref=`). Le `sha` renvoyé sert à `put_file(.., sha:)`
  pour un UPDATE (read-modify-write). `opts[:ref]` = branche/ref (défaut `main`).

  ## Returns
    * `{:ok, %{content: String.t(), sha: String.t()}}` — fichier lu (content décodé)
    * `{:error, :not_found}` — 404 (fichier/branche absent)
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
