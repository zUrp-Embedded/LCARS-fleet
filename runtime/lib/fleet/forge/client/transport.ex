defmodule Fleet.Forge.Client.Transport do
  @moduledoc """
  Configuration, HTTP, pagination and login resolution for `Fleet.Forge.Client`.
  Path components are encoded by `Fleet.Forge.Client.UrlSafe`; protocol vocabulary lives
  in `Fleet.Forge.Protocol`.

  Call-time opts override matching keys in :lcars_fleet/:pilot_forge. The merged configuration
  requires :base_url and selects a nonempty binary :token, then :token_file, then :account.
  Failure of the selected source does not try the next. Whitespace-only direct values count
  as nonempty; file contents are trimmed. There is no implicit ~/.gitea_token fallback,
  which could otherwise substitute the BEAM user's personal identity for a missing system one.

  :req_options overrides request defaults, including headers, URL, retry and timeouts.
  Its Plug option supports HTTP interception in tests.
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
  HTTP 2xx body, HTTP status/body error, or transport error. Diagnostic logging does not
  change these return shapes. Invalid configuration or request options can still raise.
  """
  @type response ::
          {:ok, term()} | {:error, {:http, pos_integer(), term()} | {:transport, term()}}

  @typedoc """
  Collected pages or an error, with no partial list on failure. Pagination adds
  :unexpected_page_shape and :pagination_budget_exceeded to transport/HTTP errors.
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

  # Selection occurs after merging: an env :token can outrank an explicit :account or :token_file.
  defp resolve_token(opts) do
    cond do
      token = non_vide(opts, :token) -> {:ok, token}
      path = non_vide(opts, :token_file) -> read_token_file(path)
      account = non_vide(opts, :account) -> token_from_authority(account)
      true -> {:error, {:config, :no_token_source}}
    end
  end

  defp non_vide(opts, cle) do
    case Keyword.get(opts, cle) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # Ask the authority on each resolution so this module does not cache a rotated token.
  defp token_from_authority(account) do
    case Fleet.Credentials.ForgeAuth.token_for(account) do
      {:ok, token} -> {:ok, token}
      {:error, cause} -> {:error, {:config, {:authority, account, cause}}}
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
  # A truthy option masks the env override; an invalid value derives, an error tuple propagates.
  def forge_bot_login(config, opts) do
    case Keyword.get(opts, :forge_bot_login) ||
           Application.get_env(:lcars_fleet, :pilot_forge_bot_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      {:error, _} = err -> err
      _ -> derive_bot_login(config)
    end
  end

  @doc false
  # Resolves this token's login, bypassing system-login overrides when resolving a role.
  @spec login_of(config()) ::
          {:ok, String.t()}
          | {:error,
             :bot_login_unresolved | {:transport, term()} | {:http, pos_integer(), term()}}
  def login_of(config), do: derive_bot_login(config)

  # One slot per URL, digest/login in the value: rotation replaces instead of accumulating.
  # Wrong cached authors affect protocol trust. No raw token is stored in persistent_term.
  # No expiry or same-token revalidation; alternating role/system tokens replace each other.
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

  # At most 200 page requests, not a wall-clock deadline or item/byte limit. The default
  # receive_timeout is not a total request duration bound and req_options can override it.
  @page_limit 50
  @max_pages 200

  @doc false
  @spec paginate(config(), String.t(), String.t()) :: paginated()
  def paginate(config, path_base, query), do: paginate(config, path_base, query, nil)

  @doc """
  Collects lists, optionally taking `unwrap` from a successful map response (e.g. search's data).
  A bare list is also accepted with unwrap set. Headers survive unwrapping; envelope ok is ignored.
  Stops on an empty page, collected count reaching the latest X-Total-Count, or a short page
  when no usable total exists. Does not deduplicate, check a snapshot or reject premature emptiness.
  """
  @spec paginate(config(), String.t(), String.t(), String.t() | nil) :: paginated()
  def paginate(config, path_base, query, unwrap) do
    do_paginate(config, path_base, query, unwrap, 1, [])
  end

  defp do_paginate(_config, path_base, _query, _unwrap, page, _acc) when page > @max_pages do
    {:error, {:pagination_budget_exceeded, path_base, @max_pages}}
  end

  # Gitea 1.26.1 bench: comments ignored page/limit but supplied X-Total-Count.
  # Using that count avoids repeated all-items pages and handles a server page cap below 50.
  # Repeated partial pages can still satisfy the total with duplicates.
  defp do_paginate(config, path_base, query, unwrap, page, acc) do
    sep = if query == "", do: "?", else: "?#{query}&"
    path = "#{path_base}#{sep}page=#{page}&limit=#{@page_limit}"

    case request_raw(config, :get, path, nil) |> unwrap_page(unwrap) do
      {:ok, %Response{status: status, body: items} = resp}
      when status in 200..299 and is_list(items) ->
        acc = [items | acc]

        if last_page?(items, acc, total_count(resp)) do
          {:ok, collect(acc)}
        else
          do_paginate(config, path_base, query, unwrap, page + 1, acc)
        end

      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        {:error, {:unexpected_page_shape, path, page, body}}

      {:ok, %Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # Empty wins even if the server announces more, avoiding a walk through the full budget.
  defp last_page?([], _acc, _total), do: true

  defp last_page?(items, acc, total) do
    got = Enum.reduce(acc, 0, fn page_items, n -> n + length(page_items) end)

    (is_integer(total) and got >= total) or
      (is_nil(total) and length(items) < @page_limit)
  end

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

  # Dependency deletion takes {index, owner, repo} in a body, unlike ordinary URL-only DELETE.
  @doc false
  @spec http_delete_body(config(), String.t(), term()) :: response()
  def http_delete_body(config, path, body), do: request(config, :delete, path, body)

  defp request_raw(config, method, path, body) do
    url = config.base_url <> "/api/v1" <> path

    # Disable retries by default to avoid stacking caller backoff; req_options wins below.
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

  # Ordinary verbs discard headers; pagination keeps them and bypasses name_permanent diagnostics.
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

  # Logs 412/423 without changing the tuple consumed by callers. PERMANENTE is diagnostic
  # wording: this code neither proves permanence nor prevents later attempts after a state change.
  defp name_permanent(status, method, path, body) when status in [412, 423] do
    Logger.warning(
      "Transport: #{method} #{path} -> HTTP #{status} " <>
        "(#{if status == 423, do: "verrouille", else: "precondition non tenue"}) — condition " <>
        "PERMANENTE, aucun nouvel essai ne la levera : #{inspect(body)}"
    )
  end

  # Announces 429 without scheduling a retry or reading the HTTP Retry-After header.
  defp name_permanent(429, method, path, body) do
    Logger.warning(
      "Transport: #{method} #{path} -> HTTP 429 (limitation de debit) — condition TRANSITOIRE" <>
        retry_after_note(body) <> " : #{inspect(body)}"
    )
  end

  defp name_permanent(_status, _method, _path, _body), do: :ok

  # Only the JSON field retry_after is read; any integer, including negative, is logged as seconds.
  defp retry_after_note(%{"retry_after" => v}) when is_integer(v), do: ", reessai dans #{v} s"
  defp retry_after_note(_), do: ", delai non annonce"

  # First header's nonnegative integer prefix; trailing text is accepted. Unparseable => nil.
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
