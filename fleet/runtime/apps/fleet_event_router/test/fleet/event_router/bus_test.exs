defmodule Fleet.EventRouter.BusTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  describe "broadcast/3 — happy path" do
    test "diffuse event valide → subscriber reçoit {atom, event}" do
      assert :ok =
               Bus.broadcast("pod.allocate", %{"pod_id" => "p1"}, ticket_id: "t1", pod_id: "p1")

      assert_receive {:"pod.allocate", event}, 500
      assert event["event_type"] == "pod.allocate"
      assert event["payload"] == %{"pod_id" => "p1"}
      assert event["ticket_id"] == "t1"
      assert event["pod_id"] == "p1"
      assert is_binary(event["ts"])
      assert is_binary(event["trace_id"])
      assert byte_size(event["trace_id"]) == 16
    end

    test "trace_id généré si non fourni" do
      Bus.broadcast("pod.allocate", %{}, [])
      assert_receive {:"pod.allocate", %{"trace_id" => trace1}}

      Bus.broadcast("pod.allocate", %{}, [])
      assert_receive {:"pod.allocate", %{"trace_id" => trace2}}

      assert trace1 != trace2
    end

    test "trace_id préservé si fourni" do
      Bus.broadcast("test", %{}, trace_id: "custom-trace")
      assert_receive {:test, %{"trace_id" => "custom-trace"}}
    end
  end

  describe "broadcast/3 — schema validation" do
    test "payload non-map → CaseClauseError ou crash (function clause)" do
      assert_raise FunctionClauseError, fn ->
        Bus.broadcast("invalid", "not a map", [])
      end
    end

    test "event_type vide → broadcast effectué (pas de validation côté schema strict ici)" do
      # Schema permet event_type minLength 1 mais "" est rejeté
      assert {:error, _} = Bus.broadcast("", %{}, [])
    end
  end

  describe "subscribe/unsubscribe" do
    test "unsubscribe stoppe la réception" do
      Bus.broadcast("pod.allocate", %{}, [])
      assert_receive {:"pod.allocate", _}

      :ok = Bus.unsubscribe()
      Bus.broadcast("pod.allocate", %{}, [])
      refute_receive {:"pod.allocate", _}, 100

      :ok = Bus.subscribe()
    end
  end

  describe "broadcast_subtopic/2 — sous-topic ch10 relay pattern" do
    test "diffuse vers fleet.events.relay.<ref>" do
      Bus.subscribe("fleet.events.relay.abc123")

      Bus.broadcast_subtopic(
        "relay.abc123",
        {:permission_relay_response, %{ref: "abc123", decision: :allow}}
      )

      assert_receive {:permission_relay_response, %{ref: "abc123", decision: :allow}}
      Bus.unsubscribe("fleet.events.relay.abc123")
    end
  end

  describe "generate_trace_id/0" do
    test "16-hex chars" do
      trace = Bus.generate_trace_id()
      assert byte_size(trace) == 16
      assert String.match?(trace, ~r/^[0-9a-f]{16}$/)
    end

    test "unique" do
      traces = for _ <- 1..100, do: Bus.generate_trace_id()
      assert length(Enum.uniq(traces)) == 100
    end
  end
end
