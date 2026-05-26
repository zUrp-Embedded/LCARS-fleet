defmodule Fleet.MCP.PushDispatcherTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.ChannelHTTP

  setup do
    # ETS via QueueOwner (démarré par Supervisor au boot fleet_mcp test env).
    case :ets.whereis(:fleet_mcp_channel_queue) do
      :undefined -> ChannelHTTP.ensure_table()
      _ -> :ets.delete_all_objects(:fleet_mcp_channel_queue)
    end

    :ok
  end

  describe "Bus pod.brief.push → ChannelHTTP.enqueue" do
    test "broadcast valide → notif disponible dans ChannelHTTP.drain" do
      :ok =
        Bus.broadcast(
          "pod.brief.push",
          %{
            "pod_id" => "qualifier",
            "content" => "task body to inject",
            "meta" => %{"ticket_id" => "fleet/lcars#42"}
          }
        )

      # PushDispatcher est un GenServer subscribé Bus — l'enqueue passe par un
      # message Phoenix.PubSub asynchrone. Polling déterministe court (la cible
      # est en mémoire ETS, l'attente est < 50ms en pratique).
      assert wait_for_drain("qualifier", 500) == [
               %{
                 "content" => "task body to inject",
                 "meta" => %{"ticket_id" => "fleet/lcars#42"}
               }
             ]
    end

    test "broadcast sans pod_id → ignoré (warning loggé, queue vide)" do
      :ok = Bus.broadcast("pod.brief.push", %{"content" => "no pod_id"})

      Process.sleep(50)
      assert ChannelHTTP.drain("qualifier") == []
    end

    test "broadcast sans content → ignoré" do
      :ok = Bus.broadcast("pod.brief.push", %{"pod_id" => "qualifier"})

      Process.sleep(50)
      assert ChannelHTTP.drain("qualifier") == []
    end

    test "multiple broadcasts sur le même pod_id → FIFO dans la queue" do
      for n <- 1..3 do
        :ok =
          Bus.broadcast("pod.brief.push", %{
            "pod_id" => "qualifier",
            "content" => "task #{n}",
            "meta" => %{}
          })
      end

      notifs = wait_for_drain_count("qualifier", 3, 500)
      assert Enum.map(notifs, & &1["content"]) == ["task 1", "task 2", "task 3"]
    end
  end

  defp wait_for_drain(pod_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_drain(pod_id, deadline)
  end

  defp poll_drain(pod_id, deadline) do
    case ChannelHTTP.drain(pod_id) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          poll_drain(pod_id, deadline)
        else
          []
        end

      list ->
        list
    end
  end

  defp wait_for_drain_count(pod_id, n, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_drain_count(pod_id, n, deadline, [])
  end

  defp poll_drain_count(pod_id, n, deadline, acc) do
    case ChannelHTTP.drain(pod_id) do
      [] ->
        if length(acc) >= n or System.monotonic_time(:millisecond) >= deadline do
          acc
        else
          Process.sleep(10)
          poll_drain_count(pod_id, n, deadline, acc)
        end

      list ->
        new_acc = acc ++ list

        if length(new_acc) >= n or System.monotonic_time(:millisecond) >= deadline do
          new_acc
        else
          Process.sleep(10)
          poll_drain_count(pod_id, n, deadline, new_acc)
        end
    end
  end
end
