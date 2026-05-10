# LCARS v3 — Hiérarchie de directives et protocole d'escalade

**Date** : 2026-03-05
**Dernière révision** : 2026-03-08
**Statut** : spécification v3
**Référencé par** : glossaire-systeme.md, roles-agents.md

_Numérotation L alignée sur `roles-agents.md` : L4=global→L0=session. L'isolation OS est une couche infrastructure séparée, pas un niveau Knowledge._

---

## 0. Infrastructure OS — couche fondation (hors Knowledge)

**Autorité** : noyau Linux, not negotiable.
**Mécanisme** : permissions fichiers (chmod/chown), groupes Linux (`fleet`, `dev`, `qualifier`, `builder`), ACLs sur `/run/fleet/`, `/home/commons/`.
**Règle** : aucun agent ne peut contourner cette couche. Pas de `sudo` dans les hooks agents. Pas de changement de permissions par un agent.
**Exemples** :
- dev ne peut pas écrire dans `/local/LCARS-fleet/` (appartient à lordzurp/architect)
- qualifier ne peut pas lire `/home/dev/` (home privé)
- builder ne peut pas modifier les CLAUDE.md (read-only pour lui)

_Cette couche n'est pas un niveau de Knowledge — c'est la fondation physique sur laquelle tout repose._

---

## 1. Hiérarchie des niveaux Knowledge (directives)

```
L4 — Framework global  (engineer / architect)
L3 — Fleet topology    (StarFleet + architect — topologie, état instances)
L2 — Métier / Domaine  (StarFleet + architect — savoir domaine)
L1 — Projet            (lead + agents actifs — contexte projet courant)
L0 — Session           (tous agents — éphémère, expire à la session)
```

### L4 — Framework global

**Autorité** : engineer, architect.
**Fichiers** : `home_claude_CLAUDE.md`, `home_claude_CLAUDE-qualifier.md`, `home_claude_CLAUDE-builder.md`, `fleet.yaml`.
**Règle** : seul Architect peut modifier L4. Déployées via `deploy.sh` vers tous les agents. Ne peuvent être contredites par aucun niveau inférieur.
**Portée** : s'appliquent à tous les agents, toujours, sans exception.
**Exemples** :
- "Jamais de `2>/dev/null` sur commandes diagnostiques"
- "Handoff files en anglais"
- "Bead format obligatoire pour toute tâche >30min"
- "Escalade : 3 tentatives avant escalade obligatoire"

### L3 — Fleet topology

**Autorité** : StarFleet (R+W), Architect (R+W), Lead (R+W).
**Fichiers** : `fleet.yaml` (section topology), `fleet-state.*`, canaux IPC actifs.
**Règle** : décrit qui existe, qui est actif, quelles instances tournent. Aucun Tier 2 n'y accède — ils ne voient pas la topologie fleet.
**Portée** : agents Tier 0 et Tier 1 uniquement.

### L2 — Métier / Domaine

**Autorité** : Architect (crée, via harvest uniquement). StarFleet (lit, déclaratif).
**Fichiers** : `<domaine>/CLAUDE.md` (ex: `rpi-embedded/CLAUDE.md`, `django-api/CLAUDE.md`).
**Règle** : L2 ne s'écrit PAS pendant un projet — uniquement via `fleet-harvest-project.sh` en fin de projet. Lecture seule pendant l'exécution pour tous les agents. StarFleet lit L2 de façon déclarative (sait que `rpi-embedded` existe, pas son contenu technique).
**Portée** : agents actifs sur ce domaine.
**Exemples** :
- "Cross-compilation ARM64 : utiliser le sysroot dans /opt/sysroot-rpi/"
- "Targets de build : arm64 et x86-64 uniquement"
- "Jamais de dépendance dynamique pour le binaire embarqué"

### L1 — Projet

