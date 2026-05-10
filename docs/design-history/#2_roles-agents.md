# Rôles et agents — LCARS

**Date** : 2026-03-08
**Dernière révision** : 2026-03-11
**Statut** : référence active
**Référencé par** : .claude/CLAUDE.md

---

## Principe fondateur

Un agent = instanciation de trois axes structuraux :
1. **Tier** — cycle de vie (permanence, provisioning, activation)
2. **Division** — mode de travail (🔴 Command / 🟡 Operations / 🔵 Sciences)
3. **Knowledge** — niveaux L accessibles en lecture/écriture

Le comportement émerge des directives, pas du nom de l'agent.
Les presets sont des alias nommés vers `(Tier, Division, Scope, L2-domain)` — définis dans `fleet.yaml`, pas dans cette directive.

---

## Topologie — frontières et sas

La fleet est un système fermé avec exactement **deux frontières** :

```
         [ OS / système ]
               ↑
      [ StarFleet — root ]        ← frontière OS (Tier 0)
               ↑
         [ Steward ]              ← sas OS (Tier 1)
               │
    ┌──────────┼──────────┐
    │     fleet interne    │      ← Tier 1+2 (tout est dedans)
    │  dev, qualifier,     │
    │  builder, agents...  │
    └──────────┼──────────┘
               │
        [ Engineer ]              ← sas User (Tier 1)
               ↓
        [ Architect ]             ← frontière User (Tier 0)
               ↓
           [ user ]
```

**Définition structurelle de Tier 0** : agent dont la défaillance coupe une frontière de la fleet. StarFleet tombe = fleet aveugle côté OS. Architect tombe = fleet aveugle côté user. Tout le reste peut tomber sans couper un boundary.

**Bulkhead pattern** : chaque Tier 0 a un sas Tier 1 exclusif. Le sas filtre/agrège pour le Tier 0 protégé. Le canal entre sas et protégé est exclusif (un seul écrivain). L'entité qui filtre n'a pas le pouvoir d'action du protégé. Le sas est le **seul** agent autorisé à `notify:` son Tier 0 — tout autre `notify:` vers un Tier 0 est interdit.

| Tier 0 (protégé) | Tier 1 (sas) | Canal exclusif | Rôle du sas |
|---|---|---|---|
| StarFleet (exécutif, root) | Steward (🟡 Ops) | to-starfleet.md (steward only writes) | filtre d'intégrité |
| Architect (décisionnel, user) | Engineer (🟡 Ops) | push terminal (engineer only) | agrégation fleet |

---

## Tiers

**Tier 0** — frontières fleet. Immuables. Provisionnés au setup, jamais instanciés dynamiquement.

**Tier 1** — sas permanents. Contexte long durée, survit aux sessions. Provisionné une fois (`useradd` + deploy directives). Invoqué via `wake-instance.sh`. Membres : Engineer, Steward.

**Tier 2a** — instances par projet. Instance Linux dédiée (user, home, mémoire inter-session). Créée vierge, peuplée par deploy.sh (directives + `instance.yaml` + symlink L2). Détruite après usage — toujours invoquer sur un contexte propre. Critère : besoin de mémoire inter-session.

**Tier 2b** — agents purs. Spawné comme subagent par un Tier 1 ou 2a via `.claude/agents/<name>.md`. Contexte éphémère, stateless entre invocations. Pas d'instance Linux. Scope déclaré dans le fichier agent. Critère : stateless par invocation.

---

## Scopes

Le scope définit ce qu'un agent est **autorisé** à faire. Ce qui n'est pas dans le scope est **interdit** (GO-0). Les scopes sont des contraintes structurelles — les presets qui les utilisent sont définis dans `fleet.yaml`.

### Tier 0+1 — scopes fixes (non configurables)

| Scope | Rôle | Autorisé | Interdit implicite |
|---|---|---|---|
| **boundary-os** | StarFleet | root, infrastructure, backups, CI gate, provisioning, L3+L4 R/W | L1, input user direct, input fleet non filtré |
| **boundary-user** | Architect | interface user, arbitrage, priorisation, L3 R | fleet IPC polling (sauf sas), notify (sauf sas), wake |
| **sas-os** | Steward | validation intégrité, to-starfleet.md exclusif, L3 R/W | exécution root, action directe |
| **sas-user** | Engineer | L4 R/W, to-engineer.md autonome, deploy, drift audit | code projet, push projet |

