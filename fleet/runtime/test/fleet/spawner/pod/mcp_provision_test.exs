defmodule Fleet.Spawner.Pod.McpProvisionTest do
  # async: false — mutates the GLOBAL app-env `:mcp_socket_provisioner` (runtime seam).
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.McpProvision

  setup do
    prev = Application.get_env(:fleet_spawner, :mcp_socket_provisioner)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_spawner, :mcp_socket_provisioner, prev),
        else: Application.delete_env(:fleet_spawner, :mcp_socket_provisioner)
    end)

    :ok
  end

  test "R1-23: MISCONFIGURED provisioner (module without callbacks) → {:error, {:mcp_provisioner_misconfigured, _}}" do
    # `Enum` is a real module but does not export ensure_pod_socket/1. The seam being DUCK-TYPED, the
    # `function_exported?` guard detects it INSTEAD of letting `apply/3` raise an UndefinedFunctionError
    # that would crash the pod's gen_statem (class R1-21).
    Application.put_env(:fleet_spawner, :mcp_socket_provisioner, Enum)

    assert {:error, {:mcp_provisioner_misconfigured, Enum}} = McpProvision.ensure_pod_socket("p1")
  end

  test "R1-23: CONFORMING provisioner (test stub) → the guard is transparent ({:ok, path})" do
    # config/test.exs sets `Fleet.Spawner.MCPSocketStub` (conforming) → ensure passes the guard.
    pod = "p-conform-#{System.unique_integer([:positive])}"
    assert {:ok, _path} = McpProvision.ensure_pod_socket(pod)
  end
end
