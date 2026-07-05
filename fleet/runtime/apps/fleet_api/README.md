# fleet_api (chantier 15)

**Date** : 2026-05-10
**Dernière révision** : 2026-07-05 (C4 — pipeline d'admission `/api/admin/spawn` extrait en `Fleet.API.SpawnAdmission` (policy), `Rest` = mapping HTTP seul ; B5 — child-spec listener via la source unique `Fleet.EventRouter.Listener.cowboy_child/1`, dispatch WS inchangé ; 2026-07-02 : B2b — allowlist DTO d'admission `/api/admin/spawn` ; P05 — readiness honnête `/api/readiness/deep`)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_api.md`, `STATUS-CHANTIERS.md`

API publique LCARS v2 (Ring 4 — frontières externes) : REST + WS.

**API agnostique du client** — le dashboard web v1.5 `:8090` est *un*
consommateur parmi d'autres possibles, pas couplé à l'arch v2.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.API.Rest` | Plug.Router HTTP `:8080` endpoints REST — reads no-auth + mapping des verdicts d'admission spawn en statuts HTTP |
| `Fleet.API.SpawnAdmission` | pipeline d'ADMISSION de `POST /api/admin/spawn` (extrait C4) : `admit/1` = allowlist DTO → `pod_id` path-safe → cap-profile chargeable (source unique `Fleet.CapProfile.load/1`) → host-native refusé fail-closed → brief requis one-shot (miroir R18, autorité partagée `Fleet.Spawner.brief_required?/1`) ; `broadcast/1` = émission canon `%Fleet.Event{source: :api}` (event hors registry/malformé → `{:error, _}`, jamais un crash). Fonctions pures + lectures catalogue (pas de process — Iron Law) |
| `Fleet.API.WS` | Cowboy WebSocket handler `:8080/ws` subscribe Phoenix.PubSub + filtre per-client topics + heartbeat 30s |
| `Fleet.API.Readiness` | read-model P05 — état opérationnel LIVE (anti-vert-creux). Introspecte config/process/persistent_term ; `deep/0` rend `status: operational\|degraded` + sous-systèmes. Jumeau runtime de `mix lcars.contracts.check` (plan source-conformance build/CI) sur le plan opérationnel. Fonctions pures (pas de process — Iron Law) |
| `Fleet.API.BuildInfo` | version du build **constatable** (« quel commit tourne ? »). `current/0` rend `%{sha, dirty, ref, source}` — SHA git court + flag dirty + ref, `source` ∈ `:release\|:working_tree\|:unknown` (provenance explicite). Totale (ne lève jamais), mémoïsée en `:persistent_term`. Fonctions pures (pas de process — Iron Law) |

## Routes REST

| Method | Route | Auth | Description |
|---|---|---|---|
| GET | `/api/health` | — | readiness probe shallow (200 dès Cowboy bind, consommé ch16 `lcars-readiness`) |
| GET | `/api/readiness/deep` | — | P05 — état opérationnel LIVE (`Fleet.API.Readiness.deep/0`). 200 même si `status: degraded` (dégradation = donnée, pas erreur HTTP). Vue de câblage interne (pas une probe externe) |
| GET | `/api/workflow_runs` | — | liste des workflow-runs |
| GET | `/api/issues` | — | liste issues |
| GET | `/api/pods` | — | liste pods |
| GET | `/api/version` | — | version du build servi — JSON `{sha, dirty, ref, source}` (`Fleet.API.BuildInfo.current/0`). Lecture → no-auth légitime. **Constatable** : la version est lue, pas déduite |
| POST | `/api/admin/spawn` | — | broadcast `admin.spawn.request` (ch6) ; **DTO public allowlisté** (422 sur champ interne) ; **503** si quiescence (drain shutdown, `Fleet.Shutdown.Quiesce`) |

**Pas d'auth applicative** (HMAC retiré — bearer statique sans surface intra-container).
Frontière = isolation réseau du container (ne pas publier `:8080` ; tunnel pour le remote).

### `/api/admin/spawn` — allowlist DTO (admission)

Surface no-auth : le payload entrant est **filtré à l'admission**, avant tout broadcast. Le `PublishConsumer`
convertit ensuite `payload["opts"]` en opts internes du spawner — sans filtre, des opts privilégiés
(`pod_dir_root`, `state_fs_root`, `human`, `project` → clone d'un repo attaquant dans le pod,
`recall_seed_jsonl`, `resume`, `session_id`, `rc_name`, `allow_no_brief`, seams module/fun…) deviendraient
pilotables depuis l'API. Le DTO public est donc **plat et explicite** :