### Tier 2 — scopes paramétrables

| Scope | Autorisé | L1 |
|---|---|---|
| **code** | code, commits, escalade | R/W |
| **build** | cmake, cross-compilation, dépôt binaires | R |
| **test** | exécution tests, rapports PASS/FAIL | R + W rapports |
| **physical** | flash, SSH device, hardware-in-loop | R |
| **advisory** | conseil lecture seule, output structuré | R ou — |
| **research** | recherche externe, one-shot, output structuré | — |
| **analysis** | git/code/specs read-only, output structuré | R |
| **documentation** | rédaction docs/README/guides | R/W docs uniquement |

Scope `physical` : seul scope autorisant une interaction avec le monde physique extérieur au système.

---

## Matrice Knowledge×Tier

| Tier | L4 | L3 | L2 | L1 | L0 | Instance Linux |
|---|---|---|---|---|---|---|
| **0** | R | R+W | R déclaratif | ✗ | R+W | Permanente |
| **1 framework** | R+W | R+W | R | ✗ | R+W | Permanente |
| **1 projet** | R | R+W | R | R+W | R+W | Permanente |
| **2a** | R | ✗ | R | R+W | R+W | Oui (mémoire inter-session) |
| **2b** | R | ✗ | R | R optionnel | R+W | Non (agent pur, éphémère) |

_Tier 0 = frontières fleet (StarFleet, Architect). Tier 1 framework = Engineer, Steward._
_L2 ne s'écrit pas pendant un projet — alimenté par harvest fin de projet uniquement._
_L3 : accès réservé Tier 0+1 — aucun Tier 2 ne voit la topologie fleet._

### Conséquence d'un niveau absent

| Niveau absent | Impact |
|---|---|
| L4 | Catastrophique — agent sans règles globales, comportement indéfini. Condition de provisionnement. |
| L3 pour Tier 0/1 | StarFleet aveugle sur la fleet, Architect aveugle sur les ressources. Dégradation sévère. |
| L2 | Dégradation qualité — raisonnement depuis premiers principes. Pas un bloqueur immédiat. |
| L1 pour Tier 2a | Bloquant total — pas de contexte projet. |
| L1 pour Tier 2b | Sans impact — agents advisory répondent depuis L2. |

---

## Règles de composition Division × Knowledge

```
🔴 Command  → accès L3 (voit la fleet, coordonne)
🟡 Operations → accès L1 en écriture (produit des artefacts)
🔵 Sciences → accès L1 en lecture seule ou pas du tout (analyse, ne modifie pas)
```

Exceptions documentées :
1. **Qualifier** (🔵 Sciences) écrit L1 : les rapports de tests sont des artefacts de validation, pas du code
2. **Doc-Writer** (🔵 Sciences) écrit L1 : la documentation est un artefact livrable, pas du code
3. **Engineer** (🟡 Operations) a L3 R+W : l'accès L3 découle du Tier 1 framework, pas de la Division
4. **Steward** (🟡 Operations) a L3 R+W : même logique — l'accès L3 découle du Tier 1, pas de la Division

---

## Injection des directives

**Principe** : toutes les directives sont identiques pour tout le monde. deploy.sh copie le même set dans chaque instance. Pas de jeux de directives séparés.

**Mécanisme scope** :
1. Tier 2a : deploy.sh génère `~/.claude/instance.yaml` depuis `fleet.yaml` (scope, tier, L2, model)
2. Tier 2b : scope déclaré dans `.claude/agents/<name>.md` de l'instance parent
3. L'agent lit les définitions de tous les scopes (§ ci-dessus), applique le sien

**Mécanisme L2** :
1. Savoir métier stocké dans `/local/LCARS/knowledge/<domain>/`
2. deploy.sh crée le symlink `~/L2 → /local/LCARS/knowledge/<domain>/` depuis `fleet.yaml`
3. Changer le domaine d'un agent = changer une ligne dans fleet.yaml + redeploy

