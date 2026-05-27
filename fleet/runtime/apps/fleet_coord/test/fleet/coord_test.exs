defmodule Fleet.CoordTest do
  use ExUnit.Case, async: false

  alias Fleet.Coord
  alias Fleet.EventRouter.Bus

  setup do
    Application.put_env(
      :fleet_coord,
      :spawner_backend,
      Fleet.Coord.HookSpawnerStub
    )

    Application.put_env(:fleet_coord, :stub_invocations, [])

    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:fleet_coord, :spawner_backend)
      Application.delete_env(:fleet_coord, :stub_invocations)
      Application.delete_env(:fleet_coord, :stub_response)
    end)

    :ok
  end

  describe "delegator API" do
    test "handle_decision/1 délégué à Policies" do
      decision = %{decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []}

      assert :ok = Coord.handle_decision(decision)
      assert_receive {_atom, %{"event_type" => "coord.notify.dashboard"}}, 500
    end

    test "handle_escalation/2 délégué à Policies" do
      assert :ok = Coord.handle_escalation(:pod_drift, %{"pod_id" => "p1"})
      assert_receive {_atom, %{"event_type" => "coord.escalate.human"}}, 500
    end

    test "invoke_soft_gate/4 délégué à SoftGate" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "pass"}})
      assert :pass = Coord.invoke_soft_gate(%{}, %{}, %{}, max_rounds: 1)
    end

    test "invoke_hook/2 délégué à Hook" do
      Application.put_env(:fleet_coord, :stub_response, {:ok, %{decision: "continue"}})
      assert :continue = Coord.invoke_hook(:before_next, %{})
    end
  end
end
