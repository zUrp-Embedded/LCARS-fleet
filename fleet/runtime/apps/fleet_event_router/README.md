# Fleet.EventRouter

**Date** : 2026-05-09
**Dernière révision** : 2026-06-05 (R5 — purge handlers fantômes + fail-loud boot Dispatch ; events.yaml = registry + dispatch)
**Statut** : implémenté run #3.1 chantier #11 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_event_router.md

Bus events + dispatch table déclarative LCARS v2 (Ring 2 — colonne
vertébrale orchestration). Webhooks Gitea + signaux OS + events
internes (`pod.*`, `pipeline.*`, `audit.verdict.*`,
`refuse_pattern_match`, `pod_drift`, `permission_relay_request`)
publiés sur Phoenix.PubSub topic `fleet.events`.

## Sous-modules

- `Fleet.EventRouter.Bus` — Phoenix.PubSub instance `Fleet.PubSub`
  + sous-topics `fleet.events.<scope>.<id>` (broadcast / subscribe /
  validation schema NDJSON soft)
- `Fleet.EventRouter.Schema` — JSON schema NDJSON (5 required + 3
  optional) validé `ex_json_schema`
- `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP `:8081` +
  HMAC SHA256 verify (secret `/etc/fleet/webhook-secret`)
- `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` SIGUSR1/SIGTERM/SIGHUP
  → broadcast `os.signal.<sig>`
- `Fleet.EventRouter.Dispatch` — table YAML déclarative `priv/events.yaml`
  → handlers `apply(module, :handle_event, [event])`
- `Fleet.EventRouter.Sanitize.Secrets` — redact `<TOKEN_REDACTED>`
  (sk-..., ghp_...) PoC-7
- `Fleet.EventRouter.Sanitize.PII` — redact `<EMAIL_REDACTED>` PoC-7

## API principale

```elixir
# Broadcast
Fleet.EventRouter.Bus.broadcast("pod.allocate", %{"pod_id" => "p1"},
  ticket_id: "fleet/lcars#42")

# Subscribe + receive
Fleet.EventRouter.Bus.subscribe()
receive do
  {:"pod.allocate", event} -> ...
end

# Sous-topic (ch10 step 4 relay pattern)
Fleet.EventRouter.Bus.subscribe("fleet.events.relay.<ref>")
Fleet.EventRouter.Bus.broadcast_subtopic("relay.<ref>",
  {:permission_relay_response, %{ref: "...", decision: :allow}})

# Sanitize chain composable
text |> Fleet.EventRouter.Sanitize.Secrets.run()
     |> Fleet.EventRouter.Sanitize.PII.run()
```

## Configuration

- `:fleet_event_router, :start_webhooks` — boot Plug.Cowboy webhooks
  (default `false` — dev/test ne touchent pas le port `:8081`)
- `:fleet_event_router, :start_dispatch` — boot Dispatch GenServer
  (default `false`)
- `:fleet_event_router, :start_signals` — boot SignalsOS GenServer
  (default `false` — éviter capture signaux dans les tests)
- `:fleet_event_router, :webhook_port` — port HTTP webhooks (default 8081)
- `:fleet_event_router, :webhook_secret_path` — path secret HMAC
  (default `/etc/fleet/webhook-secret`)
- `:fleet_event_router, :events_yaml_path` — path catalogue YAML
  (default `priv/events.yaml`)
- `:fleet_event_router, :captured_signals` — atoms signaux à capturer
  (default `[:sigusr1, :sigterm, :sighup]`)

## Catalogue events.yaml — double rôle

`priv/events.yaml` sert **deux** fonctions (cf. en-tête du fichier) :
1. **Clés = registry** `authorized_event_types` : `Bus.broadcast/2` fail-loud
   sur tout type hors registry. Tout event émis DOIT avoir sa clé.
2. **Valeurs = table de dispatch** `event → [handler]`. `[]` = registré mais
   **non dispatché** → consommé par des **subscribers directs** (`Bus.subscribe`
   + `handle_info` : WS dashboard, `AuditConsumer`, `DriftMonitor`, `Executor`).

**R5/R08** : les handlers fantômes (modules absents) ont été purgés ; `Dispatch.init`
+ `reload` sont **fail-loud** sur tout handler référencé-mais-absent (verrou
anti-récurrence, T4).

> ⚠️ **État connu (à trancher — fork architectural, hors R5)** : la table de
> dispatch est aujourd'hui **inerte** — (a) aucun module n'implémente
> `handle_event/1` (les handlers réels consomment via `Bus.subscribe`, pas via
> Dispatch) ; (b) `start_dispatch: false` par défaut → en prod le registry n'est
> pas chargé (validation broadcast inactive). Réactiver Dispatch en prod exige
> un audit « tous les types émis sont registrés » (sinon crash au 1er broadcast
> non-registré). Décision : raviver la table de dispatch (`handle_event/1` +
> enable prod + audit) OU acter « subscribers directs = canon » et retirer la
> table. Voir REPRISE/point.

## Dépendances

- `phoenix_pubsub` 2.x — bus distribution-ready
- `plug` 1.15+ + `plug_cowboy` 2.7+ — HTTP webhooks
- `jason` — JSON en07_code/decode
- `ex_json_schema` — schema validation soft
- `yaml_elixir` — dispatch table parse

## Cohérence cross-design-notes

- Consommé par chantiers PROMOTED (6, 7, 9, 10) + à venir (12, 13,
  14, 15)
- Frontière vendor N0 (vendor-agnostic)
- F-TEST-MCP mitigation deferred — MCP routing in-process tools
  `fleet_*` post-1er tool concret (chantier 13 ou 15)
