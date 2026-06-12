defmodule Fleet.MCP.ServerBehaviour do
  @moduledoc """
  Contrat opaque du serveur MCP (DN ring4/fleet_mcp.md §"Contrat technique").

  4 fonctions publiques — internals SDK cachés (discipline #2 wrap
  systématique). Behaviour exposé
  pour tests/mocks + bascule SDK ultérieure (ExMCP → Hermes) sans casser les
  apps consommatrices : interface inchangée, impl SDK changée.
  """

  @callback start_link(opts :: keyword()) :: GenServer.on_start() | {:error, term()}
  @callback register_channel(channel_name :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback list_channels() :: [String.t()]
  @callback stop() :: :ok
end
