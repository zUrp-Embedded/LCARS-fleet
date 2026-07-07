defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Webhooks Gitea HTTP endpoint (Plug.Router + Plug.Cowboy port `:8081`).

  Mandatory HMAC SHA256 verification with the secret
  `/etc/fleet/webhook-secret` (root:lcars 600 ro, not mounted into
  bwrap pod-side, system-side only).

  ## Routes

    * `POST /webhook/gitea` — Gitea JSON body, header
      `X-Gitea-Signature` HMAC SHA256. 200 ok (broadcast succeeded) /
      401 hmac mismatch / 422 event drift (unknown/forged type or outside
      the `events.yaml` registry — the forge must retry/alert) /
      415 invalid body / 500 error.
    * `GET /health` — liveness `200 ok`.
    * fallback 404.

  ## Configuration

    * `:fleet_event_router, :webhook_secret_path` — secret path
      (default `/etc/fleet/webhook-secret`)
    * `:fleet_event_router, :webhook_port` — HTTP port (default 8081)
  """

  use Plug.Router

  require Logger

  plug(:match)

  # `length`: EXPLICIT bound (Plug's implicit default is 8MB). 1 MB >> the largest legitimate Gitea
  # webhook (push/issue events). NB: the HMAC is verified AFTER the parse — the bound limits what an
  # unauthenticated caller can make us decode (listener opt-in, loopback by default).
  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    length: 1_048_576,
    body_reader: {__MODULE__, :read_raw_body, []}
  )

  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/webhook/gitea" do
    case verify_hmac(conn) do
      :ok ->
        # body_params guaranteed to be a map by `Plug.Parsers` upstream (malformed JSON → 415 before reaching here).
        # No `|| %{}`: that net is dead (body_params never nil) AND would not handle the
        # `%Plug.Conn.Unfetched{}` case either (≠ nil) — the real input guard is Plug.Parsers, not a default here.
        body = conn.body_params
        # Do NOT blindly default to "push": prefer the action (routed by
        # events.yaml, e.g. gitea.opened/closed), otherwise the authoritative event (header X-Gitea-Event),
        # otherwise "unknown" — an event with no action and non-push must not be mislabeled "push".
        event_type = "gitea." <> (body["action"] || gitea_event_header(conn) || "unknown")
        issue_id = extract_issue(body)

        # Strict canonical schema: %Fleet.Event{source: :event_router}.
        try do
          type_atom = String.to_existing_atom(event_type)

          payload = Map.put(body, "issue_id", issue_id)

          _ = Fleet.EventRouter.Bus.emit(:event_router, type_atom, payload: payload)
          send_resp(conn, 200, "ok")
        rescue
          # A dropped event must NEVER be ACKed 200. The two cases below are
          # DRIFT (not an intentional drop — there is no "known but deliberately
          # not-routed" category in this handler): we return 422 so the Gitea forge
          # logs/retries/alerts instead of believing the event was delivered.
          ArgumentError ->
            # Atom unknown to the BEAM (String.to_existing_atom failed) = a `gitea.*` type
            # never declared → producer/registry drift, or a forged type.
            Logger.warning(
              "WebhooksGitea: unknown event type #{inspect(event_type)} " <>
                "— DRIFT (atome inconnu), 422"
            )

            send_resp(conn, 422, Jason.encode!(%{error: "unknown event type", type: event_type}))

          # Do NOT swallow silently. A `gitea.*` type whose atom exists but which is not
          # in `events.yaml` = registry/producer drift → otherwise a silent drop (webhook
          # 200 but the event never routed). We make it VISIBLE (the registry must list every
          # action emitted by WebhooksGitea; see events.yaml, gitea section).
          _e in Fleet.Event.UnregisteredError ->
            Logger.warning(
              "WebhooksGitea: type #{inspect(event_type)} hors registry " <>
                "events.yaml — DROP/DRIFT, 422 (ajouter la clé si l'action doit être routée)"
            )

            send_resp(
              conn,
              422,
              Jason.encode!(%{error: "event type not in registry", type: event_type})
            )
        end

      {:error, reason} ->
        # `reason` est un atome structuré (:hmac_mismatch | :secret_missing) — le message humain
        # vit ICI (log + body 401 wire), pas dans le tuple. Jason encode l'atome en string.
        Logger.warning("WebhooksGitea: webhook REFUSÉ 401 — vérification HMAC : #{reason}")
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
  Verifies the SHA256 HMAC of `raw_body` against the `x-gitea-signature` header.

  Returns `:ok` or `{:error, :hmac_mismatch | :secret_missing}` — STRUCTURED atoms
  that are pattern-matchable (the old strings `"hmac mismatch"`/`"secret missing"` were
  not); the human rendering lives in the logs and the handler's 401 body.
  """
  @spec verify_hmac(Plug.Conn.t()) :: :ok | {:error, :hmac_mismatch | :secret_missing}
  def verify_hmac(conn) do
    secret_path =
      Application.get_env(:fleet_event_router, :webhook_secret_path, "/etc/fleet/webhook-secret")

    case File.read(secret_path) do
      {:ok, secret} ->
        # An EXISTING but EMPTY/whitespace secret file would go through this `{:ok, secret}` path →
        # `compute_hmac("", body)` → EMPTY-KEY HMAC → anyone who knows the algo forges a valid signature
        # (fail-OPEN: the HMAC check would be neutralized without us knowing). An empty-after-trim secret is
        # therefore REJECTED fail-closed like an absent secret (never an empty-key HMAC). (The webhooks
        # listener is gated by the opt-in `LCARS_FLEET_WEBHOOKS`, but we close the fail-open anyway: a
        # webhooks enabled on an empty secret is a hole, not a valid config.)
        case String.trim(secret) do
          "" ->
            Logger.error(
              "WebhooksGitea: secret HMAC VIDE/whitespace (#{secret_path}) — " <>
                "fail-closed (refus : un HMAC à clé vide est forgeable)"
            )

            {:error, :secret_missing}

          trimmed ->
            sig = conn |> get_req_header("x-gitea-signature") |> List.first() || ""
            body = conn.assigns[:raw_body] || ""
            expected = compute_hmac(trimmed, body)

            if Plug.Crypto.secure_compare(sig, expected),
              do: :ok,
              else: {:error, :hmac_mismatch}
        end

      {:error, _} ->
        {:error, :secret_missing}
    end
  end

  @doc """
  Computes the SHA256 HMAC of a body with a secret. Utility exposed
  for tests (generating the expected signature).
  """
  @spec compute_hmac(String.t(), iodata()) :: String.t()
  def compute_hmac(secret, body) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp gitea_event_header(conn) do
    conn |> get_req_header("x-gitea-event") |> List.first()
  end

  # Extract the issue from issues AND pull requests (not only issue.id).
  defp extract_issue(%{"issue" => %{"id" => id}}), do: "fleet/lcars##{id}"
  defp extract_issue(%{"pull_request" => %{"id" => id}}), do: "fleet/lcars##{id}"
  defp extract_issue(_), do: nil
end
