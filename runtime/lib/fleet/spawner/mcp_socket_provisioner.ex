defmodule Fleet.Spawner.McpSocketProvisioner do
  @moduledoc """
  Consumer-owned behaviour for the runtime MCP socket seam. Runtime resolution
  avoids an upward compile dependency from spawner to MCP; the real MCP provider
  therefore implements this contract by duck typing.
  """

  @doc """
  Creates the pod listener and returns its host socket path before launch.
  Repeated calls return the same path without duplicating the listener. The socket
  file must exist on success so the launcher can bind it into the sandbox.
  """
  @callback ensure_pod_socket(pod_id :: String.t(), tools :: [String.t()]) ::
              {:ok, Path.t()} | {:error, term()}

  @doc """
  Stops the listener and removes the socket file; closing the FD alone leaves it behind.
  Already-released pods return `:ok`. Incomplete cleanup returns
  `{:error, {:release_incomplete, _}}`; SocketWarden can reap the residual.
  """
  @callback release_pod_socket(pod_id :: String.t()) :: :ok | {:error, term()}

  # A module atom avoids a compile-time remote call across the spawner/MCP boundary.
  @default_provisioner Fleet.MCP.PodSocketSupervisor

  @doc """
  Returns `:spawner_mcp_socket_provisioner` or the canonical `default/0`.
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:lcars_fleet, :spawner_mcp_socket_provisioner, default())
  end

  @doc """
  Returns the canonical provider independently of configuration.
  Exposed so tests can verify the production fallback without deleting a global
  stub override and selecting the real provider for concurrent pod tests.
  """
  @spec default() :: module()
  def default, do: @default_provisioner
end