**Orthogonalité Tier / Scope** : un même scope peut être Tier 2a ou 2b. Le Tier détermine la persistance, le scope détermine les autorisations. fleet.yaml choisit la combinaison.

---

## Notes — companion narratif

# Notes — #2_roles-agents.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#2_roles-agents.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-08 | Création | 17 presets, taxonomie Tier/Division/Knowledge |
| 2026-03-10 | Révision | Mise à jour header |
| 2026-03-10 | Audit v2 | `lordzurp` en dur, 10 Tier 2b non déployés non flaggés, `fleet-add.sh` inexistant |
| 2026-03-11 | Nettoyage v2 | Architect-lead → Architect, Architect-fleet → Engineer. Presets → fleet.yaml (seuls les scopes restent dans la directive). Descriptions narratives → notes. fleet-add.sh → retiré (aspirationnel). Rôles NON retenus → notes. Généralisation Dev/Hardev/Frontend → scope unique `code` + L2 variable |

---

## Décisions architecturales (session v2)

### Renommage Architect-lead → Architect / Architect-fleet → Engineer

Un seul Architect (ancien Architect-lead). L'ancien Architect-fleet devient Engineer — reflète mieux son job (maintenance toolkit), évite le doublon de nom, cohérent avec `engineer-handoff.md` et `fleet-notify.sh engineer` déjà en usage.

### Généralisation des presets Tier 2

