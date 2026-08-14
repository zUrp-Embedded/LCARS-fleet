defmodule Fleet.Forge.Client.Transport do
  @moduledoc """
  HTTP/config engine of the forge client — the plumbing UNDER `Fleet.Forge.Client`.
  Vendor-agnostic in the "domain" sense: here live config/token resolution, the Req
  call (dedicated pool + instrumentation of slow calls), the pagination of source-of-truth
  collections and the derivation of the system login. (The safe encoding of URL
  segments — path-traversal lock — lives in `Fleet.Forge.Client.UrlSafe`.)
  No knowledge of the forge *protocol* (branches, labels, markers): that's
  `Fleet.Forge.Client` (domain) + `Fleet.Forge.Protocol` (vocab).

  INTERNAL surface (`@doc false`): everything is public so that `ForgeClient` can call it,
  but it is not an app contract — no caller outside `fleet_pilot`.

  ## Configuration

  Resolved at call time via `opts` (Keyword) or fallback `Application.get_env(:lcars_fleet, :pilot_forge)`:

    * `:base_url` — e.g. `"http://localhost:3000"` (laptop mirror) or `"http://10.42.0.118"` (forge NAS).
    * `:token` — Gitea token. Read from `:token_file` if absent.
    * `:token_file` — file path (default `~/.gitea_token`).
    * `:req_options` — options passed as-is to `Req.new/1` (for tests: `[plug: ...]` to intercept HTTP).
  """

  require Logger

  alias Fleet.Opts

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  @doc false
  def resolve_config(opts) do
    env = Application.get_env(:lcars_fleet, :pilot_forge, [])
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
           Application.get_env(:lcars_fleet, :pilot_forge_bot_login) do
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

  # L'EMPREINTE DU JETON EST UNE VALEUR, PLUS UNE CLE — et c'est tout le correctif. Elle etait DANS
  # la cle, donc chaque rotation creait une entree de plus et l'ancienne n'etait jamais rendue : sur
  # un noeud de longue duree, le nombre d'entrees `:persistent_term` croissait lineairement avec le
  # nombre de jetons successifs, et chaque `put` declenche un GC global.
  #
  # UNE entree par `base_url`, dont la valeur porte l'empreinte : une rotation ECRASE la precedente
  # au lieu de s'y ajouter. La propriete de correction est inchangee et c'est elle qui exigeait
  # l'empreinte quelque part — un login memorise pour un jeton ne doit jamais etre servi pour un
  # autre (le jeton du SYSTEME et celui d'un ROLE ne repondent pas le meme `/user`) : la comparaison
  # se fait maintenant sur la valeur lue, ce qui est le meme test, au meme moment, sans accumuler.
  defp derive_bot_login(config) do
    key = {__MODULE__, :bot_login, config.base_url}
    fingerprint = :crypto.hash(:sha256, config.token)

    case :persistent_term.get(key, :unset) do
      {^fingerprint, login} when is_binary(login) ->
        {:ok, login}

      _ ->
        case http_get(config, "/user") do
          {:ok, %{"login" => login}} when is_binary(login) and login != "" ->
            :persistent_term.put(key, {fingerprint, login})
            {:ok, login}

          {:ok, _} ->
            {:error, :bot_login_unresolved}

          {:error, _} = err ->
            err
        end
    end
  end

  # LA BORNE DE CETTE BOUCLE, ECRITE POUR POUVOIR ETRE REFAITE.
  #
  # `paginate/3` tourne DANS le tour de poller, qui est synchrone : tant qu'elle marche, la fleet ne
  # dispatche pas. Le pire cas a donc une valeur, et il vaut mieux qu'elle soit ecrite que devinee.
  #
  #   par requete   `receive_timeout: 10_000` (cf. `request_raw/4`) — une reponse qui ne vient pas
  #                 coupe a 10 s, jamais plus.
  #   par boucle    le TOTAL annonce (`X-Total-Count`) : on s'arrete des qu'on le tient. Le nombre de
  #                 tours est donc `ceil(total / @page_limit)`, pas `@max_pages` : un depot de 600
  #                 issues fait 12 tours, soit ~120 s au pire (borne ARITHMETIQUE, pas une mesure —
  #                 la taille reelle d'un depot varie et ce commentaire ne pretend pas la connaitre).
  #   deux gardes   une page VIDE termine quoi qu'annonce le total (une forge qui compte plus qu'elle
  #                 ne sert ne nous fait pas marcher) ; sans en-tete, l'heuristique `< @page_limit`
  #                 reprend la main.
  #
  # `@max_pages` n'est donc plus la borne effective : c'est le filet du cas ou tout le reste ment
  # simultanement — et c'est exactement l'etat qu'il a attrape avant que le total soit lu (une forge
  # qui ignore `page` rendait tout, a chaque tour, 200 fois). Les quatre tests de
  # `forge_client_pagination_test.exs` tiennent les deux gardes.
  #
  # PAS de deadline murale sur la boucle, et c'est un choix : elle transformerait une lecture LENTE
  # mais correcte en echec, alors que le mal a corriger etait une lecture qui ne finissait pas.
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
        finch: [name: Fleet.Forge.finch_name()]
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
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        _ = name_permanent(status, method, path, body)
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # DEUX ECHECS QUI NE REVIENDRONT PAS, ET QUI PORTAIENT LE VISAGE D'UN ECHEC PASSAGER.
  #
  # `423` est declare par 31 operations du contrat, `412` par 3, et rien dans ce depot ne les
  # distinguait d'un `500` : tous ressortaient en `{:http, status, body}`. Or un depot ARCHIVE ou une
  # conversation VERROUILLEE rend 423 a chaque tentative, pour toujours — un poller qui re-dispatche
  # a chaque tour produit alors la meme panne indefiniment, sans que rien ne dise qu'aucun tour ne la
  # resoudra.
  #
  # La FORME du retour ne change pas, et c'est delibere : vingt sites filtrent sur `{:http, ...}`, et
  # un tuple different ferait tomber ces deux codes dans leurs catch-all — en silence, c'est-a-dire
  # exactement le contraire du but. Ce qui manquait n'etait pas un type, c'etait de le DIRE.
  defp name_permanent(status, method, path, body) when status in [412, 423] do
    Logger.warning(
      "Transport: #{method} #{path} -> HTTP #{status} " <>
        "(#{if status == 423, do: "verrouille", else: "precondition non tenue"}) — condition " <>
        "PERMANENTE, aucun nouvel essai ne la levera : #{inspect(body)}"
    )
  end

  # LE SYMETRIQUE, ET IL MANQUAIT. `412` et `423` sont nommes PERMANENTS parce qu'aucun nouvel essai
  # ne les levera. Le `429` est l'inverse exact — il dit « reessaie plus tard » — et le depot ne le
  # connaissait pas : zero occurrence de `429`, `Retry-After` ou `too many` dans `lib/`, verifie par
  # deux moyens independants. Il ressortait donc en `{:http, 429, body}` indistinct d'un `500`, et un
  # appelant qui abandonne sur erreur abandonnait une condition qui se serait levee seule.
  #
  # La FORME du retour ne change pas, pour la meme raison que ci-dessus : vingt sites filtrent sur
  # `{:http, ...}`. Ce qui manquait n'etait pas un type, c'etait de le DIRE — et de dire COMBIEN de
  # temps, quand la forge le dit. `Retry-After` est lu ici et journalise ; le faire consommer par une
  # boucle de reessai metier est un geste d'appelant (le motif existe, `do_merge/6`), pas de ce
  # transport, qui a `retry: false` par construction.
  defp name_permanent(429, method, path, body) do
    Logger.warning(
      "Transport: #{method} #{path} -> HTTP 429 (limitation de debit) — condition TRANSITOIRE" <>
        retry_after_note(body) <> " : #{inspect(body)}"
    )
  end

  defp name_permanent(_status, _method, _path, _body), do: :ok

  # `Retry-After` n'arrive pas toujours, et son absence n'est pas zero : elle veut dire « non dit ».
  defp retry_after_note(%{"retry_after" => v}) when is_integer(v), do: ", reessai dans #{v} s"
  defp retry_after_note(_), do: ", delai non annonce"

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
