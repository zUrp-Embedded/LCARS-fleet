<!--
  title: Infrastructure fleet — Comment c'est construit
  directives_rev: 7.0-beta
  date: 2026-03-22
  last_updated: 2026-03-31
  status: v7 restructuration — nettoyé (push par rôle → topo, portabilité → conventions, LCARS workflow → workflow), fleet-env.sh ajouté
  referenced_by: build-sp.sh
-->

## Chemins système

| Chemin | Fonction |
|---|---|
| `/local/LCARS/` | Runtime. `fleet-update.sh` et `deploy.sh` opèrent depuis ici. |
| `/home/projects/LCARS/` | Working copy (dev). Commit + push vers GitHub. Réputé jetable. |
| `/home/projects/<projet>/` | Emplacement EXCLUSIF de tous les repos projet. JAMAIS dans le home d'un user. |
| `/home/projects.work/<projet>/` | Worktree orphelin — plans, backlog, handoffs, index. Branche `work/ops`, versionné séparément de main. Résolu par `$FLEET_WORKDIR`. |
| `/home/commons/` | Shared workspace inter-agents. Éphémère — `rm -rf` reset à l'état vanilla. |
| `/home/fleet-state/` | État fleet (scratchpads, logs). Persistant. |
| `/home/ready-room/` | Canal user↔fleet. Voir § Ready Room. |
| `/home/tmp/` | Workspace éphémère. Supprimable sans préavis. |
| `/home/private/` | Secrets (SSH keys, git-identity.conf). Permissions 700. JAMAIS versionné. |
|
---

## Moteur

Chaque agent fleet est une instance **Claude Code** (Anthropic, CLI). Modèle : opus (contexte 1M tokens). Le system prompt est injecté via `--system-prompt-file` et porte la topologie complète — chaque agent connaît la fleet, les autres agents, les canaux, sa position. Les hooks, skills, permissions et settings sont gérés par Claude Code via `settings.local.json` et `.claude/`. La coordination inter-agents est assurée par l'IPC spool et les scripts fleet.

---

## fleet-env.sh — kernel des scripts

`fleet-env.sh` est la source de vérité centralisée pour tous les chemins et variables fleet. Tout script fleet le source. JAMAIS hardcoder un chemin qui est résolu par `fleet-env.sh`. 26 variables exportées, 8 fonctions de requête blueprint.

---

## IPC — spool-based

Canal d'envoi : `fleet-send.sh [--type TYPE] [--priority PRIORITY] [--ref REF] <dest> <subject> [file]`
Réception : `/var/spool/fleet/inbox/<role>/`

**GO-5 — Secure Channel.** JAMAIS écrire dans les fichiers IPC avec `cat >>` ou redirection brute. Utiliser exclusivement `fleet-send.sh`. L'urgence ou la correction d'erreur ne suspendent pas GO-5.

**Enveloppe YAML** : frontmatter YAML (`from`, `to`, `subject`, `type`, `priority`, `ref`, `date`). Le corps suit après le second `---`. Flags optionnels de `fleet-send.sh` : `--type` (défaut : `task`), `--priority` (défaut : `normal`), `--ref` (référence croisée, vide par défaut).

Types canoniques : `task` · `ack` · `ping` · `escalation` · `result` · `notification`.
Priorités canoniques : `normal` · `high` · `critical`.

**Cycle de vie** :
1. `inbox/<role>/` — en attente
2. `inbox/<role>/.processing/` — en cours
3. `inbox/<role>/.consumed/` — traité + `.ack` écrit

L'agent ne supprime aucun fichier. Purge manuelle par StarFleet (>7j). Automatisation : backlog v7.0.

**PING→ACK** : tout message avec subject `PING` reçoit une réponse immédiate via `fleet-send.sh <émetteur> "ACK" <<< "<role> online. <status>"`. Format status : `idle` | `busy: <tâche courte>` | `error: <one-liner>`. Pas d'interprétation du body.

**`[FLEET-INBOX]` sentinel** : INTERDIT comme prompt ou sujet de message.

**fleet-send.sh** = dépôt pur dans le spool. Pas de wake — un daemon inotifywait gère le wake des agents.

**Dispatch hybride** (`fleet-dispatch.sh`) :
1. Pane tmux active → spool via fleet-send (daemon wake async)
2. Pas de pane → `claude -p` headless (sync)

Seuls Tier 0 et Tier 1 peuvent dispatcher. Tier 2 ne peut envoyer qu'à Tier 0 et Tier 1 (pas de peer-to-peer).

**Headless interrompu** (max_turns atteint) : résultat traité comme INCOMPLETE, pas FAIL. Le dispatcher peut relancer si le résultat partiel montre une progression. Après 2 interruptions consécutives → FAIL + escalade engineer avec diagnostic.

---

## Structure repo LCARS

```
/home/projects/LCARS/             ← checkout main (sources, code)
├── docs/                         ← documentation fleet
├── fleet/                        ← scripts, provisioning, fleet.yaml
│   └── system-prompt/
│       └── sources/              ← L4 — source de vérité (core/, organisation/, roles/, user/)
└── knowledge/                    ← L2 — savoir métier par domaine

/home/projects.work/LCARS/        ← worktree, branche orpheline work/ops
├── backlog.md
├── index.md
├── TODO/                         ← plans spécifiés, non démarrés
├── doing/                        ← plans actifs (WIP limit)
├── done/                         ← plans closurés
└── handoffs/                     ← handoffs agents (versionné)
```

Deux checkouts, un repo, un remote. La branche orpheline `work/ops` ne partage aucun ancêtre avec main — l'historique de gestion de projet est séparé de l'historique code. `$FLEET_WORKDIR` résout vers le worktree. `$FLEET_HANDOFFS` résout vers `$FLEET_WORKDIR/handoffs`.

