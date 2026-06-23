defmodule Fleet.API.RestTest do
  # async: false — pas d'auth (frontière = isolation réseau/container, cf. rest.ex § Auth), mais le bus
  # PubSub est global (le test admin.spawn broadcast + assert_receive) → séquentialiser évite le cross-talk.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Fleet.API.Rest
  alias Fleet.EventRouter.Bus

  @opts Rest.init([])

  setup do
    Bus.subscribe()
    :ok
  end

  describe "GET /api/health" do
    test "returns 200 + status ok" do
      conn = conn(:get, "/api/health") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /api/readiness/deep (P05)" do
    test "→ 200 + état opérationnel structuré" do
      conn = conn(:get, "/api/readiness/deep") |> Rest.call(@opts)

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] in ["operational", "degraded"]
      assert is_list(body["subsystems"])
      assert is_list(body["degraded"])
    end
  end

  describe "POST /api/admin/spawn — quiescence (drain shutdown)" do
    test "503 quand le daemon quiesce (refuse nouveau pod top-level)" do
      Fleet.Shutdown.Quiesce.refuse!()
      on_exit(&Fleet.Shutdown.Quiesce.resume!/0)

      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "x"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 503
    end
  end

  describe "GET endpoints (lecture état)" do
    test "GET /api/pipelines → 200 JSON" do
      conn = conn(:get, "/api/pipelines") |> Rest.call(@opts)
      assert conn.status == 200
      assert {:ok, %{"pipelines" => _}} = Jason.decode(conn.resp_body)
    end

    test "GET /api/tickets → 200 JSON" do
      conn = conn(:get, "/api/tickets") |> Rest.call(@opts)
      assert conn.status == 200
    end

    test "GET /api/pods → 200 JSON" do
      conn = conn(:get, "/api/pods") |> Rest.call(@opts)
      assert conn.status == 200
    end
  end

  describe "POST /api/admin/spawn" do
    # MA-18 : le cap-profile est validé AVANT l'ACK → un cap-profile RÉEL (canon `engineer`) doit
    # passer (202 + broadcast). Avant, n'importe quel slug rendait 202 (même inexistant).
    test "cap-profile réel → broadcast admin.spawn.request + 202" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 202

      assert_receive %Fleet.Event{
                       source: :api,
                       type: :"admin.spawn.request",
                       payload: %{"role" => "engineer"}
                     },
                     500
    end

    # MA-18 — LE finding : un slug bien formé mais SANS cap-profile (ex. `lcars spawn scout`) ne doit
    # PLUS rendre 202 (qui mentait : le PublishConsumer logguait juste un warning, zéro pod). 422 +
    # AUCUN broadcast (l'admission est refusée à la frontière, pas avalée en best-effort async).
    test "MA-18 — cap-profile inexistant → 422, PAS 202, et AUCUN broadcast" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{role: "scout-inexistant-xyz"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 422
      refute conn.status == 202

      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end

    # MA-18 — ni `cap_profile_name` ni `role` → 400 (requête mal formée), pas un 202 ni un broadcast.
    test "MA-18 — ni cap_profile_name ni role → 400" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{ticket_id: "issue-1"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 400
      refute_receive %Fleet.Event{type: :"admin.spawn.request"}, 200
    end
  end

  describe "match _ (404)" do
    test "route inexistante → 404" do
      conn = conn(:get, "/api/nonexistent") |> Rest.call(@opts)
      assert conn.status == 404
    end
  end

  # ============================================================
  # #594 D2 — dashboard V2 Elixir natif (Fleet.API.Dashboard mount)
  # ============================================================
  describe "GET /dashboard" do
    test "render HTML 200" do
      conn = conn(:get, "/dashboard") |> Rest.call(@opts)

      assert conn.status == 200
      body = conn.resp_body

      assert body =~ "<title>LCARS // V2 MAINFRAME</title>"
      assert body =~ ~s|<link rel="stylesheet" href="/dashboard/static/lcars-tva.css">|
      assert body =~ ~s|<header class="lcars-header">|
      assert body =~ ~s|<aside class="lcars-rail">|
      assert body =~ ~s|<main class="lcars-main">|

      assert body =~ ~s|id="panel-memory-query"|
      assert body =~ ~s|id="panel-build"|
      assert body =~ ~s|id="panel-coord"|
      assert body =~ ~s|id="panel-oauth"|
      assert body =~ ~s|id="panel-workers"|
      assert body =~ ~s|id="panel-health"|
    end

    test "Content-Type text/html UTF-8" do
      conn = conn(:get, "/dashboard") |> Rest.call(@opts)
      ct = get_resp_header(conn, "content-type") |> List.first()
      assert ct =~ "text/html"
      assert ct =~ "utf-8"
    end

    test "GET /dashboard/static/lcars-tva.css sert le CSS" do
      conn = conn(:get, "/dashboard/static/lcars-tva.css") |> Rest.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ "LCARS"
      assert conn.resp_body =~ "starfleet#1"
      assert conn.resp_body =~ "clean-room"
    end
  end
end
