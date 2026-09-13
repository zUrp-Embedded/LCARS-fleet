defmodule Fleet.MCP.PoCExMCPNativeTest do
  @moduledoc """
  ExMCP native-transport smoke test with a local BEAM service and a 100 ms threshold.
  Service uses ExMCP.Service's mcp_request handler; ExMCP.Server's tool DSL has a different
  dispatch shape. This does not measure the production AF_UNIX/stdio path.

  Call timing includes the reply. Notify timing covers lookup and asynchronous cast only,
  not notification processing or delivery. The original SDK-choice criterion is documented
  in ring4/fleet_mcp.md; these single samples are not a latency distribution.
  """
  use ExUnit.Case, async: false

  defmodule PoCService do
    use ExMCP.Service, name: :fleet_mcp_poc_lot1

    @impl true
    def handle_mcp_request(
          "tools/call",
          %{"name" => "ping", "arguments" => %{"echo" => echo}},
          state
        ) do
      {:ok, %{"content" => [%{"type" => "text", "text" => "pong:" <> echo}]}, state}
    end

    def handle_mcp_request("list_tools", _params, state) do
      tools = [
        %{
          "name" => "ping",
          "description" => "PoC latency ping",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"echo" => %{"type" => "string"}}
          }
        }
      ]

      {:ok, %{"tools" => tools}, state}
    end

    def handle_mcp_request(method, _params, state) do
      {:error, %{"code" => -32_601, "message" => "Method not found: " <> method}, state}
    end
  end

  @threshold_us 100_000
  @service :fleet_mcp_poc_lot1

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    # Service registration runs synchronously in init before start_supervised returns.
    start_supervised!(PoCService)
    :ok
  end

  test "native BEAM service registered and available" do
    assert ExMCP.Native.service_available?(@service)
  end

  test "call/4 round-trip latency < 100 ms (decisive DN criterion)" do
    {us, result} =
      :timer.tc(fn ->
        ExMCP.Native.call(@service, "tools/call", %{
          "name" => "ping",
          "arguments" => %{"echo" => "lot1"}
        })
      end)

    assert {:ok, %{"content" => [%{"text" => "pong:lot1"}]}} = result
    assert us < @threshold_us, "call latency #{us}µs ≥ threshold #{@threshold_us}µs (100 ms)"
  end

  test "push notify/3 (fire-and-forget) latency < 100 ms" do
    {us, result} =
      :timer.tc(fn ->
        ExMCP.Native.notify(@service, "notifications/message", %{"data" => "push-lot1"})
      end)

    assert :ok = result
    assert us < @threshold_us, "notify latency #{us}µs ≥ threshold #{@threshold_us}µs (100 ms)"
  end
end
