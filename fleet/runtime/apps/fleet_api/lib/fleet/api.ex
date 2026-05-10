defmodule Fleet.Api do
  @moduledoc """
  API publique LCARS v2 (Ring 4 — frontières externes) : REST + WS.

  **API agnostique du client** — le dashboard web v1.5 `:8090` est
  *un* consommateur parmi d'autres possibles, pas couplé à l'arch v2.

  ## Sous-modules

    * `Fleet.Api.Rest` — Plug.Router HTTP `:8080` endpoints REST
      (GET pipelines/tickets/pods/health + POST admin/spawn,
      config/update, relay/:ref) + auth HMAC token header
    * `Fleet.Api.Ws` — Cowboy WebSocket handler `:8080/ws` subscribe
      Phoenix.PubSub bus + filtre per-client topics + heartbeat 30s
    * `Fleet.Api.RelayHandler` — GenServer subscribe
      `permission_relay_request` event, ETS pending refs, POST
      `/api/relay/:ref` → broadcast `permission_relay_response`
      matching ref (round-trip ch10)
    * `Fleet.Api.GitCommitter` — pure functions wrapper atomic write
      rename + `git add` + `git commit` (canon trace strate 1)

  ## D1 décidé (split deferred)

  MVP : 1 app umbrella `fleet_api` unique (REST + WS dans même
  supervision). Pas de duplication subscribe bus, simplicité OTP
  supervision tree.

  **Deferred** : split en `fleet_bus_socket` (irréductible côté
  event_router) + `fleet_rest_facade` (optionnel surcouche). Critère
  opérationnalisable post-implem **90 jours** : si 1er client observé
  consume bus NDJSON brut sans REST surcouche (ex CLI custom, autre
  dashboard expérimental, MCP server externe) → ADR + amendement
  design note. Référence : `architecture-cible.md` §L368 + §L791.

  ## Frontière vendor

  N0 (vendor-agnostic, pas d'inférence — orchestration via PubSub bus
  ch11 PROMOTED).
  """
end
