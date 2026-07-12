defmodule Fleet.Spawner.Pod.McpProvisionTest do
  # async: false — mute l'app-env GLOBAL `:mcp_socket_provisioner` (seam runtime).
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

  test "R1-23 : provisioner MISCONFIGURÉ (module sans callbacks) → {:error, {:mcp_provisioner_misconfigured, _}}" do
    # `Enum` est un vrai module mais n'exporte pas ensure_pod_socket/1. Le seam étant DUCK-TYPED, la garde
    # `function_exported?` le détecte AU LIEU de laisser `apply/3` lever un UndefinedFunctionError qui
    # crasherait le gen_statem du pod (classe R1-21).
    Application.put_env(:fleet_spawner, :mcp_socket_provisioner, Enum)

    assert {:error, {:mcp_provisioner_misconfigured, Enum}} = McpProvision.ensure_pod_socket("p1")
  end

  test "R1-23 : provisioner CONFORME (stub de test) → la garde est transparente ({:ok, path})" do
    # config/test.exs pose `Fleet.Spawner.MCPSocketStub` (conforme) → ensure passe la garde.
    pod = "p-conform-#{System.unique_integer([:positive])}"
    assert {:ok, _path} = McpProvision.ensure_pod_socket(pod)
  end
end
