# Fleet.EventRouter

**Date** : 2026-05-09
**Dernière révision** : 2026-07-05 (D2 resync contre le code : Ring 0 [renumérotation 2026-07-04], Bus struct-only [pas de validation JSON soft, shim 3-arity inexistant], + `Fleet.Event`/`Application`/façade en sous-modules, § Contracts.Check [17 checks], env vars webhook, SignalsOS dormant ; B5 dédup « child-spec listener » : + `Fleet.EventRouter.Listener.cowboy_child/1`, source unique du child-spec Plug.Cowboy des 3 surfaces HTTP api/observation/webhook — ip BindAddress posée par construction, gates+ports restent chez les apps ; B-R2 dédup « schema/config chargé-caché » : + `Fleet.SchemaCache`, autorité Ring 0 du pattern `:persistent_term` (`resolve_json_schema!` / `fetch!` / `cached`), consommé par workflow/starfleet/coord — les copies locales de cap_profile restent, pas d'arête intra-R0 ; B-R1 dédup « émission-Bus-protégée » : `Bus.safe_emit/3-4` = cœur unique de la politique best-effort, les rescue locaux de coord/starfleet/spawner migrent dessus ; registry-vide rendu EXPLICITE : flag `:permit_when_registry_empty` ; bornes de restart explicites sur le superviseur d'app 3/60 ; BL-027 — fork tranché : Dispatch retiré, `Catalog` charge le registry au boot, events.yaml = registry pur ; R5 — purge handlers fantômes)
**Statut** : implémenté run #3.1 chantier #11 — design note PROMOTED ; + `Fleet.Shutdown.Quiesce` (R4 D5, primitive drain partagée)
**Référencé par** : 04_design-notes/fleet_event_router.md

Bus events (Phoenix.PubSub) + registry events.yaml LCARS v2 (Ring 0 —
substrat : 0 dépendance, ~12 apps en dépendent). Consommation = subscribers directs
PubSub (BL-027 ; table de dispatch retirée). Webhooks Gitea + signaux OS + events
internes (`pod.*`, `workflow_map.*`, `work_item.*`, `audit.verdict`,
`pod.drift`)
publiés sur Phoenix.PubSub topic `fleet.events`.

## Sous-modules

