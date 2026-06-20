<!-- Date: 2026-05-26 — SP draft worker (salvage). Header en commentaire: minimise pollution SP ; exemption hook GO-7 a faire (cf worklog). -->
# Protocole utilisateur — worker LCARS

**Statut** : draft POC ticket-driven (cf. chantier U-RC + agent-worker-base.md)
**Référencé par** : pod.ex (Pod.read_protocole_user) — injecté dans `.claude/protocole-user.md` au pod spawn.

## Pourquoi ce fichier (vs protocole-user d'une instance utilisateur)

Le protocole-user des instances utilisateur (starfleet, consultant, etc.)
porte des sémantiques personnelles : `yop` = reprise de session avec
lecture handoff, ou `yop` neutralisé (instance v1 éclatée). Aucune ne
correspond à un worker LCARS dispatché par la fleet.

Pour un worker, le mot-clé `yop` a une sémantique opérationnelle dédiée :
c'est le **trigger workflow ticket-driven** (cf. `agent-worker-base.md`
injecté dans le system-prompt). Ce fichier l'établit explicitement pour
éviter qu'un protocole hérité d'un user humain ne brouille le contrat.

## Mots-clés worker

| Mot-clé | Comportement worker |
|---|---|
| `yop` | **Trigger workflow.** Démarre un cycle de traitement : appelle `mcp__fleet__get_task` → traite la tâche reçue → appelle `mcp__fleet__submit_result` (status `ok` ou `failed`). Détails complets dans le system-prompt section "Agent worker LCARS". Ne JAMAIS interpréter `yop` comme "reprise de session" ou "lire un handoff" — il n'y a pas de handoff pour un worker. |
| `wake` | **Trigger workflow (fallback).** MÊME cycle que `yop` (get_task → traite → submit_result). Émis quand le rail porteur (`turn.flag`/Monitor) n'a PAS livré — la fleet te re-pousse par le REPL. **Ré-arme ton Monitor d'abord** (il a peut-être cédé, d'où le fallback), puis enchaîne le cycle. |
| `SeeU` | **No-op worker.** Pas de clôture autonome. Le system gère la fin de vie du pod (kill au promote/abandon mandate par gatekeeper). N'appelle aucun skill `/handoff` (n'existe pas pour workers). |

Tout autre mot-clé du protocole standard (`go`, `ok`, `nope`, `note:`,
etc.) reste applicable pour les échanges éventuels via send-keys
(rare — la voie principale est MCP tools, pas tmux send-keys hors `yop`,
`wake` et `/clear`).

## Slash commands

Les slash commands (`/clear`, `/help`, ...) sont injectés par la fleet
via `tmux send-keys` quand nécessaire (reset context entre cycles,
diagnostic, etc.). N'utilise PAS de slash commands de ta propre
initiative.

`/clear` entre tickets = reset context pour traiter le suivant à froid.
La fleet le déclenche après que ton `submit_result` ait été extrait.
