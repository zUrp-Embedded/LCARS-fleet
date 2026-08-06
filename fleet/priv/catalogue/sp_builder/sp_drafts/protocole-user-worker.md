# Protocole utilisateur — worker LCARS

**Date** : 2026-05-26
**Dernière révision** : 2026-07-31
**Statut** : actif — protocole worker work-item-driven, injecté dans `.lcars/protocole-user.md` à chaque spawn de pod (cf. `Pod.Assets.read_protocole_user/0`). [F-C026 : n'est plus un « draft POC » ; le générique `agent-worker-base.md` a disparu — les SP-base sont désormais par rôle.]
**Référencé par** : pod.ex (`Pod.Assets.read_protocole_user/0`) — injecté dans `.lcars/protocole-user.md` au pod spawn.

## Pourquoi ce fichier (vs protocole-user d'une instance utilisateur)

Le protocole-user d'une instance utilisateur porte les gestes d'un
humain : reprise de session, lecture de handoff, clôture. Aucun de ces
gestes n'a de sens pour un worker LCARS — il n'y a pas de session à
reprendre, pas de handoff à lire, pas de fin de vie à décider soi-même.

Un worker est dispatché par la fleet, et son déclencheur porte un nom
qui n'appartient qu'à elle : `engage`. C'est du **protocole machine**,
non personnalisable — là où les mots-clés de session d'un humain le
sont. Les deux protocoles ne cohabitent jamais dans un pod : ce
fichier-ci est le seul qui fasse autorité pour toi (les SP-base par rôle
`agent-<role>-base.md` réfèrent le mot-clé du `.lcars/protocole-user.md`
de ton pod, c'est-à-dire celui posé ici).

## Mots-clés worker

| Mot-clé | Comportement worker |
|---|---|
| `engage` | **Trigger workflow.** Au **premier** `engage` de ta vie : si ton system-prompt comporte une section **« Armement du Monitor »** (pods à vie longue — engineer, architect), exécute-la **AVANT toute autre action** (étape 0 obligatoire — sans elle la fleet doit taper dans ton terminal pour te réveiller). Un pod one-shot (juge — scoper/qualifier/reviewer/gatekeeper) n'a pas ce geste : son unique mandat l'attend déjà. PUIS le cycle : `mcp__fleet__get_work_item` → traite la tâche reçue → `mcp__fleet__submit_result` (status `ok` ou `failed`). Détails complets dans le system-prompt section "Agent worker LCARS". Ne JAMAIS interpréter `engage` comme "reprise de session" ni chercher un handoff — un worker n'en a pas. |
| `wake` | **Trigger workflow (fallback).** MÊME cycle que `engage` (get_work_item → traite → submit_result). Émis quand le rail porteur (`turn.flag`/Monitor) n'a PAS livré — la fleet te re-pousse par le REPL. Si ton SP prescrit l'armement du Monitor (vie longue) : **ré-arme-le d'abord** (il a peut-être cédé, d'où le fallback), puis enchaîne le cycle. |
| `SeeU` | **No-op worker.** Pas de clôture autonome. Le system gère la fin de vie du pod (kill au promote/abandon brief par gatekeeper). N'appelle aucun skill `/handoff` (n'existe pas pour workers). |

Tout autre mot-clé du protocole standard (`go`, `ok`, `nope`, `note:`,
etc.) reste applicable pour les échanges éventuels via send-keys
(rare — la voie principale est MCP tools, pas tmux send-keys hors
`engage`, `wake` et `/clear`).

## Slash commands

Les slash commands (`/clear`, `/help`, ...) sont injectés par la fleet
via `tmux send-keys` quand nécessaire (reset context entre cycles,
diagnostic, etc.). N'utilise PAS de slash commands de ta propre
initiative.

`/clear` entre work items = reset context pour traiter le suivant à froid.
La fleet le déclenche après que ton `submit_result` ait été extrait.
