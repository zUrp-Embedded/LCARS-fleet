<!--
  title: Core — Conventions
  directives_rev: 7.0-beta
  date: 2026-03-31
  last_updated: 2026-03-31
  status: v7 — nouveau fichier, consolidation conventions depuis workflow/core/#6/#7 + fantômes documentés
  referenced_by: build-sp.sh
  derived_from: —
-->

## Conventions

### Chemins système

| Chemin | Fonction |
|---|---|
| `/local/LCARS/` | Runtime. |
| `/home/projects/LCARS/` | Working copy (dev). Réputé jetable. |
| `/home/projects/<projet>/` | Emplacement EXCLUSIF de tous les repos projet. JAMAIS dans le home d'un user. |
| `/home/projects.work/<projet>/` | Worktree orphelin — plans, backlog, handoffs. Branche `work/ops`. Résolu par `$FLEET_WORKDIR`. |
| `/home/commons/` | Shared workspace inter-agents. Éphémère. |
| `/home/fleet-state/` | État fleet (scratchpads, logs). Persistant. |
| `/home/ready-room/` | Canal user↔fleet. Voir topologie. |
| `/home/tmp/` | Workspace éphémère. Supprimable sans préavis. |
| `/home/private/` | Secrets. Permissions 700. JAMAIS versionné. |

---

### Langue

Langue fleet (structurel, indépendant de l'user) :
- IPC, handoffs : anglais.
- Plans, architecture docs, bug journals : français.
- Code et identifiants : anglais.
- La langue de conversation user est définie dans le profil utilisateur, pas ici.

---

### Nommage

**Noms = fonction.** Tout répertoire et fichier structurant se nomme d'après sa fonction — sémantique et auto-descriptif. Un humain extérieur au projet comprend la fonction sans consulter une légende.

**Préfixes numériques** (optionnel) : quand un dossier utilise le pattern `#N_slug`, `#0` = fondations, numéros croissants = spécificité croissante. Le numéro reflète la position dans la hiérarchie conceptuelle, pas la prochaine valeur disponible. Ce pattern n'est pas obligatoire — il est utilisé dans `core/` et `docs/`, pas imposé partout.

**Scripts fleet** : kebab-case. Préfixe `fleet-` pour les scripts d'orchestration distribués aux agents (tag `DEPLOY: instance-util`). Utilitaires internes, outils spécialisés et scripts lifecycle = nommage libre, le critère est le tag DEPLOY, pas le préfixe.

**Plans** : slug kebab-case, préfixe `#NN-` (ex: `#04-sp-distribution.md`). Généré par `fleet-plan.sh`.

**Aucun nom propre** d'utilisateur dans les directives. TOUJOURS `user` (générique). Identité réelle → `fleet.yaml` et handoffs uniquement.

**Termes techniques universels** (git, cmake, pytest, tmux, bash) : JAMAIS remplacés par des équivalents Starfleet.

---

### En-tête GO-7

**Format `.md`** — immédiatement après `# Titre` :

```
**Date** : YYYY-MM-DD
**Dernière révision** : YYYY-MM-DD
**Statut** : <one-liner>
**Référencé par** : <fichiers ou —>
**Dérivé de** : <fichier source ou —>   ← fichiers dérivés uniquement
```

**Format source** (`.sh`, `.py`, `.c`, `.cpp`) — en-tête LCARS avec blocs :
- SOURCE, AUTHOR, SYSTEM, STATUS, STARDATE
- MODULE, SUBSYSTEM, LICENSE
- INTERFACE : Ring (0-4), Input, Output, JSON (oui/non), Exit codes
- Description FR + EN

**Tag DEPLOY** dans les scripts : `# DEPLOY: instance-util` (distribué aux agents) ou `# DEPLOY: skip` (non distribué). Détermine le comportement de `deploy.sh` phase 11.

**Exceptions header** : formats sans commentaires natifs (`json`, binaires). Exemptions pre-commit : `*-handoff.md`, `to-*.md`, `*-notes.md`, `*-queue.md`, `MEMORY.md`, `scratchpad.md`, `roles/`, `skills/*/SKILL.md`, `#9_archives/`.

**Pre-commit hook** : Pass 1 = auto-update dates (STARDATE ou `Dernière révision`) — bookkeeping de métadonnées. Pass 2 = vérifie la présence des headers, bloque si absents — aucun auto-fix sur le contenu.

---

### Code

**Secrets JAMAIS** dans les fichiers versionnés. Rappeler `.env` + `.gitignore` si pertinent.

**Pas de commentaires inline** sauf contraintes hardware/protocole non évidentes.

**Code explicite > code compact.** Lister les dépendances système requises.

**Après édition** : déclarer uniquement ce qui a changé et pourquoi. Pas de récapitulatif du contexte inchangé.

---

### Shell

**Pas de 2>/dev/null** sur commandes diagnostiques. Les erreurs sont de l'information. Exception : échec attendu dans un flux nominal (test d'existence).

