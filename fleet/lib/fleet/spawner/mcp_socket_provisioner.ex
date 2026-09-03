defmodule Fleet.Spawner.McpSocketProvisioner do
  @moduledoc """
  Consumer-owned behaviour for the runtime MCP socket seam. Runtime resolution
  avoids an upward compile dependency from spawner to MCP; the real MCP provider
  therefore implements this contract by duck typing.
  """

  @doc """
  ENSURE (before the launch): creates this pod's listener + socket file and
  returns the HOST PATH of the socket file. Idempotent (re-call → same path,
  no duplicate). The file MUST exist on return: otherwise the bwrap bind would
  fail (the launcher mounts the socket into the pod's sandbox).
  """
  @callback ensure_pod_socket(pod_id :: String.t(), tools :: [String.t()]) ::
              {:ok, Path.t()} | {:error, term()}

  @doc """
  RELEASE (teardown): stops the listener AND removes the socket file (closing the
  socket frees the FD, NOT the file). Idempotent — releasing an already-freed
  pod returns `:ok`; a release that could NOT fully clean up (terminate/rm failed)
  returns `{:error, {:release_incomplete, _}}` so the failure is not silently lost
  (the SocketWarden still reaps the residual at runtime).
  """
  @callback release_pod_socket(pod_id :: String.t()) :: :ok | {:error, term()}

  # Canonical default: the real impl on the fleet_mcp side. Literal atom (not a
  # literal remote call) → no compile-time dep. Set HERE once.
  @default_provisioner Fleet.MCP.PodSocketSupervisor

  @doc """
  Resolved provisioner: config `:lcars_fleet, :spawner_mcp_socket_provisioner` otherwise the
  canonical default `Fleet.MCP.PodSocketSupervisor`. SINGLE SOURCE of the default (same
  pattern as `Fleet.Spawner.LaunchBackend.resolved/0`) — the only runtime reader
  is `Pod.McpProvision`, any future reader goes through here instead of re-declaring.
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:lcars_fleet, :spawner_mcp_socket_provisioner, default())
  end

  @doc """
  The canonical default, PUBLIC because it is part of the seam's contract rather than an
  implementation detail.

  Left private, changing this attribute leaves the whole suite green — only a mutation shows it,
  because `config/test.exs` pins a stub here and no test ever sees the fallback. Asserting it
  through `resolved/0` would mean DELETING the key globally, which under an
  async suite hands the real provisioner to whatever pod test happens to be running — a hazard
  bought to test a constant. Exposing the value costs one function and no risk.
  """
  @spec default() :: module()
  def default, do: @default_provisioner
end
