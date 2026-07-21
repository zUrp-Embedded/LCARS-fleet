defmodule Fleet.API.RestTest do
  # async: false — no auth (boundary = network/container isolation, cf. rest.ex § Auth), but the
  # PubSub bus is global (the admin.spawn test broadcasts + assert_receive) → serializing avoids cross-talk.
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
    test "→ 200 + structured operational state" do
      conn = conn(:get, "/api/readiness/deep") |> Rest.call(@opts)

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] in ["operational", "degraded"]
      assert is_list(body["subsystems"])
      assert is_list(body["degraded"])
    end
  end

  describe "GET endpoints (state reads)" do
    # F-C118 — the 3 state reads were lying empty-200s (indistinguishable from an empty state) on a
    # public surface. Now an honest 501 (real observability = fleet_observation), never an empty
    # response passing itself off as a success.
    test "GET /api/workflow_runs → 501 not_implemented (no more lying empty-200)" do
      conn = conn(:get, "/api/workflow_runs") |> Rest.call(@opts)
      assert conn.status == 501
      assert {:ok, %{"error" => "not_implemented"}} = Jason.decode(conn.resp_body)
    end

    test "GET /api/issues → 501 not_implemented" do
      conn = conn(:get, "/api/issues") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/pods → 501 not_implemented (real observability = fleet_observation)" do
      conn = conn(:get, "/api/pods") |> Rest.call(@opts)
      assert conn.status == 501
    end

    test "GET /api/version → 200 + observable version JSON (sha/dirty/ref/source)" do
      conn = conn(:get, "/api/version") |> Rest.call(@opts)
      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      # SHAPE (not a literal SHA — non-hermetic): the 4 keys of the BuildInfo contract.
      assert %{"sha" => sha, "dirty" => dirty, "source" => source} = body
      assert is_binary(sha) and sha != ""
      assert is_boolean(dirty)
      assert source in ["release", "working_tree", "unknown"]
      assert Map.has_key?(body, "ref")
    end
  end


  describe "POST /api/admin/spawn — REMOVED from TCP (moved to the AF_UNIX socket)" do
    test "POST /api/admin/spawn on TCP → 404 (the write is no longer on this surface)" do
      conn =
        conn(:post, "/api/admin/spawn", Jason.encode!(%{"role" => "engineer"}))
        |> put_req_header("content-type", "application/json")
        |> Rest.call(@opts)

      assert conn.status == 404
    end
  end

  describe "match _ (404)" do
    test "nonexistent route → 404" do
      conn = conn(:get, "/api/nonexistent") |> Rest.call(@opts)
      assert conn.status == 404
    end
  end
end
