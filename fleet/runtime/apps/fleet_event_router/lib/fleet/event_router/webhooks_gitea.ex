defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Webhooks Gitea HTTP endpoint (Plug.Router + Plug.Cowboy port `:8081`).

  Vérification HMAC SHA256 obligatoire avec secret
  `/etc/fleet/webhook-secret` (root:lcars 600 ro pas mount bwrap
  pod-side, système-side seul).

  ## Routes

    * `POST /webhook/gitea` — body JSON Gitea, header
      `X-Gitea-Signature` HMAC SHA256. 200 ok / 401 hmac mismatch /
      415 invalid body / 500 error.
    * `GET /health` — liveness `200 ok`.
    * fallback 404.

  ## Configuration

    * `:fleet_event_router, :webhook_secret_path` — path secret
      (default `/etc/fleet/webhook-secret`)
    * `:fleet_event_router, :webhook_port` — port HTTP (default 8081)
  """

  use Plug.Router

  require Logger

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    body_reader: {__MODULE__, :read_raw_body, []}
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/webhook/gitea" do
    case verify_hmac(conn) do
      :ok ->
        body = conn.body_params || %{}
        event_type = "gitea." <> (body["action"] || "push")
        ticket_id = extract_ticket(body)

        Fleet.EventRouter.Bus.broadcast(event_type, body, ticket_id: ticket_id)

        send_resp(conn, 200, "ok")

      {:error, reason} ->
        Logger.warning("fleet_event_router webhook hmac mismatch: #{reason}")
        send_resp(conn, 401, Jason.encode!(%{error: reason}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc false
  def read_raw_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:more, partial, conn} ->
        {:more, partial, Plug.Conn.assign(conn, :raw_body, partial)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Vérifie le HMAC SHA256 du `raw_body` contre l'header `x-gitea-signature`.

  Returns `:ok` ou `{:error, "hmac mismatch" | "secret missing"}`.
  """
  @spec verify_hmac(Plug.Conn.t()) :: :ok | {:error, String.t()}
  def verify_hmac(conn) do
    secret_path =
      Application.get_env(:fleet_event_router, :webhook_secret_path, "/etc/fleet/webhook-secret")

    case File.read(secret_path) do
      {:ok, secret} ->
        sig = conn |> get_req_header("x-gitea-signature") |> List.first() || ""
        body = conn.assigns[:raw_body] || ""
        expected = compute_hmac(String.trim(secret), body)

        if Plug.Crypto.secure_compare(sig, expected),
          do: :ok,
          else: {:error, "hmac mismatch"}

      {:error, _} ->
        {:error, "secret missing"}
    end
  end

  @doc """
  Calcule le HMAC SHA256 d'un body avec un secret. Utilitaire exposé
  pour les tests (génération signature attendue).
  """
  @spec compute_hmac(String.t(), iodata()) :: String.t()
  def compute_hmac(secret, body) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp extract_ticket(%{"issue" => %{"id" => id}}), do: "fleet/lcars##{id}"
  defp extract_ticket(_), do: nil
end
