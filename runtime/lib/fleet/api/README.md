# Fleet.API — domain card

**Date**: 2026-07-12
**Last revised**: 2026-09-04
**Status**: active — the fleet's admin write door (AF_UNIX control socket; no TCP surface)
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

- **Il n'y a pas de surface publique.** Ce domaine ne sert qu'une chose : la porte d'écriture
  `POST /api/admin/spawn`, sur une socket AF_UNIX locale qu'un pod du réseau partagé ne peut pas
  atteindre. Aucune surface TCP, ni REST ni WebSocket.
- La confidentialité de la socket d'admin repose sur son mode `0600`. La changer est une décision de
  sécurité.

## Pourquoi il n'y a pas de listener TCP — et pourquoi ne pas en ajouter un

Un listener TCP ici n'aurait **aucune capacité propre** (mesuré, 2026-08-14) :

- les lectures d'état (`pods`, `issues`, `workflow_runs`) sont l'autorité de `Fleet.Observation`,
  servie sur socket — une route ici ne pourrait que renvoyer vers elle ;
- un flux d'événements sur le réseau serait **complet et sans authentification**, capture d'écran
  tmux d'un pod comprise ;
- `health` / `readiness` / `version` ont un **jumeau CLI** : `fleet version` lit le MÊME fichier
  (`priv/api/build_info.txt`), sans HTTP, et fonctionne fleet éteinte ;
- **aucun client n'en a besoin** : ni `bin/lcars`, ni le BEAM, ni le healthcheck du conteneur (qui
  teste le port 22) ; les tests appellent le plug directement.

⚠ Le chemin d'ÉCRITURE (`control_socket_child/0`) ne dépend d'aucun commutateur nommé d'après une
surface de LECTURE. Le remettre sous un `if api_start_listener` recréerait ce couplage.

## Modules — read the `@moduledoc` for the contract

- `Fleet.API` — domain overview + vendor frontier (context module, no code)
- `Fleet.API.ControlRouter` — the admin write door, on the AF_UNIX socket. **La seule surface.**
- `Fleet.API.SpawnAdmission` — the spawn-admission pipeline (pure functions)
- `Fleet.API.BuildInfo` — observable build stamp (lu par le log de boot et par `fleet version`)
- `Fleet.API.Readiness` — live operational read-model: MCP pod-facing status, pilot rail liveness (served by the observation deck's `/api/readiness/deep`; this domain has no route for it)
- `Fleet.API.Application` — the domain supervisor + control-listener wiring

## Config & deps

Knobs and env vars are not inventoried here — they live where they are read (`config/runtime.exs`,
the `use Boundary` deps of `Fleet.API`) and drift if copied. The vendor frontier is N0 (see
`h Fleet.API`).
