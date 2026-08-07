# System Conventions — LCARS

**Date** : 2026-03-08
**Dernière révision** : 2026-03-12
**Statut** : référence active
**Référencé par** : .claude/CLAUDE.md

---

## Nommage — règle générale

**rule** : les noms de répertoires sont sémantiques et auto-descriptifs. Pas de préfixes numériques, pas de convention imposée aux projets utilisateur. Un répertoire se nomme d'après sa fonction : `directives/`, `fleet/`, `knowledge/`, `docs/`.

**scope** : le repo LCARS et l'infrastructure fleet. Les projets utilisateur suivent leurs propres conventions — LCARS n'impose pas de structure de nommage externe.

---

## Structure repo LCARS

**rule** : le repo LCARS est la source de vérité du framework. LCARS est un **projet**, pas une dépendance système read-only. L'user qui adopte LCARS le fork — son fork est sa fleet. Sans modifiabilité par la fleet, la boucle d'auto-amélioration est brisée.

**Deux copies, deux rôles** :
- `/home/projects/LCARS/` — **working copy** (dev). Engineer commit + push vers GitHub depuis ici. Writable par le groupe `fleet`.
- `/local/LCARS/` — **runtime**. Pull depuis GitHub, deploy vers les homes. Les symlinks `~/.lcars` pointent ici. `fleet.yaml` et `fleet-env.sh` référencent ce chemin.

**LCARS-as-project** : invariant de design. La working copy doit résider dans `/home/projects/LCARS/` (chemin projet). Le runtime dans `/local/LCARS/`. Ne jamais confondre les deux — la working copy est pour le dev, le runtime est pour l'exécution fleet.

```
/home/projects/LCARS/
├── directives/     ← L4 — source de vérité, read-only sauf bug-fix validé par user
├── docs/           ← documentation fleet (guides, historiques, specs)
├── fleet/          ← scripts, provisioning, fleet.yaml
├── knowledge/      ← L2 — savoir métier par domaine (rpi-embedded, arduino-fw…)
└── work/           ← plans en cours, side quests — workflow projet, pas de la doc
```

