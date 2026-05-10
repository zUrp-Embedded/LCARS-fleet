defmodule Fleet.Spawner.LaunchBackend.PortBackend do
  @moduledoc """
  Default `LaunchBackend` placeholder pour run #3.1.

  Le backend Port.open réel sera wiré au chantier 7
  (`fleet_pod_runtime`) où le NDJSON streaming intra-pod est parsé en
  continu. Au chantier 6 (ce module), nous fournissons le contrat
  d'interface et un placeholder explicite `:not_wired_yet` pour ne
  pas couper la compile chain (cohérent ch3 backends `ClaudeCodeBackend`).

  Les tests swappent via `:fleet_spawner, :launch_backend,
  Fleet.Spawner.LaunchBackend.StubBackend` pour exercer le state
  machine du Pod GenServer sans dépendance bwrap/claude réels.
  """

  @behaviour Fleet.Spawner.LaunchBackend

  @impl Fleet.Spawner.LaunchBackend
  def launch(_args, _env) do
    {:error, :not_wired_yet}
  end
end
