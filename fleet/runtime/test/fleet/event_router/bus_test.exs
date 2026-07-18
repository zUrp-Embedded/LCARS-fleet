defmodule Fleet.EventRouter.BusTest do
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  # Z5 (ER-D2) — the `broadcast/3` blocks (legacy `{atom, map}` shim) are gone with the legacy.
  # The canonical path `broadcast/2 (topic, %Fleet.Event{})` is tested here + in
  # r1_seam_broadcast_test (registry / UnregisteredError).

  defp ev(type), do: Fleet.Event.new(:spawner, type)

  describe "subscribe/unsubscribe" do
    test "unsubscribe stops delivery" do
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      assert_receive %Fleet.Event{type: :"pod.completed"}

      :ok = Bus.unsubscribe()
      Bus.broadcast("fleet.events", ev(:"pod.completed"))
      refute_receive %Fleet.Event{type: :"pod.completed"}, 100

      :ok = Bus.subscribe()
    end
  end
end
