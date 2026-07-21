defmodule Fleet.EventRouter.BusSafeEmitTest do
  @moduledoc """
  Locks the `Bus.safe_emit/3-4` contract — the SINGLE core of the
  "protected-Bus-emission" family (dedup of the local rescues of coord/starfleet/spawner).
  Four paths:

    * OK — registered type → emitted, the subscriber receives the canonical struct
      (atom OR binary).
    * UnregisteredError — boot-order tolerated: `:log` (default) = VISIBLE warning,
      `:silent` = mute. In both cases `:ok`, NO event goes out.
    * malformed event (CONSTRUCTION bug: source outside the enum, type name never
      preregistered) — ALWAYS Logger.error + `:ok`: never swallowed mute, never a
      crash of the emitter.
    * DELIVERY error (CI-09: Phoenix.PubSub.broadcast → `{:error, reason}`) — Logger.error
      + the tuple PASSED THROUGH (a caller that acts on delivery still can). This branch was
      in the code but UNPROVEN — the "complete contract" claim omitted it.

  Covered regression: re-swallowing a malformed event in silence (the per-site
  inconsistency this core deduplicates) fails the "malformed event" cases; propagating
  the raise fails the `assert :ok`s.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus

  # The registry is a GLOBAL `:persistent_term` → no async, set saved/restored
  # (same discipline as BusRegistryEmptyTest). The registry is POPULATED here: with an
  # empty set + default permit, no UnregisteredError can occur — the "unregistered"
  # paths of this test would be dead.
  setup do
    previous = Bus.authorized_event_types()
    Bus.set_authorized_event_types(MapSet.new([:"pod.completed"]))
    :ok = Bus.subscribe()

    on_exit(fn ->
      Bus.unsubscribe()
      Bus.set_authorized_event_types(previous)
    end)

    :ok
  end

  describe "OK path" do
    test "registered type (atom) → :ok + canonical event received by the subscriber" do
      assert :ok = Bus.safe_emit(:spawner, :"pod.completed", payload: %{"pod_id" => "p1"})

      assert_receive %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        payload: %{"pod_id" => "p1"}
      }
    end

    test "registered type passed as BINARY → converted (to_existing_atom) and emitted" do
      assert :ok = Bus.safe_emit(:spawner, "pod.completed", payload: %{})
      assert_receive %Fleet.Event{source: :spawner, type: :"pod.completed"}
    end
  end

  describe "UnregisteredError — boot-order tolerated, per :on_unregistered" do
    test ":log (default) → :ok + visible warning, NO event emitted" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:spawner, :"phantom.never.registered", [])
        end)

      assert log =~ "outside the events.yaml registry"
      assert log =~ "phantom.never.registered"
      refute_receive %Fleet.Event{}, 100
    end

    test ":silent → mute :ok (no log), NO event emitted" do
      log =
        capture_log(fn ->
          assert :ok =
                   Bus.safe_emit(:spawner, :"phantom.never.registered", [],
                     on_unregistered: :silent
                   )
        end)

      refute log =~ "phantom.never.registered"
      refute log =~ "outside the events.yaml registry"
      refute_receive %Fleet.Event{}, 100
    end
  end

  describe "malformed event (construction bug) — ALWAYS Logger.error + :ok" do
    test "source outside the closed-list enum → logged ERROR, :ok (no crash), NO event" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:not_a_source, :"pod.completed", [])
        end)

      assert log =~ "malformed event"
      assert log =~ "[error]"
      refute_receive %Fleet.Event{}, 100
    end

    test "binary type name never preregistered → to_existing_atom classified as construction bug" do
      log =
        capture_log(fn ->
          assert :ok = Bus.safe_emit(:spawner, "type.jamais.preregistre.xyz", [])
        end)

      assert log =~ "malformed event"
      assert log =~ "[error]"
      refute_receive %Fleet.Event{}, 100
    end

    test ":context prefixes the message (the emitter's BUSINESS context travels in the log)" do
      log =
        capture_log(fn ->
          assert :ok =
                   Bus.safe_emit(:not_a_source, :"pod.completed", [],
                     context: "MyEmitter: alert NOT emitted"
                   )
        end)

      assert log =~ "MyEmitter: alert NOT emitted"
      assert log =~ "malformed event"
    end
  end

  describe "delivery error (CI-09) — Phoenix.PubSub.broadcast {:error, reason}" do
    setup do
      # Force the rare delivery failure via the broadcast seam (default = the real PubSub).
      Application.put_env(:fleet_event_router, :broadcast_fun, fn _name, _topic, _event ->
        {:error, :no_such_topic}
      end)

      on_exit(fn -> Application.delete_env(:fleet_event_router, :broadcast_fun) end)
      :ok
    end

    test "a broadcast {:error, reason} is Logger.error-ed AND the tuple is passed through (not a fake :ok)" do
      log =
        capture_log(fn ->
          # A REGISTERED type (so construction succeeds), whose DELIVERY then fails — the CI-09 branch.
          assert {:error, :no_such_topic} =
                   Bus.safe_emit(:spawner, :"pod.completed", [payload: %{}],
                     context: "MyEmitter: pod.completed"
                   )
        end)

      assert log =~ "[error]"
      assert log =~ "broadcast FAILED (lossy, not delivered)"
      assert log =~ "no_such_topic"
      assert log =~ "MyEmitter: pod.completed"
    end
  end
end
