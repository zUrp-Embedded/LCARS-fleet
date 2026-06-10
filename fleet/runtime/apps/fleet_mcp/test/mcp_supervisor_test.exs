defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Z7.3 (2026-06-10) — remplace l'ex-`mcp_bridge_supervisor_test.exs` (dont ~90 %
  testait le `Fleet.MCP.Bridge` mort, retiré MCP-D1). Ne garde que le smoke
  d'intégration utile : l'umbrella a booté `Fleet.MCP.Supervisor` + son seul enfant
  permanent `Fleet.MCP.Server` (PodTools = SSI `:pod_facing_port`, absent en test).
  La conformance ADR-C `Server` refuse `:pod` est couverte par `mcp_server_test.exs`.
  """
  use ExUnit.Case, async: false

  test "Supervisor umbrella : Server vivant (boot host), plus de Bridge" do
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    # Bridge retiré (husk mort) — ne doit plus être dans l'arbre.
    assert Process.whereis(Fleet.MCP.Bridge) == nil
  end
end
