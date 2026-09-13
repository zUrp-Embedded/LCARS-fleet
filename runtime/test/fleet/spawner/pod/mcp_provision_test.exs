defmodule Fleet.Spawner.Pod.McpProvisionTest do
  # Serial: the MCP provider override is application-global.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.McpProvision

  setup do
    prev = Application.get_env(:lcars_fleet, :spawner_mcp_socket_provisioner)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :spawner_mcp_socket_provisioner, prev),
        else: Application.delete_env(:lcars_fleet, :spawner_mcp_socket_provisioner)
    end)

    :ok
  end

  test "R1-23: MISCONFIGURED provisioner (module without callbacks) → {:error, {:mcp_provisioner_misconfigured, _}}" do
    # Enum loads successfully but lacks the provider callbacks, exercising conformance rejection.
    Application.put_env(:lcars_fleet, :spawner_mcp_socket_provisioner, Enum)

    assert {:error, {:mcp_provisioner_misconfigured, Enum}} = McpProvision.ensure_pod_socket("p1")
  end

  test "R1-23: CONFORMING provisioner (test stub) → the guard is transparent ({:ok, path})" do
    pod = "p-conform-#{System.unique_integer([:positive])}"
    assert {:ok, _path} = McpProvision.ensure_pod_socket(pod)
  end
end
