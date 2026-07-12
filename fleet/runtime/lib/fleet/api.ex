defmodule Fleet.API do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports: :all = 1ʳᵉ passe
  # (serrage par façade en Z4b). Le compilateur refuse toute violation — plus de discipline.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Shutdown.Quiesce,
      Fleet.CapProfile,
      Fleet.EventRouter,
      Fleet.MCP,
      Fleet.Pilot,
      Fleet.Spawner,
      Fleet.Starfleet
    ],
    exports: :all
  @moduledoc """
  LCARS v2 public API (Ring 4 — external boundaries): REST + WS.

  **Client-agnostic API** — the v1.5 `:8090` web dashboard is *one*
  possible consumer among others, not coupled to the v2 arch.

  ## Sub-modules

    * `Fleet.API.Rest` — Plug.Router HTTP REST endpoints (per-human port, laid down by bin/fleet_v2)
      (GET workflow_runs/issues/pods/health + POST admin/spawn) — no-auth
      reads, guarded writes (the `X-Auth-Token` HMAC was REMOVED;
      boundary = network/container isolation, cf. `Fleet.API.Rest` §Auth)
    * `Fleet.API.WS` — Cowboy WebSocket handler `:<port>/ws` (per-human port, bin/fleet_v2) subscribes
      the Phoenix.PubSub bus + per-client topic filter + 30s heartbeat

  ## Deferred split

  MVP: 1 single `fleet_api` umbrella app (REST + WS in the same
  supervision). No duplicated bus subscribe, OTP supervision-tree
  simplicity.

  **Deferred**: split into `fleet_bus_socket` (irreducible on the
  event_router side) + `fleet_rest_facade` (optional overlay).
  Operationalizable post-implementation criterion **90 days**: if the
  first observed client consumes the raw NDJSON bus without the REST
  overlay (e.g. custom CLI, another experimental dashboard, external MCP
  server) → we split; as long as no such client exists, the split would
  be speculative.

  ## Vendor boundary

  N0 (vendor-agnostic, no inference — orchestration via the PubSub bus;
  no vendor inference in this layer).
  """
end
