<!--
  title: Infrastructure fleet — Comment c'est construit
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC — injection via build-sp.sh
  referenced_by: build-sp.sh
-->

## Chemins système

| Chemin | Fonction |
|---|---|
| `/local/LCARS/` | Runtime. `fleet-update.sh` et `deploy.sh` opèrent depuis ici. |
| `/home/projects/LCARS/` | Working copy (dev). Commit + push vers GitHub. Réputé jetable. |
| `/home/projects/<projet>/` | Emplacement EXCLUSIF de tous les repos projet. JAMAIS dans le home d'un user. |
| `/home/commons/` | Shared workspace inter-agents. Éphémère — `rm -rf` reset à l'état vanilla. |
| `$FLEET_HANDOFFS` | Handoffs inter-agents (worktree). Persistant. |
| `/home/fleet-state/` | État fleet. Persistant. |
| `/home/ready-room/` | Canal user↔fleet. Voir § Ready Room. |
| `/home/tmp/` | Workspace éphémère. Supprimable sans préavis. |
| `/home/private/` | Secrets (SSH keys, git-identity.conf). Permissions 700. JAMAIS versionné. |

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

**Dispatch hybride** (`fleet-dispatch.sh`) :
1. Pane tmux active → spool + wake (async)
2. Pas de pane → `claude -p` headless (sync)

**Headless interrompu** (max_turns atteint) : résultat traité comme INCOMPLETE, pas FAIL. Le dispatcher peut relancer si le résultat partiel montre une progression. Après 2 interruptions consécutives → FAIL + escalade engineer avec diagnostic.

---

## Structure repo LCARS

```
/home/projects/LCARS/
├── docs/           ← documentation fleet
├── fleet/          ← scripts, provisioning, fleet.yaml
│   └── system-prompt/
│       └── sources/ ← L4 — source de vérité (core/, organisation/, roles/, user/)
├── knowledge/      ← L2 — savoir métier par domaine
└── work/           ← plans en cours, side quests
```

LCARS est un projet, pas une dépendance read-only. Fork OBLIGATOIRE = garantie du cycle fix→push→deploy.

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

### Mécanisme L2

`~/L2 → /local/LCARS/knowledge/<domain>/` depuis `fleet.yaml`. Changer le domaine = changer une ligne + redeploy.

---

## Permissions

Isolation inter-agents via groupes Linux, pas via sudo. Groupe `fleet` partagé. Seul starfleet a sudo root.

| Zone | Mode | Owner | Groupe | Notes |
|---|---|---|---|---|
| `/home/<agent>/` | 750 | agent | fleet | Lecture cross-agent via groupe |
| `/home/<agent>/.claude/` | 750 | agent | fleet | Ownership mixte root:root + agent:fleet |
| `/home/projects/LCARS/` | 775 | starfleet | fleet | starfleet propriétaire exclusif |
| `/home/projects/<projet>/` | 775 | dev | fleet | dev propriétaire |
| `work/` (projet) | 2775 | owner | fleet | Setgid fleet |
| `$FLEET_HANDOFFS` | 2775 | starfleet | fleet | Worktree, persistant |
| `/home/fleet-state/` | 2775 | starfleet | fleet | Persistant |
| `/home/commons/` | 2775 | starfleet | fleet | Éphémère |
| `/home/ready-room/` | 777 | root | root | drvfs — 777 contrainte, pas choix |
| `/home/private/` | 700 | starfleet | starfleet | Aucun accès groupe |
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

**LCARS main — workflow obligatoire sans exception** : toute modification de main passe par /lcars-fix (quick-fix) ou /lcars-feature (au-delà du boundary). Aucun mot-clé d'action ne bypass ce workflow. GO-0 : cette règle ne se déduit pas du contexte, elle s'applique.

**Push par rôle** :
1. Tier 0 (StarFleet) : LCARS uniquement. JAMAIS code projet.
2. Tier 2 (dev) : projet + branches feature LCARS depuis clone séparé. JAMAIS LCARS main.
3. Tier 1 (Engineer) : JAMAIS.
4. Cross-pushing INTERDIT.

**LCARS main = intouchable.** JAMAIS checkout de branche. Quick-fix + référence read-only.

**Quick-fix boundary** :

| Critère | Quick-fix | Feature |
|---|---|---|
| Fichiers modifiés | ≤ 8 | > 8 |
| Fichiers créés | ≤ 2 | > 2 |
| Fichiers supprimés | 0 | ≥ 1 |
| Topologie | inchangée | modifiée |
| Comportement cross-agent | inchangé | modifié |

Header-only (GO-7, STARDATE, version tag) : exempt du comptage.
Workflow quick-fix : propose compact → user OK → QA+commit+push+PR → auto-merge → fleet-update. Skill : /lcars-fix (alias : /lcars-patch).

**LCARS feature cycle** : StarFleet résumé + user OK → StarFleet provision clone (`/home/projects/lcars-<slug>/`, chown worker) → dispatch direct dev → worker code + push branche + PR → StarFleet merge + fleet-update + cleanup clone. Skill : /lcars-feature. Qualifier et reviewer exécutent des tâches mécaniques (QA, review) sous la direction de StarFleet — ils ne prennent pas de décision sur le contenu LCARS.

**Merge conflict LCARS** : StarFleet est le SEUL à merger et résoudre les conflits. Le worker ne merge jamais — il rebase sa branche feature si StarFleet le demande, puis re-push.

---

## Portabilité (IDIC)

Tout composant fleet DOIT fonctionner sans hypothèse mono-environnement. Cibles : ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif. Critère de revue : "est-ce portable ?" Modes de défaillance : path hardcodé, arch implicite, username en dur. Dépendance assumée : GNU coreutils (`stat -c`, `find -printf`). BSD/BusyBox = hors scope (pas de cible macOS/Alpine). Les scripts utilisent `grep -E` (POSIX) au lieu de `grep -P` (Perl) pour les regex.

---

## Install / deploy

Cycle idempotent : install = update. Runtime = force pull main (jetable).
Séparation : install (users, packages, clone) / deploy (contenu vers homes).
Doctor = `install --check` : dry-run read-only. `[OK]`/`[FAIL]` structuré.
WSL = cible principale. Docker = packaging. YOLO inside, isolation vs machine user.

---

## Ready Room

`/home/ready-room/` = SEUL canal contractuel user↔fleet.

`inbox/` : user → fleet. Fleet consomme et vide. Fleet n'écrit JAMAIS dans inbox.
`outbox/` : fleet → user. Fleet dépose. INTERDIT de supprimer. Edit in-place autorisé.
`fleet-live` : symlink Windows → `/home/`. Visibilité directe user sur tout `/home/` via Explorer. Aucune incidence LCARS — lecture seule côté user.

```
ready-room/
├── fleet-live → /home/    ← visu user (symlink Windows, read-only)
├── inbox/
├── outbox/
│   └── audits/
└── handoffs/
```

Persistance : drvfs mount. Survit aux rerolls WSL. Backup dédié : v7.0.
