# fleet_observation

**Date** : 2026-06-10
**Dernière révision** : 2026-07-18 (README → carte §2 : index-qui-pointe, contrat aux `@moduledoc` EN)
**Statut** : actif — observation deck read-only (surface)
**Référencé par** : —

Read / observability frontier (surface): serves an LCARS observation deck on a per-human
port. Read-only, no-auth, intra-release — it observes the fleet, mutates nothing (it depends
DOWN on the core; nothing in the core depends on it, and it never touches `fleet_starfleet`).

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Observation.Deck` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

- `Fleet.Observation.Deck` — `Plug.Router` CONTROLLER: routing + role-catalogue derivation + live snapshots; hands the data to the view
- `Fleet.Observation.Deck.View` — PURE HTML rendering (inline HTML/CSS/JS template); reads no source itself
- `Fleet.Observation.ReadModel` — GenServer + ETS, the single Bus subscriber; projects the `%Fleet.Event{}` stream, read via `projection/0` (direct ETS, never a third party's GenServer state)
- `Fleet.Observation.Application` — supervisor + Cowboy listener (per-human port, fail-loud if absent; gated in `:test`)

## Config & deps

- Knob `:fleet_observation, :http_port` — read by `Application`, set by `runtime.exs` from `LCARS_OBSERVATION_PORT` (per-human, `bin/fleet_v2`).
- Knobs `:start_listener` / `:start_readmodel` (default `true`; `false` in `:test`) — hermetic-test gates.
- Env `LCARS_BIND_HOST` (default `127.0.0.1`) — deck bind IP; local-only by default (frontier = network isolation, like `fleet_api`).
- Deps (see `use Boundary`): `fleet_spawner` (`list_pods/0`), `fleet_cap_profile` (role catalogue), `fleet_event_router` (Bus + listener), + `plug`/`plug_cowboy`/`jason`.
- `DESIGN-observabilite.md` — note de design **HISTORIQUE**/exploratoire, PAS l'autorité courante (décrit des mécaniques abandonnées : ports `:8089`/`:8090`, snapshot readiness dans le ReadModel). L'autorité observabilité = les `@moduledoc` (`Deck`, `ReadModel`) + le code.
