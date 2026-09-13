defmodule Fleet.Spawner.MCPSocketStub do
  @moduledoc false
  # Test provisioner selected by config/test.exs; no real socket is created.

  @behaviour Fleet.Spawner.McpSocketProvisioner

  @doc """
  Returns a fictitious socket path under the temporary directory without filesystem I/O.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def ensure_pod_socket(pod_id, _tools) when is_binary(pod_id) and pod_id != "" do
    {:ok, Path.join([System.tmp_dir!(), "lcars-stub-mcp", pod_id, "sock"])}
  end

  @doc """
  No-op: the stub has no socket to release.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def release_pod_socket(pod_id) when is_binary(pod_id), do: :ok
end
