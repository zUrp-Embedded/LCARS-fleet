defmodule Fleet.MCP.Application do
  @moduledoc """
  Application supervisor `fleet_mcp` — substrat MCP système-side.

  Le serveur MCP tourne hors bwrap ; le pod le consomme en CLIENT (pull/push).

  Au boot, délègue à `Fleet.MCP.Supervisor` :
    - `Fleet.MCP.Server` (garde de boot : refuse `start_link` côté pod ;
      ex-registre de channels push retiré, husk mort)
    - `Fleet.MCP.PodTools` (HTTP transport pour `get_task`/`submit_result`,
      démarré SSI `:pod_facing_port` configuré)

  Substrat channels MORT retiré : `Fleet.MCP.Bridge`
  (pont PubSub↔channels, re-broadcast vers 0 subscriber, channels push retirés)
  + sa cascade `Fleet.MCP.Schema` / `mcp-channels.yaml` / `mcp-channels-v1.json` (validation
  config jamais chargée au runtime, 0 caller après le retrait du Bridge). Le drive vit dans
  `PodTools` (pull). NB homonyme : le pont stdio→HTTP `bin/fleet_mcp_stdio_bridge.py`
  (transport drive, VIVANT) ≠ ces modules morts.

  Purge des channels push : retrait `Channel`, `ChannelHTTP`,
  `Channels.FleetControl/FleetForge`, `PushDispatcher`. PoC Channel Anthropic
  KO (4 itérations) → drive ré-implémenté via tools MCP pull
  (`get_task`/`submit_result`) + kick send-keys.

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`
  — portée par `Fleet.MCP.Supervisor`.

  ## Transport

  Le serveur tourne sur ExMCP.Native (round-trip validé empiriquement,
  pas de bascule Hermes). L'app délègue à
  `Fleet.MCP.Supervisor`. Containment : dans un pod
  (`boot_environment: :pod`) `Fleet.MCP.Server` refuse → l'app ne boote pas
  (substrat système-side hors bwrap, voulu).
  """

  use Application

  @impl true
  def start(_type, _args) do
    Fleet.MCP.Supervisor.start_link([])
  end
end
