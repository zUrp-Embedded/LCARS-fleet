defmodule Fleet.EventRouter.BusSafeEmitTest do
  @moduledoc """
  Exercises successful atom/binary emission, tolerated registry/constructor failures,
  diagnostic context and a returned delivery error injected through the seam. These cases
  do not cover all exception classes or partial delivery between main and pod topics.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus

  # Populate and restore the global registry. Empty+permissive would never exercise rejection.
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
      Application.put_env(:lcars_fleet, :event_router_broadcast_fun, fn _name, _topic, _event ->
        {:error, :no_such_topic}
      end)

      on_exit(fn -> Application.delete_env(:lcars_fleet, :event_router_broadcast_fun) end)
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

  describe "the `:broadcast_fun` seam is ANNOUNCED at boot when it is declared" do
    test "declared in config → the supervisor init says so, LOUD" do
      # The warning names the risk of deliver-then-error seams. This only calls init to inspect
      # its log; it does not start children or demonstrate completion retry behaviour.
      Application.put_env(:lcars_fleet, :event_router_broadcast_fun, fn _n, _t, _e -> :ok end)
      on_exit(fn -> Application.delete_env(:lcars_fleet, :event_router_broadcast_fun) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Fleet.EventRouter.Application.init([])
        end)

      assert log =~ "`:broadcast_fun` is DECLARED at boot"
      assert log =~ "CI-03"
    end

    test "absent → boot says NOTHING about it (the per-test put_env must stay silent)" do
      # With no seam at init there is nothing to announce; no post-init change is exercised here.
      Application.delete_env(:lcars_fleet, :event_router_broadcast_fun)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Fleet.EventRouter.Application.init([])
        end)

      refute log =~ "broadcast_fun"
    end
  end
end