**directives/** : canoniques, immuables en opération. Modification uniquement par bug-fix documenté ou décision architecturale avec validation user explicite.

**knowledge/** : croît à chaque projet. Versionné dans git — un user qui fork LCARS embarque tout le savoir accumulé. Chaque domaine est un sous-répertoire (`knowledge/rpi-embedded/`, `knowledge/arduino-fw/`…).

---

## Structure /home

**rule** : la racine `/home/` suit une arborescence fixe sur toute machine fleet. Créée par `provision-system.sh`. Prerequisite à tout déploiement. Un dossier = une fonction.

```
/home/
├── commons/              ← ext4 local — IPC inter-agents (handoffs, canaux, queues)
├── ready-room/           ← drvfs mount — canal user↔fleet (inbox/ outbox/)
├── projects/             ← repos git partagés entre agents
├── tmp/                  ← workspace éphémère (ponce, audit, clones temporaires)
├── private/              ← secrets non partagés (SSH keys, git-identity.conf)
├── <user>/               ← home user interactif (architect)
└── <agent>/              ← un home par instance fleet (dev, qualifier, builder, starfleet…)
```

**commons/** : répertoire ext4 ordinaire créé par provisioning. Contient uniquement les fichiers IPC : handoffs (`*-handoff.md`), canaux directionnels (`to-*.md`), queues (`*-queue.md`), notes (`*-notes.md`). Éphémère par design — `rm -rf /home/commons/*` reset la fleet à l'état vanilla. Aucun contenu persistant.

**ready-room/** : mount drvfs vers un dossier Windows. Seul point de contact persistant entre l'user et la fleet. Tout output produit par la fleet à destination de l'user passe par ici (archives, exports, artefacts, rapports). Configuration du mount dans `/home/private/ready-room.conf`.

**projects/** : emplacement **exclusif** de tous les repos projet. Tout repo git — projet utilisateur ou LCARS lui-même en mode dev — va dans `/home/projects/<nom>`. Pas d'exception. Initialisé par `fleet-init-project.sh`. Les repos sont re-clonables — pas de données irremplaçables.

**tmp/** : workspace éphémère pour clones d'analyse (`ponce`, `audit`). Si un repo analysé est adopté → fork dans `/home/projects/`. Contenu supprimable sans préavis.

**private/** : accessible uniquement à l'user (permissions 700). Jamais versionné, jamais partagé entre instances. Contient `ready-room.conf` (path Windows du Ready Room).

**règles** :
1. Pas de fichiers à la racine `/home/` — tout va dans un sous-répertoire nommé.
2. `private/` n'est jamais accessible aux agents fleet.

---

## Structure home agent

**rule** : tout home d'agent fleet suit cette arborescence standard. Créée par `deploy.sh` (`.claude/`, `.local/bin/`) et `fleet-init-project.sh` (`worktrees/`).

```
~/
├── .claude/          ← CLAUDE.md, skills/, hooks/, instance.yaml  (deploy.sh)
├── .local/
│   ├── bin/          ← fleet scripts                              (deploy.sh)
│   └── log/          ← logs runtime agent                         (créé par scripts)
├── L2 -> /local/LCARS/knowledge/<domain>/   ← symlink L2          (deploy.sh)
├── worktrees/        ← git worktrees                              (convention)
└── fleet -> /local/LCARS/fleet/             ← symlink             (engineer + starfleet uniquement)
```

**builder uniquement** : `~/builds/` — artefacts de build déposés par cmake/make.

**règle** : pas de fichiers projet à la racine du home. Tout repo cloné va dans `/home/projects/<nom>` (via `fleet-init-project.sh`). Tout worktree va dans `~/worktrees/<projet>/<branche>`.

**scope** : s'applique à tous les agents fleet (dev, builder, qualifier, starfleet, engineer, architect). Le home user suit la même convention pour la cohérence — exception tolérée pour les outils personnels existants.

**LCARS-dans-LCARS** : développer LCARS avec LCARS est un cas récursif. Règle stricte : tout dev sur LCARS depuis un agent fleet se fait sur une branche dédiée, jamais directement sur `main`. La branche est obligatoire, pas optionnelle. Protège contre la divergence entre source déployée et source en cours d'édition.

---

## En-tête `.md` — obligatoire system-wide

**rule** : tout fichier `.md` documentaire porte un en-tête à double lecture immédiatement après la ligne `# Titre` :

```
**Date** : YYYY-MM-DD
**Dernière révision** : YYYY-MM-DD
**Statut** : <one-liner>
**Référencé par** : <fichiers ou —>
```

**scope** : system-wide — s'applique à tous les `.md` documentaires : guides, specs, directives, READMEs, ONBOARDING, plans, bug journals, skills. S'applique à LCARS lui-même, pas seulement aux projets utilisant LCARS.

**exceptions** : fichiers IPC opérationnels exclus — ils ont une structure imposée distincte :

1. `*-handoff.md` — structure STATE/ACTIONS/DONE
2. `to-*.md`, `*-notes.md` — canaux directionnels
3. `*-queue.md`, `*-index.md` — files opérationnelles

**double lecture** :

- Humain : 4 lignes compactes, lisibles d'un coup d'œil — création, révision, statut, dépendances entrantes.
- Machine : chaque champ est atomique, format `**Clé** : valeur`, parseable par `grep -E "^\*\*Clé\*\* :"`.

**date inconnue** : utiliser git : `git log --follow --format="%ad" --date=short -- <fichier> | tail -1`

**enforcement** : ajouter l'en-tête avant toute autre modification si absent.

---

## Thinking tokens — modèles Haiku

Les modèles Haiku sont capés à **8K tokens de réflexion** (extended thinking). Sonnet/Opus n'ont pas cette limite dans les mêmes conditions. Les agents Haiku ne conviennent pas aux tâches nécessitant une réflexion profonde ou des chaînes de raisonnement longues.

---

## Suffixe `-standard`

**rule** : tout fichier suffixé `-standard` est un template non-personnalisé — valeur par défaut pour un utilisateur sans profil préexistant.

**scope** : profils utilisateur (`.claude/CLAUDE-standard.md`, `user-profile-standard.md`), et tout fichier de configuration destiné à être copié à l'onboarding puis personnalisé.

**release** : les fichiers user-spécifiques (avec profil personnalisé) sont remplacés par leur équivalent `-standard` avant distribution publique de LCARS.

**convention** : `<nom>-standard.<ext>` — suffixe avant l'extension, pas en préfixe.

---

## Ready Room — canal user↔fleet

**rule** : tout échange de fichiers entre l'user et la fleet passe par `/home/ready-room/`. Aucun fichier ne doit être déposé directement dans un repo fleet — LCARS contrôle l'intégration. Tout output produit par la fleet à destination de l'user (artefacts, exports, archives, rapports) passe par outbox.

```
/home/ready-room/
├── inbox/    ← user → fleet  (user dépose ici)
└── outbox/   ← fleet → user  (fleet dépose ici, user récupère)
```

**inbox** : l'user dépose les fichiers à intégrer (assets, configs, patches…). La fleet consomme et vide après traitement. Un fichier en inbox est une demande d'intégration, pas une intégration directe.

**outbox** : la fleet dépose les fichiers produits pour l'user (artefacts, exports, archives, rapports…). L'user récupère et vide. Pas de suppression par la fleet après dépôt.

**persistance** : le Ready Room est monté en drvfs depuis un dossier Windows. Il survit aux rerolls de l'instance WSL. C'est le seul stockage persistant côté fleet visible par l'user.

**configuration** : le path Windows du Ready Room n'est pas hardcodé — chaque user a son organisation. Stocké dans `/home/private/ready-room.conf`. Bootstrap interactif au premier provisioning si absent. Sandbox : pré-configuré automatiquement.

**protocole de surveillance inbox** : non défini — backlog.

---

## Modèle d'exécution — Tier 0/1 (Modèle A)

**rule** : symétrie stricte entre les deux côtés de la fleet.

| | Côté user | Côté OS |
|---|---|---|
| Tier 0 (décide) | Architect | StarFleet |
| Tier 1 sas (filtre + exécute) | Engineer | Steward |

**StarFleet** : diagnostique et décide. **sudo lecture seule** (logs, mounts, services, diagnostics). Ne modifie jamais le système directement — toute action passe par `to-steward.md`.

**Steward** : exécute les opérations système sous directive StarFleet. **sudo complet** (permissions, packages, services, backups, sudoers). Seul agent autorisé à écrire dans `to-starfleet.md`. Sas ≠ passif — le sas est un contrôleur de frontière actif.

**principe** : l'entité qui décide ne dispose pas du pouvoir d'exécution. L'entité qui exécute ne décide pas sans directive. Cette séparation est une garantie d'intégrité, pas une contrainte opérationnelle.

---

## Notes — companion narratif

# Notes — #3_system-conventions.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#3_system-conventions.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-08 | Révision | Sections arbo, structure home, dérivation HR→MR |
| 2026-03-10 | Audit v2 | Triple conflit autocompact (83.5%/70%/75%), `Date: —` en header |
| 2026-03-11 | Nettoyage v2 | Retrait section dérivation HR→MR (obsolète), autocompact (plomberie yaml), sections Starfleet Principles (triple duplication #0/#1/#3). lordzurp → user. Header date corrigé |

---

## Contenu retiré du canonique

### Section "dérivation HR → MR — convention de format" (obsolète)

**rule** : tout fichier HR dans `#0_directives/` qui produit un MR déployé (`~/.claude/home_claude_*`) suit les règles de traduction suivantes.

**chaîne** : `#0_directives/` (HR canon, français, append-only) → `.claude/home_claude_*` (MR dérivé, anglais, token-efficient). Le HR est l'autorité. Le MR ne contient jamais d'information absente du HR.

**format MR par défaut** : un concept = une ligne. `keyword: [N] description — nuances — distinctions`. Compact, greppable, token-efficient.

**format MR multi-lignes** : les concepts avec section dédiée dans le HR utilisent une ligne principale suivie de sous-lignes indentées à 2 espaces :

```
keyword: [N] description courte — PREREQUISITE ou note critique
  champ1: valeur
  champ2: valeur
  outputs: (1) ... (2) ... (3) ...
```

**motif** : les outils de recherche (grep) tronquent les lignes longues. Le multi-lignes garantit que la ligne principale reste lisible après grep.

**déduplication** : un mot-clé dans plusieurs contextes du HR n'apparaît qu'une fois dans le MR.

**sections narratives** : les sections marquées "non parsée par le MR" ne sont pas traduites.

> Modèle obsolète en v2 : plus de dérivation HR→MR systématique. Les directives HR sont injectées directement.

### Section "agent fine-tuning / context window / auto-compact"

Fenêtre standard : 200K tokens. Buffer réservé summarization : ~33K tokens (16,5%).

Auto-compact par défaut : ~83,5% (167K/200K). Variable de contrôle :

```bash
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70
```

À setter dans chaque script de lancement tmux par agent. Valeur recommandée fleet : 70.

La dérive observée à ~80% est structurelle : le modèle n'a plus de marge pour le raisonnement quand l'historique + tool outputs saturent la fenêtre.

> Retiré des directives : valeurs gérées en yaml/plomberie uniquement (fleet.yaml, scripts de lancement).

### Section "IDIC compliance"

**rule** : tout composant fleet doit être IDIC-compliant — aucune hypothèse hardcodée sur l'arch, l'OS, le username, ou les chemins absolus non-configurables.

**IDIC targets** : ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif.

**critère de revue** : "est-ce IDIC-compliant ?" est une question légitime en revue.

**réf** : `#4_guides_FR/#12_starfleet-protocols.md § IDIC`

> Retiré : triple duplication avec #0_principes-fondateurs (Starfleet Principles § IDIC) et #1_glossaire (§ Starfleet Principles).

### Section "Holodeck containment"

**rule** : l'instance qualifier (Holodeck) a un périmètre write strict : `test-queue.md`, `to-engineer.md`, `qualifier-handoff.md`. Toute écriture hors périmètre = containment failure.

**containment failure** : incident à journaliser dans `bug-journal.md`.

> Retiré : triple duplication. Version obsolète (qualifier-only, alors que #0 v2 a généralisé à toute la fleet).

### Section "First Contact Protocol"

**rule** : tout nouveau projet intégré à la fleet suit le First Contact Protocol — checklist bidirectionnelle projet↔fleet.

**sans protocole** : comportement non-défini.

> Retiré : triple duplication avec #0 et #1.

### Section "Temporal Prime Directive (TPD)"

**rule** : le commit graph est immuable après publication. Exception : `--force-with-lease` sur branche feature personnelle non-partagée.

> Retiré : triple duplication avec #0 et #1.

---

## Bug-fixes — 2026-03-12

### `/home/projects/` non déclaré comme emplacement exclusif des projets
La section `/home/` structure décrivait `projects/` comme "repos git clonés et partagés entre agents" sans préciser que c'est l'emplacement **exclusif**. Un agent pouvait raisonnablement cloner ailleurs. Corrigé : règle explicite "TOUS les repos dans `/home/projects/<nom>`, pas d'exception".

### `work/` absent de la structure repo LCARS
Le schéma des dossiers racine LCARS ne listait que 4 entrées (directives/, docs/, fleet/, knowledge/). `work/` (plans, side quests) était implicitement sous `docs/`, mélangeant workflow et documentation. Corrigé : `work/` ajouté comme 5e dossier racine.

### `#7_workflow` référençait `docs/work/doing/`
Path incorrect — `work/` est peer de `docs/`, pas enfant. Corrigé vers `work/doing/<topic>.md`.
