# fleet_mcp

**Date** : 2026-05-18
**Dernière révision** : 2026-06-23
**Statut** : implémenté — serveur MCP pod-facing (`get_task` / `submit_result`)
**Référencé par** : `04_design-notes/` (ring4/fleet_mcp)

Serveur MCP LCARS (Ring 4) — frontière vendor `mcp_*` (ADR-C) : wrappe le SDK
`ex_mcp` derrière un contrat opaque et expose aux pods les outils MCP du runtime.

## Modules

- `Fleet.MCP.PodTools` — outils MCP **pod-facing** : `get_task` (le pod tire son
  mandat depuis la TaskQueue), `submit_result` (le pod rend son livrable), `create_ticket`
  (l'arch délègue une implémentation) et `create_project` (l'arch onboard un projet neuf).
  `handle_tool_call/3` = fonctions pures, réutilisables hors transport.
- `Fleet.MCP.Server` — **garde de boot ADR-C** : `start_link/1` refuse
  (`{:error, :forbidden_in_pod}`) si `boot_environment == :pod` → `fleet_mcp` ne boote
  jamais côté pod (D7-bis). L'ancienne API husk `register_channel`/`list_channels`
  (push channel) + le `ServerBehaviour` sont **retirés** (F049 — morts chantier 7, 0 appelant prod).
- `Fleet.MCP.Supervisor` / `Fleet.MCP.Application` — supervision de l'app.

## Outils MCP (pod-facing)

- `get_task` — le pod récupère son mandat (corrélé `pod_id`).
- `submit_result` — le pod soumet son livrable (`payload`).
- `create_ticket` (délégation) — l'architecte délègue une brique : crée l'issue forge **prête pour le
  poller** (`Fleet.Pilot.ForgeClient.create_issue`, dispatch runtime) — auteur=arch (token de rôle de
  l'appelant **résolu depuis le SPAWN** : binding `pod_id → role` côté serveur via `Fleet.Spawner.pod_info`,
  **PAS** le `_lcars_role` du wire non authentifié — MA-15, anti-usurpation), **assignee=humain** owner
  (login OS, `Fleet.Credentials.Human`) — puis **STOP**. Pas de label : le rôle producteur est un invariant
  côté poller, pas un marqueur par-ticket. Le poller prend le relais (forge-state-machine, BL-050 : plus de
  `start_pipeline`/rail RAM). Seams test : `:forge_client`, `:role_resolver`.
- `create_project` (Rail 1 — onboarding) — l'architecte démarre un projet neuf : `Fleet.Pilot.ProjectOnboard.onboard/2`
  (repo forge + dual-worktree `main`/`work/ops` + scaffold + push). Le projet créé devient la cible de
  délégation (`:delegation_repo`) → enchaîner `create_ticket`. Dispatch runtime (pas de dep compile-time `fleet_pilot`).

NB **bridge stdio** (`bin/fleet_mcp_stdio_bridge.py`) : la liste `TOOLS` est hardcodée — tout nouveau tool
doit y être ajouté en miroir (dette connue : proxifier `tools/list` vers le central).

## Configuration

- `:fleet_mcp, :pod_facing_port` — port d'écoute MCP côté pods.
- `:fleet_mcp, :boot_environment` — environnement injecté au boot du serveur.

## Frontière vendor

`mcp_*` = N1 (ADR-C) : le SDK `ex_mcp` est wrappé derrière `Fleet.MCP.PodTools`
(`use ExMCP.Server`, tools `get_task`/`submit_result`) ; bascule vers un autre SDK
(Hermes) possible sans toucher les consommateurs.
