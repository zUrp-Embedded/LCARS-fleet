defmodule Fleet.ClaudeBridge.MCPRouterTest do
  use ExUnit.Case, async: false

  alias Fleet.ClaudeBridge.MCPRouter
  alias Fleet.ClaudeBridge.StubBackends

  setup do
    original = Application.get_env(:fleet_claude_bridge, :event_router_backend)

    on_exit(fn ->
      if original do
        Application.put_env(:fleet_claude_bridge, :event_router_backend, original)
      else
        Application.delete_env(:fleet_claude_bridge, :event_router_backend)
      end
    end)

    :ok
  end

  describe "default backend (NotWiredYet, fleet_event_router chantier 11 pas câblé)" do
    test "route_mcp_request/1 retourne {:error, :not_wired_yet}" do
      Application.delete_env(:fleet_claude_bridge, :event_router_backend)

      request = %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{}}
      assert {:error, :not_wired_yet} = MCPRouter.route_mcp_request(request)
    end
  end

  describe "dispatch via stub backend" do
    test "route_mcp_request/1 dispatch :mcp_request topic + payload intact" do
      Application.put_env(:fleet_claude_bridge, :event_router_backend, StubBackends.MCPDispatcher)

      request = %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"x" => 1}}
      assert :ok = MCPRouter.route_mcp_request(request)
      assert_received {:dispatched, :mcp_request, ^request}
    end

    test "route_mcp_request/1 propage erreur backend" do
      Application.put_env(:fleet_claude_bridge, :event_router_backend, StubBackends.MCPFailing)

      assert {:error, :stub_fail} =
               MCPRouter.route_mcp_request(%{
                 "jsonrpc" => "2.0",
                 "method" => "x",
                 "params" => %{}
               })
    end
  end
end
