defmodule Fleet.Starfleet do
  @moduledoc """
  Module système-side consommateur des outputs des pods d'arbitrage
  (gatekeeper + autres rôles décisionnels) côté core LCARS Ring 2.

  **Pas de pod, pas d'inférence dans ce module** — validation, parsing,
  audit, escalade Cat 5 seulement.

  ## Sous-modules

    * `Fleet.Starfleet.Decision` — struct sortie validate
    * `Fleet.Starfleet.Gatekeeper` — pure functions validation JSON
      décision (PoC-π3 figé `{decision, reason, details, chain}`)
    * `Fleet.Starfleet.DriftMonitor` — GenServer subscribe `fleet.events`,
      4 handlers (`pod_drift`, `workflow_map.failed`, `oauth.refresh.failed`,
      `audit.verdict`)
    * `Fleet.Starfleet.Cat5Escalator` — pure functions broadcast
      `audit.cat5.<source>` + délégation `CoordBackend` ch14
    * `Fleet.Starfleet.AuditLog` — pure functions wrapper `File.write`
      non-bang fail-safe sur `/var/log/fleet-starfleet.jsonl`
    * `Fleet.Starfleet.CoordBackend` — seam wrap `Fleet.Coord` ch14
      (default `NotWiredYet`)

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'appel SDK direct).
  """
end
