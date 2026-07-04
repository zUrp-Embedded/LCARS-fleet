# fleet_observation

**Date** : 2026-06-10
**Dernière révision** : 2026-07-05 (B5 — child-spec listener via la source unique `Fleet.EventRouter.Listener.cowboy_child/1`)
**Statut** : incréments A+B+C — BL-026 read-frontier live (PODS + read-model stream)
**Référencé par** : —
**Design** : `DESIGN-observabilite.md` (catalogue de l'observable + organisation LCARS)

**Ring** : 4 (external surface — observation deck)

Frontière **read / observabilité** du core remédié (BL-026). Sert un deck
LCARS sur un port dédié `:8091`. **On ne coupe rien** — coexiste avec :

- `fleet_api` (`:8080`, REST HMAC) — surface de **commande** ;
- `fleet_dashboard` (`:8089`, branche sœur) — autre deck observation ;
- dashboard Python v1.5 (`:8090`) — conservé en parallèle.

**Principe cardinal** : le deck **ne touche pas au core**. Il dépend vers le
bas (lit Ring 1/2/3), aucune app du core ne dépend de lui. Lecture seule,
no-auth, intra-release (ADR-C « 5-zéros ») : il observe, il ne mute rien.

## Submodules

| Module | Rôle |
|---|---|
| `Fleet.Observation.Application` | supervisor + listener Cowboy `:8091` (guardé `:test`) |
| `Fleet.Observation.Deck` | `Plug.Router` — HTML LCARS (7 decks) + endpoints read JSON |
| `Fleet.Observation.ReadModel` | GenServer + ETS, abonné unique, projette le stream `%Fleet.Event{}` |

## Public API (HTTP)

| Route | Réponse |
|---|---|
| `GET /` | shell LCARS : header BRIDGE + 7 decks (PODS live + read-model) |
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
| `:fleet_observation, :http_port` | `8091` | `runtime.exs` (`LCARS_OBSERVATION_PORT`) |
| `:fleet_observation, :start_listener` | `true` | `false` en `:test` (invariant hermétique) |
| `:fleet_observation, :start_readmodel` | `true` | `false` en `:test` (pas d'abonné Bus parasite) |
| `LCARS_BIND_HOST` (env) | `127.0.0.1` (loopback) | IP de bind du deck — read-only no-auth, **local-only par défaut** (frontière = isolation réseau, comme `fleet_api`) ; accès distant = tunnel/reverse-proxy. Exposer = opt-in via cette env. Sources uniques : `Fleet.EventRouter.BindAddress` (ip) + `Fleet.EventRouter.Listener.cowboy_child/1` (child-spec — le gate `:start_listener` et le port restent ici). |

## Dépendances

- `fleet_spawner` (Ring 1) — `Fleet.Spawner.list_pods/0` (lecture seule, deck PODS).
- `fleet_event_router` (Ring 2) — bus `%Fleet.Event{}` (`Bus.subscribe/1`, read-model).
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