**Autorité** : Lead (crée, valide). Agents Tier 2 (proposent via escalade).
**Fichiers** : `docs_and_plans/project-directives.md`, `beads-active.md`, L1 du projet courant.
**Règle** : ne peuvent pas contredire L4 ou L2. Les Tier 2 peuvent proposer des clarifications — Lead les valide avant qu'elles soient effectives. StarFleet n'accède pas à L1.
**Portée** : agents actifs sur ce projet uniquement.
**Exemples** :
- "Ce module utilise le pattern Observer — ne pas refactorer vers callbacks"
- "Tests : ctest minimum 95% avant PR"
- "Fichiers de config dans `/etc/cds/` — jamais dans le binaire"

### L0 — Session

**Autorité** : tous agents (dans leur périmètre).
**Fichiers** : `to-*.md`, `handoff/*.md`, `beads-active.md` (entrées en cours).
**Règle** : expirent à la fin de la session ou quand marquées DONE. Ne persistent pas comme référence. Une bead doit être promue en L1 avant fin de session pour ne pas être perdue.
**Portée** : tâche courante uniquement.
**Exemples** :
- "Pour cette tâche : refactorer uniquement cmake/, pas src/"
- Bead IN_PROGRESS avec acceptance criteria

---

## 2. Matrice lecture/écriture par Tier

| Tier / Rôle | L4 | L3 | L2 | L1 | L0 |
|---|---|---|---|---|---|
| **Tier 0** — StarFleet | R | R+W | R (décl.) | ✗ | R+W |
| **Tier 1 framework** — Architect | R+W | R+W | R | ✗ | R+W |
| **Tier 1 projet** — Lead | R | R+W | R | R+W | R+W |
| **Tier 2a** — Dev, Builder, Qualifier… | R | ✗ | R | R+W | R+W |
| **Tier 2b** — Hard-Guru, Search-Agent… | R | ✗ | R | R opt. | R+W |

**Règles critiques** :
- L2 ne s'écrit jamais pendant un projet — harvest uniquement.
- StarFleet n'accède pas à L1 : il garantit le système, pas le projet.
- Un agent ne peut pas s'auto-octroyer d'autorité en écrivant dans un niveau supérieur à son droit.
- Toute modification L4 requiert validation humaine (lordzurp).

---

## 3. Protocole d'escalade — le détail béton

### 3.1 Conditions d'escalade (filtre anti-bruit)

Un agent N'ESCALADE PAS immédiatement. Conditions requises :

**Escalade automatique obligatoire** (1 occurrence suffit) :
- Blocage hard : permission refusée sur fichier critique
- Corruption d'état détectée (git conflict non résolvable, bead BLOCKED)
- Budget CI dépassé (>N retries sur test qui passe normalement)
- Violation de scope détectée (agent touche fichiers hors déclaration)

**Escalade après seuil** (3 tentatives, approches différentes) :
- Erreur de compilation non comprise après 3 approches différentes
- Test qui échoue sans raison claire (bug intermittent possible)
- Ambiguité de spécification bloquante

