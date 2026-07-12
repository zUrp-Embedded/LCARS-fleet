defmodule Fleet.API.WSTest do
  use ExUnit.Case, async: true

  alias Fleet.API.WS

  describe "topic_matches?/2" do
    test "topics vide → match all" do
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

      # Heartbeat schedulé via Process.send_after 30s (pas attendu en test).
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

    test "topic non-string ([123]) → rejet à l'admission, error frame, state INCHANGÉ (pas d'ACK)" do
      # Vecteur non-auth : un topic non-string crasherait topic_matches?/2 en aval. Rejet net,
      # pas de subscribe → l'état ne doit PAS prendre les topics véreux.
      msg = Jason.encode!(%{action: "subscribe", topics: [123]})

      assert {[{:text, frame}], state} = WS.websocket_handle({:text, msg}, %{topics: []})
      assert frame =~ "error"
      assert state == %{topics: []}
    end

    test "liste mixte (string + non-string) → rejet à l'admission, state inchangé" do
      msg = Jason.encode!(%{action: "subscribe", topics: ["workflow_map.*", 5]})

      assert {[{:text, frame}], state} = WS.websocket_handle({:text, msg}, %{topics: ["old.*"]})
      assert frame =~ "error"
      assert state == %{topics: ["old.*"]}
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

    test "event non matching → no frame, state inchangé" do
      event = Fleet.Event.new(:starfleet, :"audit.log")

      assert {[], state} = WS.websocket_info(event, %{topics: ["workflow_map.*"]})
      assert state == %{topics: ["workflow_map.*"]}
    end

    test "topics vide → match all" do
      event = Fleet.Event.new(:workflow, :anything)

      assert {[{:text, frame}], _} = WS.websocket_info(event, %{topics: []})
      assert frame =~ "anything"
    end

    test "heartbeat → frame de CONTRÔLE ping + reschedule" do
      # Un vrai ping RFC 6455 (pas un frame texte) : le pong automatique du client nourrit
      # idle_timeout — un abonné passif (dashboard) n'est plus déconnecté toutes les 60s.
      assert {[{:ping, <<>>}], state} = WS.websocket_info(:heartbeat, %{topics: []})

      assert state == %{topics: []}

      # Reschedule fait via Process.send_after — pas attendu (test sync, 30s
      # trop long). On vérifie juste que le frame est correct + state préservé.
    end

    test "payload non-JSON-encodable (tuple) → frame dégradé _raw, jamais un crash du process" do
      # Le bord WS est le SEUL consommateur JSON du bus sans filet : un reason tuple d'un
      # producteur (futur, ou event forgé sur le bus no-auth) crashait chaque connexion Cowboy
      # précisément sur les events d'incident. Le rescue dégrade en vérité inspectée.
      event =
        Fleet.Event.new(:spawner, :"pod.failed",
          payload: %{"pod_id" => "p1", "reason" => {:no_ack, :wake}}
        )

      assert {[{:text, frame}], _state} = WS.websocket_info(event, %{topics: []})

      assert {:ok, %{"type" => "event", "event_type" => "pod.failed", "payload" => payload}} =
               Jason.decode(frame)

      assert payload["_raw"] =~ "no_ack"
    end

    test "message inconnu → no frame" do
      assert {[], state} = WS.websocket_info(:other, %{topics: []})
      assert state == %{topics: []}
    end
  end
end
