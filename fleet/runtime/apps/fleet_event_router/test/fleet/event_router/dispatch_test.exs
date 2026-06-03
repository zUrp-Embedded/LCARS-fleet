defmodule Fleet.EventRouter.DispatchTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.{Bus, Dispatch}

  defmodule TestHandler do
    def handle_event(event) do
      target = Application.get_env(:fleet_event_router, :test_handler_target)
      if is_pid(target), do: send(target, {:test_handler_received, event})
      :ok
    end
  end

  setup %{tmp_dir: tmp_dir} do
    yaml_path = Path.join(tmp_dir, "events.yaml")

    File.write!(yaml_path, """
    events:
      pod.allocate:
        - Fleet.EventRouter.DispatchTest.TestHandler
      gitea.opened:
        - Fleet.EventRouter.DispatchTest.TestHandler
    """)

    Application.put_env(:fleet_event_router, :events_yaml_path, yaml_path)
    Application.put_env(:fleet_event_router, :test_handler_target, self())

    {:ok, _disp} = start_supervised(Dispatch)

    on_exit(fn ->
      Application.delete_env(:fleet_event_router, :events_yaml_path)
      Application.delete_env(:fleet_event_router, :test_handler_target)
      # Reset persistent_term registry pour ne pas leaker la MapSet restrictive
      # (tmp yaml = 2 entrées) vers les tests d'autres apps qui broadcast en
      # schema canon strict (BL-021 chantier 3 : assert_authorized! activé).
      Fleet.EventRouter.Bus.set_authorized_event_types(MapSet.new())
    end)

    :ok
  end

  describe "dispatch via YAML table" do
    test "event mappé → handler reçoit le payload" do
      Bus.broadcast("pod.allocate", %{"pod_id" => "p1"}, [])

      assert_receive {:test_handler_received, event}, 1_000
      assert event["event_type"] == "pod.allocate"
      assert event["payload"] == %{"pod_id" => "p1"}
    end

    test "event non-mappé → no-op (pas de handler call)" do
      Bus.broadcast("untracked.event", %{}, [])

      refute_receive {:test_handler_received, _}, 200
    end

    test "handler module inconnu → log warning + pas de crash" do
      yaml_path = Application.fetch_env!(:fleet_event_router, :events_yaml_path)

      File.write!(yaml_path, """
      events:
        ghost.event:
          - Fleet.NonExistent.Handler
      """)

      Dispatch.reload()
      _ = :sys.get_state(Dispatch)

      Bus.broadcast("ghost.event", %{}, [])
      refute_receive {:test_handler_received, _}, 200
    end
  end

  describe "reload/0" do
    test "recharge le catalogue YAML modifié" do
      yaml_path = Application.fetch_env!(:fleet_event_router, :events_yaml_path)

      File.write!(yaml_path, """
      events:
        new.event:
          - Fleet.EventRouter.DispatchTest.TestHandler
      """)

      Dispatch.reload()
      _ = :sys.get_state(Dispatch)

      Bus.broadcast("new.event", %{"x" => 1}, [])
      assert_receive {:test_handler_received, %{"event_type" => "new.event"}}, 1_000
    end
  end
end
