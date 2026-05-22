defmodule Fleet.MCP.Application do
  @moduledoc """
  Application supervisor `fleet_mcp` (Lot 1 — Ring 4 MCP substrat).

  DN : `ring4/fleet_mcp.md` + `ring4/mcp-channels-substrate.md`.

  Au boot (post-PoC ExMCP validé) — délégué à `Fleet.MCP.Supervisor` :
    - `Fleet.MCP.Server` (GenServer : registry channels + lifecycle ;
      registration/list bas-débit sérialisés — PAS un goulot ; broadcast =
      Phoenix.PubSub fan-out, JAMAIS via le GenServer — anti-goulot DN)
    - `Fleet.MCP.Bridge` (GenServer : subscribe Phoenix.PubSub bus interne ↔
      re-broadcast MCP channels, config-driven `mcp-bridge.yaml`)
    - `Fleet.MCP.Channel` / `FleetControl` / `FleetForge` / `Schema` = behaviour +
      fonctions pures (zéro process — Iron Law)

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` (DN fleet_mcp.md
  §Lifecycle) — portée par `Fleet.MCP.Supervisor`.

  ## État Lot 1 — PoC PASS → impl complète (DN trigger §2)

  PoC ExMCP.Native **PROVEN** (round-trip + push < 100 ms, suite GREEN) →
  ExMCP validé empiriquement, pas de bascule Hermes. L'app délègue à
  `Fleet.MCP.Supervisor`. Conformance ADR-C : dans un pod
  (`boot_environment: :pod`) `Fleet.MCP.Server` refuse → l'app ne boote pas
  (substrat système-side hors-bwrap, voulu).
  """

  use Application

  @impl true
  def start(_type, _args) do
    Fleet.MCP.Supervisor.start_link([])
  end
end
