defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Gitea webhook router. Application enables it with :event_router_start_webhooks and
  :event_router_webhook_port (default 8081). POST /webhook/gitea authenticates the raw body
  using SHA256 HMAC in X-Gitea-Signature before JSON parsing. The secret path is configured
  by :event_router_webhook_secret_path, default /etc/fleet/webhook-secret; file ownership,
  permissions and pod exclusion are deployment responsibilities, not verified here.

  POST returns 200 when the emitter returns :ok, 401 for unavailable secret/signature
  mismatch, and 422 for unknown/unregistered types or returned emission errors. Request
  read errors return 400; parser/size exceptions use Plug's status handling. Signed JSON
  is not a validated Gitea schema. Acknowledgement does not prove subscriber processing,
  and the endpoint has no replay/deduplication check. Webhooks accelerate the durable poll rail.

  After successful shared parsing, GET /health returns 200 and unmatched routes return 404.
  Parser errors can preempt either response, even though those routes require no HMAC.
  """

  use Plug.Router

  alias Plug.Conn

  require Logger

  # Share the read limit with Plug.Parsers, avoiding conflicting body-size policies.
  @max_body 1_048_576

  plug(:match)

  # Read raw bytes before parsing so invalid signatures cannot reach JSON decoding on this route.
  # The parser must then reuse those bytes; merely moving HMAC ahead of a parser-owned read fails.
  plug(:authenticate_webhook)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    length: @max_body,
    body_reader: {__MODULE__, :read_raw_body, []}
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/webhook/gitea" do
    # Require the authentication marker without recomputing HMAC. This detects a missing
    # authentication stage, not every invalid ordering or an externally preassigned marker.
    %{hmac_verified: true} = conn.assigns

    body = conn.body_params
    action = body["action"]
    action = if is_binary(action), do: action, else: nil
    event_type = "gitea." <> (action || gitea_event_header(conn) || "unknown")
    issue_id = extract_issue(body)

    try do
      type_atom = String.to_existing_atom(event_type)

      payload = Map.put(body, "issue_id", issue_id)

      emit_fun =
        Application.get_env(
          :lcars_fleet,
          :event_router_webhook_emit_fun,
          &Fleet.EventRouter.Bus.emit/3
        )

      case emit_fun.(:event_router, type_atom, payload: payload) do
        :ok ->
          send_resp(conn, 200, "ok")

        {:error, reason} ->
          Logger.warning(
            "WebhooksGitea: broadcast FAILED #{inspect(reason)} for #{event_type} " <>
              "— DRIFT, 422 (never ACK a dropped event)"
          )

          send_resp(conn, 422, "broadcast failed")
      end
    rescue
      ArgumentError ->
        Logger.warning(
          "WebhooksGitea: unknown event type #{inspect(event_type)} " <>
            "— DRIFT (unknown atom), 422"
        )

        send_resp(conn, 422, Jason.encode!(%{error: "unknown event type", type: event_type}))

      _e in Fleet.Event.UnregisteredError ->
        Logger.warning(
          "WebhooksGitea: type #{inspect(event_type)} outside the events.yaml " <>
            "registry — DROP/DRIFT, 422 (add the key if the action must be routed)"
        )

        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "event type not in registry", type: event_type})
        )
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc false
  @spec read_raw_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_raw_body(conn, opts) do
    # Reuse authenticated bytes; a second adapter read would see an exhausted body. Other
    # routes may reach the parser without authentication and use the adapter fallback.
    case conn.assigns do
      %{raw_body: body} ->
        {:ok, body, conn}

      _ ->
        case Conn.read_body(conn, opts) do
          {:ok, body, conn} -> {:ok, body, Conn.assign(conn, :raw_body, body)}
          {:more, partial, conn} -> {:more, partial, conn}
          {:error, _} = err -> err
        end
    end
  end

  # Only this POST requires HMAC. Health/unmatched routes still pass through Plug.Parsers.
  defp authenticate_webhook(%Conn{method: "POST", path_info: ["webhook", "gitea"]} = conn, _) do
    case Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        conn = Conn.assign(conn, :raw_body, body)

        case verify_hmac(conn) do
          :ok ->
            Conn.assign(conn, :hmac_verified, true)

          {:error, reason} ->
            Logger.warning("WebhooksGitea: webhook REFUSED 401 — HMAC verification: #{reason}")

            conn |> send_resp(401, Jason.encode!(%{error: reason})) |> halt()
        end

      # Refuse partial reads as too large rather than checking HMAC on incomplete bytes.
      {:more, _partial, _conn} ->
        raise Plug.Parsers.RequestTooLargeError

      {:error, reason} ->
        Logger.warning("WebhooksGitea: unreadable request body (#{inspect(reason)}) → 400")

        conn |> send_resp(400, "bad request") |> halt()
    end
  end

  defp authenticate_webhook(conn, _opts), do: conn

  @doc """
  Verifies the raw body's SHA256 HMAC against `x-gitea-signature`.

  Reads and trims the secret on every call so rotation takes effect without restart.
  Empty/whitespace or unreadable secrets return secret_missing. Rotate through atomic rename
  on the same filesystem: in-place writes can expose partial/empty keys and reject legitimate
  requests. Availability depends on this read; retries are the sender's responsibility.

  Uses the first signature header and conn.assigns.raw_body (default empty bytes), comparing
  against lowercase hex. Direct callers must supply the actual raw body. This helper does
  not itself require the route or perform body-size checking.
  """
  @spec verify_hmac(Conn.t()) :: :ok | {:error, :hmac_mismatch | :secret_missing}
  def verify_hmac(conn) do
    secret_path =
      Application.get_env(
        :lcars_fleet,
        :event_router_webhook_secret_path,
        "/etc/fleet/webhook-secret"
      )

    case File.read(secret_path) do
      {:ok, secret} ->
        case String.trim(secret) do
          "" ->
            Logger.error(
              "WebhooksGitea: HMAC secret EMPTY/whitespace (#{secret_path}) — " <>
                "fail-closed (refused: an empty-key HMAC is forgeable)"
            )

            {:error, :secret_missing}

          trimmed ->
            compare_signature(conn, trimmed)
        end

      {:error, _} ->
        {:error, :secret_missing}
    end
  end

  # Use secure_compare for signature comparison; missing headers become an empty mismatching value.
  defp compare_signature(conn, secret) do
    sig = conn |> get_req_header("x-gitea-signature") |> List.first() || ""
    expected = compute_hmac(secret, conn.assigns[:raw_body] || "")

    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, :hmac_mismatch}
  end

  @doc """
  Computes a lowercase SHA256 HMAC for `body`.
  """
  @spec compute_hmac(String.t(), iodata()) :: String.t()
  def compute_hmac(secret, body) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp gitea_event_header(conn) do
    conn |> get_req_header("x-gitea-event") |> List.first()
  end

  # Use repo-scoped number, never internal id, to match UI links and poller correlation.
  # Missing number yields nil; a present value is interpolated without numeric validation.
  defp extract_issue(%{"issue" => %{"number" => number}} = body), do: issue_ref(body, number)

  defp extract_issue(%{"pull_request" => %{"number" => number}} = body),
    do: issue_ref(body, number)

  defp extract_issue(_), do: nil

  # Unknown repository stays an explicit sentinel rather than impersonating a real repository.
  defp issue_ref(body, number) do
    # Match nested shape before reading full_name: extract_issue runs outside the route's rescue.
    repo =
      case body do
        %{"repository" => %{"full_name" => full_name}} when is_binary(full_name) -> full_name
        _ -> "unknown"
      end

    "#{repo}##{number}"
  end
end