LCARS est un projet, pas une dépendance read-only. Fork OBLIGATOIRE = garantie du cycle fix→push→deploy.

### Assemblage SP — build-sp.sh

`build-sp.sh` assemble le system prompt de chaque agent depuis les sources (`sources/`). Il lit `manifest.yaml` (blocs, positions, targets) et `fleet.yaml` (system_prompt par rôle). L'assemblage est déterministe : même sources = même SP. Le SP assemblé est un artefact déployé dans `~/.claude/` par `deploy.sh`, pas un fichier versionné.

### Profiles fleet

3 profiles dans `fleet/profiles/`, héritage récursif via `extends:` :

| Profile | Extends | Agents | Usage |
|---|---|---|---|
| **fleet** | — | starfleet, qualifier, reviewer | Auto-maintenance LCARS |
| **projects** | fleet | + architect, engineer, dev, qualifier, reviewer, documenter, researcher | Production soft |
| **embedded** | projects | + builder, deployer | Hardware/firmware |

Agents LCARS et projet partagent les mêmes rôles (qualifier, reviewer). Même scope (`test`, `analysis`), contexte déterminé par le projet cible (L4 LCARS vs L1 projet).

Le type de projet (firmware, web, script) n'est PAS un axe de profil — c'est du L2. Un dev avec L2 firmware = dev firmware.

Profile par défaut : `projects`. Changement : `fleet-build-yaml.sh <profile>`.

---

## Structure home agent

```
~/
├── .claude/          ← CLAUDE.md, skills/, hooks/     (deploy.sh)
├── .local/
│   ├── bin/          ← fleet scripts                  (deploy.sh)
│   └── log/          ← logs runtime agent             (scripts)
├── L2 -> /local/LCARS/knowledge/<domain>/              (deploy.sh)
```

### Mécanisme L2 (future)

`~/L2 → /local/LCARS/knowledge/<domain>/` depuis `fleet.yaml`. Changer le domaine = changer une ligne + redeploy. Non déployé actuellement — le symlink et le mécanisme de résolution sont implémentés dans deploy.sh mais les répertoires knowledge ne sont pas encore peuplés.

---

## Permissions

Isolation inter-agents via groupes Linux, pas via sudo. Groupe `fleet` partagé. Seul starfleet a sudo root. L'user physique WSL (`lordzurp`) own l'infrastructure partagée — les agents accèdent via le groupe fleet.

| Zone | Mode | Owner | Groupe | Notes |
|---|---|---|---|---|
| `/home/<agent>/` | 750 | agent | fleet | Lecture cross-agent via groupe |
| `/home/<agent>/.claude/` | 1770 | lordzurp | fleet | Sticky bit — agents ne peuvent pas supprimer/modifier leur propre config |
| `/local/LCARS/` | 2755 | starfleet | fleet | Runtime, setgid, groupe read-only |
| `/home/projects/LCARS/` | 2770 | lordzurp | fleet | Working copy dev, setgid |
| `/home/projects/<projet>/` | 775 | dev | fleet | dev propriétaire |
| `/home/projects.work/<projet>/` | 2770 | lordzurp | fleet | Worktree, setgid fleet |
| `/home/fleet-state/` | 2770 | lordzurp | fleet | Persistant |
| `/home/commons/` | 2770 | lordzurp | fleet | Éphémère |
| `/home/ready-room/` | 777 | root | root | drvfs — 777 contrainte, pas choix |
| `/home/private/` | 700 | lordzurp | lordzurp | Aucun accès groupe |
| Scripts `.sh` | 755 | owner | fleet | |
| Fichiers `.md` | 644 | owner | fleet | |
| Logs | 664 | starfleet | fleet | |

---

## GitHub

| Mode | `github.mode` | Repos dans | PAT |
|---|---|---|---|
| Personnel | `personal` | `<user>/` | Classic (scope `repo`) |
| Organisation | `org` | `<github.org>/` | Classic (scope `repo`) |

Auth : PAT via `gh` credential helper. `/home/private/.github-token` (chmod 640). Propagé à tous les agents qui push (scope `code` + `sudo:full`) via `gh auth login --with-token`.
SSH : clé ed25519 starfleet. Fallback si PAT absent.
Remotes : HTTPS par défaut. Changer de mode : `fleet-system.yaml` + `fleet-update.sh`.

---

## Git / deploy

**Triangle strict** : source → GitHub → runtime. Aucun raccourci. Aucun transfert direct (cp, rsync, scp, symlink, patch manuel) entre le clone dev et le runtime.

**Commit graph immuable.** Violations : `push --force` sur branche partagée, `commit --amend` sur commit poussé, `rebase` sur branche fetchée. Exception : `--force-with-lease` sur branche feature personnelle non-partagée avec mention handoff.

**fleet-update.sh OBLIGATOIRE après tout push LCARS.** JAMAIS `deploy.sh` directement.

**LCARS — propriétaire exclusif : StarFleet.** Aucun autre agent ne modifie LCARS main.

---

## Install / deploy

Cycle idempotent : install = update. Runtime = force pull main (jetable).
Séparation : install (users, packages, clone) / deploy (contenu vers homes).
Doctor = `install --check` : dry-run read-only. `[OK]`/`[FAIL]` structuré.
WSL = cible principale. Docker = packaging. YOLO inside, isolation vs machine user.

---

## Ready Room

`/home/ready-room/` = canal contractuel user↔fleet. drvfs mount, survit aux rerolls WSL.

`inbox/` : user → fleet. L'agent lit, déplace dans `.consumed/` après traitement. Fleet n'écrit JAMAIS dans inbox.
`outbox/` : fleet → user, à la demande. Rien d'automatique n'y va. L'user demande, l'agent dépose.
