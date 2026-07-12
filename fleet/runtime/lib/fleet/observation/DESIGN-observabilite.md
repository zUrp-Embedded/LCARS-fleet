# DESIGN — Observabilité du core LCARS Fleet (`fleet_observation`)

**Date** : 2026-06-10
**Dernière révision** : 2026-07-12
**Statut** : design note exploratoire (incrément A — la base de travail). Mode exploration : pas de mauvaise réponse, on teste.
**Référencé par** : `lib/fleet/observation/README.md`
**Auteur** : agent de correction (suite de mission post-remédiation Z0→Z7)

---

## 0. Mission

Rendre **observable** le core runtime qu'on vient de remettre à jour (remédiation Z0→Z7).
Le core sait *faire* (spawn pods, router events, piloter pipelines, juger via gatekeeper) — il
ne sait pas encore **se montrer**. C'est le rôle de cette couche.

Trois dashboards préexistent et **restent en vie** (on coupe rien maintenant, ménage à la fin) :

| Port | Quoi | Statut |
|---|---|---|
| `:8090` | dashboard Python v1.5 | DÉCOMMISSIONNÉ (retiré) |
| `:8089` | `fleet_dashboard` (branche sœur `dashboard/observability-8089`) | squelette observation deck |
| **`:8091`** | **`fleet_observation` (CE design)** | **nouveau — la prise propre BL-026** |

→ knob `LCARS_OBSERVATION_PORT` (défaut `8091`), changeable sans recompile.

---

## 1. Le principe cardinal — le dashboard NE TOUCHE PAS au core

C'est **le** critère, pas un détail esthétique. Le test architectural BL-020/BL-026 :

> Si les coutures du core sont propres, l'observabilité se **branche par-dessus, gratuitement**.
> Si je dois modifier le core pour l'observer → c'est un **fail architectural** que je **trace**,
> pas que je bricole.

Conséquences dures :
- `fleet_observation` dépend **vers le bas** (Ring 4 → lit Ring 1/2/3), jamais l'inverse.
- **Aucune** app du core ne dépend de `fleet_observation`, n'en importe un module, ni n'émet « pour le dashboard ».
- Le dashboard lit **deux** choses, et rien d'autre :
  1. le **stream d'events** `%Fleet.Event{}` (la colonne vertébrale, déjà là) ;
  2. des **API de lecture déjà publiques** et stables (`Spawner.list_pods/0`, `Readiness.deep/0`).
- **Jamais** d'introspection directe de l'état interne d'un GenServer tiers
  (`:sys.get_state`, `TaskQueue.Server` state…). Si une donnée n'est pas
  exposée proprement, le manque se **trace** (« seam manquant ») — il ne se contourne pas.

C'est exactement la thèse BL-026 (frontière read-model explicite). Cette couche EST
l'implémentation de BL-026 pour MON core remédié.

---

## 2. Frontière read-model — `Fleet.Observation.ReadModel`

Leçon directe du Python v1 (`fleet-hub.py` = REST read-only / `fleet-monitor.py` = display) **et**
du skill OTP : **un seul** processus consomme le flux et maintient la projection ; les lecteurs
(endpoints HTTP, futurs TUI) lisent la projection, **pas** la source.

```
%Fleet.Event{} bus (fleet.events)          API read publiques (snapshot boot)
        │                                          │
        ▼                                          ▼
  ┌─────────────────────────────────────────────────────┐
  │  Fleet.Observation.ReadModel  (GenServer unique)     │
  │   • subscribe au bus  • projette  • snapshot au boot │
  │   • possède une table ETS (:read_concurrency)        │
  └─────────────────────────────────────────────────────┘
        │ reads bypass le GenServer (ETS direct)
        ▼
  Fleet.Observation.Deck (Plug.Router)  →  GET /api/* (JSON)  →  client JS poll
```

- **Iron Law OTP respecté** : le GenServer sérialise les **écritures** (un event = une projection
  mise à jour) ; les **lectures** (`/api/pods` etc.) tapent l'ETS directement, zéro contention.
- **Phoenix-thinking « external polling = 1 GenServer, pas N clients »** : ce ne sont pas les N
  navigateurs qui interrogent le core — c'est UN ReadModel qui projette une fois, lu par tous.
- Au boot : un **snapshot** (`Spawner.list_pods/0`, `Readiness.deep/0`) amorce la projection,
  puis le stream la maintient à jour (pattern hub v1 : topologie au boot + deltas live).

> **Incrément** : le squelette (B) peut lire `Spawner.list_pods/0` en direct depuis le Deck
> (comme la branche sœur :8089) ; **C** interpose le ReadModel. La design note pose la cible.

---

## 3. Catalogue exhaustif de l'observable (dérivé du core remédié)

Par ring/app — ce que chaque expose, et la **source read-only**. (Audit-exhaustif : on liste
TOUT ce qui est observable, on triera l'affichage après — un manque tu, c'est un mensonge.)

