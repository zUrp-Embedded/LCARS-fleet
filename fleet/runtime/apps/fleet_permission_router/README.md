# Fleet.PermissionRouter

**Date** : 2026-05-09
**Dernière révision** : 2026-05-09
**Statut** : implémenté run #3.1 chantier #10 — design note PROMOTED
**Référencé par** : work/beyond_#3.1/design-notes/promoted/fleet_permission_router.md

Module `can_use_tool` callback decisions (Ring 3 gates sécurité).
Invoqué par `Fleet.ClaudeBridge.PermissionAdapter` (chantier 8
PROMOTED, F-ADP-2 mitigation closed). Refus par défaut canon LCARS
v1 §0 #1.

## API

- `Fleet.PermissionRouter.start_link/1` — démarre la GenServer
- `Fleet.PermissionRouter.can_use_tool/3` — décision flow 5 steps,
  retourne `:allow | {:allow, map} | {:deny, reason} | :ask`
- Behaviour `Fleet.PermissionRouter.Callback` exposé (vendor-extensible)

## 5 steps flow (architecture-cible §L559-565 figé)

1. `Fleet.IpcFilter.filter_tool_call/2` (chantier 9 PROMOTED) — deny
   si REFUSE_PATTERN match
2. Auto-allow si `tool in cap_profile.spec.scope.allowedTools`
3. Auto-deny si `tool in cap_profile.spec.scope.disallowedTools`
4. Relay user si `cap_profile.spec.invocation.policy == :show` —
   PubSub broadcast + match ref + receive 30s timeout config
5. Sinon auto-deny par défaut (canon v1 §0 #1)

## Architecture

GenServer minimaliste state-config (process raison runtime = step 4
relay async blocant). State `%{relay_timeout_ms, default_action}`.

`RelayBackend` behaviour swappable (default `NotWiredYet` — câblage
chantier 11 `fleet_event_router`). Cohérent ch3/ch6/ch7/ch8/ch9.

## Configuration

- `:fleet_permission_router, :relay_timeout_ms` — timeout step 4
  (default 30_000)
- `:fleet_permission_router, :default_action` — action step 5
  (default `:deny` — canon, pas réouvrable)
- `:fleet_permission_router, :relay_backend` — module
  `RelayBackend` (default `NotWiredYet`)
- `:fleet_permission_router, :audit_log_path` — path log NDJSON
  (default `/var/log/fleet-audit.jsonl`)
- `:fleet_permission_router, :auto_start` — boot supervisor child
  automatique (default `false` — caller appelle `start_link/1`
  explicitement)

## Cohérence cross-design-notes

- `fleet_claude_bridge` (ch8 PROMOTED) `PermissionAdapter` délègue
  ici (F-ADP-2 mitigation closed côté bridge — adapter mince)
- `fleet_ipc_filter` (ch9 PROMOTED) invoqué step 1 du flow
- `fleet_capprofile` (ch1 PROMOTED) struct `%CapProfile{}` consommée
- `fleet_event_router` (ch11) PubSub bus deferred via RelayBackend
- `fleet_api` (ch15) WebSocket subscribe step 4 relay deferred
