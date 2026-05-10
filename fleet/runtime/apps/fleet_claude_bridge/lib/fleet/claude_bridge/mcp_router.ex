defmodule Fleet.ClaudeBridge.MCPRouter do
  @moduledoc """
  D3 décidé : MCP **stdio externe** (DSL `MCP.Server` SDK BYPASS).

  PoC-4 PROVEN : MCP stdio externe gratuit, portabilité préservée.
  Les `fleet_*` tools restent process séparés MCP standard, le DSL
  `MCP.Server` SDK n'est pas utilisé.

  `route_mcp_request/1` route les requests `mcp_message/control_request`
  vers `Fleet.EventRouter` (chantier 11 `fleet_event_router`) PubSub
  bus. Default backend retourne `:not_wired_yet` jusqu'à ce que
  `fleet_event_router` soit câblé.
  """

  defmodule Backend do
    @moduledoc """
    Behaviour pour le backend dispatch events MCP.
    """

    @callback dispatch(topic :: atom(), payload :: term()) ::
                :ok | {:error, term()}
  end

  @doc """
  Route une MCP request vers le bus events.

  ## Inputs

    * `request` — map avec au moins `"jsonrpc"` + `"method"` + `"params"`
      (MCP protocol shape)

  ## Returns

    * `:ok` si dispatch OK
    * `{:error, reason}` sinon (incl. `:not_wired_yet` tant que
      `fleet_event_router` chantier 11 pas câblé)
  """
  @spec route_mcp_request(map()) :: :ok | {:error, term()}
  def route_mcp_request(request) when is_map(request) do
    backend().dispatch(:mcp_request, request)
  end

  defp backend do
    Application.get_env(
      :fleet_claude_bridge,
      :event_router_backend,
      Fleet.ClaudeBridge.MCPRouter.NotWiredYet
    )
  end
end

defmodule Fleet.ClaudeBridge.MCPRouter.NotWiredYet do
  @moduledoc false

  @behaviour Fleet.ClaudeBridge.MCPRouter.Backend

  @impl Fleet.ClaudeBridge.MCPRouter.Backend
  def dispatch(_topic, _payload), do: {:error, :not_wired_yet}
end