### Ring 1 — substrat pod
| Observable | Détail | Source |
|---|---|---|
| **Pods vivants** | `pod_id`, rôle, `phase` (state machine), `conditions`, `issue_id`, `session_id`, `tmux_session` | `Fleet.Spawner.list_pods/0` |
| Phase pod | machine d'état du Pod (allocate→launch→…→completed/failed) | events `pod.*` |
| `result_deadline` | timer de réponse armé/annulé (Z1) | events |
| Identité forge | rôle→humain résolu (Z4), trailer co-author | (config, peu « live ») |
| Cap-profiles chargés | profils disponibles, containment/lifetime/monitor | `fleet_cap_profile` (read) |

### Ring 2 — backbone orchestration
| Observable | Détail | Source |
|---|---|---|
| **Event stream** | LE flux `%Fleet.Event{}` (type, source, trace_id, ts, payload) | `Fleet.EventRouter.Bus.subscribe/1` |
| Registry events | clés `events.yaml` (ce qui est registrable) + drift producteur | `events.yaml` |
| **File de mandats** | tasks pending/active/completed/failed (get_work_item/submit_result) | `fleet_task_queue` |
| Pilot | dispatcher on/off, routes chargées, poll repo/intervalle | `fleet_pilot` |

### Ring 3 — coordination + policy
| Observable | Détail | Source |
|---|---|---|
| **Pipelines** | pipelines par état, stages, transitions | events pipeline |
| **Gatekeeper** | escalades (mécanisme Z3-B : gate non-tranchable→juge), verdicts, gate_evals en attente | events `gatekeeper.*` / `audit.verdict` |
| DeliverableGate | résultat de porte F-01 (trailer co-author vérifié, I-CBC) | events |
| Coord | policies chargées, actions coord | `fleet_coord` |
| MCP | configured/unconfigured, bridge stdio vivant | `fleet_mcp` |

### Ring 4 / substrat — surface & santé
| Observable | Détail | Source |
|---|---|---|
| **Readiness deep** | le jumeau runtime de `contracts.check` (anti-vert-creux) | `Fleet.API.Readiness.deep/0` |
| Quiescence | shutdown en cours de drain ? (`:quiescing`) | `Fleet.Shutdown.Quiesce` |
| Boot | orchestrateur, pods permanents bootés, root-boot-guard | events boot |
| API | endpoints REST, connexions WS, no-auth by design (isolation réseau) + écritures gardées (POST /api/admin/spawn) | `fleet_api` |
| `not_wired_yet` | modules présents mais non câblés | introspection config |
| Quota OAUTH / rate-limit | 5h / weekly usage (angle :8090, BL-016) | (source à câbler — flag) |

### HORS PÉRIMÈTRE — `fleet_starfleet`
**Non-négo #2** : starfleet est hors-fleet. Le dashboard observe **la fleet**, **pas** starfleet.
Je l'**exclus** de la surface. (Observer sa vivacité de l'extérieur ≠ lui bâtir une protection —
mais je ne l'instrumente pas, je ne m'y abonne pas, je n'affiche pas son audit.)

---

## 4. Organisation harmonieuse — les « decks » LCARS

Le thème LCARS n'est pas du chrome : c'est une **grammaire d'état**. Le monitor v1 le prouve
(couleur + glyphe = sémantique immédiate). Je reprends son vocabulaire et je l'élève en panels.

### 4.1 Vocabulaire d'état (repris de `STATUS_STYLE`, monitor v1)
| État | Couleur | Glyphe | Sens |
|---|---|---|---|
| idle | `#88AAFF` bleu-gris | ● | nominal |
| active | `#FF9900` orange | ◉ | actif |
| startup | `#FFCC00` ambre | ⟳ | init |
| waiting | `#FFCC99` pêche | ◐ | attente |
| handoff | `#88AAFF` bleu | ↗ | passage |
| blocked | `#FF4444` rouge | ✖ | bloqué |
| **stale+active** | rouge | **!** | **CRASH probable** (heuristique v1 : à garder) |
| offline/absent | dim | — / ○ | absent |

Plus : **âge relatif** (`5m`, `2h30m`, `3j`) et **détection stale** (event trop vieux = grisé).
Ce sont des idées **fonctionnelles** du v1, pas du décor — je les porte.

### 4.2 Les decks (sections de l'écran)
| Deck | Panels | Rôle |
|---|---|---|
| **BRIDGE** | health global (LED), readiness deep résumé, quiescence, horloge, débit d'events | vue commande, coup d'œil 3 sec |
| **PODS** | grille de **workflow_maps par rôle** (icône SVG + phase/conditions/stale→CRASH/âge) | façon monitor v1, le cœur opérationnel |
| **FLOW** | file de mandats (pending/active/done/failed) + pipelines par état + stages | le travail en cours |
| **GATEKEEPER** | escalades Z3-B + verdicts + gate_evals en attente | le juge d'exception, rare-par-construction |
| **COORDINATION** | routes Pilot, policies/actions coord, MCP config | le tissu de décision |
| **STREAM** | tail live `%Fleet.Event{}`, critiques surlignés | la colonne vertébrale brute |
| **DIAGNOSTICS** | `not_wired_yet`, boot state, root-guard, quota OAUTH | la santé profonde |