**Critère de discrimination** : le SCOPE (ce que l'agent est autorisé à faire), pas le SAVOIR (L2 injecté). Deux agents même scope + L2 différent = même preset, config YAML différente.

Tier 2a avant : Dev, Hardev, Frontend, Builder, Qualifier (5). Après : Dev, Builder, Qualifier (3). Hardev = Dev + L2(embedded). Frontend = Dev + L2(frontend).

Tier 2b : même logique. Les scopes irréductibles restent (physical, advisory, research, analysis, documentation). Les presets (noms, modèles, L2) vivent dans fleet.yaml.

### Séparation directive / config

- **Directive (#2)** : définitions de scopes (contraintes structurelles, immuables). Ce qui n'est pas dans le scope est INTERDIT (GO-0).
- **fleet.yaml** : presets (noms, tier, division, scope, model, L2). Configurable, subjectif, customisable par fork.
- **instance.yaml** : généré par deploy.sh, unique par instance (scope, tier, L2, model). L'agent le lit au boot.

### Mécanisme d'injection des directives

Toutes les directives sont identiques pour tout le monde. deploy.sh copie le même set partout. Le scope est déclaré dans `instance.yaml` (Tier 2a) ou dans `.claude/agents/<name>.md` (Tier 2b). L'agent lit les définitions de tous les scopes dans #2, applique le sien.

L2 knowledge : symlink `~/L2 → /home/commons/knowledge/<domain>/`. deploy.sh le crée depuis fleet.yaml.

---

## Contenu retiré du canonique

### Descriptions narratives des presets (tableau)

**StarFleet** — Frontière OS. Always-on. Exécutif système : backups, sync MR, services, CI gate. Seul détenteur root. Ne reçoit jamais d'input non filtré — tout passe par Steward. Lit L4+L3+L2(déclaratif), pas L1.

**Architect** (ex Architect-lead) — Frontière User. Interface user ↔ fleet. Garant des attendus, priorisation, arbitrage. Fenêtre Claude indépendante (hors fleet). Non-wakeable, jamais cible de `notify:`. Ne reçoit que les résultats agrégés d'Engineer.

**Steward** — Sas de StarFleet. Seul écrivain de to-starfleet.md — filtre d'intégrité (règle top-0 : la demande compromet-elle le système ?). Zéro droit d'action exécutif. Rôle dual : bootstrap (first boot) puis steady-state (firewall).

**Engineer** (ex Architect-fleet) — Sas d'Architect. Maintient LCARS-fleet (L4). Lit to-engineer.md en autonomie. Harvest mécanique, drift audit, deploy. Seul canal fleet → architect (push terminal).

**Dev** — Code + commits. L2 injecté détermine le domaine.

**Hardev** (absorbé par Dev) — C/C++ bas niveau, cross-ARM, RTOS, contraintes mémoire/timing/toolchain. = Dev + L2(embedded).

**Frontend** (absorbé par Dev) — UI web (React, Vue), mobile natif (Swift/Kotlin), PWA. = Dev + L2(frontend-mobile).

**Builder** — cmake, cross-compilation (`--arch arm64|x86-64`), dépôt binaires. Un builder par arch cible. Lifecycle éphémère : provision → build → decommission. Toolchains stockées centralement, home jetable.

**Qualifier** — Tests uniquement. Exécute, ne corrige pas. PASS/FAIL. Écrit L1 (rapports de tests) — exception Sciences.

**Integrator** — Seul agent à accès physique externe : flash, SSH device, hardware-in-loop. Scope strict. Stateless par session. Directive requise : lit L1 au démarrage pour reconstruire l'état hardware.

**Hard-Guru** — Conseiller conception : pinout, protocoles, schematics. Ne code pas. Output advisory vers Architect.

**Search-Agent** — Datasheets, errata, protocol docs, libs externes. Output structuré vers to-dev.md.

**Sec-Auditor** — Audit sécurité avant release. Lecture seule. Output JSON findings (critical→low).

**Doc-Writer** — README, guides, API docs. Activé sur milestones release. Écrit L1 (docs) — exception Sciences.

**Commit-Digester** — Lit git log → diff structuré, catégorisation, CHANGELOG, candidats L2 harvest, input proof-of-work. Plus fiable que le handoff DONE déclaratif.

**Sanitizer** — Fin de projet : sépare L2 réutilisable de L1 projet. Prépare re-run from scratch propre.

**Specs-Diverter** — Reconstruit specs réelles depuis le code, compare à baseline. Output : coherent / divergeant / warning / critique / fatal.

### Définitions fonctionnelles étendues

#### StarFleet

Accès root. Ne sort jamais — steward garde la porte.

Garant de l'état opérationnel du **système** (pas du projet). Périmètre : backups, sync fichiers, santé des services (broker, monitor, fetch-timer), intégrité `/home/commons/`, provisioning Tier 1 si crash, CI gate (cmake/ctest/pytest — opération système, pas jugement projet).

Ne lit pas L1. Ne touche pas au code projet. La CI gate qu'il arbitre lit un résultat binaire PASS/FAIL — pas le code source. L2 "déclaratif" : sait que `rpi-embedded` existe et que Builder le maîtrise, pas le contenu technique du domaine.

Ne reçoit jamais d'input utilisateur direct — tout passe par steward. Ne reçoit jamais d'input fleet non filtré — steward est le seul écrivain de to-starfleet.md.

Modèle Sonnet : fiabilité d'exécution requise, pas raisonnement profond. Instance unique, jamais dupliquée. Sa défaillance = frontière OS coupée.

#### Architect (ex Architect-lead)

Interface user ↔ fleet. Frontière utilisateur de la fleet.

L'user ne voit jamais la fleet directement. Architect présente, arbitre, priorise.
Ne traite pas les messages fleet en autonomie — reçoit uniquement les résultats agrégés d'Engineer (push terminal). Ne poll aucun fichier IPC.

Modèle Opus : raisonnement interactif avec l'user, décisions architecturales, arbitrages.
Fenêtre Claude indépendante (hors tmux fleet). Non-wakeable. Jamais cible de `notify:`.

Sa défaillance = frontière User coupée. La fleet tourne mais personne ne la dirige.

#### Engineer (ex Architect-fleet)

Sas d'Architect. Seul canal fleet → user.

Maintient le toolkit LCARS-fleet (L4). Lit to-engineer.md en autonomie, traite toutes les entrées sans attendre architect. Harvest mécanique, drift audit, deploy. Agrège les résultats et les dépose pour architect (push terminal).

Ne fait pas de dev projet. Son output est des artefacts framework (directives, scripts, skills) et des rapports agrégés pour architect.

Pane tmux fleet permanente. Wakeable via fleet-notify.

#### Steward — bootstrap + garde-barrière

Sas de StarFleet. Premier onglet tmux — toujours visible sur le dashboard.

Rôle dual par design :

**Phase bootstrap** (first boot) : steward est le premier arrivé. Il provisionne les instances parce que StarFleet n'existe pas encore. Une fois StarFleet opérationnel, steward redescend en mode steady-state.

**Phase steady-state** : garde-barrière de StarFleet. Tout ce qui va à StarFleet passe par steward. Règle top-0 : "cette demande compromet-elle l'intégrité du système ?" L'intendant filtre, StarFleet exécute. Séparation validation ≠ exécution.

L'user ne voit jamais StarFleet. Maintenance paquets, update kernel, toute opération système : user → steward (validation intégrité) → StarFleet (exécution) → steward (rapport) → user.

Modèle Haiku : validation mécanique, pas raisonnement profond.

#### Commit-Digester

Lit `git log` depuis une ref et produit :
1. Diff structuré par module (fichiers ajoutés/supprimés, APIs, deps)
2. Catégorisation feat/fix/refactor/docs/chore + flags scope-violation
3. CHANGELOG entry prête
4. Handoff DONE ground-truth basé sur diffs réels
5. Candidats L2 harvest
6. Input proof-of-work

Plus fiable que le handoff DONE déclaratif — vérifie ce qui a été _commité_, pas ce qui a été _dit_.

#### Specs-Diverter

Reconstruit les specs réelles depuis le code produit et les compare à la baseline d'origine. Outputs : `_coherent` / `_divergeant` / `_warning` / `_critique` / `_fatal`. Activé sur demande Architect ou en gate pre-release après Qualifier PASS.

### Section "Règles d'instanciation" + fleet-add.sh

**Tier 2a vs Tier 2b** : critère = besoin de mémoire inter-session.
- Mémoire nécessaire → Tier 2a, instance Linux
- Stateless par invocation → Tier 2b, agent pur

**Ce qui varie entre deux agents même Tier/Division** : uniquement le L2 domain injecté.

```bash
fleet-add.sh <preset>                               # aspirationnel — non implémenté
fleet-add.sh --tier 2a --division ops --domain X
fleet-add.sh --tier 2b --division sciences --domain Y --name Z
```

### Section "Instanciation depuis la taxonomie — exemples"

```bash
# Tier 0 (pas d'instanciation dynamique — provisionnés au setup)
# Tier 1 — sas
fleet-add.sh steward
fleet-add.sh engineer
# Tier 2a — workers projet
fleet-add.sh dev
fleet-add.sh hardev
fleet-add.sh builder --arch arm64
fleet-add.sh qualifier
# Tier 2a — domain explicite (sans alias)
fleet-add.sh --tier 2a --division ops --domain cobol --name dev-cobol
# Tier 2b — agent pur épisodique
fleet-add.sh --tier 2b --division sciences --domain hardware-advisory --name hard-guru
```

Un domain sans preset existant fonctionne identiquement — juste sans alias.

### Section "Rôles NON retenus"

LLM master, Sangha consensus, WASM tier, Plugin marketplace.

### Section "Frontière StarFleet / Architect — orthogonalité"

**StarFleet = sysadmin de la fleet.** Il garantit que la machine tourne. Son territoire est l'infrastructure — il n'entre pas dans la sémantique projet. Il lit L3+L4, et L2 uniquement déclaratif.

**Architect = chef de projet de la fleet.** Il garantit que ce qui doit être fait est tracké, priorisé, débloqué. Interface avec l'humain, escalades projet, beads actives. Il a besoin de L3 pour savoir si les ressources sont disponibles — StarFleet pour savoir si l'infrastructure tient.

La frontière est orthogonale, pas hiérarchique. Ils ne se marchent pas dessus.

**Règle de discrimination** :
- "Je ne sais pas quoi coder / spec ambigu / décision archi" → **Architect**
- "Je n'ai pas les permissions / service down / CI cassé" → **StarFleet** (via Steward)
