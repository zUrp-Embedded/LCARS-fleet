defmodule Fleet.Spawner.MCPSocketStub do
  @moduledoc false
  # Stub du provisionneur de socket MCP per-pod — adopte le behaviour
  # `Fleet.Spawner.McpSocketProvisioner` (le contrat du seam `:mcp_socket_provisioner`) : le
  # compilateur vérifie que le stub reste conforme au contrat réel (anti stub-menteur). Mirror de
  # `Fleet.Spawner.LaunchBackend.StubBackend` : rend un chemin SANS créer de vrai socket `/run/lcars/...`
  # (les tests spawner ne polluent pas le FS système ni ne dépendent de fleet_mcp). Défaut test posé par
  # config/test.exs, exactement comme `launch_backend: StubBackend`.
  #
  # Le chemin rendu vit sous `System.tmp_dir!()` (jamais `/run/lcars`) et n'est JAMAIS matérialisé : le
  # stub ne touche pas le FS. `release_pod_socket/1` est un no-op `:ok`.

  @behaviour Fleet.Spawner.McpSocketProvisioner

  @doc """
  Rend `{:ok, socket_path}` (chemin fictif sous tmp, dépendant du pod_id) SANS créer de socket.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def ensure_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    {:ok, Path.join([System.tmp_dir!(), "lcars-stub-mcp", pod_id, "sock"])}
  end

  @doc """
  No-op idempotent (`:ok`) — le stub n'a jamais créé de socket à retirer.
  """
  @impl Fleet.Spawner.McpSocketProvisioner
  def release_pod_socket(pod_id) when is_binary(pod_id), do: :ok
end
