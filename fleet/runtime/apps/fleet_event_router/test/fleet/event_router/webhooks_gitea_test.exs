defmodule Fleet.EventRouter.WebhooksGiteaTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @moduletag :tmp_dir

  alias Fleet.EventRouter.{Bus, WebhooksGitea}

  setup %{tmp_dir: tmp_dir} do
    secret_path = Path.join(tmp_dir, "webhook-secret")
    File.write!(secret_path, "supersecret\n")

    Fleet.EventRouter.TestEnv.put_env_restoring(
      :fleet_event_router,
      :webhook_secret_path,
      secret_path
    )

    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)

    %{secret: "supersecret"}
  end

  defp post_with_sig(body_map, secret) do
    body = Jason.encode!(body_map)
    sig = WebhooksGitea.compute_hmac(secret, body)

    conn(:post, "/webhook/gitea", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-gitea-signature", sig)
  end

  describe "POST /webhook/gitea" do
    test "HMAC valide → 200 + broadcast event gitea.<action>", %{secret: secret} do
      body = %{"action" => "opened", "issue" => %{"id" => 42}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert conn.resp_body == "ok"

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"action" => "opened", "issue_id" => "fleet/lcars#42"}
                     },
                     500
    end

    test "M20 : sans action, event_type via header X-Gitea-Event (pas défaut 'push')", %{
      secret: secret
    } do
      body = %{"ref" => "refs/heads/main"}

      conn =
        post_with_sig(body, secret)
        |> put_req_header("x-gitea-event", "push")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.push"}, 500
    end

    test "M20 : sans action ni header → gitea.unknown (pas mislabel 'push')", %{secret: secret} do
      body = %{"ref" => "refs/heads/main"}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200
      assert_receive %Fleet.Event{source: :event_router, type: :"gitea.unknown"}, 500
    end

    test "M21 : issue extrait d'une pull request (pas seulement issue)", %{secret: secret} do
      body = %{"action" => "opened", "pull_request" => %{"id" => 99}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 200

      assert_receive %Fleet.Event{
                       source: :event_router,
                       type: :"gitea.opened",
                       payload: %{"issue_id" => "fleet/lcars#99"}
                     },
                     500
    end

    test "F-009 : event type drift (atome `gitea.*` inconnu) → 422, plus d'ACK 200 silencieux", %{
      secret: secret
    } do
      # action jamais déclarée → `String.to_existing_atom("gitea.<action>")` lève ArgumentError →
      # avant F-009 le handler renvoyait 200 « ok » (la forge croyait l'event livré, drop muet).
      body = %{"action" => "zzz_drift_action_inexistante_42", "issue" => %{"id" => 7}}
      conn = post_with_sig(body, secret) |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "unknown event type"
      # pas de broadcast d'un event drift
      refute_receive %Fleet.Event{source: :event_router}, 200
    end

    test "HMAC manquante → 401", %{secret: _secret} do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "HMAC fausse → 401" do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "deadbeef")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
    end

    test "secret manquant → 401" do
      Application.put_env(:fleet_event_router, :webhook_secret_path, "/nonexistent")

      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", "any")
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "secret missing"
    end

    test "MA-13 : secret fichier VIDE/whitespace → 401 fail-closed (PAS d'HMAC à clé vide forgeable)",
         %{tmp_dir: tmp_dir} do
      # Fichier secret EXISTANT mais vide (whitespace) → AVANT MA-13 : compute_hmac("", body) → un attaquant
      # forge une signature valide sans connaître AUCUN secret (fail-open). On vérifie que la signature
      # CALCULÉE-SUR-CLÉ-VIDE (ce que ferait l'attaquant) est REFUSÉE.
      empty_secret = Path.join(tmp_dir, "empty-secret")
      File.write!(empty_secret, "   \n  \t\n")
      Application.put_env(:fleet_event_router, :webhook_secret_path, empty_secret)

      body = Jason.encode!(%{"action" => "opened"})
      forged_sig = WebhooksGitea.compute_hmac("", body)

      conn =
        conn(:post, "/webhook/gitea", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-gitea-signature", forged_sig)
        |> WebhooksGitea.call(WebhooksGitea.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "secret missing"
      refute_receive %Fleet.Event{source: :event_router}, 200
    end
  end

  describe "GET /health" do
    test "200 ok" do
      conn = conn(:get, "/health") |> WebhooksGitea.call(WebhooksGitea.init([]))
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "fallback 404" do
    test "GET /unknown → 404" do
      conn = conn(:get, "/unknown") |> WebhooksGitea.call(WebhooksGitea.init([]))
      assert conn.status == 404
    end
  end

  describe "compute_hmac/2" do
    test "déterministe + 64-hex chars" do
      h1 = WebhooksGitea.compute_hmac("secret", "body")
      h2 = WebhooksGitea.compute_hmac("secret", "body")
      assert h1 == h2
      assert byte_size(h1) == 64
    end
  end
end
