# fleet_mcp

**Date** : 2026-05-18
**Dernière révision** : 2026-06-26 (B2a — gate architecte serveur-side des tools privilégiés)
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

## Autorisation architecte — tools privilégiés (gate serveur-side)

`create_project`, `create_ticket` et `get_ticket_status` sont des actes d'**architecte** : créer un repo
forge, écrire/pousser dans `/home/projects`, déléguer du travail, suivre une délégation. Avant, la seule
barrière était la **visibilité côté pont** (`fleet_mcp_stdio_bridge.py` ne liste ces tools que si
`LCARS_ROLE==architect`) — ce n'est **pas** une autorisation : un pod worker qui a `Bash` + joint le central
en loopback peut reconstruire le JSON-RPC et appeler ces tools directement, hors filtre client.

Le garde `require_architect/1` ferme ce trou **serveur-side** : il enveloppe `verify_pod` (identité prouvée
par la capability par-pod) **puis** exige que le rôle gravé au spawn soit `architect`. Le rôle vient du pod
**vérifié**, jamais du `_lcars_role` du wire. Tout rôle autre (engineer, reviewer, rôle nil/inconnu) →
`{:error, :forbidden_not_architect}` ; identité non prouvée → l'erreur de `verify_pod` est propagée
(`:pod_unknown`, `:pod_capability_*`, `:pod_id_required`). Fail-closed : aucun cas ne retombe sur un accès
autorisé. Le vrai architecte (`permanent-architect`) passe ; les workers sont refusés.

## Outils MCP (pod-facing)

- `get_task` — le pod récupère son mandat (corrélé `pod_id` **vérifié par capability**).
- `submit_result` — le pod soumet son livrable (`payload`) ; **`task_id` OBLIGATOIRE** = le `task_id` rendu
  par `get_task` (le broker corrèle sur CE mandat précis, jamais « la dernière active » du pod_id — 2e verrou
  anti-impersonation après la capability). task_id absent → `:task_id_required` ; ≠ mandat actif → `:task_id_mismatch`.
- `create_ticket` (délégation, **architecte only**) — l'architecte délègue une brique : crée l'issue forge
  **prête pour le poller** (`Fleet.Pilot.ForgeClient.create_issue`, dispatch runtime). Gate `require_architect`
  (identité prouvée par capability **puis** rôle du spawn == `architect`, jamais le `_lcars_role` du wire —
  MA-15 / SEC-MCP-003). **Fail-closed** : worker non-architecte → `:forbidden_not_architect` ; pod non prouvé
  → REFUS (`:pod_unknown` etc., plus de repli compte système) ; token de rôle absent → `:role_token_unavailable`
  (jamais en système). auteur=arch (token du compte de rôle de l'appelant), **assignee=humain** owner (login
  OS, `Fleet.Credentials.Human`) — puis **STOP**. Pas de label : le rôle producteur est un invariant côté
  poller. Le poller prend le relais (forge-state-machine, BL-050). Seams test : `:forge_client`, `:pod_resolver`.
- `create_project` (Rail 1 — onboarding, **architecte only**) — l'architecte démarre un projet neuf :
  `Fleet.Pilot.ProjectOnboard.onboard/2` (repo forge + dual-worktree `main`/`work/ops` + scaffold + push).
  Gate `require_architect` **avant** toute création de repo / écriture disque (un worker ne peut pas onboarder).
  Le repo créé est RENDU dans le résultat (`repo`/`delegation_target`) → l'arch le passe explicitement à
  `create_ticket` / `get_ticket_status` (plus de mémoire globale `:delegation_repo`). Dispatch
  runtime (pas de dep compile-time `fleet_pilot`). Seams test : `:project_onboard`, `:pod_resolver`.
- `get_ticket_status` (suivi, **architecte only**) — lit l'état d'un ticket délégué (issue + PR) du repo
  passé en `project` (**REQUIS** : `owner/name` du ticket ; pas de routage par défaut — sans `project` →
  `:project_required`, jamais d'état lu sur le mauvais projet). Gate `require_architect` (cohérent avec
  create_ticket/create_project : seul l'architecte suit ses délégations). Lecture seule (`ForgeClient`).
  Seams test : `:forge_client`, `:pod_resolver`.

NB **bridge stdio** (`bin/fleet_mcp_stdio_bridge.py`) : la liste `TOOLS` est hardcodée — tout nouveau tool
doit y être ajouté en miroir (dette connue : proxifier `tools/list` vers le central). Le pont injecte aussi
l'identité du pod dans chaque tool-call : `_lcars_pod_id` (corrélation) + `_lcars_pod_capability` (preuve,
depuis l'env `LCARS_POD_CAPABILITY` posé au spawn) + `_lcars_role` (indicatif, jamais autorité). Le filtre
de visibilité des tools privilégiés côté pont (`LCARS_ROLE==architect`) reste une commodité UX (ne pas
montrer un tool inutilisable) — l'**autorisation** est désormais serveur-side (`require_architect`) : un pod
worker qui reconstruit le JSON-RPC pour appeler `create_project`/`create_ticket`/`get_ticket_status` hors du
filtre client est refusé par le central, pas par le pont.

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
