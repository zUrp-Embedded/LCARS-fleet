# fleet_api (chantier 15)

**Date** : 2026-05-10
**Dernière révision** : 2026-06-24 (P05 — readiness honnête `/api/readiness/deep` + `Fleet.API.Readiness` read-model anti-vert-creux)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_api.md`, `STATUS-CHANTIERS.md`

API publique LCARS v2 (Ring 4 — frontières externes) : REST + WS.

**API agnostique du client** — le dashboard web v1.5 `:8090` est *un*
consommateur parmi d'autres possibles, pas couplé à l'arch v2.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.API.Rest` | Plug.Router HTTP `:8080` endpoints REST |
| `Fleet.API.WS` | Cowboy WebSocket handler `:8080/ws` subscribe Phoenix.PubSub + filtre per-client topics + heartbeat 30s |
| `Fleet.API.GitCommitter` | atomic write rename + `git add` + `git commit` (canon trace strate 1, architecture-cible §L380) |
| `Fleet.API.Readiness` | read-model P05 — état opérationnel LIVE (anti-vert-creux). Introspecte config/process/persistent_term ; `deep/0` rend `status: operational\|degraded` + sous-systèmes. Jumeau runtime de `mix lcars.contracts.check` (plan source-conformance build/CI) sur le plan opérationnel. Fonctions pures (pas de process — Iron Law) |

## Routes REST

| Method | Route | Auth | Description |
|---|---|---|---|
| GET | `/api/health` | — | readiness probe shallow (200 dès Cowboy bind, consommé ch16 `lcars-readiness`) |
| GET | `/api/readiness/deep` | — | P05 — état opérationnel LIVE (`Fleet.API.Readiness.deep/0`). 200 même si `status: degraded` (dégradation = donnée, pas erreur HTTP). Vue de câblage interne (pas une probe externe) |
| GET | `/api/pipelines` | — | liste état pipelines |
| GET | `/api/tickets` | — | liste tickets |
| GET | `/api/pods` | — | liste pods |
| POST | `/api/admin/spawn` | — | broadcast `admin.spawn.request` (ch6) ; **503** si quiescence (drain shutdown, `Fleet.Shutdown.Quiesce`) |
| POST | `/api/config/update` | — | atomic write + git commit |

**Pas d'auth applicative** (HMAC retiré — bearer statique sans surface intra-container).
Frontière = isolation réseau du container (ne pas publier `:8080` ; tunnel pour le remote).

## WebSocket protocol

```
GET /ws (upgrade)

C → S: {"action": "subscribe", "topics": ["pipeline.*", "audit.cat5.*"]}
S → C: {"type": "connected"}
S → C: {"type": "subscribed", "topics": [...]}
S → C: {"type": "ping"}                                  ← heartbeat 30s
S → C: {"type": "event", "event_type": "pipeline.completed", "payload": {...}}
S → C: {"type": "error", "reason": "..."}
```

Topics : exact match OU wildcard suffixe `*` (ex `pipeline.*` match
`pipeline.completed`). Liste vide = subscribe-all.

## Public API

```elixir
# GitCommitter atomic write + git commit
{:ok, sha} = Fleet.API.GitCommitter.commit_config_change(
  "intensity.json", ~s|{"level":"low"}|, "user1"
)
```

## Configuration

| Knob | Default | Rôle |
|---|---|---|
| `:fleet_api, :http_port` | `8080` | port Cowboy listener |
| `:fleet_api, :start_listener` | `true` | bool — `false` en tests (`config/test.exs`) |
| `:fleet_api, :git_repo_path` | `/var/lib/lcars/config` | racine repo config |
| `LCARS_BIND_HOST` (env) | `127.0.0.1` (loopback) | IP de bind du listener — surface no-auth (`/api/admin/spawn`, `/api/config/update`) **local-only par défaut** ; exposer (ex. `0.0.0.0`) = opt-in explicite via cette env. Source unique : `Fleet.EventRouter.BindAddress`. |

> **Bind loopback (frontière réseau).** Le listener écoute `{127,0,0,1}` par
> défaut : la surface est no-auth et le contrat de sécurité est « isolation
> réseau ». Le dashboard navigateur (`:8080/dashboard` + `/ws`) est donc
> local-only ; un accès distant passe par un tunnel/reverse-proxy. Exposer
> publiquement = poser `LCARS_BIND_HOST` (global, toutes surfaces).

## Tests

```bash
mix test apps/fleet_api
```

Tests utilisent `Plug.Test` pour Rest (pas de listener réel) et
callbacks Cowboy directs pour WS (pas de socket réel).

## Dépendances

* `fleet_event_router` (ch11 PROMOTED) — Bus PubSub
* `:plug`, `:plug_cowboy`, `:jason`

## D1 décidé (split deferred)

MVP : 1 app umbrella `fleet_api` unique (REST + WS dans même
supervision OTP). Pas de duplication subscribe bus, simplicité tree.

**Deferred — critère post-implem 90 jours** : split éventuel en
`fleet_bus_socket` (irréductible côté event_router) +
`fleet_rest_facade` (optionnel surcouche). Critère opérationnalisable :
si 1er client observé consume bus NDJSON brut sans REST surcouche
(ex CLI custom, autre dashboard expérimental, MCP server externe) →
ADR + amendement design note. Référence : `architecture-cible.md`
§L368 + §L791, design note `fleet_api.md` D1.

## Frontière vendor

N0 (vendor-agnostic, orchestration via PubSub bus).
