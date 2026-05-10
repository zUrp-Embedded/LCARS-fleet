# Fleet.ClaudeBridge

**Date** : 2026-05-09
**Dernière révision** : 2026-05-09
**Statut** : implémenté run #3.1 chantier #8 — design note PROMOTED
**Référencé par** : work/beyond_#3.1/design-notes/promoted/fleet_claude_bridge.md

Wrapper SDK Elixir `guess/claude_code` côté LCARS Ring 1. Surface
restreinte (pas exposer pid `Session` aux pods workers) + intégration
disciplines canon LCARS §1 "refus par défaut" (F-ADP-2).

## Sous-modules

- `Fleet.ClaudeBridge.HookRegistry` — F-ADP-2 mitigation CRITICAL :
  force `can_use_tool` non-nil au boot (raise sinon)
- `Fleet.ClaudeBridge.PermissionAdapter` — adapter SDK `can_use_tool`
  délègue à `Fleet.PermissionRouter` (chantier 10) avec backend
  swappable + DefaultDeny par défaut
- `Fleet.ClaudeBridge.SessionWrapper` — wrap permissif `Session.new/1`
  + `Session.send/2`, ref opaque `%{adapter: :port, opaque: term()}`
- `Fleet.ClaudeBridge.MCPRouter` — D3 MCP stdio externe (DSL
  `MCP.Server` SDK BYPASS) → bus events
- `Fleet.ClaudeBridge.Stream` — D4 helpers maison (~100L) sans
  helpers `Stream` SDK (660 LOC SKIP)
- `Fleet.ClaudeBridge.SPInjection` — flags `claude -p`
  `--system-prompt-file` + `--append-system-prompt-file` (N2 / N2bis)

## 5 disciplines SDK (canon design note L62)

1. **Pin exact** — version SDK figée (réintroduction post-pod-1.18)
2. **Wrap systématique** — pas appels SDK directs côté pods/router
3. **Watcher upstream** — surveille releases SDK
4. **Audit 100%** — surface SDK consommée audit chantier 7
5. **PR upstream** — bugs/features remontent à `guess/claude_code`

## Configuration

- `:fleet_claude_bridge, :permission_router_backend` — module backend
  `PermissionAdapter.Backend` (default
  `PermissionAdapter.DefaultDeny`, refus par défaut canon §1)
- `:fleet_claude_bridge, :session_backend` — module backend
  `SessionWrapper.Backend` (default
  `SessionWrapper.NotWiredYet`, câblage post-pod-1.18 + chantier 7)
- `:fleet_claude_bridge, :event_router_backend` — module backend
  `MCPRouter.Backend` (default `MCPRouter.NotWiredYet`,
  câblage chantier 11 `fleet_event_router`)

## SDK dep deferred

Dep `:claude_code` prescrite design note L157 NON introduite tant que
pod qualifier est en Elixir 1.14 (transitif `peri 0.8.4` requiert
`~> 1.17`, fail compile). Cohérent apprentissages A1+A5. Sous-modules
utilisent maps shape-compatibles avec structs SDK (`%{can_use_tool,
hooks_pre, hooks_post}` ↔ `%ClaudeCode.HookRegistry{}`). Wiring SDK
réel = post-pod-1.18 + chantier 7 `fleet_pod_runtime`.
