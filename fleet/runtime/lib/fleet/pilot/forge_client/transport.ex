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

  **Last revised**: 2026-08-04
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

  @page_limit 50
  @max_pages 200

  @doc false
  def paginate(config, path_base, query) do
    do_paginate(config, path_base, query, 1, [])
  end

  defp do_paginate(_config, path_base, _query, page, _acc) when page > @max_pages do
    {:error, {:pagination_budget_exceeded, path_base, @max_pages}}
  end

  defp do_paginate(config, path_base, query, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case http_get(config, path) do
      {:ok, items} when is_list(items) ->
        acc = [items | acc]

        if length(items) < @page_limit do
          {:ok, acc |> Enum.reverse() |> Enum.concat()}
        else
          do_paginate(config, path_base, query, page + 1, acc)
        end

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

  # DELETE WITH A BODY. Unusual, and it is the forge that asks for it: Gitea identifies a
  # dependency edge by the OBJECT to detach (`{index, owner, repo}`), not by an id in the path —
  # the same body its POST twin takes. Kept separate from `http_delete/2` so that no caller sends a
  # body by accident on the many endpoints that carry their target in the URL.
  @doc false
  def http_delete_body(config, path, body), do: request(config, :delete, path, body)

  defp request(config, method, path, body) do
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

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp forge_result_tag({:ok, %Req.Response{status: status}}), do: "http #{status}"
  defp forge_result_tag({:error, exception}), do: "transport #{inspect(exception)}"
end
