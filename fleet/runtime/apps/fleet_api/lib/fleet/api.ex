defmodule Fleet.API do
  @moduledoc """
  API publique LCARS v2 (Ring 4 — frontières externes) : REST + WS.

  **API agnostique du client** — le dashboard web v1.5 `:8090` est
  *un* consommateur parmi d'autres possibles, pas couplé à l'arch v2.

  ## Sous-modules

    * `Fleet.API.Rest` — Plug.Router HTTP `:8080` endpoints REST
      (GET pipelines/tickets/pods/health + POST admin/spawn) — lecture
      no-auth, écriture gardée (le HMAC `X-Auth-Token` a été RETIRÉ ;
      frontière = isolation réseau/container, cf. `Fleet.API.Rest` §Auth)
    * `Fleet.API.WS` — Cowboy WebSocket handler `:8080/ws` subscribe
      Phoenix.PubSub bus + filtre per-client topics + heartbeat 30s

  ## Split différé

  MVP : 1 app umbrella `fleet_api` unique (REST + WS dans même
  supervision). Pas de duplication subscribe bus, simplicité OTP
  supervision tree.

  **Différé** : split en `fleet_bus_socket` (irréductible côté
  event_router) + `fleet_rest_facade` (optionnel surcouche). Critère
  opérationnalisable post-implem **90 jours** : si 1er client observé
  consume bus NDJSON brut sans REST surcouche (ex CLI custom, autre
  dashboard expérimental, MCP server externe) → on splitte ; tant
  qu'aucun tel client n'existe, le split serait spéculatif.

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'inférence — orchestration via le bus
  PubSub ; aucune inférence vendor dans cette couche).
  """
end
