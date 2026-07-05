# fleet_observation

**Date** : 2026-06-10
**Dernière révision** : 2026-07-05 (C4 — gabarit HTML/CSS/JS extrait en `Fleet.Observation.Deck.View` (rendu pur), `Deck` = contrôleur seul ; B5 — child-spec listener via la source unique `Fleet.EventRouter.Listener.cowboy_child/1` ; D2 — resync contrat : port per-humain, route `/table`, deps réelles Ring 0/1)
**Statut** : incréments A+B+C — BL-026 read-frontier live (PODS + read-model stream)
**Référencé par** : —
**Design** : `DESIGN-observabilite.md` (catalogue de l'observable + organisation LCARS)

**Ring** : 4 (external surface — observation deck)

Frontière **read / observabilité** du core remédié (BL-026). Sert un deck
LCARS sur un port dédié per-humain (`LCARS_OBSERVATION_PORT`, posé par
`bin/fleet_v2`). **On ne coupe rien** — coexiste avec :

- `fleet_api` (port per-humain `FLEET_API_PORT`, REST no-auth — HMAC retiré) — surface de **commande** ;
- `fleet_dashboard` (`:8089`, branche sœur) — autre deck observation ;
- dashboard Python v1.5 (`:8090`) — conservé en parallèle.

**Principe cardinal** : le deck **ne touche pas au core**. Il dépend vers le
bas (deps réelles : Ring 0/1), aucune app du core ne dépend de lui. Lecture seule,
no-auth, intra-release (ADR-C « 5-zéros ») : il observe, il ne mute rien.

## Submodules

| Module | Rôle |
|---|---|
| `Fleet.Observation.Application` | supervisor + listener Cowboy (port per-humain, fail-loud si absent ; guardé `:test`) |
| `Fleet.Observation.Deck` | `Plug.Router` — CONTRÔLEUR : routing + dérivation du catalogue de rôles (assets/cap-profiles) + snapshots live ; passe la donnée à la vue |
| `Fleet.Observation.Deck.View` | rendu HTML PUR (gabarit inline HTML/CSS/JS — extrait C4) : `page/0` shell LCARS statique (7 decks, données tirées côté client via `/api/*`), `table_page/2` tableau serveur zéro-CSS (reçoit rôles + pods groupés en argument, ne lit aucune source) |
| `Fleet.Observation.ReadModel` | GenServer + ETS, abonné unique, projette le stream `%Fleet.Event{}` |

## Public API (HTTP)

| Route | Réponse |
|---|---|
| `GET /` | shell LCARS : header BRIDGE + 7 decks (PODS live + read-model) |
| `GET /table` | tableau par rôle rendu côté serveur (zéro JS) : un bloc par rôle du catalogue cap-profiles (rôles pod, `host_native != true`), pods groupés — même snapshot live que `/api/pods` |
| `GET /api/pods` | `{"pods": [...], "count": n}` — pods vivants (vue JSON-safe, live) |
| `GET /api/projection` | projection read-model (stream + counts + decks event-dérivés) |
| `GET /health` | `{"status": "ok", ...}` |
| `GET /static/lcars-tva.css` | feuille de style LCARS |
| `GET /static/assets/*.svg` | icônes de rôles + favicons |

## Les 7 decks (cf. DESIGN §4)

`BRIDGE` (santé/readiness/quiescence) · `PODS` (workflow_maps par rôle, **live**) ·
`FLOW` (work items + pipelines) · `GATEKEEPER` (escalades Z3-B + verdicts) ·
`COORDINATION` (Pilot/coord/MCP) · `STREAM` (tail `%Fleet.Event{}`) ·
`DIAGNOSTICS` (boot/oauth/mcp/sdk/signal/git). `PODS` = snapshot live
(`/api/pods`) ; les decks event-dérivés (FLOW/GATEKEEPER/COORDINATION/STREAM/
DIAGNOSTICS + résumé BRIDGE) sont alimentés par la **projection read-model**
(`/api/projection`), routés par préfixe de type d'event (cf. ReadModel).

## Configuration

| Clé | Default | Source |
|---|---|---|
| `:fleet_observation, :http_port` | **aucun** (`fetch_env!`, fail-loud si absent) | `runtime.exs` ← `LCARS_OBSERVATION_PORT` (posé par `bin/fleet_v2`, per-humain) ; `0` en `:test` |
| `:fleet_observation, :start_listener` | `true` | `false` en `:test` (invariant hermétique) |
| `:fleet_observation, :start_readmodel` | `true` | `false` en `:test` (pas d'abonné Bus parasite) |
| `LCARS_BIND_HOST` (env) | `127.0.0.1` (loopback) | IP de bind du deck — read-only no-auth, **local-only par défaut** (frontière = isolation réseau, comme `fleet_api`) ; accès distant = tunnel/reverse-proxy. Exposer = opt-in via cette env. Sources uniques : `Fleet.EventRouter.BindAddress` (ip) + `Fleet.EventRouter.Listener.cowboy_child/1` (child-spec — le gate `:start_listener` et le port restent ici). |

## Dépendances

- `fleet_spawner` (Ring 1) — `Fleet.Spawner.list_pods/0` (lecture seule, deck PODS + `/table`).
- `fleet_cap_profile` (Ring 0) — catalogue des rôles affichés (`/table` : `CapProfile.list/0` + `load/1`, filtre `host_native`).
- `fleet_event_router` (Ring 0) — bus `%Fleet.Event{}` (`Bus.subscribe/1`, read-model) + bind du listener (`BindAddress`, `Listener.cowboy_child/1`).
- `plug`, `plug_cowboy`, `jason`.

## Frontière starfleet

**Hors périmètre** (non-négo #2) : le deck observe **la fleet**, pas
`fleet_starfleet`. L'icône `starfleet.svg` existe dans les assets mais aucun
panel ne l'instrumente.

## Frontière BL-026 (implémentée)

`Fleet.Observation.ReadModel` (abonné **unique** au bus) projette le stream
`%Fleet.Event{}` dans une table ETS qu'il possède ; le deck lit **la projection**
via `ReadModel.projection/0` (read ETS direct, bypass GenServer — Iron Law),
**jamais** l'état GenServer interne d'un tiers. Les `PODS` restent un snapshot
live (`Spawner.list_pods/0`) car `pod.*` n'émet que des terminaux.

**Test architectural BL-020/BL-026** : le core n'a été touché qu'en **un** point
— l'ajout du read-seam `Fleet.Spawner.list_pods/0` (énumération générique, owned
par le spawner). Tout le reste se branche par-dessus sans modifier le core.
