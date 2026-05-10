defmodule Fleet.Api.RestTest do
  # async: false — Application.put_env sur :api_secret_path mute l'état
  # global runtime ; séquentialiser évite la pollution cross-test.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @moduletag :tmp_dir

  alias Fleet.Api.Rest
  alias Fleet.EventRouter.Bus

  @opts Rest.init([])

  setup %{tmp_dir: tmp_dir} do
    secret_path = Path.join(tmp_dir, "api-secret")
    File.write!(secret_path, "test-secret-1234")
    Application.put_env(:fleet_api, :api_secret_path, secret_path)

    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:fleet_api, :api_secret_path)
    end)

    {:ok, secret: "test-secret-1234"}
  end

  defp valid_token(secret) do
    :crypto.mac(:hmac, :sha256, secret, "fleet-api-v1") |> Base.encode16(case: :lower)
  end

  describe "GET /api/health (no auth)" do
    test "returns 200 + status ok" do
      conn = conn(:get, "/api/health") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "auth HMAC" do
    test "missing token → 401", %{secret: _secret} do
      conn = conn(:get, "/api/pipelines") |> Rest.call(@opts)
      assert conn.status == 401
    end

    test "wrong token → 401" do
      conn =
        conn(:get, "/api/pipelines")
        |> put_req_header("x-auth-token", "wrong")
        |> Rest.call(@opts)

      assert conn.status == 401
    end

    test "valid token → 200", %{secret: secret} do
      conn =
        conn(:get, "/api/pipelines")
        |> put_req_header("x-auth-token", valid_token(secret))
        |> Rest.call(@opts)

      assert conn.status == 200
    end
  end

  describe "GET endpoints (lecture état)" do
    setup %{secret: secret} do
      {:ok, token: valid_token(secret)}
    end

    test "GET /api/pipelines → 200 JSON", %{token: token} do
      conn =
        conn(:get, "/api/pipelines")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 200
      assert {:ok, %{"pipelines" => _}} = Jason.decode(conn.resp_body)
    end

    test "GET /api/tickets → 200 JSON", %{token: token} do
      conn =
        conn(:get, "/api/tickets")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 200
    end

    test "GET /api/pods → 200 JSON", %{token: token} do
      conn =
        conn(:get, "/api/pods")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 200
    end
  end

  describe "POST /api/admin/spawn" do
    setup %{secret: secret} do
      {:ok, token: valid_token(secret)}
    end

    test "broadcast admin.spawn.request + 202", %{token: token} do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "scout"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 202

      assert_receive {_atom,
                      %{
                        "event_type" => "admin.spawn.request",
                        "payload" => %{"role" => "scout"}
                      }},
                     500
    end
  end

  describe "POST /api/relay/:ref" do
    setup %{secret: secret} do
      # RelayHandler démarré par Fleet.Api.Application supervisor.
      {:ok, token: valid_token(secret)}
    end

    test "ref inconnu → 404", %{token: token} do
      conn =
        conn(:post, "/api/relay/unknown-ref", Jason.encode!(%{decision: "allow"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 404
    end
  end

  describe "match _ (404)" do
    setup %{secret: secret} do
      {:ok, token: valid_token(secret)}
    end

    test "route inexistante → 404", %{token: token} do
      conn =
        conn(:get, "/api/nonexistent")
        |> put_req_header("x-auth-token", token)
        |> Rest.call(@opts)

      assert conn.status == 404
    end
  end
end
