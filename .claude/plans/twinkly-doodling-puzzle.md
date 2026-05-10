# Plan : suppression du préfixe cDs- — renommage générique des instances

## Contexte

Les instances WSL portent le préfixe `cDs-` (lié au projet Cult of the Dead Star), mais le toolkit est devenu un projet indépendant. On rend les noms génériques. Bug existant : le dossier Windows de l'architecte s'appelle `Architect` (pas `cDs-architect`), créant un fantôme dans deploy.sh.

## Convention cible

Tout minuscule :
| Ancien | Nouveau |
|---|---|
| `cDs-starfleet` | `starfleet` |
| `cDs-dev` | `dev` |
| `cDs-build-ARM` | `build-arm` |
| `cDs-build-X86-64` | `build-x86-64` |
| `cDs-architect` / `Architect` | `architect` |

---

## Phase 1 — Code (branche, pas de deploy)

Branche `refactor/generic-instance-names` sur Claude-directives. Aucun impact runtime — le fleet peut tourner.

### Scripts fleet (6 fichiers)

| Fichier | Changement |
|---|---|
| `fleet/fleet.yaml` | id + wsl-name des 5 instances |
| `fleet/fleet-hub.py` | `INSTANCE_FILES` dict (5 entrées) |
| `fleet/fleet-monitor.py` | `INSTANCE_ORDER` list |
| `fleet/fleet-launch.sh` | `wsl -d` commands (garder anciens noms WSL pour l'instant, variable séparée) |
| `fleet/light_off.sh` | `WORKERS` array + `WORKER_PANE` map |
| `fleet/backup-wsl.sh` | `INSTANCES` array |

### Hooks (2 fichiers)

| Fichier | Changement |
|---|---|
| `.claude/hooks/session-startup.sh` | case patterns : `*starfleet`, `*dev`, `*build-arm`, `*build-x86-64`, `*architect` (glob, backward-compat temporaire) + checks `[[ == *starfleet ]]` et `[[ == *build-arm ]]` |
| `.claude/hooks/post-write-doc-reminder.sh` | pattern match `*starfleet` au lieu de `cDs-starfleet` |

### deploy.sh

`TARGETS` array : paths vers `#2_Home/<nouveau-nom>/.claude`. Le filtre cross-arm64 : `*build-x86-64*`.

**Attention** : ces paths ne sont valides qu'après le renommage des dossiers Windows (Phase 3A). Pendant la transition, `$HOME/.claude` (dernière cible) attrape l'instance courante.

### Commands (2 fichiers)

| Fichier | Changement |
|---|---|
| `.claude/commands/handoff.md` | refs instances dans la doc |
| `.claude/commands/maj_doc.md` | refs instances + paths handoff |

### Documentation (5 fichiers)

| Fichier | Changement |
|---|---|
| `DIRECTIVES.md` | scope boundaries, skill deployment |
| `home_claude_CLAUDE.md` | scope boundaries, builder rules, instance list |
| `memory/ipc-protocol.md` | table instances, matrice handoff, exemples |
| `README.md` | diagrammes archi, exemples curl, tmux (FR + EN) |
| `docs_and_plans/guides/bug-journal.md` | refs dans les entrées existantes |

### WSL-setup repo (branche `WSL2`)

| Fichier | Changement |
|---|---|
| `README.md` | exemples, diagrammes (FR + EN) |
| `CLAUDE.md` | exemple instance-name |
| `post-install-build-ARM.sh` | commentaire header |
| `post-install-build-x86.sh` | commentaire header |
| `docs_and_plans/guides/bug-journal.md` | refs dans entrées |

---

## Phase 2 — Données partagées (fleet stoppé)

**Prérequis** : `~/stop` — aucune session Claude active.

### 2A — Renommer les fichiers handoff

```
/home/commons/handoff/
  cDs-starfleet-handoff.md    → starfleet-handoff.md
  cDs-dev-handoff.md           → dev-handoff.md
  cDs-build-ARM-handoff.md     → build-arm-handoff.md
  cDs-build-X86-64-handoff.md  → build-x86-64-handoff.md
  cDs-architect-handoff.md     → architect-handoff.md
```

### 2B — Sed-replace dans tous les fichiers handoff

`s/cDs-starfleet/starfleet/g; s/cDs-architect/architect/g; s/cDs-dev/dev/g; s/cDs-build-ARM/build-arm/g; s/cDs-build-X86-64/build-x86-64/g` sur tous les `.md` dans handoff/ et handoff/archive/.

### 2C — Mettre à jour instance-name dans chaque home

Via `/home/wsl-root/#2_Home/` (drvfs, accessible depuis architect) :

```
#2_Home/cDs-dev/.claude/instance-name          → "dev"
#2_Home/cDs-build-ARM/.claude/instance-name    → "build-arm"
#2_Home/cDs-build-X86-64/.claude/instance-name → "build-x86-64"
#2_Home/cDs-starfleet/.claude/instance-name   → "starfleet"
#2_Home/Architect/.claude/instance-name        → "architect"
```

### 2D — Mettre à jour MEMORY.md de chaque instance

Header d'identité (`Instance: cDs-xxx` → `Instance: xxx`) dans les MEMORY.md accessibles via `#2_Home/<name>/.claude/projects/*/memory/MEMORY.md`.

### 2E — Deploy + merge

```bash
cd /home/wsl-root/#0_Claude-directives
git checkout refactor/generic-instance-names
bash deploy.sh
git checkout main && git merge refactor/generic-instance-names
git push origin main
```

Idem WSL-setup sur branche `WSL2`.

---

## Phase 3 — Windows-side (lordzurp, PowerShell)

### 3A — Renommer les dossiers #2_Home (REQUIS)

Sans ça, `deploy.sh` pointe vers des dossiers inexistants.

```powershell
wsl --shutdown
Rename-Item "C:\Users\lordzurp\WSL\#2_Home\cDs-dev" "dev"
Rename-Item "C:\Users\lordzurp\WSL\#2_Home\cDs-build-ARM" "build-arm"
Rename-Item "C:\Users\lordzurp\WSL\#2_Home\cDs-build-X86-64" "build-x86-64"
Rename-Item "C:\Users\lordzurp\WSL\#2_Home\cDs-starfleet" "starfleet"
Rename-Item "C:\Users\lordzurp\WSL\#2_Home\Architect" "architect"
```

### 3B — Mettre à jour fstab + wsl.conf dans chaque instance (REQUIS après 3A)

Le fstab de chaque instance référence `#2_Home/<ancien-nom>` pour le mount `/home/<user>`. Il est dans le VHDX (ext4), donc il faut booter chaque instance pour l'éditer.

Procédure par instance (ex: `cDs-dev`) :
```powershell
wsl -d cDs-dev -u root -- sed -i 's/#2_Home\\cDs-dev/#2_Home\\dev/g' /etc/fstab
wsl -d cDs-dev -u root -- sed -i 's/hostname = cDs-dev/hostname = dev/' /etc/wsl.conf
wsl --terminate cDs-dev
```

Puis renommer le dossier (3A), puis rebooter pour vérifier.

**Ordre critique** : éditer fstab AVANT de renommer le dossier. Sinon l'instance boote sans home.

### 3C — Renommer les distributions WSL (OPTIONNEL, recommandé de SKIP)

`wsl --rename` n'existe pas. Seules options :
- **Export/reimport** : `wsl --export cDs-dev dev.tar` → `wsl --unregister cDs-dev` → `wsl --import dev #1_Instances/dev dev.tar`. Lent (GB de données), risque de corruption.
- **Registry hack** : éditer `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\`. Non documenté, cassable par Windows Update.

**Recommandation : ne pas renommer les distributions.** Le seul endroit qui utilise le nom WSL est `fleet-launch.sh` (`wsl -d cDs-dev`). On garde ces noms dans `fleet.yaml` (champ `wsl-name`) et on les lit depuis le script.

**Impact si on skip** : `wsl -l -v` affiche les anciens noms. Cosmétique uniquement — l'identité logique est partout le nouveau nom.

### 3D — Nettoyage

```powershell
Remove-Item -Recurse "C:\Users\lordzurp\WSL\#2_Home\cDs-architect"  # fantôme
Remove-Item -Recurse "C:\Users\lordzurp\WSL\#2_Home\cDs-build"      # décommissionné
```

---

## Risques

| Risque | Impact | Mitigation |
|---|---|---|
| fstab désynchronisé après rename #2_Home | Instance boote sans home → session inutilisable | Éditer fstab AVANT le rename du dossier. Script automatisé. |
| Handoff renommé pendant qu'une instance écrit | Fichier perdu ou orphelin | Fleet stoppé pendant Phase 2. Aucune session active. |
| fleet-hub cherche nouveau nom, fichier pas encore renommé | Dashboard vide, 404 | Phase 2 est atomique : code + fichiers dans la même fenêtre de maintenance. |
| Export/reimport WSL corrompt le VHDX | Perte de l'instance (sysroot, build cache) | On skip Phase 3C. Les distros gardent l'ancien nom WSL. |
| deploy.sh pointe vers #2_Home/dev mais dossier pas encore renommé | Hooks non déployés vers la bonne cible | Phase 3A est faite juste après Phase 2E. En attendant, `$HOME/.claude` catch-all fonctionne. |
| MEMORY.md dans le VHDX pas accessible via drvfs | Identité stale au démarrage | Les MEMORY.md des homes drvfs sont accessibles via #2_Home. Seuls les MEMORY.md dans les project dirs ext4 sont inaccessibles — à corriger au premier boot de chaque instance. |

## Rollback

| Phase | Rollback |
|---|---|
| Phase 1 | `git checkout main` + `deploy.sh` |
| Phase 2 | Re-rename handoff files, restore instance-name files, re-deploy from main |
| Phase 3A | Re-rename dossiers Windows |
| Phase 3C | Impossible si export/reimport fait → raison de plus pour skip |

## Ordre d'exécution

| Étape | Qui | Durée | Fleet |
|---|---|---|---|
| Phase 1 complète | architect | ~1h | Peut tourner |
| `~/stop` | lordzurp | 2 min | **STOPPÉ** |
| Phase 2A-2D | architect | 15 min | Stoppé |
| Phase 2E (deploy + merge) | architect | 10 min | Stoppé |
| Phase 3A (rename dossiers) | lordzurp (PowerShell) | 5 min | Stoppé |
| Phase 3B (fstab + wsl.conf) | lordzurp (PowerShell) | 15 min | Stoppé |
| Phase 3D (nettoyage) | lordzurp | 2 min | Stoppé |
| `~/start` | lordzurp | 2 min | **RELANCÉ** |

Downtime total : ~45 min. Phase 3C (WSL distro rename) : skip recommandé.
