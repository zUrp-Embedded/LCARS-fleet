defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Webhooks Gitea HTTP endpoint (Plug.Router + Plug.Cowboy, port `:webhook_port`, default 8081).

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

  **Last revised**: 2026-08-03
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
        # Plug.Parsers guarantees `body` is a map, NOT that `action` is a string: a non-string action
        # (e.g. `{"action": 123}`) fed to `<>` would raise OUTSIDE the try below → Cowboy 500,
        # bypassing the 422-on-drift discipline. Non-string ≈ absent (unusable) → same header fallback.
        action = body["action"]
        action = if is_binary(action), do: action, else: nil
        event_type = "gitea." <> (action || gitea_event_header(conn) || "unknown")
        issue_id = extract_issue(body)

        # Strict canonical schema: %Fleet.Event{source: :event_router}.
        try do
          type_atom = String.to_existing_atom(event_type)

          payload = Map.put(body, "issue_id", issue_id)

          # `Bus.emit` can return an `{:error, _}` TUPLE (PubSub adapter down), NOT only raise. A dropped
          # event must NEVER be ACKed 200 (module invariant) → MATCH the return: `:ok` → 200, `{:error}` →
          # 422 so Gitea retries/alerts (same fail-loud stance as the rescue clauses below). `emit_fun` seam
          # (test): forces the `{:error}` path deterministically.
          emit_fun =
            Application.get_env(
              :fleet_event_router,
              :webhook_emit_fun,
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
          # A dropped event must NEVER be ACKed 200. The two cases below are
          # DRIFT (not an intentional drop — there is no "known but deliberately
          # not-routed" category in this handler): we return 422 so the Gitea forge
          # logs/retries/alerts instead of believing the event was delivered.
          ArgumentError ->
            # Atom unknown to the BEAM (String.to_existing_atom failed) = a `gitea.*` type
            # never declared → producer/registry drift, or a forged type.
            Logger.warning(
              "WebhooksGitea: unknown event type #{inspect(event_type)} " <>
                "— DRIFT (unknown atom), 422"
            )

            send_resp(conn, 422, Jason.encode!(%{error: "unknown event type", type: event_type}))

          # Do NOT swallow silently. A `gitea.*` type whose atom exists but which is not
          # in `events.yaml` = registry/producer drift → otherwise a silent drop (webhook
          # 200 but the event never routed). We make it VISIBLE (the registry must list every
          # action emitted by WebhooksGitea; see events.yaml, gitea section).
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

      {:error, reason} ->
        # `reason` is a structured atom (:hmac_mismatch | :secret_missing) — the human message
        # lives HERE (log + 401 wire body), not in the tuple. Jason encodes the atom as a string.
        Logger.warning("WebhooksGitea: webhook REFUSED 401 — HMAC verification: #{reason}")
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
        # The COMPLETE body: `read_body` accumulates internally up to `:length` (1 MB), so `{:ok}` always
        # carries the whole payload. This is the ONLY `:raw_body` `verify_hmac` ever reads — the HMAC is
        # computed over exactly these bytes.
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:more, partial, conn} ->
        # `{:more}` ⟺ body > `:length` ⟹ `Plug.Parsers` raises `RequestTooLargeError` BEFORE the dispatch,
        # so `verify_hmac` NEVER runs on this path (the 1 MB cap IS the read boundary). We deliberately do
        # NOT stash `partial` as `:raw_body`: a truncated body is never a valid HMAC input, and leaving it
        # unset keeps the HMAC path fail-CLOSED (nil → "" → mismatch → 401) even if this branch were ever
        # reached. This is why a large payload yields the 413 bound, not a truncated-HMAC 401.
        {:more, partial, conn}

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
              "WebhooksGitea: HMAC secret EMPTY/whitespace (#{secret_path}) — " <>
                "fail-closed (refused: an empty-key HMAC is forgeable)"
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

  # Extract the issue from issues AND pull requests, keyed on the REPO-SCOPED `number`.
  #
  # It used to key on the internal `id`, and the comment below said so while naming the divergence
  # as latent: "if a webhook->pod correlation is ever wired, key it on `number`". A divergence that
  # waits for its first consumer is a trap set for whoever wires it -- they inherit a ref that looks
  # like an issue reference (`fleet/lcars#4711`) and is not one. Closed BEFORE that consumer exists,
  # which is the only moment it costs nothing (BL-6-43.3).
  #
  # The display consumers gain from it too: the deck now shows the number a human can click, where
  # the internal id matched nothing they could look up.
  #
  # No `id` fallback ON PURPOSE. A fallback would restore exactly the ambiguity being removed --
  # sometimes a number, sometimes an id, with no way to tell which -- and silently. A Gitea webhook
  # always carries `number`; a body without it is degenerate and takes the `nil` clause already
  # there, the same fail-closed treatment as a body with no issue at all.
  defp extract_issue(%{"issue" => %{"number" => number}} = body), do: issue_ref(body, number)

  defp extract_issue(%{"pull_request" => %{"number" => number}} = body),
    do: issue_ref(body, number)

  defp extract_issue(_), do: nil

  # `<repository.full_name>#<id>` — the repo comes from the webhook PAYLOAD, not hardcoded (multi-repo
  # correct). A real Gitea webhook ALWAYS carries `repository.full_name`; a body without it is
  # DEGENERATE/malformed. We fall back to an explicit sentinel `"unknown"`, NOT a fabricated real repo name
  # (`"fleet/lcars"` would IMPERSONATE an actual repo in the display event) — honest: we don't know the repo.
  # The ref is the repo-scoped `number` — the SAME key the Poller ingests on, so a webhook→pod
  # correlation can be wired later without a translation step that nobody would remember to add.
  defp issue_ref(body, number) do
    # Pattern-match the body STRUCTURE, not `get_in` then a guard: `Plug.Parsers` guarantees `body`
    # is a map, NOT that `repository` is one. On `{"repository": "x"}` (a forged/malformed body),
    # `get_in("x", ["full_name"])` raises `FunctionClauseError` in `Access` — and the `|| "unknown"`
    # only catches `repository` ABSENT, not non-map. That raise fires in `extract_issue/1` at the
    # call site ABOVE the `try` → Cowboy 500, OUTSIDE the 422-on-drift discipline this module holds.
    # The twin of the `action` is_binary guard above — both untrusted-shape gates.
    repo =
      case body do
        %{"repository" => %{"full_name" => full_name}} when is_binary(full_name) -> full_name
        _ -> "unknown"
      end

    "#{repo}##{number}"
  end
end
