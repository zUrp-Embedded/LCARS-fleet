defmodule Fleet.API.WSTest do
  use ExUnit.Case, async: true

  alias Fleet.API.WS

  describe "topic_matches?/2" do
    test "topics vide → match all" do
      assert WS.topic_matches?("anything", [])
      assert WS.topic_matches?("pipeline.completed", [])
    end

    test "exact match" do
      assert WS.topic_matches?("pipeline.completed", ["pipeline.completed"])
      refute WS.topic_matches?("pod.started", ["pipeline.completed"])
    end

    test "wildcard suffix .*" do
      assert WS.topic_matches?("pipeline.completed", ["pipeline.*"])
      assert WS.topic_matches?("pipeline.failed", ["pipeline.*"])
      assert WS.topic_matches?("pipeline.stage.completed", ["pipeline.*"])
      refute WS.topic_matches?("pod.started", ["pipeline.*"])
    end

    test "multi patterns OR" do
      assert WS.topic_matches?("pipeline.completed", ["pod.*", "pipeline.*"])
      assert WS.topic_matches?("pod.started", ["pod.*", "pipeline.*"])
      refute WS.topic_matches?("audit.log", ["pod.*", "pipeline.*"])
    end

    test "exact + wildcard mix" do
      assert WS.topic_matches?("audit.log", ["audit.log", "pod.*"])
      assert WS.topic_matches?("pod.started", ["audit.log", "pod.*"])
    end
  end

  describe "websocket_init/1" do
    test "subscribe Bus + init heartbeat + frame connected" do
      assert {[{:text, frame}], state} = WS.websocket_init(%{topics: []})
      assert frame == ~s|{"type":"connected"}|
      assert state == %{topics: []}

      # Heartbeat schedulé via Process.send_after 30s (pas attendu en test).
    end
  end

  describe "websocket_handle/2 subscribe action" do
    test "{action: subscribe, topics: [...]} → ack + state.topics updated" do
      msg = Jason.encode!(%{action: "subscribe", topics: ["pipeline.*", "pod.*"]})

      assert {[{:text, frame}], new_state} = WS.websocket_handle({:text, msg}, %{topics: []})

      assert {:ok, %{"type" => "subscribed", "topics" => ["pipeline.*", "pod.*"]}} =
               Jason.decode(frame)

      assert new_state.topics == ["pipeline.*", "pod.*"]
    end

    test "JSON malformé → error frame, state inchangé" do
      assert {[{:text, frame}], state} = WS.websocket_handle({:text, "not json"}, %{topics: []})
      assert frame =~ "invalid_msg"
      assert state == %{topics: []}
    end

    test "action inconnue → error frame" do
      msg = Jason.encode!(%{action: "weird"})
      assert {[{:text, frame}], _} = WS.websocket_handle({:text, msg}, %{topics: []})
      assert frame =~ "unknown action"
    end
  end

  describe "websocket_info/2 events" do
    test "event matching topic → frame event JSON" do
      event = %Fleet.Event{
        source: :pipeline,
        type: :"pipeline.completed",
        timestamp: DateTime.utc_now(),
        payload: %{"id" => "p1"}
      }

      assert {[{:text, frame}], state} =
               WS.websocket_info(event, %{topics: ["pipeline.*"]})

      assert {:ok,
              %{
                "type" => "event",
                "event_type" => "pipeline.completed",
                "payload" => %{"id" => "p1"}
              }} = Jason.decode(frame)

      assert state == %{topics: ["pipeline.*"]}
    end

    test "event non matching → no frame, state inchangé" do
      event = %Fleet.Event{
        source: :starfleet,
        type: :"audit.log",
        timestamp: DateTime.utc_now(),
        payload: %{}
      }

      assert {[], state} = WS.websocket_info(event, %{topics: ["pipeline.*"]})
      assert state == %{topics: ["pipeline.*"]}
    end

    test "topics vide → match all" do
      event = %Fleet.Event{
        source: :pipeline,
        type: :anything,
        timestamp: DateTime.utc_now(),
        payload: %{}
      }

      assert {[{:text, frame}], _} = WS.websocket_info(event, %{topics: []})
      assert frame =~ "anything"
    end

    test "heartbeat → ping frame + reschedule" do
      assert {[{:text, ~s|{"type":"ping"}|}], state} =
               WS.websocket_info(:heartbeat, %{topics: []})

      assert state == %{topics: []}

      # Reschedule fait via Process.send_after — pas attendu (test sync, 30s
      # trop long). On vérifie juste que le frame est correct + state préservé.
    end

    test "message inconnu → no frame" do
      assert {[], state} = WS.websocket_info(:other, %{topics: []})
      assert state == %{topics: []}
    end
  end
end
