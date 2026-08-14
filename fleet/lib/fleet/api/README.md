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

- **Il n'y a plus de surface TCP du tout** (2026-08-14). Ce domaine ne sert qu'une chose : la porte
  d'écriture `POST /api/admin/spawn`, sur une socket AF_UNIX locale qu'un pod du réseau partagé ne
  peut pas atteindre. L'invariant n'est plus « la surface publique est en lecture seule » — c'est
  **il n'y a pas de surface publique**.
- La confidentialité de la socket d'admin repose sur son mode `0600`. La changer est une décision de
  sécurité.

## Ce qui a été retiré, et pourquoi — pour que personne ne le reconstruise

`Fleet.API.Rest`, `Fleet.API.WS` et `Fleet.API.Readiness` ont été **supprimés**, avec le listener
TCP. Mesure du 2026-08-14 : ce listener n'avait **aucune capacité propre**.

- les lectures d'état (`pods`, `issues`, `workflow_runs`) rendaient **501** en renvoyant vers
  `Fleet.Observation` — ce n'était pas son autorité, et son message de renvoi nommait un port
  (`deck :8091`) mort depuis que l'observation est passée sur socket ;
- `/ws` était déjà débranché — coupure réversible du même jour, pour une raison qui tenait :
  il projetait le flux d'événements **complet et sans authentification**, capture d'écran tmux d'un
  pod comprise ;
- `health` / `readiness` / `version` ont un **jumeau CLI** : `fleet_v2 version` lit le MÊME fichier
  (`priv/api/build_info.txt`), sans HTTP, et fonctionne fleet éteinte ;
- **personne ne l'appelait** : ni `bin/lcars` (son propre commentaire le disait), ni le BEAM, ni le
  healthcheck du conteneur (qui teste le port 22) ; les tests appelaient le plug directement.

⚠ Le retirer a aussi découplé l'écriture : `control_socket_child/0` était imbriqué dans
`if api_start_listener` — le chemin d'ÉCRITURE dépendait d'un commutateur nommé d'après une surface
de LECTURE.

## Modules — read the `@moduledoc` for the contract

- `Fleet.API` — domain overview + vendor frontier (context module, no code)
- `Fleet.API.ControlRouter` — the admin write door, on the AF_UNIX socket. **La seule surface.**
- `Fleet.API.SpawnAdmission` — the spawn-admission pipeline (pure functions)
- `Fleet.API.BuildInfo` — observable build stamp (lu par le log de boot et par `fleet_v2 version`)
- `Fleet.API.Application` — the domain supervisor + control-listener wiring

## Config & deps

Knobs and env vars are not inventoried here — they live where they are read (`config/runtime.exs`,
the `use Boundary` deps of `Fleet.API`) and drift if copied. The vendor frontier is N0 (see
`h Fleet.API`).
