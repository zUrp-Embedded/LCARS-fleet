# Protocole utilisateur — worker LCARS

**Date** : 2026-05-26
**Dernière révision** : 2026-07-20
**Statut** : actif — protocole worker work-item-driven, injecté dans `.lcars/protocole-user.md` à chaque spawn de pod (cf. `Pod.Assets.read_protocole_user/0`). [F-C026 : n'est plus un « draft POC » ; le générique `agent-worker-base.md` a disparu — les SP-base sont désormais par rôle.]
**Référencé par** : pod.ex (`Pod.Assets.read_protocole_user/0`) — injecté dans `.lcars/protocole-user.md` au pod spawn.

## Pourquoi ce fichier (vs protocole-user d'une instance utilisateur)

Le protocole-user des instances utilisateur (starfleet, consultant, etc.)
porte des sémantiques personnelles : `yop` = reprise de session avec
lecture handoff, ou `yop` neutralisé (instance v1 éclatée). Aucune ne
correspond à un worker LCARS dispatché par la fleet.

Pour un worker, le mot-clé `yop` a une sémantique opérationnelle dédiée :
c'est le **trigger workflow work-item-driven** (les SP-base par rôle
`agent-<role>-base.md` réfèrent ce mot-clé du `.lcars/protocole-user.md`). Ce fichier l'établit explicitement pour
éviter qu'un protocole hérité d'un user humain ne brouille le contrat.

## Mots-clés worker

| Mot-clé | Comportement worker |
|---|---|
| `yop` | **Trigger workflow.** Au **premier** `yop` de ta vie : si ton system-prompt comporte une section **« Armement du Monitor »** (pods à vie longue — engineer, architect), exécute-la **AVANT toute autre action** (étape 0 obligatoire — sans elle la fleet doit taper dans ton terminal pour te réveiller). Un pod one-shot (juge — consultant/qualifier/reviewer/gatekeeper) n'a pas ce geste : son unique mandat l'attend déjà. PUIS le cycle : `mcp__fleet__get_work_item` → traite la tâche reçue → `mcp__fleet__submit_result` (status `ok` ou `failed`). Détails complets dans le system-prompt section "Agent worker LCARS". Ne JAMAIS interpréter `yop` comme "reprise de session" ou "lire un handoff" — il n'y a pas de handoff pour un worker. |
| `wake` | **Trigger workflow (fallback).** MÊME cycle que `yop` (get_work_item → traite → submit_result). Émis quand le rail porteur (`turn.flag`/Monitor) n'a PAS livré — la fleet te re-pousse par le REPL. Si ton SP prescrit l'armement du Monitor (vie longue) : **ré-arme-le d'abord** (il a peut-être cédé, d'où le fallback), puis enchaîne le cycle. |
| `SeeU` | **No-op worker.** Pas de clôture autonome. Le system gère la fin de vie du pod (kill au promote/abandon brief par gatekeeper). N'appelle aucun skill `/handoff` (n'existe pas pour workers). |

Tout autre mot-clé du protocole standard (`go`, `ok`, `nope`, `note:`,
etc.) reste applicable pour les échanges éventuels via send-keys
(rare — la voie principale est MCP tools, pas tmux send-keys hors `yop`,
`wake` et `/clear`).

## Slash commands

Les slash commands (`/clear`, `/help`, ...) sont injectés par la fleet
via `tmux send-keys` quand nécessaire (reset context entre cycles,
diagnostic, etc.). N'utilise PAS de slash commands de ta propre
initiative.

`/clear` entre work items = reset context pour traiter le suivant à froid.
La fleet le déclenche après que ton `submit_result` ait été extrait.
