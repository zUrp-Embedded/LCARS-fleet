defmodule Fleet.MCP.Application do
  @moduledoc """
  Application supervisor `fleet_mcp` (Lot 1 — Ring 4 MCP substrat).

  DN : `ring4/fleet_mcp.md`.

  Au boot (post-PoC ExMCP validé) — délégué à `Fleet.MCP.Supervisor` :
    - `Fleet.MCP.Server` (GenServer : registry + lifecycle bas-débit sérialisés
      — PAS un goulot)
    - `Fleet.MCP.PodTools` (HTTP transport pour `get_task`/`submit_result`,
      démarré SSI `:pod_facing_port` configuré)

  Z7.3 / Z5 (MCP-D1, 2026-06-10) — substrat channels MORT retiré : `Fleet.MCP.Bridge`
  (pont PubSub↔channels, re-broadcast vers 0 subscriber, channels push retirés chantier 7)
  + sa cascade `Fleet.MCP.Schema` / `mcp-channels.yaml` / `mcp-channels-v1.json` (validation
  config jamais chargée au runtime, 0 caller après le retrait du Bridge). Le drive vit dans
  `PodTools` (pull). NB homonyme : le pont stdio→HTTP `bin/fleet_mcp_stdio_bridge.py`
  (transport drive, VIVANT) ≠ ces modules morts.

  BL-021 chantier 7 — purge ADR-G C5.1 : retrait `Channel`, `ChannelHTTP`,
  `Channels.FleetControl/FleetForge`, `PushDispatcher`. PoC Channel Anthropic
  KO 4 itérations 2026-05-27 → drive ré-implémenté via tools MCP pull
  (`get_task`/`submit_result`) + kick send-keys.

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