**Ne jamais escalader** :
- Erreurs attendues (compilation d'un fichier intentionnellement cassé)
- Problèmes résolus en <3 tentatives
- Questions "nice to have" (utiliser la solution la plus conservatrice)

### 3.2 Directions d'escalade autorisées

```
Tier 2 (Dev, Builder, Qualifier…)
  ──→ Lead          : escalade PROJET (spec ambiguë, décision archi, bead bloquée)
  ──→ StarFleet    : escalade INFRA  (permission refusée, service down, CI gate)
  ──(urgence)──→ Architect-fleet  [tag ESCALADE-URGENTE requis, raison explicitée]

Lead (Tier 1 projet)
  ──→ StarFleet    : si problème infra impacte le projet
  ──→ Architect-fleet : si décision L4 ou provisioning requis

StarFleet (Tier 0)
  ──→ Architect-fleet : provisioning, décision L4, situation critique système
  ──→ Architect-lead  : interactif uniquement, lordzurp présent

Interdits :
  tout agent → architect direct (non-wakeable, sauf lordzurp en session)
  dev → dev (pas de communication horizontale directe entre Tier 2)
  StarFleet → Lead (canaux orthogonaux — infra n'ordonne pas au projet)
```

**Règle de discrimination projet vs infra** :
- "Je ne sais pas quoi coder / le spec est ambigu / décision archi" → **Lead**
- "Je n'ai pas les permissions / le service est down / le CI est cassé" → **StarFleet**

### 3.3 Protocole complet d'une escalade

**Étape 1 — Escalateur : écriture structurée dans le canal**

Format obligatoire dans `to-lead.md` ou `to-steward.md` selon le type :
```markdown
## ESCALADE [<role>] — YYYYMMDD-HHMMSS

**Motif** : [BLOCAGE_HARD | SEUIL_3_TENTATIVES | URGENCE]
**Type** : [PROJET | INFRA]
**Contexte** : <bref — tâche en cours, bead concernée>
**Tentatives** :
1. <approche 1> → <résultat>
2. <approche 2> → <résultat>
3. <approche 3> → <résultat>
**Bloquant** : <ce qu'on ne peut pas faire sans réponse>
**Proposition** (optionnel) : <si une solution candidate existe>
```

**Étape 2 — Escalateur : stop complet sur cet item**

L'agent ARRÊTE le travail sur l'item escaladé. Il peut continuer d'autres tâches non liées si elles existent. Il ne spécule pas sur la résolution.

**Étape 3 — Escalatee : accusé de réception [ACK]**

Format dans le canal retour :
```markdown
## [ACK] ESCALADE reçue — YYYYMMDD-HHMMSS

**De** : <lead | StarFleet>
**Item** : <référence escalade>
**Status** : ANALYSE | EN_COURS | RÉSOLU
**ETA** : <si applicable>
```

**Étape 4 — Escalatee : résolution**

```markdown
## [RÉSOLU] ESCALADE — YYYYMMDD-HHMMSS

**Décision** : <explication + directive si applicable>
**Action** : <ce que l'escalateur doit faire maintenant>
**Nouvelle directive L1** (si applicable) : <texte à ajouter dans project-directives.md>
```

**Étape 5 — Escalateur : confirmation DONE**

Marque la bead correspondante comme DONE ou BLOCKED (selon résolution). Continue le travail.

### 3.4 Circuit breaker

**Trigger** : même item escaladé plus de 2 fois dans la même session sans résolution.

**Action** :
1. L'escalateur écrit `## CIRCUIT-BREAKER [<role>] — <item>` dans le canal
2. L'escalateur arrête toute activité sur cet item pour la session
3. La bead est marquée `BLOCKED — circuit-breaker`
4. L'escalateur continue uniquement les tâches indépendantes
5. Le déblocage requiert une intervention humaine (lordzurp) ou architect en session

**Journalisation** : tout circuit-breaker est logué dans `bug-journal.md` avec la séquence complète.

**Pourquoi béton** : sans circuit breaker, les escalades circulaires (`A→B→A→B...`) consomment du budget context sans résolution. Le breaker force la main du humain.

### 3.5 Sécurité du mécanisme d'escalade

**Immutabilité des logs** : les fichiers `to-*.md` sont append-only par convention. Un agent ne peut pas modifier une entrée passée (pas de `sed -i` sur ces fichiers). Violation = bug journal.

**Pas d'auto-escalade de permissions** : écrire une escalade ne modifie pas les droits de l'agent. Un Tier 2 qui escalade vers Lead ne devient pas Lead le temps de la résolution. Il attend.

**Audit trail** : tous les `to-*.md` sont versionnés dans git avec timestamps. N'importe qui peut rejouer la séquence.

**Détection d'escalade circulaire** :
```
dev → lead [normal]
lead → engineer [normal]
engineer → dev [via to-dev.md, pas une escalade montante]
```
Une escalade est circulaire si A→B et dans la même session B→A sur le même item. Circuit breaker déclenche.

**Validation humaine obligatoire pour** :
- Modifications de directives L4 ou L2 (même si proposées par Lead)
- Déploiement d'un nouvel agent (`fleet-add.sh`)
- Push après CI gate fail (exception manuelle avec justification)

---

## 4. Directives minimales obligatoires par niveau

### L4 — Contenu minimal d'un CLAUDE.md agent (framework global)

Chaque agent doit avoir dans son CLAUDE.md :
```markdown
## Escalade

- Seuil : 3 tentatives sur approches différentes avant escalade
- Canal projet : to-lead.md [<role>] avec format ESCALADE standardisé
- Canal infra : to-steward.md [<role>] pour blocages système/permissions
- Stop : arrêter l'item escaladé immédiatement, ne pas spéculer
- Circuit breaker : >2 escalades sans résolution sur même item → CIRCUIT-BREAKER
```

### L2 — Contenu minimal d'un CLAUDE.md métier (domaine)

```markdown
## Contexte domaine

<domaine> — <description 1 ligne>
Stack : <liste outils/langages>
Toolchain : <compilation, tests, deploy>
Contraintes spécifiques : <liste>

## Escalade domaine

Si ambiguité sur comportement hardware/protocol attendu → escalader vers Lead (pas déduire).
```

### L1 — Contenu minimal d'un project-directives.md (projet)

```markdown
## Identité projet

Nom : <projet>
Agents actifs : [dev, qualifier, builder, ...]
CI : <commande exacte de build + test>
Push gate : <cmake --build . && ctest> ou <pytest> selon projet

## Beads actives

(géré automatiquement — ne pas éditer manuellement)
```

---

## 5. Exemples de flux complets

### Flux 1 — Escalade projet normale (seuil atteint)

```
dev: tente fix bug #42 — approche 1 (échec)
dev: tente fix bug #42 — approche 2 (échec)
dev: tente fix bug #42 — approche 3 (échec)
dev: écrit ESCALADE PROJET dans to-lead.md avec les 3 tentatives
dev: marque bead #42 IN_PROGRESS → BLOCKED (escalade en attente)
dev: passe à tâche #43 (indépendante)

lead: [ACK] reçu dans to-dev.md
lead: analyse le problème
lead: [RÉSOLU] — directive L1 ajoutée + instruction pour dev

dev: lit résolution
dev: marque bead #42 IN_PROGRESS à nouveau
dev: applique la directive
dev: valide (tests PASS)
dev: marque bead #42 DONE
```

### Flux 2 — Circuit breaker

```
dev: ESCALADE PROJET #55 → lead [première fois]
lead: [RÉSOLU] — instruction X
dev: tente instruction X → même problème
dev: ESCALADE PROJET #55 → lead [deuxième fois]
lead: [RÉSOLU] — instruction Y
dev: tente instruction Y → même problème
dev: CIRCUIT-BREAKER #55 — >2 escalades sans résolution
dev: bead #55 → BLOCKED circuit-breaker
dev: écrit dans bug-journal.md
dev: continue tâches indépendantes uniquement

[Déblocage nécessite lordzurp ou architect en session interactive]
```

### Flux 3 — Escalade infra urgente → engineer

```
dev: détecte corruption de l'état git (merge conflict dans bead system)
dev: tentative de résolution → risque aggravation
dev: écrit ESCALADE-URGENTE INFRA dans to-architect.md [dev]
dev: STOP TOTAL — aucune autre action sur le repo
dev: notifie steward via to-steward.md

engineer: [ACK]
engineer: intervient directement
engineer: [RÉSOLU] + bead reset + instruction
dev: reprend
```

### Flux 4 — Escalade infra normale → StarFleet

```
dev: permission refusée sur /home/commons/handoff/ (blocage hard)
dev: écrit ESCALADE INFRA dans to-steward.md [dev]
dev: stop sur item, continue tâches indépendantes

StarFleet: diagnostique (service down ? ACL incorrecte ?)
StarFleet: [ACK] puis [RÉSOLU] dans to-dev.md
dev: reprend
```

---

*Produit par architect — 2026-03-05. Mis à jour 2026-03-08 : numérotation L alignée taxonomie, StarFleet ✗ L1, routing escalade projet→Lead / infra→StarFleet.*
