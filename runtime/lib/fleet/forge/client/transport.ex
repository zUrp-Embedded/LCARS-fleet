defmodule Fleet.Forge.Client.Transport do
  @moduledoc """
  HTTP/config engine of the forge client — the plumbing UNDER `Fleet.Forge.Client`.
  Vendor-agnostic in the "domain" sense: here live config/token resolution, the Req
  call (dedicated pool + instrumentation of slow calls), the pagination of source-of-truth
  collections and the derivation of the system login. (The safe encoding of URL
  segments — path-traversal lock — lives in `Fleet.Forge.Client.UrlSafe`.)
  No knowledge of the forge *protocol* (branches, labels, markers): that's
  `Fleet.Forge.Client` (domain) + `Fleet.Forge.Protocol` (vocab).

  INTERNAL surface (`@doc false`): everything is public so that `Fleet.Forge.Client` and its
  sub-modules can call it, but it is not an app contract — no caller outside this domain.

  ## Configuration

  Resolved at call time via `opts` (Keyword) or fallback `Application.get_env(:lcars_fleet, :pilot_forge)`:

    * `:base_url` — e.g. `"http://localhost:3000"` (laptop mirror) or `"http://10.42.0.118"` (forge NAS).
    * `:token` — Gitea token, supplied directly by the caller.
    * `:token_file` — an EXPLICIT path. A caller that already holds one (a second forge, a witness).
    * `:account` — a forge ACCOUNT name. The token is ASKED of the authority service, at call time.
    * `:req_options` — options passed as-is to `Req.new/1` (for tests: `[plug: ...]` to intercept HTTP).

  ## Aucun repli vers `~/.gitea_token`, et c'est une regle d'IDENTITE

  Le BEAM tourne sous l'uid de l'humain de fleet : un repli vers son `~/.gitea_token` resoudrait
  vers le jeton PERSONNEL de cette personne. Une boite dont le cablage systeme manque ne tomberait
  pas en panne — elle agirait sur la forge sous l'identite d'un humain, avec ses droits, sans
  qu'une ligne le dise. Sans source de jeton, la resolution rend `{:config, :no_token_source}` :
  un refus nomme, jamais un succes sous une autre identite.
  """

  require Logger

  alias Fleet.Opts
  alias Req.Response

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  @typedoc """
  Le retour de TOUT verbe HTTP de ce module.

  Trois formes, et la deuxieme est la seule que vingt sites filtrent : `{:http, status, body}` porte
  un refus de la forge (y compris les 412/423 DEFINITIFS, dont la forme est deliberement identique —
  cf. `name_permanent/4`), `{:transport, exception}` porte une panne de fil.
  """
  @type response ::
          {:ok, term()} | {:error, {:http, pos_integer(), term()} | {:transport, term()}}

  @typedoc """
  Le retour de la pagination : la liste COLLECTEE, ou un refus.

  Deux refus lui sont propres, en plus de ceux de `response()` : une page 2xx dont la forme n'est ni
  une liste ni l'enveloppe attendue (`:unexpected_page_shape`), et le filet `@max_pages` — une forge
  qui ignore `page` rendrait sinon la meme page indefiniment.
  """
  @type paginated :: {:ok, [term()]} | {:error, term()}

  @doc false
  @spec resolve_config(keyword()) :: {:ok, config()} | {:error, term()}
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

  # TROIS SOURCES, ORDONNEES, ET AUCUN REPLI IMPLICITE. Un jeton fourni, un chemin fourni, un compte
  # a demander — et si aucune n'est la, un refus qui le dit. L'ordre est celui du SPECIFIQUE vers le
  # GENERAL : ce que l'appelant tient de la main gagne sur ce que la boite a configure.
  defp resolve_token(opts) do
    cond do
      is_binary(token = Keyword.get(opts, :token)) and token != "" ->
        {:ok, token}

      is_binary(path = Keyword.get(opts, :token_file)) and path != "" ->
        read_token_file(path)

      is_binary(account = Keyword.get(opts, :account)) and account != "" ->
        # ⚠ DEMANDE A CHAQUE APPEL, ET C'EST LA PROPRIETE ACHETEE, PAS UN OUBLI D'OPTIMISATION. Un
        # jeton mis en cache ici reprendrait exactement la peremption infinie que ce chantier retire.
        # Le cout est un aller-retour sur socket unix LOCALE devant un appel HTTP a la forge — du
        # bruit. Le jour ou une mesure reclame un cache, ce sera un parametre de DEBIT, et il faudra
        # le dire ailleurs que dans un `defp`.
        case Fleet.Credentials.ForgeAuth.token_for(account) do
          {:ok, token} -> {:ok, token}
          {:error, cause} -> {:error, {:config, {:authority, account, cause}}}
        end

      true ->
        {:error, {:config, :no_token_source}}
    end
  end

  defp read_token_file(path) do
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

  @doc false
  @spec forge_bot_login(config(), keyword()) :: {:ok, String.t()} | {:error, term()}
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
  @spec login_of(config()) ::
          {:ok, String.t()}
          | {:error,
             :bot_login_unresolved | {:transport, term()} | {:http, pos_integer(), term()}}
  def login_of(config), do: derive_bot_login(config)

  # L'EMPREINTE DU JETON EST UNE VALEUR, PAS UNE CLE. Dans la cle, chaque rotation creerait une
  # entree de plus, jamais rendue : sur un noeud de longue duree, le nombre d'entrees
  # `:persistent_term` croitrait avec le nombre de jetons successifs, et chaque `put` declenche un
  # GC global.
  #
  # UNE entree par `base_url`, dont la valeur porte l'empreinte : une rotation ECRASE la precedente
  # au lieu de s'y ajouter. La propriete de correction est la meme — un login memorise pour un jeton
  # ne doit jamais etre servi pour un autre (le jeton du SYSTEME et celui d'un ROLE ne repondent pas
  # le meme `/user`) — et la comparaison sur la valeur lue est le meme test, au meme moment, sans
  # accumuler.
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
  # `@max_pages` n'est donc pas la borne effective : c'est le filet du cas ou tout le reste ment
  # simultanement — une forge qui ignore `page` rend tout, a chaque tour, et sans total lu tourne
  # 200 fois (mesure). Les quatre tests de
  # `forge_client_pagination_test.exs` tiennent les deux gardes.
  #
  # PAS de deadline murale sur la boucle, et c'est un choix : elle transformerait une lecture LENTE
  # mais correcte en echec, alors que le mal a eviter est une lecture qui ne finit pas.
  @page_limit 50
  @max_pages 200

  @doc false
  @spec paginate(config(), String.t(), String.t()) :: paginated()
  def paginate(config, path_base, query), do: paginate(config, path_base, query, nil)

  @doc """
  Same pagination, for an endpoint whose page arrives in an ENVELOPE instead of as a bare list.

  Gitea is not uniform here: the list endpoints answer with a JSON array, `/repos/search` answers
  `%{"ok" => true, "data" => [...]}`. `unwrap` names the key to take, `nil` means "the body IS the
  list" — the shape every existing caller has.

  It is a PARAMETER and not a second paginator, because the stop condition is the part that has a
  scar (`X-Total-Count` first, empty page always wins, `< @page_limit` only as a fallback). A copy
  of that loop for one endpoint is a copy that drifts away from the reasoning above it.
  """
  @spec paginate(config(), String.t(), String.t(), String.t() | nil) :: paginated()
  def paginate(config, path_base, query, unwrap) do
    do_paginate(config, path_base, query, unwrap, 1, [])
  end

  defp do_paginate(_config, path_base, _query, _unwrap, page, _acc) when page > @max_pages do
    {:error, {:pagination_budget_exceeded, path_base, @max_pages}}
  end

  # LA CONDITION D'ARRET EST UN FAIT QUAND LA FORGE LE DONNE, UNE HEURISTIQUE SINON.
  #
  # `X-Total-Count` est annonce sur les endpoints de liste, y compris sur celui dont `page` et
  # `limit` sont IGNORES (mesure 1.26.1 : 7 commentaires -> `X-Total-Count: 7`). Sans lui, le seul
  # signal disponible serait `length(items) < @page_limit`, et cette heuristique ment de deux facons :
  #
  #   * un endpoint qui ignore `page` rend TOUT a chaque tour — sous le plafond elle conclut juste
  #     par accident, au-dessus elle boucle jusqu'au budget sur des pages identiques ;
  #   * `@page_limit` egale le `max_response_items` du serveur par VALEUR, pas par derivation : un
  #     plafond serveur abaisse ferait ecreter la premiere page et la troncature serait muette.
  #
  # Le total supprime les deux : on s'arrete quand on tient ce qui a ete annonce. `nil` veut dire
  # « non annonce », jamais zero — dans ce cas seulement on retombe sur l'heuristique.
  defp do_paginate(config, path_base, query, unwrap, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case request_raw(config, :get, path, nil) |> unwrap_page(unwrap) do
      {:ok, %Response{status: status, body: items} = resp}
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
          true -> do_paginate(config, path_base, query, unwrap, page + 1, acc)
        end

      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        {:error, {:unexpected_page_shape, path, page, body}}

      {:ok, %Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # The envelope is taken BEFORE the shape guard, so a body that is neither a list nor the expected
  # envelope falls through to `:unexpected_page_shape` — one refusal for both, and the headers stay
  # on the response the stop condition reads.
  defp unwrap_page(result, nil), do: result

  defp unwrap_page({:ok, %Response{status: status, body: body} = resp}, key)
       when status in 200..299 and is_map(body) do
    {:ok, %{resp | body: Map.get(body, key)}}
  end

  defp unwrap_page(other, _key), do: other

  defp collect(acc), do: acc |> Enum.reverse() |> Enum.concat()

  @doc false
  @spec http_get(config(), String.t()) :: response()
  def http_get(config, path), do: request(config, :get, path, nil)
  @doc false
  @spec http_put(config(), String.t(), term()) :: response()
  def http_put(config, path, body), do: request(config, :put, path, body)
  @doc false
  @spec http_post(config(), String.t(), term()) :: response()
  def http_post(config, path, body), do: request(config, :post, path, body)
  @doc false
  @spec http_patch(config(), String.t(), term()) :: response()
  def http_patch(config, path, body), do: request(config, :patch, path, body)
  @doc false
  @spec http_delete(config(), String.t()) :: response()
  def http_delete(config, path), do: request(config, :delete, path, nil)

  # DELETE WITH A BODY. Unusual, and it is the forge that asks for it: Gitea identifies a
  # dependency edge by the OBJECT to detach (`{index, owner, repo}`), not by an id in the path —
  # the same body its POST twin takes. Kept separate from `http_delete/2` so that no caller sends a
  # body by accident on the many endpoints that carry their target in the URL.
  @doc false
  @spec http_delete_body(config(), String.t(), term()) :: response()
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
      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Response{status: status, body: body}} ->
        _ = name_permanent(status, method, path, body)
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # DEUX ECHECS QUI NE REVIENDRONT PAS, ET QUI PORTAIENT LE VISAGE D'UN ECHEC PASSAGER.
  #
  # `423` est declare par 31 operations du contrat, `412` par 3, et seule cette ligne de journal les
  # distingue d'un `500` : tous ressortent en `{:http, status, body}`. Or un depot ARCHIVE ou une
  # conversation VERROUILLEE rend 423 a chaque tentative, pour toujours — un poller qui re-dispatche
  # a chaque tour produit la meme panne indefiniment, et rien d'autre ne dit qu'aucun tour ne la
  # resoudra.
  #
  # La FORME du retour est la meme, et c'est delibere : vingt sites filtrent sur `{:http, ...}`, et
  # un tuple different ferait tomber ces deux codes dans leurs catch-all — en silence, c'est-a-dire
  # exactement le contraire du but. Ce qui compte n'est pas un type, c'est de le DIRE.
  defp name_permanent(status, method, path, body) when status in [412, 423] do
    Logger.warning(
      "Transport: #{method} #{path} -> HTTP #{status} " <>
        "(#{if status == 423, do: "verrouille", else: "precondition non tenue"}) — condition " <>
        "PERMANENTE, aucun nouvel essai ne la levera : #{inspect(body)}"
    )
  end

  # LE SYMETRIQUE. `412` et `423` sont nommes PERMANENTS parce qu'aucun nouvel essai ne les levera.
  # Le `429` est l'inverse exact — il dit « reessaie plus tard » — et sans cette ligne il ressort en
  # `{:http, 429, body}` indistinct d'un `500` : un appelant qui abandonne sur erreur abandonne une
  # condition qui se serait levee seule.
  #
  # La FORME du retour est la meme, pour la meme raison que ci-dessus : vingt sites filtrent sur
  # `{:http, ...}`. Ce qui compte est de le DIRE — et de dire COMBIEN de temps, quand la forge le
  # dit. `Retry-After` est lu ici et journalise ; le faire consommer par une
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
  defp total_count(%Response{} = resp) do
    case Response.get_header(resp, "x-total-count") do
      [v | _] ->
        case Integer.parse(v) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp forge_result_tag({:ok, %Response{status: status}}), do: "http #{status}"
  defp forge_result_tag({:error, exception}), do: "transport #{inspect(exception)}"
end
