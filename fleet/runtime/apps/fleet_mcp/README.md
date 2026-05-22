# fleet_mcp — à écrire

**Date** : 2026-05-18
**Statut** : placeholder — app à implémenter post-session
**Dérivé de** : 04_design-notes/ + session 2026-05-17/18 (rings finalisés)

Cette app fait partie du **core V2 cible** (rings finalisés cette session) mais n'est pas encore implémentée.

## Scope V2

MCP server LCARS, wrapper SDK MCP Elixir. Candidats SDK :
- Hermes (cloudwalk, v0.14, mainstream)
- Anubis (zoedsoupe, v1.5, fork)
- ExMCP (azmaveth, supporte ACP bonus)

Étude + choix à faire avant écriture. Frontière vendor `mcp_*` (ADR-C).

Channels custom v2 :
- `fleet-control` (Memory-X V1)
- `fleet-forge` (auto-routing tickets — substitue le pattern Monitor + BOOT sentinel)
