defmodule Fleet.MCP.ChannelHTTPTest do
  use ExUnit.Case, async: false

  alias Fleet.MCP.ChannelHTTP

  setup do
    # QueueOwner démarré par Fleet.MCP.Supervisor au boot fleet_mcp en test
    # env → ETS table déjà là. On vide juste le state entre tests pour
    # isolation (async: false ; OK car ETS table partagée entre tests).
    case :ets.whereis(:fleet_mcp_channel_queue) do
      :undefined -> ChannelHTTP.ensure_table()
      _ -> :ets.delete_all_objects(:fleet_mcp_channel_queue)
    end

    :ok
  end

  describe "enqueue/2 + drain/1" do
    test "enqueue then drain returns the notification" do
      notif = %{"content" => "hello", "meta" => %{"ticket_id" => "fleet/lcars#42"}}
      :ok = ChannelHTTP.enqueue("qualifier", notif)

      assert [^notif] = ChannelHTTP.drain("qualifier")
    end

    test "multiple enqueues drain in FIFO order" do
      n1 = %{"content" => "first", "meta" => %{}}
      n2 = %{"content" => "second", "meta" => %{}}
      n3 = %{"content" => "third", "meta" => %{}}

      :ok = ChannelHTTP.enqueue("qualifier", n1)
      :ok = ChannelHTTP.enqueue("qualifier", n2)
      :ok = ChannelHTTP.enqueue("qualifier", n3)

      assert [^n1, ^n2, ^n3] = ChannelHTTP.drain("qualifier")
    end

    test "drain on empty pod_id returns []" do
      assert [] = ChannelHTTP.drain("inexistant")
    end

    test "drain twice → second call returns [] (queue vidée)" do
      :ok = ChannelHTTP.enqueue("qualifier", %{"content" => "x", "meta" => %{}})
      assert [_] = ChannelHTTP.drain("qualifier")
      assert [] = ChannelHTTP.drain("qualifier")
    end

    test "queues isolated per pod_id" do
      :ok = ChannelHTTP.enqueue("qualifier", %{"content" => "q1", "meta" => %{}})
      :ok = ChannelHTTP.enqueue("reviewer", %{"content" => "r1", "meta" => %{}})

      assert [%{"content" => "q1"}] = ChannelHTTP.drain("qualifier")
      assert [%{"content" => "r1"}] = ChannelHTTP.drain("reviewer")
    end
  end

  describe "HTTP roundtrip via Plug.Test" do
    test "POST /internal/channels/notify → enqueue + 200 ok" do
      body =
        Jason.encode!(%{
          "pod_id" => "qualifier",
          "content" => "task body",
          "meta" => %{"k" => "v"}
        })

      conn =
        Plug.Test.conn(:post, "/internal/channels/notify", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> ChannelHTTP.call(ChannelHTTP.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"ok" => true}

      assert [%{"content" => "task body", "meta" => %{"k" => "v"}}] =
               ChannelHTTP.drain("qualifier")
    end

    test "POST /internal/channels/notify body invalide → 400" do
      body = Jason.encode!(%{"missing" => "fields"})

      conn =
        Plug.Test.conn(:post, "/internal/channels/notify", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> ChannelHTTP.call(ChannelHTTP.init([]))

      assert conn.status == 400
      assert %{"ok" => false} = Jason.decode!(conn.resp_body)
    end

    test "GET /channels/:pod_id/poll vide avec timeout=1 → 200 [] (~1s)" do
      started = System.monotonic_time(:millisecond)

      conn =
        Plug.Test.conn(:get, "/channels/qualifier/poll?timeout=1")
        |> ChannelHTTP.call(ChannelHTTP.init([]))

      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 200
      assert %{"ok" => true, "notifications" => []} = Jason.decode!(conn.resp_body)
      # ~1s timeout respecté (avec marge ±200ms)
      assert elapsed >= 900 and elapsed < 1500
    end

    test "GET /channels/:pod_id/poll avec notif déjà queued → renvoi immédiat" do
      :ok = ChannelHTTP.enqueue("qualifier", %{"content" => "ready", "meta" => %{}})

      started = System.monotonic_time(:millisecond)

      conn =
        Plug.Test.conn(:get, "/channels/qualifier/poll?timeout=10")
        |> ChannelHTTP.call(ChannelHTTP.init([]))

      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 200
      assert %{"notifications" => [%{"content" => "ready"}]} = Jason.decode!(conn.resp_body)
      # Renvoi immédiat (pas de wait timeout)
      assert elapsed < 500
    end
  end
end
