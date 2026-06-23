defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Webhooks Gitea HTTP endpoint (Plug.Router + Plug.Cowboy port `:8081`).

  Vérification HMAC SHA256 obligatoire avec secret
  `/etc/fleet/webhook-secret` (root:lcars 600 ro pas mount bwrap
  pod-side, système-side seul).

  ## Routes

    * `POST /webhook/gitea` — body JSON Gitea, header
      `X-Gitea-Signature` HMAC SHA256. 200 ok (broadcast réussi) /
      401 hmac mismatch / 422 event drift (type inconnu/forgé ou hors
      registry `events.yaml` — la forge doit retry/alerter, F-009) /
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
        # M20 : ne pas défaulter aveuglément sur "push". Préférer l'action (routing
        # events.yaml gitea.opened/closed), sinon l'event authoritatif (header X-Gitea-Event),
        # sinon "unknown" — un event actionless non-push n'est plus mislabelé "push".
        event_type = "gitea." <> (body["action"] || gitea_event_header(conn) || "unknown")
        ticket_id = extract_ticket(body)

        # BL-021 chantier 9 (B) — schema canon strict %Fleet.Event{source: :event_router}.
        try do
          type_atom = String.to_existing_atom(event_type)

          payload = Map.put(body, "ticket_id", ticket_id)

          event = %Fleet.Event{
            source: :event_router,
            type: type_atom,
            timestamp: DateTime.utc_now(),
            pod_id: nil,
            correlation_id: nil,
            payload: payload
          }

          _ = Fleet.EventRouter.Bus.broadcast("fleet.events", event)
          send_resp(conn, 200, "ok")
        rescue
          # F-009 : un event droppé ne doit PLUS être ACK 200. Les deux cas ci-dessous
          # sont du DRIFT (pas un drop intentionnel — il n'existe aucune catégorie
          # « connu mais volontairement non-routé » dans ce handler) : on renvoie 422
          # pour que la forge Gitea journalise/retry/alerte au lieu de croire l'event livré.
          ArgumentError ->
            # Atome inconnu du BEAM (String.to_existing_atom a échoué) = type `gitea.*`
            # jamais déclaré → drift producteur/registry forgé.
            Logger.warning(
              "fleet_event_router webhook gitea unknown event type #{inspect(event_type)} " <>
                "— DRIFT (atome inconnu), 422"
            )

            send_resp(conn, 422, Jason.encode!(%{error: "unknown event type", type: event_type}))

          # Z5 #9 : NE PLUS avaler en silence. Un type `gitea.*` dont l'atome existe mais
          # qui n'est pas dans `events.yaml` = drift registry/producteur → drop muet (webhook
          # 200 mais event jamais routé). On le rend VISIBLE (le registry doit lister toute
          # action émise par WebhooksGitea ; cf. events.yaml section gitea).
          _e in Fleet.Event.UnregisteredError ->
            Logger.warning(
              "fleet_event_router webhook gitea type #{inspect(event_type)} hors registry " <>
                "events.yaml — DROP/DRIFT, 422 (ajouter la clé si l'action doit être routée)"
            )

            send_resp(
              conn,
              422,
              Jason.encode!(%{error: "event type not in registry", type: event_type})
            )
        end

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
        # MA-13 — un fichier secret EXISTANT mais VIDE/whitespace passait par ce chemin `{:ok, secret}` →
        # `compute_hmac("", body)` → HMAC à CLÉ VIDE → quiconque connaît l'algo forge une signature valide
        # (fail-OPEN : la vérif HMAC est neutralisée sans le savoir). Un secret trimmé vide est REJETÉ
        # fail-closed comme un secret absent (jamais d'HMAC à clé vide). (Gated par opt-in
        # `LCARS_FLEET_WEBHOOKS`, mais on ferme le fail-open : un webhooks activé sur un secret vide est un
        # trou, pas une config valide.)
        case String.trim(secret) do
          "" ->
            Logger.error(
              "fleet_event_router webhook : secret HMAC VIDE/whitespace (#{secret_path}) — " <>
                "fail-closed (refus : un HMAC à clé vide est forgeable)"
            )

            {:error, "secret missing"}

          trimmed ->
            sig = conn |> get_req_header("x-gitea-signature") |> List.first() || ""
            body = conn.assigns[:raw_body] || ""
            expected = compute_hmac(trimmed, body)

            if Plug.Crypto.secure_compare(sig, expected),
              do: :ok,
              else: {:error, "hmac mismatch"}
        end

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

  defp gitea_event_header(conn) do
    conn |> get_req_header("x-gitea-event") |> List.first()
  end

  # M21 : extraire le ticket des issues ET des pull requests (pas seulement issue.id).
  defp extract_ticket(%{"issue" => %{"id" => id}}), do: "fleet/lcars##{id}"
  defp extract_ticket(%{"pull_request" => %{"id" => id}}), do: "fleet/lcars##{id}"
  defp extract_ticket(_), do: nil
end
