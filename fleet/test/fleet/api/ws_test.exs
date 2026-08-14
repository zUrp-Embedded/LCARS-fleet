defmodule Fleet.API.WSTest do
  use ExUnit.Case, async: true

  alias Fleet.API.WS

  # 6-056 — LE POINT DE TERMINAISON EST DEBRANCHE PAR DEFAUT, ET LE MODULE RESTE INTACT.
  #
  # Il projette le flux d'evenements COMPLET sans authentification : un client qui ne demande rien
  # recoit tout, y compris une CAPTURE DE L'ECRAN tmux d'un pod (`wake.failed`). La posture gravee
  # « api REST/WS no-auth by design » vaut pour de l'observabilite, pas pour ca.
  #
  # DEBRANCHE et non SUPPRIME, sur arbitrage user : « personne ne le consomme » est une mesure sur
  # CE depot a CET instant (deux candidats ecartes un par un le 2026-08-14 — le deck Python lit
  # `/api/pods` en HTTP, le deck Elixir n'a aucune WebSocket et son DESIGN dit la separation). Une
  # coupure reversible dit la meme chose qu'une suppression et se rend en une ligne.
  #
  # Ces deux tests sont ce qui rend la coupure REVERSIBLE plutot qu'oubliee : le jour ou quelqu'un
  # rallume le commutateur, le second prouve que la route revient telle quelle.
  describe "6-056 — la route est un commutateur, pas une suppression" do
    alias Fleet.API.Application, as: APIApp

    test "par defaut : aucune route /ws dans le dispatch" do
      assert APIApp.ws_route() == []
    end

    test "commutateur arme : la route revient, sur le meme handler" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :api_serve_ws, true)
      assert [{"/ws", WS, []}] = APIApp.ws_route()
    end
  end

  describe "topic_matches?/2" do
    test "empty topics → match all" do
      assert WS.topic_matches?("anything", [])
      assert WS.topic_matches?("workflow_map.completed", [])
    end

    test "exact match" do
      assert WS.topic_matches?("workflow_map.completed", ["workflow_map.completed"])
      refute WS.topic_matches?("pod.started", ["workflow_map.completed"])
    end

    test "wildcard suffix .*" do
      assert WS.topic_matches?("workflow_map.completed", ["workflow_map.*"])
      assert WS.topic_matches?("workflow_map.failed", ["workflow_map.*"])
      assert WS.topic_matches?("workflow_map.step.completed", ["workflow_map.*"])
      refute WS.topic_matches?("pod.started", ["workflow_map.*"])
    end

    test "multi patterns OR" do
      assert WS.topic_matches?("workflow_map.completed", ["pod.*", "workflow_map.*"])
      assert WS.topic_matches?("pod.started", ["pod.*", "workflow_map.*"])
      refute WS.topic_matches?("audit.log", ["pod.*", "workflow_map.*"])
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

      # Heartbeat scheduled via Process.send_after 30s (not awaited in test).
    end
  end

  describe "websocket_handle/2 subscribe action" do
    test "{action: subscribe, topics: [...]} → ack + state.topics updated" do
      msg = Jason.encode!(%{action: "subscribe", topics: ["workflow_map.*", "pod.*"]})

      assert {[{:text, frame}], new_state} = WS.websocket_handle({:text, msg}, %{topics: []})

      assert {:ok, %{"type" => "subscribed", "topics" => ["workflow_map.*", "pod.*"]}} =
               Jason.decode(frame)

      assert new_state.topics == ["workflow_map.*", "pod.*"]
    end

    test "non-string topic ([123]) → rejected at admission, error frame, state UNCHANGED (no ACK)" do
      # No-auth vector: a non-string topic would crash topic_matches?/2 downstream. Clean rejection,
      # no subscribe → the state must NOT take the rotten topics.
      msg = Jason.encode!(%{action: "subscribe", topics: [123]})

      assert {[{:text, frame}], state} = WS.websocket_handle({:text, msg}, %{topics: []})
      assert frame =~ "error"
      assert state == %{topics: []}
    end

    test "mixed list (string + non-string) → rejected at admission, state unchanged" do
      msg = Jason.encode!(%{action: "subscribe", topics: ["workflow_map.*", 5]})

      assert {[{:text, frame}], state} = WS.websocket_handle({:text, msg}, %{topics: ["old.*"]})
      assert frame =~ "error"
      assert state == %{topics: ["old.*"]}
    end

    test "malformed JSON → error frame, state unchanged" do
      assert {[{:text, frame}], state} = WS.websocket_handle({:text, "not json"}, %{topics: []})
      assert frame =~ "invalid_msg"
      assert state == %{topics: []}
    end

    test "unknown action → error frame" do
      msg = Jason.encode!(%{action: "weird"})
      assert {[{:text, frame}], _} = WS.websocket_handle({:text, msg}, %{topics: []})
      assert frame =~ "unknown action"
    end
  end

  describe "websocket_info/2 events" do
    test "event matching topic → frame event JSON" do
      event = Fleet.Event.new(:workflow, :"workflow_map.completed", payload: %{"id" => "p1"})

      assert {[{:text, frame}], state} =
               WS.websocket_info(event, %{topics: ["workflow_map.*"]})

      assert {:ok,
              %{
                "type" => "event",
                "event_type" => "workflow_map.completed",
                "payload" => %{"id" => "p1"}
              }} = Jason.decode(frame)

      assert state == %{topics: ["workflow_map.*"]}
    end

    test "non-matching event → no frame, state unchanged" do
      event = Fleet.Event.new(:starfleet, :"audit.log")

      assert {[], state} = WS.websocket_info(event, %{topics: ["workflow_map.*"]})
      assert state == %{topics: ["workflow_map.*"]}
    end

    test "empty topics → match all" do
      event = Fleet.Event.new(:workflow, :anything)

      assert {[{:text, frame}], _} = WS.websocket_info(event, %{topics: []})
      assert frame =~ "anything"
    end

    test "heartbeat → CONTROL ping frame + reschedule" do
      # A real RFC 6455 ping (not a text frame): the client's automatic pong feeds
      # idle_timeout — a passive subscriber (dashboard) is no longer disconnected every 60s.
      assert {[{:ping, <<>>}], state} = WS.websocket_info(:heartbeat, %{topics: []})

      assert state == %{topics: []}

      # Reschedule done via Process.send_after — not awaited (sync test, 30s
      # too long). We only check that the frame is correct + state preserved.
    end

    test "non-JSON-encodable payload (tuple) → degraded _raw frame, never a process crash" do
      # The WS edge is the ONLY JSON consumer of the bus without a net: a reason tuple from a
      # producer (future, or an event forged on the no-auth bus) would crash every Cowboy connection
      # precisely on incident events. The rescue degrades into inspected truth.
      event =
        Fleet.Event.new(:spawner, :"pod.failed",
          payload: %{"pod_id" => "p1", "reason" => {:no_ack, :wake}}
        )

      assert {[{:text, frame}], _state} = WS.websocket_info(event, %{topics: []})

      assert {:ok, %{"type" => "event", "event_type" => "pod.failed", "payload" => payload}} =
               Jason.decode(frame)

      assert payload["_raw"] =~ "no_ack"
    end

    test "unknown message → no frame" do
      assert {[], state} = WS.websocket_info(:other, %{topics: []})
      assert state == %{topics: []}
    end
  end
end
