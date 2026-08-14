# Fleet.Observation — domain card

**Date**: 2026-06-10
**Last revised**: 2026-08-13
**Status**: active — read-only observation deck (surface)
**Referenced by**: —

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

- **Aucune molette de port** (6-072/6-098) : le deck n'a pas d'adresse. Il écoute sur
  `/run/lcars/console/<humain>/deck.sock`, chemin **dérivé** de l'humain qui lance le BEAM
  (`Application.deck_socket/0`) et jamais déclaré. `LCARS_OBSERVATION_PORT` et
  `:observation_http_port` ont été **retirées**, pas rendues optionnelles : une variable obligatoire
  dont la valeur ne sert à rien bloque un démarrage sans rien configurer.
- Knobs `:start_listener` / `:start_readmodel` (default `true`; `false` in `:test`) — hermetic-test gates.
- Env `LCARS_BIND_HOST` (default `127.0.0.1`) — deck bind IP; local-only by default (frontier = network isolation, like `fleet_api`).
- Deps (see `use Boundary`): `fleet_spawner` (`list_pods/0`), `fleet_cap_profile` (role catalogue), `fleet_event_router` (Bus + listener), + `plug`/`plug_cowboy`/`jason`.
- `DESIGN-observabilite.md` — note de design **HISTORIQUE**/exploratoire, PAS l'autorité courante (décrit des mécaniques abandonnées : ports `:8089`/`:8090`, snapshot readiness dans le ReadModel). L'autorité observabilité = les `@moduledoc` (`Deck`, `ReadModel`) + le code.
