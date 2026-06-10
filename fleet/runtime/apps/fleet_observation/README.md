# fleet_observation

**Date** : 2026-06-10
**Dernière révision** : 2026-06-10
**Statut** : squelette (incrément B — BL-026 read-frontier, deck PODS live)
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
| `Fleet.Observation.ReadModel` | *(incrément C)* GenServer + ETS, projette le stream `%Fleet.Event{}` |

## Public API (HTTP)

| Route | Réponse |
|---|---|
| `GET /` | shell LCARS : header BRIDGE + 7 decks (PODS live, autres → read-model C) |
| `GET /api/pods` | `{"pods": [...], "count": n}` — pods vivants (vue JSON-safe) |
| `GET /health` | `{"status": "ok", ...}` |
| `GET /static/lcars-tva.css` | feuille de style LCARS |
| `GET /static/assets/*.svg` | icônes de rôles + favicons |

## Les 7 decks (cf. DESIGN §4)

`BRIDGE` (santé/readiness/quiescence) · `PODS` (cartes par rôle, **live**) ·
`FLOW` (mandats + pipelines) · `GATEKEEPER` (escalades Z3-B + verdicts) ·
`COORDINATION` (Pilot/coord/MCP) · `STREAM` (tail `%Fleet.Event{}`) ·
`DIAGNOSTICS` (not_wired_yet/boot/quota). En incrément B seul `PODS` est
alimenté ; les autres affichent un placeholder **honnête** (« en attente du
read-model C ») — pas de vert creux.

## Configuration

| Clé | Default | Source |
|---|---|---|
| `:fleet_observation, :http_port` | `8091` | `runtime.exs` (`LCARS_OBSERVATION_PORT`) |
| `:fleet_observation, :start_listener` | `true` | `false` en `:test` (invariant hermétique) |

## Dépendances

- `fleet_spawner` (Ring 1) — `Fleet.Spawner.list_pods/0` (lecture seule).
- `fleet_event_router` (Ring 2) — bus `%Fleet.Event{}` (read-model, incrément C).
- `plug`, `plug_cowboy`, `jason`.

## Frontière starfleet

**Hors périmètre** (non-négo #2) : le deck observe **la fleet**, pas
`fleet_starfleet`. L'icône `starfleet.svg` existe dans les assets mais aucun
panel ne l'instrumente.

## Frontière BL-026 (cible — incrément C)

Le squelette lit `Fleet.Spawner.list_pods/0` directement. L'incrément C
interpose `Fleet.Observation.ReadModel` qui projette le stream `%Fleet.Event{}`
+ un snapshot au boot ; le deck lit **la projection**, jamais l'état GenServer
interne. Test architectural : le core n'est pas touché (diff hors
`apps/fleet_observation/` + `config/` + `mix.exs` = 0).