| Champ | Forme | Rôle |
|---|---|---|
| `cap_profile_name` / `role` | string (l'un des deux, requis) | profil de capacités (validé : 400 si absent, 422 si inconnu, **422 si host-native**) |
| `issue_id` | string | corrélation forge/event |
| `brief` | string | le travail du pod ; **replacé dans l'`opts` interne construit par l'API** ; **requis** pour un cap-profile `one-shot` (422 sinon — miroir R18) |
| `pod_id` | string path-safe | identifiant imposé (admin) ; accepté **uniquement** si `[A-Za-z0-9._-]` sans `..`, sinon 422 |

Toute clé top-level **hors** de cette liste (y compris un `opts` brut fourni par le client) → **422** avant
le moindre broadcast (rien n'atteint le consumer/spawner). L'API reconstruit elle-même l'`opts` ; un `opts`
client n'est jamais transmis. Défense en profondeur côté consumer : `PublishConsumer.to_keyword/1` ne gobe
plus une liste brute (une liste non-keyword → `[]`).

**Host-native interdit par cette porte.** Un cap-profile `metadata.containment: none` (host-native :
starfleet, architecte-interactif) lance un pod **hors-sandbox**, sur l'hôte *as* l'humain — le pouvoir le
plus fort de la fleet. La porte spawn générique (no-auth) le **REFUSE** : à l'admission, après le load du
cap-profile, `Fleet.CapProfile.containment(cap)` doit valoir `"bwrap"` ; sinon **422** (`host_native_forbidden`)
avant tout broadcast — aucun pod hôte ne peut naître via l'API. Le host-native garde sa voie dédiée hors-bande
(starfleet / `bin/host_launch.sh`), jamais cette API. Source unique de containment partagée avec le spawner
(`Fleet.CapProfile.containment/1`) → l'API et le lancement réel ne peuvent pas diverger de verdict.

**Brief requis pour un one-shot (miroir R18).** Un cap-profile `one-shot` (reviewer/qualifier/consultant)
lancé SANS `brief` partirait sans travail → le spawner le refuse (`brief_required`, ZÉRO pod). Sans garde
à l'admission, le 202 « mis en file » serait un **202 menteur** (jumeau du cap-profile menteur). L'API vérifie
donc à l'admission : `Fleet.Spawner.brief_required?(cap) and not has_brief?` → **422** avant tout broadcast.
`brief_required?/1` est l'**autorité partagée** (même lecture que `brief_guard`) → pas de règle dupliquée.
Un one-shot légitime porte son `brief` dans le DTO → il passe (202).

### Version constatable (`Fleet.API.BuildInfo`)

« Quel commit tourne ? » doit se **constater**, pas se déduire — une release est
auto-contenue (ERTS bundlé, pas de repo git ni de Mix au runtime). `BuildInfo.current/0`
rend `%{sha, dirty, ref, source}` ; le champ `source` rend la provenance **explicite** :

| `source` | Quand | Donnée |
|---|---|---|
| `:release` | `priv/build_info.txt` présent (embarqué au `mix release`, step `write_build_info/1` du `mix.exs` racine, après `:assemble`) | parse du fichier — la release ne touche jamais git |
| `:working_tree` | pas de fichier (mode source/dev) | git LIVE (`rev-parse --short HEAD`, `--abbrev-ref HEAD`, `status --porcelain`) |
| `:unknown` | ni fichier ni git exploitable (git absent, pas un repo) | `%{sha: "unknown", dirty: false, ref: nil}` |

`current/0` est **totale** (ne lève jamais → n'empêche jamais le boot) et mémoïsée en
`:persistent_term` (un seul `git` sur la vie du BEAM, pas un par requête). `priv/build_info.txt`
est **généré au release uniquement** (gitignored), jamais dans le source.

Trois surfaces exposent la même donnée : l'endpoint `GET /api/version`, un `Logger.info` au
boot de `fleet_api` (`LCARS fleet — build <sha><-dirty?> ref=<ref> (source=<source>)`), et la
commande `bin/fleet_v2 version` (lit le priv embarqué en release, git LIVE en source).

## WebSocket protocol

```
GET /ws (upgrade)

C → S: {"action": "subscribe", "topics": ["workflow_map.*", "audit.cat5.*"]}
S → C: {"type": "connected"}
S → C: {"type": "subscribed", "topics": [...]}
S → C: {"type": "ping"}                                  ← heartbeat 30s
S → C: {"type": "event", "event_type": "workflow_map.completed", "payload": {...}}
S → C: {"type": "error", "reason": "..."}
```

Topics : exact match OU wildcard suffixe `*` (ex `workflow_map.*` match
`workflow_map.completed`). Liste vide = subscribe-all.

## Configuration

| Knob | Default | Rôle |
|---|---|---|
| `:fleet_api, :http_port` | `8080` | port Cowboy listener |
| `:fleet_api, :start_listener` | `true` | bool — `false` en tests (`config/test.exs`) |
| `LCARS_BIND_HOST` (env) | `127.0.0.1` (loopback) | IP de bind du listener — surface no-auth dont la seule écriture restante (`/api/admin/spawn`, gardée) est **local-only par défaut** ; exposer (ex. `0.0.0.0`) = opt-in explicite via cette env. Sources uniques : `Fleet.EventRouter.BindAddress` (ip) + `Fleet.EventRouter.Listener.cowboy_child/1` (child-spec — le gate `:start_listener` et le port restent ici). |

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
* `fleet_pilot` (Ring 2) — readiness sonde la liveness du rail step
* `fleet_spawner` (Ring 1) — readiness lit le backend de lancement résolu via `Fleet.Spawner.LaunchBackend.resolved/0` (source unique du défaut, pas re-copié)
* `fleet_starfleet` (Ring 3) — readiness lit le backend dispatcher de shutdown résolu via `Fleet.Starfleet.Shutdown.configured_dispatcher/0` (source unique du défaut)
* `fleet_cap_profile` (ch1) — validation cap-profile à l'admission `/api/admin/spawn`
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
