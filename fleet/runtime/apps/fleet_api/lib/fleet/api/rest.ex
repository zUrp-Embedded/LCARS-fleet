defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP `:8080` endpoints REST + auth HMAC token header.

  ## Routes MVP

    * `GET /api/health` — readiness probe
    * `GET /api/pipelines` / `tickets` / `pods` — lecture état (stubs MVP)
    * `POST /api/admin/spawn` — broadcast `admin.spawn.request` event
    * `POST /api/config/update` — atomic write + git commit auto via
      `GitCommitter` (canon trace strate 1)
    * `POST /api/relay/:ref` — `RelayHandler.respond` round-trip ch10

  ## Auth

  Header `X-Auth-Token` validé HMAC SHA256 contre secret
  `:fleet_api, :api_secret_path` (default `/etc/fleet/api-secret`
  root:lcars 600). Constant-time compare via `Plug.Crypto.secure_compare`.

  ## Health endpoint

  `GET /api/health` retourne 200 + `%{status: "ok", ts: ...}` sans
  auth (consommé par chantier 16 lcars-readiness script,
  architecture-cible §L737).
  """

  use Plug.Router

  alias Fleet.API.{GitCommitter, RelayHandler}
  alias Fleet.EventRouter.Bus

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:require_auth)
  plug(:dispatch)

  # Public health probe — no auth (skipped via require_auth special-case)
  get "/api/health" do
    send_json(conn, %{status: "ok", ts: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  get "/api/pipelines" do
    send_json(conn, %{pipelines: []})
  end

  get "/api/tickets" do
    send_json(conn, %{tickets: []})
  end

  get "/api/pods" do
    send_json(conn, %{pods: []})
  end

  post "/api/admin/spawn" do
    # BL-021 chantier 9 (B) — migrated to schema canon %Fleet.Event{source: :api}.
    event = %Fleet.Event{
      source: :api,
      type: :"admin.spawn.request",
      timestamp: DateTime.utc_now(),
      pod_id: nil,
      correlation_id: nil,
      payload: conn.body_params || %{}
    }

    case safe_broadcast(event) do
      :ok -> send_resp(conn, 202, ~s|{"status":"queued"}|)
      {:error, reason} -> send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp safe_broadcast(%Fleet.Event{} = event) do
    Bus.broadcast("fleet.events", event)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  post "/api/config/update" do
    case conn.body_params do
      %{"file_path" => path, "content" => content} ->
        user_id = conn.assigns[:user_id] || "api-user"

        case GitCommitter.commit_config_change(path, content, user_id) do
          {:ok, sha} ->
            send_json(conn, %{commit_sha: sha})

          {:error, reason} ->
            send_resp(conn, 500, Jason.encode!(%{error: reason}))
        end

      _ ->
        send_resp(conn, 400, ~s|{"error":"missing file_path or content"}|)
    end
  end

  post "/api/relay/:ref" do
    decision = conn.body_params["decision"] || ""

    case RelayHandler.respond(ref, decision) do
      :ok -> send_resp(conn, 200, ~s|{"status":"ok"}|)
      {:error, reason} -> send_resp(conn, 404, Jason.encode!(%{error: reason}))
    end
  end

  # #594 D2 — dashboard V2 Elixir natif. Mount Fleet.API.Dashboard sous
  # /dashboard. Pas d'auth HTTP (ADR-C accès intra-release, GET-only UI,
  # whitelisté dans require_auth/2 ligne ~97).
  forward("/dashboard", to: Fleet.API.Dashboard)

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  # ============================================================
  # Auth plug
  # ============================================================

  @doc false
  def require_auth(%Plug.Conn{request_path: "/api/health"} = conn, _opts), do: conn

  # #594 D2 — dashboard V2 UI : pas d'auth HTTP (intra-release, GET-only,
  # ADR-C 5-zéros). Whitelist /dashboard et /dashboard/static/*.
  def require_auth(%Plug.Conn{request_path: "/dashboard" <> _, method: "GET"} = conn, _opts),
    do: conn

  def require_auth(conn, _opts) do
    sig = get_req_header(conn, "x-auth-token") |> List.first() || ""

    case load_secret() do
      {:ok, secret} ->
        expected =
          :crypto.mac(:hmac, :sha256, secret, "fleet-api-v1")
          |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(sig, expected) do
          assign(conn, :user_id, "api-user")
        else
          conn
          |> send_resp(401, ~s|{"error":"unauthorized"}|)
          |> halt()
        end

      {:error, _reason} ->
        conn
        |> send_resp(401, ~s|{"error":"auth secret unavailable"}|)
        |> halt()
    end
  end

  defp load_secret do
    path = Application.get_env(:fleet_api, :api_secret_path, "/etc/fleet/api-secret")

    case File.read(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_json(conn, payload) do
    send_resp(conn, 200, Jason.encode!(payload))
  end
end
