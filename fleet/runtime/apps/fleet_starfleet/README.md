# fleet_starfleet (chantier 13)

**Date** : 2026-05-10
**Dernière révision** : 2026-07-05 (dédup B4/D8 : plomberie GenServer périodique de `MCPMonitor`/`MCPWatcher` → fonctions partagées `Fleet.Starfleet.PeriodicCheck` (pas de macro), chaque jumeau garde init/do_check/forme de réponse ; B-R2 dédup chargé-caché : `Gatekeeper.init_schema!/0` + get-or-raise délégués à `Fleet.SchemaCache`, autorité Ring 0 ; 2026-07-02 : test du contrat re-subscribe au Bus après restart — un consommateur d'events tué se ré-abonne via `init/1` et reçoit les events suivants ; R4 D5 — `Shutdown` + backend réel `AggregateDispatcher` câblé prod, seam `:shutdown_dispatcher` ; D2 resync contrat↔code : sous-modules complets (`Application`, `AuditConsumer`, `BootOrchestrator`, behaviours), `in_flight_count` réel (non-permanents + pending, plus de Pipeline RAM), catalogue knobs complet, atomes events à jour)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_starfleet.md`, `STATUS-CHANTIERS.md`

Module système-side consommateur des outputs des pods d'arbitrage
(gatekeeper + autres rôles décisionnels) côté core LCARS Ring 2.
Source : `04_design-notes/fleet_starfleet.md` (Régime 1, profil
**CONFORMANCE**, PoC-π3 PROVEN + PoC-10).

**Pas de pod, pas d'inférence dans ce module** — validation, parsing,
audit, escalade Cat 5 seulement.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Starfleet.Application` | supervisor `:one_for_one` (intensité 3/60 explicite) — `Gatekeeper.init_schema!/0` fail-fast au boot, pré-enregistre les atomes events (`starfleet_event_atoms/0`, cf. Atom registration), démarre les enfants gatés par les knobs `start_*` (cf. Configuration) |
| `Fleet.Starfleet.Decision` | struct sortie validate `{decision, reason, details, chain}` |
| `Fleet.Starfleet.Gatekeeper` | pure functions validation JSON décision (PoC-π3 figé) + schema strict `priv/schema/decision-v1.json` `ex_json_schema` au load fail-fast + cache schema via `Fleet.SchemaCache` (autorité Ring 0, `:persistent_term`) |
| `Fleet.Starfleet.DriftMonitor` | GenServer subscribe `fleet.events`, 4 handlers (`pod.drift`, `workflow_map.failed`, `oauth.refresh.failed`, `audit.verdict`) — cf. Events handlés. Seams test `name:` / `subscribe: false` |
| `Fleet.Starfleet.AuditConsumer` | GenServer subscribe `fleet.events`, log audit-grade **sélectif** (log seul, aucun side effect runtime) : lifecycle pods `pod.completed`/`pod.failed`, boot `fleet.boot_complete\|partial\|failed`, task-queue `work_item.*`/`state.corrupt`, extensions V2 `sdk.upstream_alert`/`mcp.server_crashed`, `pod.drift` (dormant, 0 producteur). Seam test `subscribe: false` |
| `Fleet.Starfleet.BootOrchestrator` | Task `:transient` post-readiness — `Fleet.Spawner.PermanentBoot.boot_permanent_pods/0` (gaté par `auto_boot_enabled?/0`, env `LCARS_BOOT_PERMANENT_AT_START`) puis émet `fleet.boot_complete\|partial\|failed` (best-effort via `Bus.safe_emit`). Ne crash JAMAIS le daemon : rescue → `fleet.boot_failed`, mode degraded |
| `Fleet.Starfleet.Cat5Escalator` | pure functions `escalate/3` (source, payload, correlation_id) → log `AuditLog` + broadcast canon `starfleet.audit_cat5_<source>` + délégation `CoordBackend.handle_escalation/3` (miss de routage → `Logger.warning`, jamais avalé muet). Les 3 sources câblées bout en bout mais **dormantes** (events d'entrée sans producteur live) |
| `Fleet.Starfleet.AuditLog` | wrapper `File.write/3` non-bang fail-safe sur `~/.lcars/log/fleet-starfleet.jsonl` (NDJSON append, chemin défaut via `Fleet.Layout.state_dir()`). **Rotation au seuil** (`:audit_log_max_bytes`, défaut 10 MB) → 1 backup `.1` : l'audit local est une convenance forensics, le durable = forge |
| `Fleet.Starfleet.CoordBackend` | behaviour seam wrap `Fleet.Coord` ch14 (`handle_decision/2`, `handle_escalation/3` — correlation_id explicite). `resolved/0` = **source unique** du backend résolu (config + défaut) lue par `Cat5Escalator`/`DriftMonitor` — pas de défaut redupliqué par site |
| `Fleet.Starfleet.CoordBackend.NotWiredYet` | backend défaut (cohérent canon §0 #1) — log debug + `:ok`, escalade audit-only tant que coord pas câblé (prod : `runtime.exs` pose `Fleet.Coord`) |
| `Fleet.Starfleet.MCPMonitor` | GenServer périodique (60s) — health check passif du substrat MCP pod-facing (cible `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` via `which_children`, ou atome nommé) ; transition `:ok → :crashed` → broadcast `mcp.server_crashed` (retour = log seul) |
| `Fleet.Starfleet.MCPWatcher` | GenServer périodique (hebdo) — drift de version du SDK MCP (`ex_mcp`) local vs Hex.pm ; mismatch → broadcast `sdk.upstream_alert` (fetcher injectable `:mcp_watcher_upstream_fetcher`) |
| `Fleet.Starfleet.PeriodicCheck` | plomberie PARTAGÉE des deux jumeaux ci-dessus : `start_link(module, opts)` (GenServer nommé), `schedule/2` (send_after récursif), `tick/3` (corps du handle_info), `check_now/3` (hook test sync). Fonctions, pas de macro `use` ; chaque jumeau garde son `init/1`, son `do_check/1` et la forme de sa réponse. NE PAS généraliser au-delà de ces 2 modules |
| `Fleet.Starfleet.Shutdown` | GenServer grace shutdown coordonné (`begin/1`, `drain_in_flight/1`) — DN ring0 `lcars-fleet_service`. Déclencheur historique (`ExecStop` systemd) retiré 2026-06-16, à recâbler sur `fleet_v2 stop` (backlog graceful-shutdown) — la logique de drain reste valide. Seam `:shutdown_dispatcher` (behaviour `Shutdown.Dispatcher`). `configured_dispatcher/0` = **source unique** du backend résolu (config + défaut canon `NoOpDispatcher`), lue à l'`init` ET par la readiness (`fleet_api`) — pas de second défaut à aligner |
| `Fleet.Starfleet.Shutdown.Dispatcher` | behaviour du seam (`refuse_new_jobs/1`, `in_flight_count/0`) — EST l'abstraction du drain (pas de god-module `Fleet.Dispatcher`, décision user 2026-06-05) |
| `Fleet.Starfleet.Shutdown.NoOpDispatcher` | backend défaut test/fallback — drain immédiat 0 in-flight (honnête-dégradé, documenté, pas un Goodhart) |
| `Fleet.Starfleet.Shutdown.AggregateDispatcher` | backend **réel** (câblé prod runtime.exs) — `in_flight_count` = pods vivants **non-permanents** (`Spawner.list_pods` filtré par `PermanentBoot.permanent?/1` — les résidents Type 1/3 ne comptent pas, sinon drain inatteignable) + work items `:pending` (`TaskQueue.list_pending` par `apply`, seulement si l'app tourne — pas d'inversion de layering). Plus de comptage pipelines RAM (moteur `Fleet.Workflow.Executor` supprimé). **Fail-CLOSED** : comptage injoignable (restart en plein quiesce) → sentinel > 0, le drain attend son timeout au lieu de conclure « vide » à tort. `refuse_new_jobs` active `Fleet.Shutdown.Quiesce` |

(`Fleet.Starfleet` lui-même = moduledoc de tête du namespace, aucun code.)

## Public API

```elixir
{:ok, %Fleet.Starfleet.Decision{decision: "halt", reason: "r", details: %{}, chain: []}} =
  Fleet.Starfleet.Gatekeeper.validate(~s|{"decision":"halt","reason":"r","details":{}}|)

# correlation_id explicite (3e argument, nil hors work item)
:ok = Fleet.Starfleet.Cat5Escalator.escalate(:pod_drift, %{"pod_id" => "p1", "drift_count" => 3}, nil)

:ok = Fleet.Starfleet.AuditLog.write(%{"source" => "test", "action" => "boot"})
```

## Schema décision (PoC-π3 figé)

```json
{
  "decision": "allow|halt|escalate|retry",
  "reason": "string non-vide",
  "details": {},
  "chain": ["string", ...]
}
```

`reason`, `decision`, `details` requis. `chain` optionnel (default `[]`).

## Events handlés (DriftMonitor)

| event_type | trigger Cat 5 |
|---|---|
| `pod.drift` | si `drift_count >= 3` — dormant : émetteur prévu (filtre IPC pod-side) jamais implémenté, 0 producteur |
| `workflow_map.failed` | inconditionnel — dormant : producteur historique (moteur RAM `Fleet.Workflow.Executor`) supprimé |
| `oauth.refresh.failed` | inconditionnel — dormant : pas de producteur câblé |
| `audit.verdict` | `Gatekeeper.validate` puis `CoordBackend.handle_decision/2` ; verdict non routé → `Logger.warning` (pas jeté muet) |

Les 3 chemins Cat 5 sont câblés de bout en bout (DriftMonitor → Cat5Escalator →
broadcast + coord) mais dormants tant qu'aucun producteur n'émet leurs events d'entrée.

## Atom registration

Atomes events pré-enregistrés compile-time via l'attribut
`@starfleet_event_atoms` de `Fleet.Starfleet.Application` (exposé
`starfleet_event_atoms/0`) :

* `starfleet.audit_cat5_{pod_drift,workflow_map_failed,oauth_refresh_failed}` — escalades Cat 5 (les anciens `audit.cat5.*` pointillés étaient des vestiges jamais émis)
* `audit.verdict`
* `fleet.boot_{complete,partial,failed}` — lifecycle BootOrchestrator
* `sdk.upstream_alert`, `mcp.server_crashed` — extensions V2 (MCPWatcher/MCPMonitor)

Cohérent ch11 M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).

## Schema cache `:persistent_term`

Schema `decision-v1.json` chargé une fois au boot via
`Fleet.Starfleet.Gatekeeper.init_schema!/0` (appelé par
`Application.start/2`), délégué à l'autorité Ring 0 `Fleet.SchemaCache`
(`fleet_event_router` — dédup B-R2), clé
`{Fleet.Starfleet.Gatekeeper, :decision_schema}`. Lecture par
`SchemaCache.fetch!/2` (raise actionnable si pas chargé).

## Configuration (knobs `:fleet_starfleet`)

### Gating des enfants du superviseur

Tous posés à `false` par `config/test.exs` (hermétisme : subscribers Bus,
emit `fleet.boot_*`, timers et drain global parasiteraient les tests async —
les tests dédiés instancient manuellement avec opts isolés).

| Clé | Défaut | Enfant gaté |
|---|---|---|
| `:start_drift_monitor` | `true` | `DriftMonitor` |
| `:start_shutdown` | `true` | `Shutdown` |
| `:start_audit_consumer` | `true` | `AuditConsumer` |
| `:start_boot_orchestrator` | `true` | `BootOrchestrator` |
| `:start_mcp_monitor` | `true` | `MCPMonitor` (purement local, zéro I/O réseau) |
| `:start_mcp_watcher` | `false` | `MCPWatcher` — **opt-in** (HTTP sortant Hex.pm, à activer là où l'outbound est autorisé) |

### Backends (seams)

| Clé | Défaut | Rôle |
|---|---|---|
| `:coord_backend` | `CoordBackend.NotWiredYet` — prod (`runtime.exs`) : `Fleet.Coord` | backend décision/escalade, lu via `CoordBackend.resolved/0` |
| `:shutdown_dispatcher` | `Shutdown.NoOpDispatcher` — prod (`runtime.exs`) : `Shutdown.AggregateDispatcher` | backend drain, lu via `Shutdown.configured_dispatcher/0` |
| `:spawner_mod` | `Fleet.Spawner` | seam **test uniquement** (stub d'un `list_pods` qui lève/exit) — la prod ne pose jamais cette clé |

### Paramètres

| Clé | Défaut | Rôle |
|---|---|---|
| `:decision_schema_path` | `priv/schema/decision-v1.json` (via `:code.priv_dir`) | schema JSON décision (Gatekeeper) |
| `:audit_log_path` | `Fleet.Layout.state_dir()/log/fleet-starfleet.jsonl` (≈ `~/.lcars/log/…`) — env `LCARS_STARFLEET_AUDIT_LOG` mappée par `runtime.exs` | log NDJSON audit Cat 5 |
| `:audit_log_max_bytes` | `10 * 1024 * 1024` (10 MB) | seuil de rotation (1 backup `.1`) |
| `:mcp_monitor_check_interval_ms` | `60_000` | période health check MCP |
| `:mcp_monitor_target` | `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` | cible liveness (`{:supervised, sup, child_id}` ou atome nommé) |
| `:mcp_watcher_check_interval_ms` | `:timer.hours(168)` (hebdo) | période check version SDK |
| `:mcp_watcher_package` | `"ex_mcp"` | package Hex.pm surveillé |
| `:mcp_watcher_upstream_fetcher` | `nil` (→ fetch API Hex.pm via Req) | fetcher injectable (tests déterministes) |

## Tests

```bash
( cd apps/fleet_starfleet && mix test )
# 1 doctest + 57 tests, 0 failures
```

## Dépendances

* `fleet_event_router` (ch11 PROMOTED) — Bus PubSub events + `Fleet.SchemaCache` (autorité chargé-caché Ring 0)
* `fleet_cap_profile` — `Fleet.Layout.state_dir()` (chemin défaut du log audit)
* `fleet_spawner` — `PermanentBoot` (BootOrchestrator, filtre permanents du drain) + `list_pods` (AggregateDispatcher) ; pas de cycle (spawner ⊀ starfleet vérifié)
* `:jason`, `:ex_json_schema`, `:req` (MCPWatcher — fetch Hex.pm)

**Pas** des dépendances mix, câblés autrement :

* `fleet_coord` (ch14) — backend posé à runtime par la config (`runtime.exs` → `:coord_backend, Fleet.Coord`), défaut `NotWiredYet`
* `fleet_task_queue` — `list_pending` lu par `apply` (module en variable, aucune dép compile-time — pas d'inversion de layering), seulement si l'app tourne réellement

## Frontière vendor

N0 (vendor-agnostic, pas d'inférence ni d'appel SDK direct).
