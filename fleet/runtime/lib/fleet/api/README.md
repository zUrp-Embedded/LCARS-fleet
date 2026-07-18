# fleet_api

**Date** : 2026-05-10
**Dernière révision** : 2026-07-18 (README → carte §2 : index-qui-pointe, contrat aux `@moduledoc` EN)
**Statut** : actif — API publique REST + WS (surface)
**Référencé par** : —

LCARS public API (external surface): REST + WS on a per-human port. Client-agnostic
(consumers: `bin/lcars`, health/readiness probes). **No-auth by design** — the security contract
is the container's network isolation, not an app-level token (see `Fleet.API.Rest` § Auth).

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.API` in IEx, or `lib/`). Nothing here is restated,
only pointed at.

## Modules

- `Fleet.API` — context moduledoc (REST + WS overview, vendor frontier); no code
- `Fleet.API.Rest` — `Plug.Router` HTTP: no-auth reads (health/version/readiness) + maps spawn-admission verdicts to HTTP statuses
- `Fleet.API.WS` — Cowboy WebSocket `/ws`: PubSub subscribe + per-client topic filter + 30s heartbeat
- `Fleet.API.SpawnAdmission` — the `POST /api/admin/spawn` admission pipeline (DTO allowlist → path-safe `pod_id` → cap-profile → host-native fail-closed → brief-required, mirror of R18); pure functions
- `Fleet.API.Readiness` — LIVE operational state (anti-hollow-green); `deep/0` → `operational|degraded` + subsystems
- `Fleet.API.BuildInfo` — observable build stamp (`current/0` → `sha`/`dirty`/`ref`/`source`); total, memoized
- `Fleet.API.Application` — `:one_for_one` supervisor; starts the Cowboy listener; `post_boot/0` = build-info trace (sd_notify retired, acte4 A-14)

## Config & deps

- Knob `:fleet_api, :http_port` — Cowboy port, `fetch_env!` fail-loud (A7); set by `runtime.exs` from `FLEET_API_PORT` (per-human, `bin/fleet_v2`); `0` in `:test`.
- Knob `:fleet_api, :start_listener` (default `true`; `false` in `:test` — REST via `Plug.Test`, WS via direct callbacks).
- Env `LCARS_BIND_HOST` (default `127.0.0.1`) — listener bind IP; local-only by default (frontier = network isolation).
- Deps (all descending — see `use Boundary`): `fleet_event_router` (Bus + listener), `fleet_pilot` (readiness step probe), `fleet_mcp` (readiness pod-facing probe), `fleet_spawner` (admission + backend), `fleet_starfleet` (shutdown dispatcher), `fleet_cap_profile` (cap-profile validation), + `plug`/`plug_cowboy`/`jason`.
- Vendor frontier: N0 (vendor-agnostic). Split (D1): deferred — see design note `fleet_api.md`.
