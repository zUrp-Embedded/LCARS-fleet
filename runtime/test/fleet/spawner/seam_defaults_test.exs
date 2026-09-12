defmodule Fleet.Spawner.SeamDefaultsTest do
  @moduledoc """
  Verify the real MCP provisioner default independently of the configured test stub.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.McpSocketProvisioner

  test "MCPSocketProvisioner: the canonical default is the real fleet_mcp side" do
    # Read default/0 directly: deleting the global override could select the real provider
    # for a concurrently running pod test.
    assert McpSocketProvisioner.default() == Fleet.MCP.PodSocketSupervisor
  end

  test "MCPSocketProvisioner: a configured provisioner still WINS over the default" do
    assert McpSocketProvisioner.resolved() == Fleet.Spawner.MCPSocketStub

    refute McpSocketProvisioner.resolved() ==
             McpSocketProvisioner.default()
  end
end