### 4.3 Intégration des assets (`/tmp/LCARS_design/`)
- **Icônes SVG de rôles** (architect, consultant, engineer, gatekeeper, qualifier, reviewer,
  starfleet*, vulcan) → en-tête des workflow_maps PODS / GATEKEEPER. (*starfleet : icône dispo mais
  pas de panel starfleet — non-négo #2.)
- **favicon.svg / favicon-minimal.svg** → onglet.
- **CSS LCARS** (clean-room, repris du squelette :8089 `lcars-tva.css` + analyse *Charte LCARS*)
  → frame, bezels, panels, LED, CRT-overlay.
- **Gitea LCARS Skin** + **Analyse Charte LCARS** → références de palette/typo pour cohérence
  visuelle inter-surfaces (gitea, dashboard, deck = même monde).

---

## 5. Décisions techniques (P4 — tranché, exposé)

1. **App** : `fleet_observation` (OTP `:fleet_observation`, `Fleet.Observation.*`). Distinct du
   sœur `fleet_dashboard`/`:8089` (le dashboard `:8080/dashboard` a été RETIRÉ, acte3 vague B) → ménage
   au final. Vocab aligné BL-026 (`Fleet.Observability`/`ReadModel`).
   - **Flag convergence** : à la fusion des branches, 2 « dashboards » natifs cohabiteront
     (`fleet_dashboard` :8089 et `fleet_observation` :8091). Décision de ménage = user, plus tard.
2. **Port** : `:8091`, knob `LCARS_OBSERVATION_PORT`. Coexiste avec 8080/8089/8090.
3. **Ring 4**, listener Cowboy dédié, **guardé `:test`** (`start_listener: false` en test — invariant
   hermétique, sinon `mix test` bind le port).
4. **Auth** : **aucune** sur le deck (read-only, GET-only, intra-release, ADR-C « 5-zéros »).
   Distinct de la question API-D1 (WS `/ws`) — ici c'est de la **lecture** pure, pas de mutation.
5. **Frontière starfleet** : exclue (non-négo #2).
6. **Read-model** : `ReadModel` GenServer + ETS (`:read_concurrency`), seul abonné au bus côté
   observabilité ; le deck lit l'ETS. Snapshot au boot.

---

## 6. Incréments

- **A — Design note** (ce doc) : catalogue + organisation + thème. ✅ *(la base de travail)*
- **B — Scaffold** : app `fleet_observation`, `Application` (supervisor + Cowboy :8091 guardé test),
  `Deck` (Plug.Router : `/`, `/health`, `/api/*`, `/static/*`), intégration assets LCARS,
  squelette des 7 decks (lecture directe `list_pods` d'abord, comme :8089). README contrat.
- **C — Read-model** ✅ : `Fleet.Observation.ReadModel` (GenServer + ETS, abonné unique
  `%Fleet.Event{}`). Routage deck par préfixe de type (catalogue data). Le deck lit la projection
  via `ReadModel.projection/0` (read ETS direct, bypass GenServer). Endpoint `/api/projection`,
  6 decks event-dérivés câblés. **Résultat du test architectural** : le core n'a été touché qu'en
  **un** point — l'ajout du read-seam `Fleet.Spawner.list_pods/0`. Couture quasi-propre.

---

## 7. Inspirations intégrées (traçabilité)
- **`fleet-hub.py` v1** → split producteur/lecteur, REST read-only, snapshot+stale, topologie au boot.
- **`fleet-monitor.py` v1** → grammaire couleur+glyphe, workflow_maps par rôle, stale→CRASH, âge relatif, inbox.
- **`fleet_dashboard` :8089 (branche sœur)** → squelette LCARS (frame/panels/LED/clock), `pod_view`
  JSON-safe (exclure les termes non-encodables `last_error`/`last_result`), poll client 3 s.
- **BL-026** → la frontière read-model, la liste des projections, le check P01 frontier-purity (futur).

---

## 8. Questions ouvertes (flags, non bloquants)
- **F-OBS-1** — quota OAUTH/rate-limit (5h/weekly) : la source (statusline stdin par pod, BL-016)
  n'est pas encore câblée côté fleet. Panel DIAGNOSTICS le prévoit, la donnée viendra plus tard.
- **F-OBS-2** — convergence `fleet_dashboard` :8089 vs `fleet_observation` :8091 : ménage user.
- **F-OBS-3** — check P01 frontier-purity (`reads_internal_genserver_state:false`) à folder dans
  `mix lcars.contracts.check` plus tard (downstream, ne pas élargir le scope maintenant).
