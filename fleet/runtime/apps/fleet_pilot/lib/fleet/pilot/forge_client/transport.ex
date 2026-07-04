defmodule Fleet.Pilot.ForgeClient.Transport do
  @moduledoc """
  Moteur HTTP/config du client forge — la plomberie SOUS `Fleet.Pilot.ForgeClient`.
  Vendor-agnostic au sens « domaine » : ici vivent la résolution de config/token, l'appel
  Req (pool dédié + instrumentation des appels lents), la pagination des collections
  source-de-vérité et la dérivation du login système. (L'encodage sûr des segments
  d'URL — verrou path-traversal — vit dans `Fleet.Pilot.ForgeClient.UrlSafe`.)
  Aucune connaissance du *protocole* forge (branches, labels, marqueurs) : ça, c'est
  `Fleet.Pilot.ForgeClient` (domaine) + `Fleet.Pilot.ForgeProtocol` (vocab).

  Surface INTERNE (`@doc false`) : tout est public pour que `ForgeClient` l'appelle,
  mais ce n'est pas un contrat d'app — pas de caller hors `fleet_pilot`.

  ## Configuration

  Résolue à l'appel via `opts` (Keyword) ou fallback `Application.get_env(:fleet_pilot, :forge)` :

    * `:base_url` — ex `"http://localhost:3000"` (laptop mirror) ou `"http://10.42.0.118"` (forge NAS).
    * `:token` — token Gitea. Lu depuis `:token_file` si absent.
    * `:token_file` — path fichier (défaut `~/.gitea_token`, convention v1.5).
    * `:req_options` — options passées tel quel à `Req.new/1` (pour tests : `[plug: ...]` pour intercepter HTTP).
  """

  require Logger

  alias Fleet.Pilot.Opts

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  # ============================================================
  # Config resolution
  # ============================================================

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
                # Un fichier token VIDE (ou whitespace-only) trime en "" → header
                # `authorization: token ` envoyé tel quel → 401 TARDIF côté forge (échec opaque,
                # diagnostiqué loin de la source). On tranche ICI, à la config, fail-loud explicite.
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

  # ============================================================
  # Identité forge — login du compte système (porteur de FORGE_TOKEN).
  # ============================================================

  @doc false
  # Login du compte système (le propriétaire de FORGE_TOKEN). Config `:forge_bot_login` (déploiement)
  # OU dérivé une fois via `GET /user` (l'authentifié du token), caché. Irrésoluble → `{:error}` :
  # les callers refusent alors de faire foi de marqueurs non vérifiables (fail-closed).
  def forge_bot_login(config, opts) do
    # opts (seam test) > config (déploiement) > dérivé /user (caché).
    case Keyword.get(opts, :forge_bot_login) ||
           Application.get_env(:fleet_pilot, :forge_bot_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      _ -> derive_bot_login(config)
    end
  end

  defp derive_bot_login(config) do
    case :persistent_term.get({__MODULE__, :bot_login}, :unset) do
      login when is_binary(login) ->
        {:ok, login}

      :unset ->
        case http_get(config, "/user") do
          {:ok, %{"login" => login}} when is_binary(login) and login != "" ->
            :persistent_term.put({__MODULE__, :bot_login}, login)
            {:ok, login}

          {:ok, _} ->
            {:error, :bot_login_unresolved}

          {:error, _} = err ->
            err
        end
    end
  end

  # ============================================================
  # URL-segment safety — DÉPLACÉ vers `Fleet.Pilot.ForgeClient.UrlSafe` (autorité unique,
  # cluster PUR de sécurité path-traversal). Les modules domaine (ForgeClient/Repo/Jury/Files)
  # importent UrlSafe directement — plus d'encodage défini ici.
  # ============================================================

  # ============================================================
  # HTTP plumbing
  # ============================================================

  @page_limit 50

  @doc false
  # Lecture PAGINÉE d'une collection source-de-vérité (issues / pulls / comments). Gitea
  # plafonne `limit` à 50/page — une seule page rate les items 51+ (issues/PR ignorés, marqueurs de
  # step_run sous-comptés). On boucle `page=1,2,...` (`@page_limit` items/page) en accumulant jusqu'à la
  # DERNIÈRE page : une page rendant < @page_limit items (ou vide) est la dernière (invariant Gitea :
  # une page pleine implique « peut-être une suite »). Comportement identique à l'ancien ≤50 items :
  # une collection ≤50 tient en page 1 (< 50 → stop), un seul round-trip. `query` = query-string SANS
  # pagination (ex. `"state=open&type=issues"` ou `""`). Toute page en erreur HTTP/transport remonte
  # (fail-loud : un caller source-de-vérité ne doit JAMAIS travailler sur une vue tronquée silencieuse).
  def paginate(config, path_base, query) do
    do_paginate(config, path_base, query, 1, [])
  end

  defp do_paginate(config, path_base, query, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case http_get(config, path) do
      {:ok, items} when is_list(items) ->
        acc = acc ++ items

        # Page pleine → il PEUT y avoir une suite ; page partielle/vide → dernière page, on s'arrête.
        if length(items) < @page_limit do
          {:ok, acc}
        else
          do_paginate(config, path_base, query, page + 1, acc)
        end

      # Réponse 2xx de forme INATTENDUE (non-liste) sur un endpoint de collection. Rendre
      # `{:ok, acc}` ferait passer une vue VIDE pour une collection vide : page 1 non-liste →
      # `{:ok, []}` indistinguable d'une collection réellement vide → le poller croirait « rien à
      # dispatcher » (route → :none, budget rework sous-compté), un caller source-de-vérité
      # travaillerait sur une vue VIDE silencieuse — le faux-succès que le fail-loud HTTP
      # empêche déjà pour les erreurs réseau, la forme inattendue en étant le trou. D'où une
      # ERREUR TYPÉE : la collection n'est PAS dérivable de cette page →
      # `{:error, {:unexpected_page_shape, …}}`. Les callers (`list_scoped_issues`, `get_route`,
      # `count_signed_step_runs`, `get_predecessor_result`, `comment_signed?`) propagent déjà `{:error, _}`.
      {:ok, non_list} ->
        {:error, {:unexpected_page_shape, path, page, non_list}}

      {:error, _} = err ->
        err
    end
  end

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

  defp request(config, method, path, body) do
    url = config.base_url <> "/api/v1" <> path

    # `retry: false` — le retry HTTP est délégué au caller :
    # `Fleet.Pilot.Poller` a son propre backoff exponentiel + jitter
    # (5min cap, anti-thundering-herd) et sérialise le traitement d'un
    # event à la fois. Le retry built-in Req (1s/2s/4s sur
    # 5xx) duplicaterait cette logique + ralentirait les tests d'erreur
    # de 7s par cas.
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
        # Pool dédié à `conn_max_idle_time` court (cf. `Fleet.Pilot.Application.forge_finch_spec`) : évite
        # qu'une connexion idle devienne stale et fasse pendre le 1er appel jusqu'au receive_timeout. Dans
        # la liste de BASE (avant le merge) → un test qui injecte `plug:` via `req_options` prime (le plug
        # court-circuite l'adapter Finch), l'hermétisme des tests reste intact.
        finch: Fleet.Pilot.ForgeFinch
      ]
      |> Opts.maybe_put(:json, body)
      |> Keyword.merge(config.req_options)

    started = System.monotonic_time(:millisecond)
    result = Req.request(req_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    # INSTRUMENTATION : un appel à la forge LOCALE qui dépasse 1s est anormal → on le trace (méthode,
    # path, durée, issue). C'est l'instrument qui dira au prochain run POURQUOI create_issue cumule
    # ~30s (3 appels forge : create_issue + add_label[GET+PUT]) — connexion stale ? endpoint qui pend ?
    if elapsed > 1_000 do
      Logger.warning(
        "ForgeClient #{method} #{path} LENT #{elapsed}ms → #{forge_result_tag(result)}"
      )
    end

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # Résumé compact d'un résultat Req pour le log d'instrumentation (status HTTP ou erreur transport).
  defp forge_result_tag({:ok, %Req.Response{status: status}}), do: "http #{status}"
  defp forge_result_tag({:error, exception}), do: "transport #{inspect(exception)}"
end
