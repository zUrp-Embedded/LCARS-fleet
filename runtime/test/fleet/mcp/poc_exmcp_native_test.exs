defmodule Fleet.MCP.PoCExMCPNativeTest do
  @moduledoc """
  PoC (DN ring4/fleet_mcp.md §"SDK choice — empirical validation criterion").

  Decisive DN criterion: functional MCP round-trip + latency < 100 ms via the
  native BEAM transport. Validates the ExMCP (azmaveth) choice; if KO → switch
  to Hermes (the SDK wrap lives in `Fleet.MCP.PodTools` `use ExMCP.Server`,
  tools `get_work_item`/`submit_result` unchanged; F049 — `Fleet.MCP.Server`
  is only a boot guard now).

  Canonical native pattern (deps/ex_mcp/lib/ex_mcp/service.ex §Usage):
  `use ExMCP.Service, name: <atom>` — auto-registers `ExMCP.Native` in init/1,
  generates `handle_call({:mcp_request, %{"method"=>_,"params"=>_}}, ...)` which
  routes to the `handle_mcp_request/3` callback. `use ExMCP.Server` was the
  wrong mixin (HTTP/stdio transport, deftool DSL → `{:handle_tool_call,...}`,
  never `{:mcp_request,...}` → GenServer.call without a clause → 5 s timeout).
  Round-trip measured with `call/4` + `notify/3` via `:timer.tc`. D-LS-6 proof
  (real e2e measurement, not a claim).
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
    # use ExMCP.Service: register_service is called in init/1 (synchronous);
    # start_supervised! only returns after init → service already registered.
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
