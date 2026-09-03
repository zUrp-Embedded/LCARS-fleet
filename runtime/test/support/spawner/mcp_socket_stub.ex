defmodule Fleet.Spawner.MCPSocketStub do
  @moduledoc false
  # Stub of the per-pod MCP socket provisioner — adopts the
  # `Fleet.Spawner.McpSocketProvisioner` behaviour (the contract of the `:mcp_socket_provisioner`
  # seam): the compiler checks that the stub stays conformant to the real contract (anti
  # lying-stub). Mirror of `Fleet.Spawner.LaunchBackend.StubBackend`: returns a path WITHOUT
  # creating a real `/run/lcars/...` socket (spawner tests neither pollute the system FS nor
  # depend on fleet_mcp). Test default set by config/test.exs, exactly like
  # `launch_backend: StubBackend`.
  #
  # The returned path lives under `System.tmp_dir!()` (never `/run/lcars`) and is NEVER
  # materialized: the stub does not touch the FS. `release_pod_socket/1` is a `:ok` no-op.

  @behaviour Fleet.Spawner.McpSocketProvisioner

  @doc """
  Returns `{:ok, socket_path}` (fictitious path under tmp, derived from the pod_id) WITHOUT creating a socket.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def ensure_pod_socket(pod_id, _tools) when is_binary(pod_id) and pod_id != "" do
    {:ok, Path.join([System.tmp_dir!(), "lcars-stub-mcp", pod_id, "sock"])}
  end

  @doc """
  Idempotent no-op (`:ok`) — the stub never created a socket to remove.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def release_pod_socket(pod_id) when is_binary(pod_id), do: :ok
end
