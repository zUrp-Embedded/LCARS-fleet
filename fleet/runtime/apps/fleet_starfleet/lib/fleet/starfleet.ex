defmodule Fleet.Starfleet do
  @moduledoc """
  Module système-side consommateur des outputs des pods d'arbitrage
  (gatekeeper + autres rôles décisionnels) côté core LCARS Ring 2.

  **Pas de pod, pas d'inférence dans ce module** — validation, parsing,
  audit, escalade Cat 5 seulement.

  ## Sous-modules

    * `Fleet.Starfleet.Application` — superviseur de l'app (consumers gated
      par config : hermétisme test)
    * `Fleet.Starfleet.Decision` — struct sortie validate
    * `Fleet.Starfleet.Gatekeeper` — pure functions validation JSON
      décision (PoC-π3 figé `{decision, reason, details, chain}`)
    * `Fleet.Starfleet.DriftMonitor` — GenServer subscribe `fleet.events`,
      4 handlers (`pod.drift`, `workflow_map.failed`, `oauth.refresh.failed`,
      `audit.verdict`)
    * `Fleet.Starfleet.Cat5Escalator` — pure functions escalade Cat 5 :
      broadcast canon `starfleet.audit_cat5_<source>` + délégation `CoordBackend`
    * `Fleet.Starfleet.AuditLog` — pure functions wrapper `File.write`
      non-bang fail-safe, NDJSON rotaté (défaut `~/.lcars/log/fleet-starfleet.jsonl`,
      knob `:audit_log_path`)
    * `Fleet.Starfleet.CoordBackend` — seam wrap `Fleet.Coord` ch14
      (default `NotWiredYet`)
    * `Fleet.Starfleet.AuditConsumer` — consumer Bus du rail AUDIT
      (lifecycle + sécurité, préfixe de log `AUDIT <event.type>`)
    * `Fleet.Starfleet.BootOrchestrator` — orchestrateur post-readiness
      (Task `:transient`, émet `fleet.boot_complete`/`boot_partial`/`boot_failed`)
    * `Fleet.Starfleet.Shutdown` (+ behaviour `Shutdown.Dispatcher`,
      `NoOpDispatcher`, `AggregateDispatcher`) — quiesce + drain borné du BEAM
    * `Fleet.Starfleet.MCPMonitor` — health check passif du substrat MCP
      pod-facing (`Fleet.MCP.PodSocketSupervisor`)
    * `Fleet.Starfleet.MCPWatcher` — cron passif : drift de version upstream
      du SDK MCP Elixir sur Hex.pm
    * `Fleet.Starfleet.PeriodicCheck` — plomberie partagée des checks
      périodiques (`MCPMonitor`, `MCPWatcher`)

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'appel SDK direct).
  """
end
