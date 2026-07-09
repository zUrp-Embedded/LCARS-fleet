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
    * `:token_file` — file path (default `~/.gitea_token`, v1.5 convention).
    * `:req_options` — options passed as-is to `Req.new/1` (for tests: `[plug: ...]` to intercept HTTP).
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
                # An EMPTY token file (or whitespace-only) trims to "" → header
                # `authorization: token ` sent as-is → LATE 401 on the forge side (opaque failure,
                # diagnosed far from the source). We cut it HERE, at config time, explicit fail-loud.
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
  # Forge identity — login of the system account (bearer of FORGE_TOKEN).
  # ============================================================

  @doc false
  # Login of the system account (the owner of FORGE_TOKEN). Config `:forge_bot_login` (deployment)
  # OR derived once via `GET /user` (the token's authenticated user), cached. Unresolvable → `{:error}`:
  # callers then refuse to trust unverifiable markers (fail-closed).
  def forge_bot_login(config, opts) do
    # opts (test seam) > config (deployment) > derived /user (cached).
    case Keyword.get(opts, :forge_bot_login) ||
           Application.get_env(:fleet_pilot, :forge_bot_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      # Explicit error seam: a deployment misconfig surfaced as `{:error, _}`, or a test injecting an
      # unresolvable bot → propagated as-is (callers fail-closed on an unverifiable bot).
      {:error, _} = err -> err
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
  # URL-segment safety — MOVED to `Fleet.Pilot.ForgeClient.UrlSafe` (single authority,
  # PURE path-traversal security cluster). The domain modules (ForgeClient/Repo/Jury/Files)
  # import UrlSafe directly — no more encoding defined here.
  # ============================================================

  # ============================================================
  # HTTP plumbing
  # ============================================================

  @page_limit 50

  @doc false
  # PAGINATED read of a source-of-truth collection (issues / pulls / comments). Gitea
  # caps `limit` at 50/page — a single page misses items 51+ (issues/PR ignored, step_run
  # markers under-counted). We loop `page=1,2,...` (`@page_limit` items/page) accumulating until the
  # LAST page: a page returning < @page_limit items (or empty) is the last (Gitea invariant:
  # a full page implies "maybe a continuation"). Behavior identical to the old ≤50 items:
  # a collection ≤50 fits in page 1 (< 50 → stop), a single round-trip. `query` = query-string WITHOUT
  # pagination (e.g. `"state=open&type=issues"` or `""`). Any page with an HTTP/transport error bubbles up
  # (fail-loud: a source-of-truth caller must NEVER work on a silently truncated view).
  def paginate(config, path_base, query) do
    do_paginate(config, path_base, query, 1, [])
  end

  defp do_paginate(config, path_base, query, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case http_get(config, path) do
      {:ok, items} when is_list(items) ->
        acc = acc ++ items

        # Full page → there MAY be a continuation; partial/empty page → last page, we stop.
        if length(items) < @page_limit do
          {:ok, acc}
        else
          do_paginate(config, path_base, query, page + 1, acc)
        end

      # 2xx response of UNEXPECTED shape (non-list) on a collection endpoint. Returning
      # `{:ok, acc}` would pass an EMPTY view for an empty collection: page 1 non-list →
      # `{:ok, []}` indistinguable from a truly empty collection → the poller would believe "nothing to
      # dispatch" (route → :none, rework budget under-counted), a source-of-truth caller
      # would work on a silently EMPTY view — the false-success that the HTTP fail-loud
      # already prevents for network errors, the unexpected shape being its gap. Hence a
      # TYPED ERROR: the collection is NOT derivable from this page →
      # `{:error, {:unexpected_page_shape, …}}`. The callers (`list_scoped_issues`, `get_route`,
      # `count_signed_step_runs`, `get_predecessor_result`, `comment_signed?`) already propagate `{:error, _}`.
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

    # `retry: false` — HTTP retry is delegated to the caller:
    # `Fleet.Pilot.Poller` has its own exponential backoff + jitter
    # (5min cap, anti-thundering-herd) and serializes the processing of one
    # event at a time. Req's built-in retry (1s/2s/4s on
    # 5xx) would duplicate this logic + slow the error tests
    # by 7s per case.
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
        # Pool dedicated with a short `conn_max_idle_time` (cf. `Fleet.Pilot.Application.forge_finch_spec`): prevents
        # an idle connection from going stale and hanging the 1st call until receive_timeout. In
        # the BASE list (before the merge) → a test injecting `plug:` via `req_options` takes precedence (the plug
        # short-circuits the Finch adapter), test hermeticity stays intact.
        finch: Fleet.Pilot.ForgeFinch
      ]
      |> Opts.maybe_put(:json, body)
      |> Keyword.merge(config.req_options)

    started = System.monotonic_time(:millisecond)
    result = Req.request(req_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    # INSTRUMENTATION: a call to the LOCAL forge exceeding 1s is abnormal → we trace it (method,
    # path, duration, issue). It's the instrument that will tell the next run WHY create_issue accumulates
    # ~30s (3 forge calls: create_issue + add_label[GET+PUT]) — stale connection? hanging endpoint?
    if elapsed > 1_000 do
      Logger.warning(
        "ForgeClient: #{method} #{path} SLOW #{elapsed}ms → #{forge_result_tag(result)}"
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

  # Compact summary of a Req result for the instrumentation log (HTTP status or transport error).
  defp forge_result_tag({:ok, %Req.Response{status: status}}), do: "http #{status}"
  defp forge_result_tag({:error, exception}), do: "transport #{inspect(exception)}"
end
