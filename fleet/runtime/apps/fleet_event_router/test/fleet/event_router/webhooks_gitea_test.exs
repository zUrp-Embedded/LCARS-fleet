defmodule Fleet.EventRouter.WebhooksGiteaTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @moduletag :tmp_dir

  alias Fleet.EventRouter.{Bus, WebhooksGitea}

  setup %{tmp_dir: tmp_dir} do
    secret_path = Path.join(tmp_dir, "webhook-secret")
    File.write!(secret_path, "supersecret\n")
    Application.put_env(:fleet_event_router, :webhook_secret_path, secret_path)

    :ok = Bus.subscribe()

    on_exit(fn ->
      Bus.unsubscribe()
      Application.delete_env(:fleet_event_router, :webhook_secret_path)
    end)

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

      assert_receive {:"gitea.opened", event}, 500
      assert event["event_type"] == "gitea.opened"
      assert event["ticket_id"] == "fleet/lcars#42"
      assert event["payload"]["action"] == "opened"
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
