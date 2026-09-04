defmodule Fleet.EventRouter.WebhooksGitea do
  @moduledoc """
  Webhooks Gitea HTTP endpoint (Plug.Router + Plug.Cowboy, port `:event_router_webhook_port`,
  default 8081; off unless `:event_router_start_webhooks`).

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

    * `:lcars_fleet, :event_router_webhook_secret_path` — secret path
      (default `/etc/fleet/webhook-secret`)
    * `:lcars_fleet, :event_router_webhook_port` — HTTP port (default 8081)
  """

  use Plug.Router

  alias Plug.Conn

  require Logger

  # ONE bound, ONE source. The read below and `Plug.Parsers` must agree on the cap or the two would
  # disagree about what "too large" means — and the one that reads FIRST is the one that decides.
  @max_body 1_048_576

  plug(:match)

  # AUTHENTICATE BEFORE PARSING, and that means READING the body here rather than merely moving the
  # check up. The HMAC covers the RAW body: capture that raw body in `Plug.Parsers` (its
  # `body_reader:`) and `verify_hmac/1` cannot run any earlier than the handler without `raw_body`
  # being nil — which makes `secure_compare` false on EVERY request, legitimate ones included. The
  # parser must consume what this plug already holds.
  #
  # What it buys: a request with a bad signature is refused after a bounded read and BEFORE any JSON
  # deserialization. Otherwise an anonymous caller obtains up to 1 MiB of read AND a full
  # `Jason.decode!` per request with no identity check anywhere on that path — CPU and memory per
  # connection, and the parser's own surface exposed to unauthenticated input.
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
    # PLUS DE SECONDE VERIFICATION ICI, et pas de clause defensive non plus. `:authenticate_webhook`
    # est le seul chemin vers cette route et il a deja calcule le HMAC sur le corps brut ; le
    # recalculer serait payer deux fois, et une branche 401 inatteignable serait du code mort.
    #
    # Ce qui remplace la branche : un MATCH. Si le plug etait retire ou deplace apres `Plug.Parsers`,
    # `conn.assigns` ne porterait pas la marque et cette ligne leve un MatchError — 500 bruyant au
    # premier appel, jamais un 200 sur un corps non authentifie. L'ordre des plugs cesse d'etre une
    # convention.
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
    # SERVES WHAT `authenticate_webhook/2` ALREADY READ. A body can only be read once: on the
    # webhook route the authenticating plug has consumed it, so a second `read_body` here would
    # yield `""` and the parser would decode an empty body on every authenticated request. The
    # fallback below is not dead — it is the path of every OTHER route (health, the 404 catch-all),
    # which is never authenticated and whose body nobody has touched.
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

  # Only the webhook route: `/health` carries no body and no signature, and the 404 fallback must
  # stay a 404 rather than become a 401 about a route that does not exist.
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

      # OVER THE CAP: refused with the SAME exception `Plug.Parsers` raises for this case, and for the
      # same reason — an explicit bound beats a 401 computed on a truncated body, which would blame
      # the signature for a size problem. The check never runs on a partial read.
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

  THE SECRET IS READ FROM DISK ON EVERY REQUEST, AND THAT IS THE CHOICE — not an oversight. The file
  is provisioned and ROTATED by the operator outside the BEAM (`/etc/fleet/webhook-secret`, root
  owned, mode 600), and a rotation must take effect on the next webhook rather than at the next
  fleet restart. Caching it would make the running node the authority on a secret whose authority is
  the filesystem, and the operator would have no way to tell whether the value in memory is the one
  they just wrote.

  WHAT IT COSTS, NAMED so nobody has to rediscover it: one `File.read/1` per request on the
  authentication path, and a hard dependency of the endpoint's availability on the file's. A secret
  momentarily unreadable — a mount, a permission, a non-atomic rotation (write-in-place rather than
  write-then-rename) — yields 401 on LEGITIMATE webhooks, which the forge will replay. The mitigation
  is on the writer's side, not here: rotate by `rename(2)`, which is atomic, and the reader either
  sees the old file whole or the new one whole.

  The bound that makes the cost acceptable: this endpoint is OFF by default
  (`event_router_start_webhooks`), the forge is local, and the webhook is an ACCELERATOR of the poll
  rail — never a source of truth. A read per request on a path that is not the durable one is a
  trade this fleet can make; the same read on the poll rail would not be.
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
  Computes a lowercase SHA256 HMAC for `body`.
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
  # NOT the internal `id`, and the difference is invisible at the output: a ref built from the id
  # reads exactly like an issue reference (`fleet/lcars#4711`) and is not one. Whoever wires a
  # webhook->pod correlation inherits that ref, and the deck shows a number a human can click
  # rather than an id that matches nothing they can look up.
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
