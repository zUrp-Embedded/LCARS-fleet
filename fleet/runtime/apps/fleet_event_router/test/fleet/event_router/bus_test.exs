defmodule Fleet.EventRouter.BusTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  # Z5 (ER-D2) — les blocs `broadcast/3` (shim legacy `{atom, map}`) retirés avec le legacy.
  # Le chemin canon `broadcast/2 (topic, %Fleet.Event{})` est testé ici + dans
  # r1_seam_broadcast_test (registry / UnregisteredError).

  defp ev(type),
    do: %Fleet.Event{source: :spawner, type: type, timestamp: DateTime.utc_now(), payload: %{}}

  describe "subscribe/unsubscribe" do
    test "unsubscribe stoppe la réception" do
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      assert_receive %Fleet.Event{type: :"pod.completed"}

      :ok = Bus.unsubscribe()
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      refute_receive %Fleet.Event{type: :"pod.completed"}, 100

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
end
