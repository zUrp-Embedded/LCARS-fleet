# fleet_mcp

**Date** : 2026-05-18
**Dernière révision** : 2026-06-24
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

## Identité du pod — prouvée par capability (anti-usurpation)

Le serveur ne croit **JAMAIS** le `_lcars_pod_id` du wire comme autorité : les `pod_id` sont
DÉTERMINISTES (`<repo>-issue-<n>-<role>`, cf. `Fleet.Pilot.PodId`) donc devinables. Un pod (qui a `Bash`
+ joint le central en loopback) pourrait POST le `pod_id` d'un autre pour lire son mandat ou clôturer sa
tâche (SEC-MCP-003). L'identité est donc prouvée par une **capability par-pod** : un secret aléatoire (256
bits) généré au SPAWN, injecté UNIQUEMENT dans l'env de CE pod (`LCARS_POD_CAPABILITY` → le pont l'envoie
en `_lcars_pod_capability`), et VÉRIFIÉ serveur-side (comparaison à temps constant) contre la capability
enregistrée pour le `pod_id` via `Fleet.Spawner.pod_info`. SO_PEERCRED ne discrimine pas (tous les pods
d'un humain partagent l'UID) → la capability secrète est le bon mécanisme.

`verify_pod/1` gate **tout** tool corrélé pod (`get_task`, `submit_result`, résolution de rôle de
`create_ticket`). Fail-closed, **aucun fallback anonyme** : capability absente → `:pod_capability_required`,
fausse → `:pod_capability_mismatch`, pod inconnu → `:pod_unknown`, pod_id absent → `:pod_id_required`. Le
rôle se résout sur le pod_id **VÉRIFIÉ** (même appel `pod_info` → `{role, capability}`, pas de drift).

## Outils MCP (pod-facing)

- `get_task` — le pod récupère son mandat (corrélé `pod_id` **vérifié par capability**).
- `submit_result` — le pod soumet son livrable (`payload`) ; **`task_id` OBLIGATOIRE** = le `task_id` rendu
  par `get_task` (le broker corrèle sur CE mandat précis, jamais « la dernière active » du pod_id — 2e verrou
  anti-impersonation après la capability). task_id absent → `:task_id_required` ; ≠ mandat actif → `:task_id_mismatch`.
- `create_ticket` (délégation) — l'architecte délègue une brique : crée l'issue forge **prête pour le
  poller** (`Fleet.Pilot.ForgeClient.create_issue`, dispatch runtime) — auteur=arch (token de rôle de
  l'appelant **résolu depuis le SPAWN VÉRIFIÉ** : `verify_pod` prouve l'identité (capability) PUIS rend le
  `role` gravé au spawn via `Fleet.Spawner.pod_info`, **PAS** le `_lcars_role` du wire non authentifié —
  MA-15 / SEC-MCP-003). **Fail-closed** : pod non prouvé → REFUS (plus de repli compte système, qui était un
  trou — un pod inconnu postait en système) ; token de rôle absent → `:role_token_unavailable` (jamais en
  système). **assignee=humain** owner (login OS, `Fleet.Credentials.Human`) — puis **STOP**. Pas de label :
  le rôle producteur est un invariant côté poller, pas un marqueur par-ticket. Le poller prend le relais
  (forge-state-machine, BL-050 : plus de `start_pipeline`/rail RAM). Seams test : `:forge_client`, `:pod_resolver`.
- `create_project` (Rail 1 — onboarding) — l'architecte démarre un projet neuf : `Fleet.Pilot.ProjectOnboard.onboard/2`
  (repo forge + dual-worktree `main`/`work/ops` + scaffold + push). Le projet créé devient la cible de
  délégation (`:delegation_repo`) → enchaîner `create_ticket`. Dispatch runtime (pas de dep compile-time `fleet_pilot`).

NB **bridge stdio** (`bin/fleet_mcp_stdio_bridge.py`) : la liste `TOOLS` est hardcodée — tout nouveau tool
doit y être ajouté en miroir (dette connue : proxifier `tools/list` vers le central). Le pont injecte aussi
l'identité du pod dans chaque tool-call : `_lcars_pod_id` (corrélation) + `_lcars_pod_capability` (preuve,
depuis l'env `LCARS_POD_CAPABILITY` posé au spawn) + `_lcars_role` (indicatif, jamais autorité).

## Configuration

- `:fleet_mcp, :pod_facing_port` — port d'écoute MCP côté pods.
- `:fleet_mcp, :boot_environment` — environnement injecté au boot du serveur.
- `LCARS_BIND_HOST` (env) — IP de bind du listener pod-facing. **Loopback
  `127.0.0.1` par défaut** : les pods joignent le MCP via le pont stdio→HTTP sur
  `http://127.0.0.1:<port>/mcp` (même hôte, cf. `LCARS_FLEET_MCP_URL` /
  `bin/fleet_mcp_stdio_bridge.py`) → loopback est COMPATIBLE, ne casse rien.
  Threadé via l'option `:host` du transport HTTP ExMCP. Source unique :
  `Fleet.EventRouter.BindAddress` ; exposer = opt-in via cette env.

## Frontière vendor

`mcp_*` = N1 (ADR-C) : le SDK `ex_mcp` est wrappé derrière `Fleet.MCP.PodTools`
(`use ExMCP.Server`, tools `get_task`/`submit_result`) ; bascule vers un autre SDK
(Hermes) possible sans toucher les consommateurs.
