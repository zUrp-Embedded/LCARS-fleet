# fleet_mcp

**Date** : 2026-05-18
**Dernière révision** : 2026-06-12
**Statut** : implémenté — serveur MCP pod-facing (`get_task` / `submit_result`)
**Référencé par** : `04_design-notes/` (ring4/fleet_mcp)

Serveur MCP LCARS (Ring 4) — frontière vendor `mcp_*` (ADR-C) : wrappe le SDK
`ex_mcp` derrière un contrat opaque et expose aux pods les outils MCP du runtime.

## Modules

- `Fleet.MCP.PodTools` — outils MCP **pod-facing** : `get_task` (le pod tire son
  mandat depuis la TaskQueue) et `submit_result` (le pod rend son livrable).
  `handle_tool_call/3` = fonctions pures, réutilisables hors transport.
- `Fleet.MCP.Server` — wrap opaque du SDK `ex_mcp` (registre de channels opaque
  `register_channel/2` + `list_channels/0`, gardé pour extensibilité future).
- `Fleet.MCP.ServerBehaviour` — contrat (4 fonctions) pour tests/mocks + bascule
  SDK ultérieure (ExMCP → Hermes) sans casser les apps consommatrices.
- `Fleet.MCP.Supervisor` / `Fleet.MCP.Application` — supervision de l'app.

## Outils MCP (pod-facing)

- `get_task` — le pod récupère son mandat (corrélé `pod_id`).
- `submit_result` — le pod soumet son livrable (`payload`).

## Configuration

- `:fleet_mcp, :pod_facing_port` — port d'écoute MCP côté pods.
- `:fleet_mcp, :boot_environment` — environnement injecté au boot du serveur.

## Frontière vendor

`mcp_*` = N1 (ADR-C) : le SDK `ex_mcp` est wrappé derrière `Fleet.MCP.Server` ;
bascule vers un autre SDK (Hermes) possible sans toucher les consommateurs.
