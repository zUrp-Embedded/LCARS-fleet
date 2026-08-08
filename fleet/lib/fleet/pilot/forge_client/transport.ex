defmodule Fleet.Pilot.ForgeClient.Transport do
  @moduledoc """
  HTTP/config engine of the forge client — the plumbing UNDER `Fleet.Pilot.ForgeClient`.
  Vendor-agnostic in the "domain" sense: here live config/token resolution, the Req
  call (dedicated pool + instrumentation of slow calls), the pagination of source-of-truth
  collections and the derivation of the system login. (The safe encoding of URL
  segments — path-traversal lock — lives in `Fleet.Pilot.ForgeClient.UrlSafe`.)
  No knowledge of the forge *protocol* (branches, labels, markers): that's
  `Fleet.Pilot.ForgeClient` (domain) + `Fleet.Pilot.ForgeProtocol` (vocab).

  INTERNAL surface (`@doc false`): everything is public so that `ForgeClient` can call it,
  but it is not an app contract — no caller outside `fleet_pilot`.

  ## Configuration

  Resolved at call time via `opts` (Keyword) or fallback `Application.get_env(:fleet_pilot, :forge)`:

    * `:base_url` — e.g. `"http://localhost:3000"` (laptop mirror) or `"http://10.42.0.118"` (forge NAS).
    * `:token` — Gitea token. Read from `:token_file` if absent.
    * `:token_file` — file path (default `~/.gitea_token`).
    * `:req_options` — options passed as-is to `Req.new/1` (for tests: `[plug: ...]` to intercept HTTP).
  """

  require Logger

  alias Fleet.Pilot.Opts

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  @doc false
  def resolve_config(opts) do
    env = Application.get_env(:fleet_pilot, :forge, [])
    merged = Keyword.merge(env, opts)

    with {:ok, base_url} <- fetch_required(merged, :base_url),
         {:ok, token} <- resolve_token(merged) do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         token: token,
         req_options: Keyword.get(merged, :req_options, [])
       }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:config, {:missing, key}}}
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case Keyword.get(opts, :token_file) || default_token_file() do
          nil ->
            {:error, {:config, :no_token_source}}

          path ->
            case File.read(path) do
              {:ok, content} ->
                case String.trim(content) do
                  "" -> {:error, {:config, {:token_file_empty, path}}}
                  token -> {:ok, token}
                end

              {:error, reason} ->
                {:error, {:config, {:token_file, path, reason}}}
            end
        end
    end
  end

  defp default_token_file do
    case System.user_home() do
      nil -> nil
      home -> Path.join(home, ".gitea_token")
    end
  end

  @doc false
  def forge_bot_login(config, opts) do
    case Keyword.get(opts, :forge_bot_login) ||
           Application.get_env(:fleet_pilot, :forge_bot_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      {:error, _} = err -> err
      _ -> derive_bot_login(config)
    end
  end

  # LA CLE DE CACHE PORTE CE QUI DETERMINE LA REPONSE.
  #
  # Le login est une propriete du JETON sur SA forge, jamais du module. Keye sur
  # `{__MODULE__, :bot_login}` seul, un second jeton — rotation, ou deux forges dans la meme VM —
  # heritait du login du premier pour toute la vie du noeud. Et ce login est l'argument du primitif
  # de confiance `ForgeProtocol.system_authored?/2` : s'en tromper, ce n'est pas afficher un mauvais
  # nom, c'est comparer l'auteur d'un commentaire au mauvais compte.
  #
  # Le jeton n'est JAMAIS stocke : `:persistent_term` est lisible par tout processus du noeud. Son
  # empreinte suffit a distinguer deux jetons sans en reveler aucun.
  @doc false
  # Le login DE CE JETON, sans passer par les surcharges de `forge_bot_login/2`.
  #
  # `derive_bot_login/1` n'a jamais rien eu de specifique au bot : c'est « qui suis-je avec ce
  # jeton », et depuis que sa cle porte l'empreinte du jeton, il repond juste pour n'importe lequel.
  # `forge_bot_login/2`, lui, consulte d'abord `opts[:forge_bot_login]` puis l'env applicative —
  # deux surcharges qui rendraient le login du SYSTEME pour un jeton de ROLE, ce qui est exactement
  # le genre de reponse plausible et fausse qu'on cherche a supprimer.
  def login_of(config), do: derive_bot_login(config)

  defp derive_bot_login(config) do
    key = {__MODULE__, :bot_login, config.base_url, :crypto.hash(:sha256, config.token)}

    case :persistent_term.get(key, :unset) do
      login when is_binary(login) ->
        {:ok, login}

      :unset ->
        case http_get(config, "/user") do
          {:ok, %{"login" => login}} when is_binary(login) and login != "" ->
            :persistent_term.put(key, login)
            {:ok, login}

          {:ok, _} ->
            {:error, :bot_login_unresolved}

          {:error, _} = err ->
            err
        end
    end
  end

  @page_limit 50
  @max_pages 200

  @doc false
  def paginate(config, path_base, query) do
    do_paginate(config, path_base, query, 1, [])
  end

  defp do_paginate(_config, path_base, _query, page, _acc) when page > @max_pages do
    {:error, {:pagination_budget_exceeded, path_base, @max_pages}}
  end

  # LA CONDITION D'ARRET EST UN FAIT QUAND LA FORGE LE DONNE, UNE HEURISTIQUE SINON.
  #
  # `X-Total-Count` est annonce sur les endpoints de liste, y compris sur celui dont `page` et
  # `limit` sont IGNORES (mesure 1.26.1 : 7 commentaires -> `X-Total-Count: 7`). Sans lui, le seul
  # signal disponible etait `length(items) < @page_limit`, et cette heuristique ment de deux facons :
  #
  #   * un endpoint qui ignore `page` rend TOUT a chaque tour — sous le plafond elle conclut juste
  #     par accident, au-dessus elle boucle jusqu'au budget sur des pages identiques ;
  #   * `@page_limit` egale le `max_response_items` du serveur par VALEUR, pas par derivation : un
  #     plafond serveur abaisse ferait ecreter la premiere page et la troncature serait muette.
  #
  # Le total supprime les deux : on s'arrete quand on tient ce qui a ete annonce. `nil` veut dire
  # « non annonce », jamais zero — dans ce cas seulement on retombe sur l'heuristique.
  defp do_paginate(config, path_base, query, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case request_raw(config, :get, path, nil) do
      {:ok, %Req.Response{status: status, body: items} = resp}
      when status in 200..299 and is_list(items) ->
        acc = [items | acc]
        got = Enum.reduce(acc, 0, fn page_items, n -> n + length(page_items) end)
        total = total_count(resp)

        cond do
          # Une page vide est la fin, quoi qu'annonce le total : elle borne le cas ou le serveur
          # rend moins que ce qu'il compte (filtrage de droits) sans nous laisser tourner.
          items == [] -> {:ok, collect(acc)}
          is_integer(total) and got >= total -> {:ok, collect(acc)}
          is_nil(total) and length(items) < @page_limit -> {:ok, collect(acc)}
          true -> do_paginate(config, path_base, query, page + 1, acc)
        end

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error, {:unexpected_page_shape, path, page, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp collect(acc), do: acc |> Enum.reverse() |> Enum.concat()

  @doc false
  def http_get(config, path), do: request(config, :get, path, nil)
  @doc false
  def http_put(config, path, body), do: request(config, :put, path, body)
  @doc false
  def http_post(config, path, body), do: request(config, :post, path, body)
  @doc false
  def http_patch(config, path, body), do: request(config, :patch, path, body)
  @doc false
  def http_delete(config, path), do: request(config, :delete, path, nil)

  # DELETE WITH A BODY. Unusual, and it is the forge that asks for it: Gitea identifies a
  # dependency edge by the OBJECT to detach (`{index, owner, repo}`), not by an id in the path —
  # the same body its POST twin takes. Kept separate from `http_delete/2` so that no caller sends a
  # body by accident on the many endpoints that carry their target in the URL.
  @doc false
  def http_delete_body(config, path, body), do: request(config, :delete, path, body)

  defp request_raw(config, method, path, body) do
    url = config.base_url <> "/api/v1" <> path

    # Callers own retry policy; Req retries would stack another backoff.
    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "token " <> config.token},
          {"accept", "application/json"}
        ],
        receive_timeout: 10_000,
        retry: false,
        finch: [name: Fleet.Pilot.ForgeFinch]
      ]
      |> Opts.maybe_put(:json, body)
      |> Keyword.merge(config.req_options)

    started = System.monotonic_time(:millisecond)
    result = Req.request(req_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    if elapsed > 1_000 do
      Logger.warning(
        "Transport: #{method} #{path} SLOW #{elapsed}ms → #{forge_result_tag(result)}"
      )
    end

    result
  end

  # `request/4` rend ce qu'il a toujours rendu ; `request_raw/4` garde la REPONSE, en-tetes compris.
  # Le decoupage existe pour une seule raison : la forge annonce le total d'une liste dans
  # `X-Total-Count`, et ce total est la difference entre une condition d'arret exacte et une
  # heuristique (cf. `do_paginate/5`).
  defp request(config, method, path, body) do
    case request_raw(config, method, path, body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  end

  # Le total annonce, ou `nil` s'il ne l'est pas. `nil` n'est PAS zero : il veut dire « non dit »,
  # et la pagination retombe alors sur son heuristique en le sachant.
  defp total_count(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "x-total-count") do
      [v | _] ->
        case Integer.parse(v) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp forge_result_tag({:ok, %Req.Response{status: status}}), do: "http #{status}"
  defp forge_result_tag({:error, exception}), do: "transport #{inspect(exception)}"
end
