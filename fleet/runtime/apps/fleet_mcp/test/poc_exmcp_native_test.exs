defmodule Fleet.MCP.PoCExMCPNativeTest do
  @moduledoc """
  Lot 1 PoC (plan-implementation.md §Lot 1 trigger 1 ; DN ring4/fleet_mcp.md
  §"Choix SDK — critère validation empirique").

  Critère décisif DN : round-trip MCP fonctionnel + latence < 100 ms via
  transport native BEAM. Valide le choix ExMCP (azmaveth) AVANT impl complète
  `apps/fleet_mcp/`. Si KO → bascule Hermes (le wrap SDK vit dans
  `Fleet.MCP.PodTools` `use ExMCP.Server`, tools `get_work_item`/`submit_result`
  inchangés ; F049 — `Fleet.MCP.Server` n'est plus qu'une garde de boot).

  Pattern canonique natif (deps/ex_mcp/lib/ex_mcp/service.ex §Usage) :
  `use ExMCP.Service, name: <atom>` — auto-register `ExMCP.Native` en init/1,
  génère `handle_call({:mcp_request, %{"method"=>_,"params"=>_}}, ...)` qui
  route vers le callback `handle_mcp_request/3`. `use ExMCP.Server` était le
  mauvais mixin (transport HTTP/stdio, DSL deftool → `{:handle_tool_call,...}`,
  jamais `{:mcp_request,...}` → GenServer.call sans clause → timeout 5 s).
  Mesure round-trip `call/4` + `notify/3` via `:timer.tc`. Preuve D-LS-6
  (mesure e2e réelle, pas claim).
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
    # use ExMCP.Service : register_service appelé dans init/1 (synchrone) ;
    # start_supervised! ne retourne qu'après init → service déjà enregistré.
    start_supervised!(PoCService)
    :ok
  end

  test "service native BEAM enregistré et disponible" do
    assert ExMCP.Native.service_available?(@service)
  end

  test "round-trip call/4 latence < 100 ms (critère décisif DN)" do
    {us, result} =
      :timer.tc(fn ->
        ExMCP.Native.call(@service, "tools/call", %{
          "name" => "ping",
          "arguments" => %{"echo" => "lot1"}
        })
      end)

    assert {:ok, %{"content" => [%{"text" => "pong:lot1"}]}} = result
    assert us < @threshold_us, "latence call #{us}µs ≥ seuil #{@threshold_us}µs (100 ms)"
  end

  test "push notify/3 (fire-and-forget) latence < 100 ms" do
    {us, result} =
      :timer.tc(fn ->
        ExMCP.Native.notify(@service, "notifications/message", %{"data" => "push-lot1"})
      end)

    assert :ok = result
    assert us < @threshold_us, "latence notify #{us}µs ≥ seuil #{@threshold_us}µs (100 ms)"
  end
end
