# Fleet.Observation — domain card

**Date**: 2026-06-10
**Last revised**: 2026-09-04
**Status**: active — read-only observation deck (surface)
**Referenced by**: —

Read / observability frontier (surface): serves an LCARS observation deck on a per-human
unix socket. Read-only, no-auth, intra-release — it observes the fleet, mutates nothing (it depends
DOWN on the core; nothing in the core depends on it, and it never touches the admiral domain).

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Observation.Deck` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

- `Fleet.Observation.Deck` — `Plug.Router` CONTROLLER: routing + role-catalogue derivation + live snapshots; hands the data to the view
- `Fleet.Observation.Deck.View` — PURE HTML rendering (inline HTML/CSS/JS template); reads no source itself
- `Fleet.Observation.ReadModel` — GenServer + ETS, the single Bus subscriber; projects the `%Fleet.Event{}` stream, read via `projection/0` (direct ETS, never a third party's GenServer state)
- `Fleet.Observation.Application` — supervisor + the deck's unix-socket listener (`Fleet.EventRouter.UnixListener` on `deck_socket/0`; gated in `:test`)

## Config & deps

- **Aucune molette de port** (6-072/6-098) : le deck n'a pas d'adresse. Il écoute sur
  `/run/lcars/console/<humain>/deck.sock`, chemin **dérivé** de l'humain qui lance le BEAM
  (`Application.deck_socket/0`) et jamais déclaré. Pas de `LCARS_OBSERVATION_PORT`, pas de
  `:observation_http_port`, pas même en option : une variable obligatoire dont la valeur ne sert à
  rien bloque un démarrage sans rien configurer.
- Knobs `:lcars_fleet, :observation_start_listener` / `:observation_start_readmodel` (default `true`; `false` in `:test`) — hermetic-test gates.
- No bind address: the deck has no IP to bind (`LCARS_BIND_HOST` concerns the event router's webhook listener, not this domain).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/observation.ex`) — this card points at it and does not copy it. A dependency list transcribed here goes stale the day an edge moves, and nothing goes red: boundary compiles the real one.
