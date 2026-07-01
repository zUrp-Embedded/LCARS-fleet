# Fleet.EventRouter

**Date** : 2026-05-09
**Dernière révision** : 2026-07-01 (registry-vide rendu EXPLICITE : flag `:permit_when_registry_empty` ; bornes de restart explicites sur le superviseur d'app 3/60 ; BL-027 — fork tranché : Dispatch retiré, `Catalog` charge le registry au boot, events.yaml = registry pur ; R5 — purge handlers fantômes)
**Statut** : implémenté run #3.1 chantier #11 — design note PROMOTED ; + `Fleet.Shutdown.Quiesce` (R4 D5, primitive drain partagée)
**Référencé par** : 04_design-notes/fleet_event_router.md

Bus events (Phoenix.PubSub) + registry events.yaml LCARS v2 (Ring 2 —
colonne vertébrale orchestration). Consommation = subscribers directs
PubSub (BL-027 ; table de dispatch retirée). Webhooks Gitea + signaux OS + events
internes (`pod.*`, `pipeline.*`, `audit.verdict.*`,
`pod_drift`)
publiés sur Phoenix.PubSub topic `fleet.events`.

## Sous-modules

- `Fleet.EventRouter.Bus` — Phoenix.PubSub instance `Fleet.PubSub`
  (broadcast / subscribe / validation schema NDJSON soft)
- `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP `:8081` +
  HMAC SHA256 verify (secret `/etc/fleet/webhook-secret`)
- `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` SIGUSR1/SIGTERM/SIGHUP
  → broadcast `os.signal.<sig>`
- `Fleet.EventRouter.Catalog` — charge le **registry** `priv/events.yaml` au boot
  (`load!/0` → `authorized_event_types`). Source unique du parse exposée :
  `event_type_strings/0` (clés-types, réutilisée par `Application.preregister_event_atoms/0`,
  dedup F035) + `events_yaml_path/0` (résolution du path). Consommation = subscribers
  directs PubSub (BL-027 ; ex-`Dispatch` retiré, cf. § Catalogue)
- `Fleet.EventRouter.BindAddress` — source UNIQUE de l'IP de bind des listeners
  Cowboy du runtime (`ip/1`). Vit ici car substrat universel (comme `Fleet.Event`)
  consommé par les 4 surfaces HTTP (`fleet_api`, `fleet_mcp`, `fleet_observation`,
  webhook) sans inversion de layering. Invariant : loopback `{127,0,0,1}` par
  défaut, exposition = opt-in nommé (`LCARS_BIND_HOST` global, override de surface
  ex. `LCARS_WEBHOOK_BIND_HOST`)
- `Fleet.Shutdown.Quiesce` — primitive partagée du drain de shutdown (flag
  `:persistent_term` `quiescing?/refuse!/resume!`). Vit ici car substrat
  universel (comme `Fleet.Event`) : lisible par `fleet_pipeline`/`fleet_api`
  (gate top-level) sans inversion de layering. Policy (quand quiescer) =
  `fleet_starfleet` (`Shutdown.AggregateDispatcher`). Pas de process (Iron Law)

## API principale

```elixir
# Broadcast canon (struct %Fleet.Event{}) — fail-loud si type hors registry
Fleet.EventRouter.Bus.broadcast("fleet.events", %Fleet.Event{
  source: :spawner, type: :"pod.allocate",
  timestamp: DateTime.utc_now(), payload: %{"pod_id" => "p1"}})

# Subscribe + receive (subscriber direct = canon, BL-027)
Fleet.EventRouter.Bus.subscribe()
receive do
  %Fleet.Event{type: :"pod.allocate"} = event -> ...
end

# (Compat shim legacy 3-arity {atom, map} — à retirer ch3 BL-021)
# Fleet.EventRouter.Bus.broadcast("pod.allocate", %{...}, ticket_id: "...")
```

## Configuration

- `:fleet_event_router, :start_webhooks` — boot Plug.Cowboy webhooks
  (default `false` — dev/test ne touchent pas le port `:8081`)
- `:fleet_event_router, :load_event_registry` — charge le registry events.yaml
  au boot (`Catalog.load!`, default `true` ; `false` en `:test` pour l'hermétisme
  — registry vide → validation broadcast off). En prod (`true`), un events.yaml
  absent/invalide **raise** (crash-boot, F-008/Pattern A : pas de Bus sans
  validation — un deploy cassé ne démarre pas)
- `:fleet_event_router, :permit_when_registry_empty` — régime du Bus quand
  `authorized_event_types` est **vide** (boot précoce / test sans registry).
  `true` (défaut) = laisse passer (safety-net d'init voulu, pas un by-pass : dès
  que le set est peuplé la validation tranche) ; `false` = **fail-closed** (raise
  tant que `Catalog.load!` n'a pas chargé le registry). Le comportement vide est
  ainsi EXPLICITE, plus un trou silencieux. Voir `Bus.assert_authorized!/1`
- `:fleet_event_router, :start_signals` — boot SignalsOS GenServer
  (default `false` — éviter capture signaux dans les tests)
- `:fleet_event_router, :webhook_port` — port HTTP webhooks (default 8081)
- `LCARS_WEBHOOK_BIND_HOST` / `LCARS_BIND_HOST` (env) — IP de bind du listener
  webhook. **Loopback `127.0.0.1` par défaut.** Le webhook est la SEULE surface
  dont l'exposition publique est un besoin légitime : une forge Gitea sur une
  autre machine POST dessus (loopback la bloquerait). `LCARS_WEBHOOK_BIND_HOST`
  (ex. `0.0.0.0`) expose CE listener seul, sans toucher les surfaces de commande
  (`fleet_api`, deck). `LCARS_BIND_HOST` (global) l'expose aussi ; l'override de
  surface l'emporte. Protection = HMAC SHA256 (indépendant du bind). Source
  unique : `Fleet.EventRouter.BindAddress`.
- `:fleet_event_router, :webhook_secret_path` — path secret HMAC
  (default `/etc/fleet/webhook-secret`)
- `:fleet_event_router, :events_yaml_path` — path catalogue YAML
  (default `priv/events.yaml`)
- `:fleet_event_router, :captured_signals` — atoms signaux à capturer
  (default `[:sigusr1, :sigterm, :sighup]`)

## Catalogue events.yaml — registry (BL-027)

`priv/events.yaml` est un **registry PUR** : ses **clés** = `authorized_event_types`,
chargées au boot par `Fleet.EventRouter.Catalog.load!/0` → `Bus.broadcast/2`
**fail-loud** sur tout type hors registry (verrou anti-récurrence, T4). Tout event
émis DOIT avoir sa clé. Les **valeurs sont `[]`** (le runtime n'en consomme aucune).

La **consommation** se fait par **subscribers directs** (Phoenix.PubSub :
`Bus.subscribe` + `handle_info` — WS dashboard, `AuditConsumer`, `DriftMonitor`,
`Spawner.PublishConsumer`, …). Qui consomme quoi est documenté
dans le moduledoc de chaque consommateur.

> **Décision BL-027 (user 2026-06-05)** : « subscribers directs = canon ». Le
> GenServer `Dispatch` (table `event → handle_event/1`, jamais câblée — aucun
> module n'implémentait `handle_event/1`) a été **retiré** ; PubSub `subscribe` EST
> le dispatch. Le chargement du registry, auparavant couplé au `Dispatch` off-en-prod
> (→ validation broadcast inactive en prod), est désormais fait par `Catalog.load!`
> au boot (prod-on/test-off). Audit des ~15 émetteurs : les statiques émettent des
> types registrés, les dynamiques externes (`webhooks_gitea`/`signals_os`/`policies`/
> `Pod.best_effort_broadcast`) rescue `UnregisteredError` → activation sûre. MA-04 : le lifecycle
> `pod.completed`/`work_item_completed` passe par `required_broadcast` (PROPAGE l'échec, ne l'avale pas).

## Dépendances

- `phoenix_pubsub` 2.x — bus distribution-ready
- `plug` 1.15+ + `plug_cowboy` 2.7+ — HTTP webhooks
- `jason` — JSON encode/decode
- `ex_json_schema` — schema validation soft
- `yaml_elixir` — parse du registry `events.yaml` (Catalog + preregister ; la dispatch table est retirée BL-027)

## Cohérence cross-design-notes

- Consommé par chantiers PROMOTED (6, 7, 9, 10) + à venir (12, 13,
  14, 15)
- Frontière vendor N0 (vendor-agnostic)
- F-TEST-MCP mitigation deferred — MCP routing in-process tools
  `fleet_*` post-1er tool concret (chantier 13 ou 15)
