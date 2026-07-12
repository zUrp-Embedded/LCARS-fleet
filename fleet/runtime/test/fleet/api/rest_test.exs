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

  describe "GET endpoints (lecture état)" do
    # F-C118 — les 3 lectures d'état étaient des empty-200 menteurs (indistinguables d'un état vide) sur
    # surface publique. Désormais 501 honnête (l'observabilité réelle = fleet_observation), jamais un vide
    # qui se fait passer pour un succès.
    test "GET /api/workflow_runs → 501 not_implemented (plus d'empty-200 menteur)" do
      conn = conn(:get, "/api/workflow_runs") |> Rest.call(@opts)
      assert conn.status == 501
      assert {:ok, %{"error" => "not_implemented"}} = Jason.decode(conn.resp_body)
    end

    test "GET /api/issues → 501 not_implemented" do
      conn = conn(:get, "/api/issues") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/pods → 501 not_implemented (observabilité réelle = fleet_observation)" do
      conn = conn(:get, "/api/pods") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/version → 200 + JSON version constatable (sha/dirty/ref/source)" do
      conn = conn(:get, "/api/version") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      # SHAPE (pas un SHA littéral — non-hermétique) : les 4 clefs du contrat BuildInfo.
      assert %{"sha" => sha, "dirty" => dirty, "source" => source} = body
      assert is_binary(sha) and sha != ""
      assert is_boolean(dirty)
      assert source in ["release", "working_tree", "unknown"]
      assert Map.has_key?(body, "ref")
    end
  end


  describe "POST /api/admin/spawn — RETIRÉ du TCP (déplacé sur la socket AF_UNIX)" do
    test "POST /api/admin/spawn sur le TCP → 404 (l'écriture n'est plus sur cette surface, A-21)" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 404
    end
  end

  describe "match _ (404)" do
    test "route inexistante → 404" do
      conn = conn(:get, "/api/nonexistent") |> Rest.call(@opts)
      assert conn.status == 404
    end
  end
end
