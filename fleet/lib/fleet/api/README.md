# Fleet.API — domain card

**Date**: 2026-07-12
**Last revised**: 2026-07-20
**Status**: active — external surface of the fleet (REST + WS + admin control socket)
**Referenced by**: —

The fleet's external surface. Client-agnostic: `bin/lcars`, health/readiness probes and
the observation deck are consumers among others, none coupled to the internals.

**No-auth by design** — the security contract is the container's network isolation, not an
app-level token. The one exception to "read-only over the network" is the admin write, which
is moved OFF TCP entirely (see invariants).

**This file is a map. Each module owns its contract in its own `@moduledoc` — read those
(`h Fleet.API` for the domain overview, then `h Fleet.API.<Module>`). Nothing here is
restated, only pointed at.**

## Invariants

- The public TCP surface is **read-only**. The single write, `POST /api/admin/spawn`, is served
  off TCP on a local AF_UNIX socket a pod on the shared network cannot reach — so a TCP client
  hitting that path gets a 404, not a write. Split proven in `Fleet.API.Rest` + `ControlRouter`.
- No app-level auth. Confidentiality of the admin socket rests on its `0600` mode; everything
  else rests on network/container isolation. A change to either is a security decision.

## Modules — read the `@moduledoc` for the contract

- `Fleet.API` — domain overview + vendor frontier (context module, no code)
- `Fleet.API.Rest` — the read-only TCP HTTP surface
- `Fleet.API.ControlRouter` — the admin write door, on the AF_UNIX socket
- `Fleet.API.WS` — the `/ws` WebSocket surface onto the PubSub bus
- `Fleet.API.SpawnAdmission` — the spawn-admission pipeline (pure functions)
- `Fleet.API.Readiness` — live operational state (anti-hollow-green)
- `Fleet.API.BuildInfo` — observable build stamp
- `Fleet.API.Application` — the domain supervisor + listener wiring

## Config & deps

Knobs and env vars are not inventoried here — they live where they are read (`config/runtime.exs`,
the `use Boundary` deps of `Fleet.API`) and drift if copied. The vendor frontier is N0 (see
`h Fleet.API`).
