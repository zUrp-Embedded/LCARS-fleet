defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Integration smoke of the `fleet_mcp` root supervisor: the umbrella booted
  `Fleet.MCP.Supervisor` + its permanent children — `Fleet.MCP.Server` (boot
  guard), the `Fleet.MCP.PodSocketRegistry` `Registry`, and the socket-acceptor
  DynamicSupervisor `Fleet.MCP.PodSocketSupervisor` (started host-side
  unconditionally, with no socket at all as long as no pod is provisioned).
  """
  use ExUnit.Case, async: false

  test "umbrella Supervisor: Server + pod-facing socket substrate alive, no more Bridge" do
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketRegistry))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketSupervisor))
    # Bridge removed (dead husk) — must no longer be in the tree.
    assert Process.whereis(Fleet.MCP.Bridge) == nil
  end

  describe "pod_facing_status/0 — probes the PROCESS (the acceptor DynamicSupervisor), not a knob" do
    test ":operational when the acceptor DynamicSupervisor runs (host-side)" do
      assert {:operational, detail} = Fleet.MCP.Supervisor.pod_facing_status()
      assert detail.acceptor_supervisor == true
      # No pod provisioned in the ambient test env → zero active acceptor/socket.
      assert detail.sockets == 0
    end

    test ":unknown when the on-disk cross-check cannot run — fail-closed, never a hollow :operational" do
      # Force the socket scan to raise (a non-path base makes Path.join/wildcard raise) → the
      # deaf-pod cross-check could not run. The acceptor DynamicSupervisor is alive in the ambient
      # test env, so we reach the cross-check. The status must NOT read :operational.
      prev = Application.get_env(:fleet_mcp, :sock_base)
      Application.put_env(:fleet_mcp, :sock_base, 123)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:fleet_mcp, :sock_base, prev),
          else: Application.delete_env(:fleet_mcp, :sock_base)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:unknown, detail} = Fleet.MCP.Supervisor.pod_facing_status()
          assert detail.acceptor_supervisor == true
          assert detail.note =~ "could not run"
        end)

      assert log =~ "scan FAILED"
    end
  end
end