- `Fleet.EventRouter` — façade moduledoc-only (index des sous-modules, aucun code)
- `Fleet.Event` — struct canon des events (**wire format UNIQUE** : tous les
  producteurs émettent `%Fleet.Event{}`, aucun tuple). `source` = enum closed
  list (12 sources canoniques), **enforcée** par le constructeur `new/3`
  (« parse, don't validate » : source hors-enum lève). Porte aussi
  `UnregisteredError` (type hors registry)
- `Fleet.EventRouter.Bus` — Phoenix.PubSub instance `Fleet.PubSub`
  (broadcast/subscribe **struct-only** `%Fleet.Event{}` ; la SEULE validation
  au broadcast = appartenance au registry, fail-loud `UnregisteredError` —
  pas de validation JSON soft, pas de `Fleet.EventRouter.Schema`)
- `Fleet.EventRouter.Application` — superviseur d'app : `Catalog.load!` au boot,
  pré-enregistrement des atoms event_type (`preregister_event_atoms` — les
  émetteurs dynamiques passent par `to_existing_atom`, anti atom-leak),
  `gitea_event_types/0` (source unique des actions gitea émissibles), bornes de
  restart 3/60 ; le PubSub vit sous un superviseur DÉDIÉ `max_restarts: 0`
  (un restart local perdrait toutes les souscriptions du node → escalade
  délibérée jusqu'au node)
- `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP (port `:webhook_port`,
  défaut 8081) + HMAC SHA256 verify (secret `/etc/fleet/webhook-secret`)
- `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` SIGUSR1/SIGTERM/SIGHUP
  → broadcast `os.signal.<sig>`. **Dormant** : aucun on-switch runtime ne
  l'active (cf. § Configuration `:start_signals`)
- `Mix.Tasks.Lcars.Contracts.Check` — checker des contrats inter-module
  (verrou de cohérence du repo, cf. § Contracts.Check)
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
- `Fleet.EventRouter.Listener` — source UNIQUE du **child-spec Cowboy** des
  listeners HTTP (`cowboy_child/1` : opts `plug`/`port` requis ; `scheme`,
  `dispatch` RAW, `ref`, `surface_env` optionnels), pendant « spec » de
  `BindAddress` (même concern « comment on expose un listener » — l'`:ip`
  loopback-par-défaut est posée PAR CONSTRUCTION). Consommé par `fleet_api`
  (REST+WS, dispatch), `fleet_observation` (deck) et le webhook Gitea de cette
  app (dedup B5, zéro nouvelle arête). Les gates (`:start_listener`/
  `:start_webhooks`) et la résolution du port restent chez chaque app
- `Fleet.Shutdown.Quiesce` — primitive partagée du drain de shutdown (flag
  `:persistent_term` `quiescing?/refuse!/resume!`). Vit ici car substrat
  universel (comme `Fleet.Event`) : lisible par `fleet_workflow`/`fleet_api`
  (gate top-level) sans inversion de layering. Policy (quand quiescer) =
  `fleet_starfleet` (`Shutdown.AggregateDispatcher`). Pas de process (Iron Law)
- `Fleet.SchemaCache` — autorité du pattern « artefact chargé une fois, caché en
  `:persistent_term` » (dédup B-R2). `resolve_json_schema!(key, path)` :
  read+decode+resolve ExJsonSchema, idempotent, fail-loud au boot ;
  `fetch!(key, hint)` : get-or-raise message actionnable ; `cached(key, fun)` :
  lazy sentinel générique. Vit ici car substrat universel (comme `Fleet.Event`) :
  consommé par `fleet_workflow` (Loader), `fleet_starfleet` (Gatekeeper),
  `fleet_coord` (Policies) sans nouvelle arête. Écrit UNE fois au boot, lu à
  chaque validation — jamais de `put` par-tick (GC storm). Pas de process (Iron Law)

## API principale

```elixir
# Broadcast canon (struct %Fleet.Event{}) sur le topic principal — fail-loud si type hors registry.
# `broadcast_main/1` centralise le littéral du topic ; `main_topic/0` l'expose (autorité).
Fleet.EventRouter.Bus.broadcast_main(%Fleet.Event{
  source: :spawner, type: :"pod.allocate",
  timestamp: DateTime.utc_now(), payload: %{"pod_id" => "p1"}})
# Variante explicite (topic arbitraire) : Fleet.EventRouter.Bus.broadcast(Fleet.EventRouter.Bus.main_topic(), event)

# Idiome producteur : construire l'event canon + broadcaster main en un appel — fail-loud
# (mêmes raises que broadcast_main + ceux de Fleet.Event.new, non attrapés).
Fleet.EventRouter.Bus.emit(:spawner, :"pod.allocate", payload: %{"pod_id" => "p1"})

# Variante PROTÉGÉE pour les émetteurs best-effort (observabilité/escalade) — politique d'erreur
# UNIFIÉE (dédup des rescue locaux coord/starfleet/spawner) : UnregisteredError toléré selon
# `:on_unregistered` (`:log` défaut | `:silent` boot-order nominal) ; event malformé (bug de
# construction) TOUJOURS Logger.error + :ok — jamais avalé muet, jamais un crash de l'émetteur.
# `type` accepte aussi un binaire (to_existing_atom sous le rescue, anti atom-leak).
# PAS pour les events load-bearing (pod.completed) : eux doivent PROPAGER l'échec.
Fleet.EventRouter.Bus.safe_emit(:starfleet, :"mcp.server_crashed",
  [payload: %{"target" => "..."}],
  on_unregistered: :silent, context: "MCPMonitor: alerte NON émise")

# Subscribe + receive (subscriber direct = canon, BL-027) — défaut = main_topic/0
Fleet.EventRouter.Bus.subscribe()
receive do
  %Fleet.Event{type: :"pod.allocate"} = event -> ...
end
```

Il n'existe AUCUN shim 3-arity `broadcast(event_type, payload, opts)` : le Bus
est struct-only (cf. moduledoc `Fleet.EventRouter.Bus` § « Pourquoi struct-only »).

## Configuration

- `:fleet_event_router, :start_webhooks` — boot Plug.Cowboy webhooks
  (default `false` — dev/test ne touchent pas le port `:8081`). On-switch
  runtime : env `LCARS_FLEET_WEBHOOKS=true` (`config/runtime.exs` —
  intégration forge opt-in, défaut OFF)
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
  (default `false`). **Aucun on-switch runtime ne le pose à `true`**
  (`config/runtime.exs`) : le `handle_info({:signal, _})` du GenServer est mort
  (les signaux OS vont au gen_event `:erl_signal_server`, pas au GenServer ;
  SIGUSR1 halterait même la VM). Module gated-off en attendant le vrai fix
  (gen_event handler) ; les clés `os.signal.*` du registry sont dormantes
- `:fleet_event_router, :webhook_port` — port HTTP webhooks (default 8081 ;
  override env `LCARS_FLEET_WEBHOOK_PORT`, lu seulement si
  `LCARS_FLEET_WEBHOOKS=true`)
- `LCARS_WEBHOOK_BIND_HOST` / `LCARS_BIND_HOST` (env) — IP de bind du listener
  webhook. **Loopback `127.0.0.1` par défaut.** Le webhook est la SEULE surface
  dont l'exposition publique est un besoin légitime : une forge Gitea sur une
  autre machine POST dessus (loopback la bloquerait). `LCARS_WEBHOOK_BIND_HOST`
  (ex. `0.0.0.0`) expose CE listener seul, sans toucher les surfaces de commande
  (`fleet_api`, deck). `LCARS_BIND_HOST` (global) l'expose aussi ; l'override de
  surface l'emporte. Protection = HMAC SHA256 (indépendant du bind). Source
  unique : `Fleet.EventRouter.BindAddress`.
- `:fleet_event_router, :webhook_secret_path` — path secret HMAC
  (default `/etc/fleet/webhook-secret` ; override env
  `FLEET_WEBHOOK_SECRET_PATH`)
- `:fleet_event_router, :events_yaml_path` — path registry YAML
  (default `priv/events.yaml` résolu via `:code.priv_dir` — tient en release)
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
> `pod.completed`/`work_item.completed` passe par `required_broadcast` (PROPAGE l'échec, ne l'avale pas).

## Contracts.Check — verrou de cohérence du repo

`Mix.Tasks.Lcars.Contracts.Check` (`lib/mix/tasks/lcars.contracts.check.ex`,
~900 LOC) valide les contrats inter-module AVANT exécution : chaque check garde
une classe de dérive déjà rencontrée (rouge tant que le fix n'est pas landé) —
un agent qui re-dérive casse le build. **17 checks, tous implémentés**
(`@pending_checks` vide) ; sortie YAML `status + checks[] + evidence
(file:line)`, exit≠0 si au moins un check `fail`.

Trois points de lancement :

- `mix lcars.contracts.check` (`--quiet` = exit code seul) — CLI/CI ;
- alias `mix gate` (mix.exs racine) — compile strict + tests + shell gate + checks ;
- step de `mix release` (`verrou_contracts/1`, mix.exs racine, appelle
  `run_checks/0`) — la release REFUSE de bâtir si un contrat est rouge.

Les **combinators** vivent dans le même fichier (section « Combinators ») :
3 familles data-driven — A `presence_check` (marqueur présent dans le code),
B `residue_check` (zéro résidu dans des fichiers vivants), C `evidence_check`
(liste de conditions évaluées au call-site) ; 8 des 17 checks en sont des
instanciations pures. Anti-vert-creux : chaque match est confirmé sur la ligne
strippée de son commentaire (`strip_comment/1` — une mention en commentaire ne
compte pas).

## Dépendances

- `phoenix_pubsub` 2.x — bus distribution-ready
- `plug` 1.15+ + `plug_cowboy` 2.7+ — HTTP webhooks
- `jason` — JSON encode/decode
- `ex_json_schema` — gate structurel **build-time** du canon `events.yaml`
  (`events_schema_test`) ; PAS une validation au broadcast (le broadcast
  vérifie l'appartenance au registry)
- `yaml_elixir` — parse du registry `events.yaml` (Catalog + preregister ; la dispatch table est retirée BL-027)

## Cohérence cross-design-notes

- Consommé par chantiers PROMOTED (6, 7, 9, 10) + à venir (12, 13,
  14, 15)
- Frontière vendor N0 (vendor-agnostic)
- F-TEST-MCP mitigation deferred — MCP routing in-process tools
  `fleet_*` post-1er tool concret (chantier 13 ou 15)
