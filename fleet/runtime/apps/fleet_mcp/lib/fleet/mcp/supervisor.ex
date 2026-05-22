defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Superviseur racine `fleet_mcp` (DN ring4/fleet_mcp.md §"Contrat
  technique" `Fleet.MCP.Supervisor` + §Lifecycle).

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` (DN).
  Enfants : `Fleet.MCP.Server` (registry/lifecycle opaque) +
  `Fleet.MCP.Bridge` (pont Phoenix.PubSub ↔ MCP channels). Les channels
  (`FleetControl`/`FleetForge`/`Schema`) sont des modules purs/behaviours
  — **aucun process** (Iron Law), pas d'enfant.

  Conformance ADR-C (DN D7-bis) : si `boot_environment == :pod`,
  `Fleet.MCP.Server.start_link/1` renvoie `{:error, :forbidden_in_pod}` →
  l'enfant échoue → ce superviseur échoue → `fleet_mcp` ne boote pas dans
  un pod. Comportement voulu (substrat système-side hors-bwrap).
  Phoenix.PubSub `Fleet.PubSub` est démarré par `fleet_event_router`
  (chantier 11) — dépendance umbrella, non démarré ici (pas de double-start).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {Fleet.MCP.Server, opts},
      {Fleet.MCP.Bridge, opts}
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