**Pas de trial-and-error.** Raisonner avant d'exécuter. La bonne commande du premier coup.

**Fix root cause.** Quand une commande échoue, lire l'erreur et fixer le problème sous-jacent. JAMAIS retenter avec des flags différents sans comprendre. Un contournement produit de la dette technique dans le livrable.

**Batch cap.** Avant d'exécuter un outil d'analyse, lint ou format sur un glob ou une liste de fichiers : compter d'abord (`wc -l` ou équivalent). Au-delà de 10 fichiers, découper en lots séquentiels. Au-delà de 50, demander confirmation user. Jamais de glob non borné sur un outil non-trivial.

**Reproductible** : toute séquence shell DOIT fonctionner identiquement sur un environnement frais.

**README OBLIGATOIRE avant push** : mettre à jour le README pour refléter les changements.

---

### Format handoff

Structure obligatoire :

```
## STATE
date: YYYY-MM-DD HH:MM
ref: <version ou contexte>
action: <action en cours ou handoff>
status: <online|offline|in-progress>
blocker: <description ou none>
waiting: <description ou none>
notify: <description ou none>

## ACTIONS
[ ] tâche non traitée
[x] tâche traitée (PASS ou FAIL = traité)

## DONE
### YYYY-MM-DD HH:MM — description
Résumé de ce qui a été fait.
```

`[ ]` = personne n'a traité. `[x]` = résultat produit (quel qu'il soit). FAIL n'est pas "pas fait" — c'est un résultat.

---

### Bug journal

Chaque repo avec `docs/` maintient `docs/#11_bug-journal.md`. Entrée OBLIGATOIRE quand un bug est fixé, avant fin de session.

---

### Portabilité (IDIC)

Tout composant fleet DOIT fonctionner sans hypothèse mono-environnement. Cibles : ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif. Critère de revue : "est-ce portable ?" Modes de défaillance : path hardcodé, arch implicite, username en dur. Dépendance assumée : GNU coreutils (`stat -c`, `find -printf`). BSD/BusyBox = hors scope (pas de cible macOS/Alpine). Les scripts utilisent `grep -E` (POSIX) au lieu de `grep -P` (Perl) pour les regex.

---

### Auditeurs — opérationnel

Position et rôle : voir topologie.md § Auditeurs.

**Codex — opérationnel** : user `codex` (gid `external`). Lit `/home/projects/` (ACL). IPC : fichiers plats dans `/home/commons/codex/` (interface dans `.readmefirst`). Émetteurs autorisés vers `to-codex.md` : architect, starfleet, consultant, engineer. Codex écrit dans `to-architect.md`, `to-starfleet.md`, `to-consultant.md`, `to-engineer.md`. ACK inline (jamais fichier séparé). Outputs dans `/home/codex/` : `livrables/` + `audits/`. Pas de wake — poll à la demande. Rotation `.YYYY-MM-DD.bak`, purge >7j par starfleet.

**Consultant — opérationnel** : user `consultant` (groupe `fleet`). Pane tmux dédié (window 3:consultant) ou session indépendante. IPC spool fleet (wake passif). Home purgé à chaque lancement. SP complet + skills (ponce, reverse, audit). Livre dans `$FLEET_WORKDIR/audits/`.

---

### IPC fleet — format et règles

**GO-5 — Secure Channel.** JAMAIS écrire dans les fichiers IPC avec `cat >>` ou redirection brute. Utiliser exclusivement `fleet-send.sh`. L'urgence ou la correction d'erreur ne suspendent pas GO-5.

Canal d'envoi : `fleet-send.sh [--type TYPE] [--priority PRIORITY] [--ref REF] <dest> <subject> [file]`
Réception : `/var/spool/fleet/inbox/<role>/`

**Enveloppe YAML** : frontmatter (`from`, `to`, `subject`, `type`, `priority`, `ref`, `date`). Le corps suit après le second `---`.

Types canoniques : `task` · `ack` · `ping` · `escalation` · `result` · `notification`.
Priorités canoniques : `normal` · `high` · `critical`.

**Cycle de vie** :
1. `inbox/<role>/` — en attente
2. `inbox/<role>/.processing/` — en cours
3. `inbox/<role>/.consumed/` — traité + `.ack` écrit

L'agent ne supprime aucun fichier. Purge par StarFleet (>7j).

**PING→ACK** : tout message avec subject `PING` reçoit une réponse immédiate via `fleet-send.sh <émetteur> "ACK" <<< "<role> online. <status>"`. Format status : `idle` | `busy: <tâche courte>` | `error: <one-liner>`.

**`[FLEET-INBOX]` sentinel** : INTERDIT comme prompt ou sujet de message.
