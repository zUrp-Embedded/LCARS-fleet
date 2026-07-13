# Glossaire LCARS

**Date** : 2026-03-07
**Dernière révision** : 2026-03-11
**Statut** : référence active
**Référencé par** : .claude/CLAUDE.md

---

## Principe fondateur — rien d'implicite

Tout comportement attendu d'un agent doit être explicitement documenté dans une directive.
Tout comportement attendu d'un user doit être explicitement documenté dans le protocole.

Un comportement non documenté n'existe pas. Il n'est pas "évident", "logique" ou "de bon sens" — il est **absent**. L'agent n'infère pas le comportement souhaité. L'user ne présuppose pas que l'agent comprend l'implicite.

Cette règle s'applique sans exception à :
- Toute directive `CLAUDE.md`
- Tout protocole utilisateur
- Tout handoff, canal, queue
- Tout script fleet

Un document qui dit "en général" ou "dans la plupart des cas" est un document à corriger.

---

## Frontier

**Définition** : zone opérationnelle où un agent fleet travaille au-delà de son périmètre nominal — un projet externe, LCARS lui-même, un domaine non défini, une question sans précédent dans les directives.

**Principe fondamental** : les agents ne sont pas *dans* la fleet comme dans un conteneur. Ils *sont* la fleet. Leurs directives sont constitutives, pas situationnelles. Un agent fleet opérant à la Frontier porte ses règles avec lui par construction (L4 priority override, toujours).

**Corollaire** : les règles fleet s'appliquent à LCARS lui-même. Pas par récursivité accidentelle — par constitution de l'agent.

**Risque** : la Frontier est le point d'entrée de la dérive. Trois vecteurs :
1. **Sur-adaptation** — l'agent adapte ses règles au territoire au lieu de les y appliquer
2. **Silence** — l'agent opère sans signal, sans escalade, dans une zone non couverte
3. **Hybridation** — l'agent mélange les règles du périmètre nominal et celles du territoire

**Garde-fou** : quand les règles existantes sont insuffisantes à la Frontier, c'est un signal d'escalade L4 — pas d'improvisation locale.

---

## Entités et rôles

**fleet** — ensemble d'instances + infrastructure + IPC + framework, instancié **par projet**. Pas system-wide. La fleet LCARS est la fleet éphémère qui patche le framework lui-même.

**instance** — la ressource complète : User Linux + session tmux + directives `.claude/` déployées + mémoire. Ce qui entoure un agent. Unité atomique de provisioning et de décommissionnement.

**agent** — le LLM seul. Siège dans une instance permanente (Tier 1) ou spawné on-demand (Tier 2). On ne contrôle pas l'agent directement — on contrôle son contexte via l'instance et ses directives.

**worker** — instance contenant un agent, role-driven. Rôle qui nécessite une instance dédiée (Dev, Qualifier, Builder...). Par opposition aux rôles de coordination pure.

**Tier 0** — immuable. StarFleet : always-on, seul garant du provisioning Tier 1 en cas de crash.

**Tier 1** — permanent. Contexte long durée, survit aux sessions. Provisionné une fois (`useradd` + deploy directives). Invoqué à l'usage via `wake-instance.sh`. Membres : Architect, Lead, StarFleet.

**Tier 2** — on-demand. Spawné par un agent Tier 1 via `.claude/agents/` pour la durée d'une tâche. Contexte éphémère — stateless entre invocations. Contexte injecté par `fleet-init-project.sh` avant spawn. Peut avoir une instance Linux dédiée ou non — le Tier définit le cycle de vie, pas l'infrastructure.

---

## Infrastructure

**framework** _(aussi nommé "toolkit" dans le code)_ — le repo LCARS. Scripts fleet, directives, skills, hooks, provisioning. Maintenu par Architect.

**`fleet-broker.py`** — service asyncio, socket Unix `/run/fleet/fleet.sock`, protocol JSON lines. IPC principal v2+. Fallback fichier préservé.

**`deploy.sh`** — déploiement des directives (CLAUDE.md, hooks, skills, settings) depuis LCARS vers les homes de toutes les instances actives.

**`fleet.yaml`** — registre de la fleet : rôles, tiers, modèles, sudo rules. Source de vérité pour deploy.sh et start.sh. Non restrictif : la fleet peut invoquer des workers dynamiques non pré-déclarés. Déclare aussi les cibles hardware autorisées pour Integrator (scope sécurité).

---

## IPC et communication

**handoff** — fichier markdown de persistance d'état d'une instance (`<instance>-handoff.md`). Lu au démarrage, mis à jour en session. Contient STATE + ACTIONS + DONE. Stocké en EN (token-efficient).

**canal directionnel** — fichier de communication mono-directionnel ciblé (`to-dev.md`, `to-qualifier.md`, `to-engineer.md`...). Adressé à un rôle owner qui agit dessus. Multi-writer possible sauf `to-starfleet.md` (steward only — bulkhead pattern).

**queue** — log de travail inter-instances, voué à se purger dans le temps. Chaque queue définit ses writers, readers et resolver dans son header — le header prime. Distinct du canal directionnel : pas de destinataire unique, nature cumulative.

**bug-queue** — log de bugs (`/home/commons/bug-queue.md`). Writers : toute instance. Resolver : dev uniquement.

**test-queue** — log de tests (`/home/commons/test-queue.md`). Owner/writer : qualifier. StarFleet peut lire.

**qualifier-notes** — notes opérationnelles de l'instance qualifier (`/home/commons/qualifier-notes.md`). Directives actives + résultats diffusés aux autres instances.

**steward-notes-index** — index machine-readable de `steward-notes.md`. Parsé par `steward-notes-check.sh` au démarrage StarFleet pour nettoyage automatique des entrées stale.

**wake** — réveil d'une instance dormante via `fleet-notify.sh`. Déclenché quand `notify: <instance>` détecté dans un STATE. Message envoyé dans la session tmux existante.

**fleet-wake-wt** — mécanisme de convocation StarFleet. Ouvre une nouvelle fenêtre terminal dédiée via interop OS. Détails d'implémentation dans `fleet-notify.sh`.

**steward-notes** *(IPC)* — mécanisme d'append : toute instance peut ajouter une entrée clé adressée à une ou plusieurs cibles. Lu au démarrage par les instances concernées. Entrées stale purgées automatiquement via `steward-notes-index`.

**escalade** — transmission d'un blocage vers le niveau hiérarchique supérieur immédiat. Toujours avec contexte explicite. Jamais silencieuse. Un seul échelon à la fois.

**Topologie IPC** (émetteurs, lecteurs, wake matrix, règles spéciales par agent) : définie dans `[TODO: registre IPC]`. Le glossaire définit les concepts, le registre définit le câblage.

---

## Cycle de vie et STATE

**STATE** — bloc machine-readable de 8 champs dans chaque handoff. Parsé par fleet-hub.py pour le dashboard. Champs : `date`, `ref`, `action`, `status`, `blocker`, `waiting`, `notify`, `session`. Fichiers sans bloc `## STATE` (ex : `steward-notes.md`) ne sont pas parsés — leurs champs éventuels sont informels.

Règle de traduction : lire EN → traduire FR → présenter FR → écrire le bloc EN **original** (inchangé). Le FR est une vue lecture seule, jamais source d'écriture.

**date** — tag de présence. Format strict : `YYYY-MM-DD HH:MM`. Sans heure : stale permanent (strptime échoue → stale forcé).

**action** — nature de la tâche en cours. Valeurs canoniques : `startup`, `thinking`, `code`, `build`, `deploy`, `validate`, `audit`, `idle`, `shutdown`, `handoff`, `crashed`, `forced shutdown`.

**idle** *(action)* — instance disponible, rien à faire, prête à recevoir une tâche.

**handoff** *(action)* — action STATE finale d'une session terminée proprement via `/handoff`. À distinguer du fichier handoff.

**status** — état de la tâche en cours. Valeurs canoniques : `done`, `in-progress`, `open`, `unknown` (fallback fleet-hub si absent).

**waiting** — description de ce qu'on attend. Non-vide quand `notify` est actif — apparaît dans le message de wake.

**notify** — nom d'instance ou `none`. Déclenche un wake quand non-nul. Dédupliqué par fleet-monitor.

**session** — identifiant JSONL de session (UUID). Utilisé par fleet-hub pour le token tracking. `none` si pas de session active.

_Champs dérivés (calculés par fleet-hub, non écrits dans le handoff) :_

**stale** — STATE dont le champ `date` dépasse 30 min sans mise à jour. fleet-hub grise la carte dashboard.

**pending_actions** — liste des tâches `- [ ]` non complétées dans la section ACTIONS du handoff.

**fleet-monitor** — démon de surveillance fleet (distinct de fleet-hub). Surveille les handoffs, déduplique les wakes `notify`, détecte les instances stale.

**session-hygiene** — checklist de fin de session dans `/handoff` : git status clean, beads IN_PROGRESS documentées, bug-journal à jour, budget context noté.

---

## Savoir et mémoire

_Ordre de priorité : L4 écrase L3 écrase L2 écrase L1 écrase L0. En cas de conflit, la couche haute prend le dessus._

_Note : l'ordre Tier (0=StarFleet, 2=agent) et l'ordre L (0=session, 4=Framework global) sont intentionnellement inversés — cohérents chacun dans leur espace de nommage._

**L4 — Framework global** — savoir universel, immuable. Vit dans le repo LCARS (`directives/`). Maintenu par Architect. Toute modification L4 requiert validation User. Highest tier : prend le dessus sur tout.

**L3 — Fleet** — savoir opérationnel de la fleet déployée : registre instances, `steward-notes.md` (directives cross-session actives), topologie IPC, état du deploy, capacités actives. C'est le niveau que StarFleet habite — il connaît L3 et L2, mais pas L1 (le code projet). Plus volatile que L2.

**L2 — Métier** — savoir permanent par domaine technique (`rpi-embedded`, `arduino-fw`...). Croît à chaque projet. Vit dans le repo LCARS (`knowledge/<domain>/`). Versionné, partagé entre instances via le repo. Injecté au démarrage d'une nouvelle fleet projet.

**L1 — Projet** — savoir spécifique à un projet unique. Archivé à la fin du Dev. Jamais supprimé.

**L0 — Session** — contexte éphémère, durée de vie = une session Claude Code. Priorité la plus basse.

**steward-notes** *(Savoir)* — savoir prescriptif cross-session, composant de L3. Règles opérationnelles durables que toute instance doit appliquer. Alimenté par append multi-source, lu au démarrage par les instances ciblées.

**domaine** — catégorie de projet technique (`rpi-embedded`, `arduino-fw`, `linux-daemon`...). Regroupe patterns, toolchain, bugs récurrents accumulés. Racine du gain exponentiel inter-projets.

---

## Qualité et CI

**bead** — unité de travail NDI. Format markdown dans les handoffs avec `Status` et `Criteria` explicites. Permet à un agent de reprendre après crash sans re-briefing.

**NDI** — Nondeterministic Idempotence. Propriété d'une tâche : peut être interrompue et reprise sans effet de bord, même si le résultat n'est pas déterministe.

**CI gate** — hook pre-push déterministe. Le push est bloqué si `cmake --build && ctest` ne passe pas. Arbitre objectif, non substituable par Qualifier.

**Commit-Digester** — définition fonctionnelle complète dans `#2_roles-agents.md`. En résumé : lit `git log` → diff structuré + catégorisation commits + CHANGELOG + candidats L2 harvest.

---

## Terminologie — règles de nommage

**HR** *(Human-Readable)* — fichier rédigé en langage naturel (français par défaut). Lisible par l'humain pour audit et compréhension, lisible par l'agent pour application. Style : phrases complètes, structure documentaire.

**MR** *(Machine-Readable)* — fichier rédigé en anglais compact, optimisé pour injection dans le contexte agent. Token-efficient. Style : clé-valeur, listes, format condensé.

Chaque fichier est l'un ou l'autre. Le suffixe (`-HR`, `_MR`, `_EN`) l'indique quand le nom seul est ambigu. Pas de relation de dérivation obligatoire — un fichier HR peut être injecté directement. Le style est un indicateur, pas une hiérarchie.

**Convention de nommage des fichiers** :

| Suffixe | Signification |
|---|---|
| _(aucun)_ | Langage natif du contexte (FR par défaut) |
| `_EN` | Set de directives en anglais — même contenu, autre langue |
| `_MR` | Machine-readable anglais compact |

Règle : on marque l'exception, pas la règle. Un fichier sans suffixe est la source naturelle.

**Starfleet terminology** — termes utilisés dans le système : StarFleet, Architect, Lead, Qualifier, Hardev, Hard-Guru, Integrator, Stardate, Relay. Les rôles Tier 2 (Dev, Builder, Hardev, etc.) n'ont pas d'équivalent Starfleet formel — intentionnel.

**Exceptions immuables** — les termes techniques universels ne sont jamais remplacés par des équivalents Starfleet :
1. `build` — terme technique. Reste `build`, `cmake --build`, `builder`.
2. Tout terme de l'écosystème standard (git, cmake, pytest, tmux, bash, etc.) reste inchangé.

**GO-7 / Ship's Manifest — en-tête obligatoire** :

Tout fichier versionné supportant des commentaires ou métadonnées doit porter un en-tête déclaratif. Pour `.md`, immédiatement après `# Titre` :

```
**Date** : YYYY-MM-DD
**Dernière révision** : YYYY-MM-DD
**Statut** : <one-liner>
**Référencé par** : <fichiers ou —>
```

Exceptions : formats sans commentaires natifs (`json`, binaires), fichiers IPC opérationnels (`*-handoff.md`, `to-*.md`, `*-notes.md`, `*-queue.md`).
Règle : ajouter l'en-tête avant toute autre modification si absent.

**Règle stricte — aucun nom propre d'utilisateur dans les directives** :

Les directives, guides et protocoles utilisent toujours `user` (générique). Jamais un pseudo ou username réel.
- Identité réelle → `fleet.yaml` (config) et handoffs (état de session) uniquement
- Chemins système (`/home/<username>/`) → variable fleet (`$USER_HOME`) ou documentation technique explicitement marquée

---

## Starfleet Principles

Quatre principes opérationnels nommés. Chaque nom est un alias sur un concept ou protocole existant — la métaphore est prédictive et mémorable, pas cosmétique.

**IDIC** *(Infinite Diversity in Infinite Combinations)* — tout composant fleet doit fonctionner sans hypothèse mono-environnement. **IDIC targets** = ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif. Critère de revue : "est-ce IDIC-compliant ?" Mode de défaillance : path hardcodé, arch implicite, username en dur.

**Holodeck Containment** — chaque instance opère dans un périmètre write borné et explicite. Containment failure = écriture hors périmètre = incident. **Corollaire récursif (GO-0)** : appliqué à la fleet elle-même — la fleet a exactement deux sorties (frontière OS : StarFleet, frontière User : Architect-lead). Chaque sortie a un sas exclusif Tier 1. Structure : Tier 0 = frontières, Tier 1 = sas (bulkheads), Tier 2 = exécution interne.

**First Contact Protocol** — protocole d'onboarding projet→fleet. Bidirectionnel : le projet doit être prêt à recevoir LCARS, la fleet doit être prêt à opérer le projet. Sans First Contact complet : comportement non-défini.

**Temporal Prime Directive (TPD)** — le commit graph est immuable après publication. Violations : `push --force` sur branche partagée, `commit --amend` sur commit poussé, `rebase` sur branche fetchée. Paradoxe temporel = état divergent entre agents. Exception : `--force-with-lease` sur branche feature personnelle non-partagée avec mention handoff.

---

## Notes — companion narratif

# Notes — #1_glossaire-systeme.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#1_glossaire-systeme.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-07 | Création | Glossaire initial v1.1 |
| 2026-03-08 | Révision | Sections validées, Frontier ajouté |
| 2026-03-10 | Audit v2 | NDI dupliqué, path `commons/handoff/` obsolète, marqueurs VALIDÉ figent des erreurs |
| 2026-03-10 | Nettoyage v2 | Retrait Vision LCARS, narratif Frontier, section Rôles formels, aspirationnels, matrices IPC → futur registre, callouts GFM, doublons L0-L4, Idées v4. Ajout définitions HR/MR. Convention nommage réécrite. Holodeck généralisé. Paths corrigés |

---

## Contenu retiré du canonique

### Vision LCARS (en-tête)

> Framework pour les créateurs de PCB qui en ont marre de galérer à faire du code pour que leur truc clignotte. L'User apporte le hard (schematics, pinouts, décisions électroniques). La fleet apporte le soft associé (drivers, firmware, OS, tests, doc).

### Frontier — métaphores narratives

**Double référence** :
- _ST Final Frontier_ : la frontière de l'espace connu. L'Enterprise ne s'arrête pas à la frontière — elle l'emporte avec elle. Les règles de la Federation voyagent avec l'équipage, elles ne restent pas à la base.
- _US West Frontier_ : la limite de colonisation en mouvement. Le shérif n'a pas de périmètre fixe — il couvre là où il est. Les colons ne suspendent pas leur civilisation en franchissant la ligne ; **ils sont la civilisation** qui fait avancer la ligne.

### Section "Rôles formels" (renvoi vers #2)

_Extrait dans le document dédié : [`roles-agents.md`](#1_roles-agents.md)_
_Tableau complet des agents (Tier × Division × Modèle × Activation) et définitions fonctionnelles détaillées dans ce fichier._

### Infrastructure — scripts aspirationnels

**`provision-user.sh`** _(nom illustratif — script à écrire)_ — création complète d'une instance : `useradd` + configuration `.claude/` + deploy des directives.

**`decommission.sh`** _(nom illustratif — script à écrire)_ — suppression totale : shutdown propre + archive home + `userdel -r`. Rien d'implicite ne subsiste. Règle archive par rôle : builder = OBLIGATOIRE (heures de compilation non reproductibles rapidement), tous les autres = optionnelle.

### Matrices IPC (émetteurs/lecteurs + wake)

Déplacées en attendant création du registre IPC structuré (`[TODO: registre IPC]`).

**Matrice canaux** :

| Canal | Écrit par | Lu par |
|---|---|---|
| `to-steward.md` | Dev, Qualifier, Builder, Architect-lead | Steward |
| `to-starfleet.md` | Steward **uniquement** (bulkhead) | StarFleet |
| `to-engineer.md` | Dev, Qualifier, Steward, StarFleet | Architect-fleet (traite tout) |
| `to-dev.md` | StarFleet, Qualifier, Builder, Architect-fleet | Dev |
| `to-qualifier.md` | StarFleet, Dev, Builder, Architect-fleet | Qualifier |
| `to-build.md` | Dev, StarFleet | Builder |

**Matrice wake** :

| Instance | Wakeable par | Mécanisme |
|---|---|---|
| Steward | StarFleet, Architect-fleet | `fleet-notify.sh steward` → tmux |
| Architect-fleet | StarFleet, Dev, Qualifier, Builder, Steward | `fleet-notify.sh engineer` → tmux |
| Architect-lead | **Personne** — interactif uniquement | ouverture manuelle session |
| StarFleet | — (always-on, Tier 0) | — |
| Dev | StarFleet, Architect-fleet | `fleet-notify.sh dev` → tmux |
| Qualifier | StarFleet, Architect-fleet | `fleet-notify.sh qualifier` → tmux |
| Builder | StarFleet, Architect-fleet | `fleet-notify.sh builder` → tmux |

**Règles IPC spéciales** :
- **Hard-Guru** : pas de canal IPC propre — output markdown posé directement dans la session Lead.
- **Search-Agent** : stateless one-shot — spawné par Dev/Hardev, output dans `to-dev.md`, termine.
- **Architect-lead** : ne reçoit jamais de `notify:` dans un STATE. Non-wakeable par design.
- **steward-notes** : append-only. Jamais de suppression de ligne existante par un agent.

### Cycle de vie — détails retirés

_Stockage : EN sur disque (machine-readable, token-efficient). Présentation : langue user_vars (FR par défaut) via fleet-hub output terminal._

**user_vars** — `[réservé — non défini en v3]` Variables de configuration par User/fleet : langue de présentation, seuils, préférences. Sera un fichier YAML dédié. Non stockées dans les handoffs.

### Savoir — éléments aspirationnels

**fleet-init-project** — script de démarrage projet : injecte L4 + L3 + L2 Métier + L1 Projet vierge dans le contexte des agents.

**fleet-harvest-project** — script de distillation fin de projet : extrait le savoir généralisable de L1 → L2 Métier. L1 reste archivé avec le projet.

**métier-plugin** — L2 packagé comme unité autonome et importable : fichier de règles (machine-readable EN) + docs narratives (FR) + structure du domaine. Validé à l'import par un agent dédié. Plugins locaux/privés uniquement — pas de marketplace.

### Qualité — éléments aspirationnels

**proof-of-work** — bundle CI PASS + qualifier ACK + build OK en un rapport JSON parseable par StarFleet. Verdict binaire GO/NO-GO.

### Scope — doublon L0-L4 retiré

Définitions L0-L4 identiques à § Savoir et mémoire. Section Scope ne garde qu'un renvoi.

### Starfleet Principles — références historiques

Réf : `Captain_log.md` Phase 11.
Réf complète : `#4_guides_FR/#12_starfleet-protocols.md`

### Convention de nommage — ancien modèle (pré-v2)

*Pattern docs* — source native user, dérivés pour agents :
| Fichier | Rôle |
|---|---|
| `file.md` | Source de vérité — langue native user. |
| `file_EN.md` | Traduction EN — dérivée de la source. |
| `file_MR.md` | Machine-reading EN — injection agent. Dérivée de la source. |

*Pattern directives* — MR injecté, HR dérivé pour audit :
| Fichier | Rôle |
|---|---|
| `file.md` | MR — injecté dans les agents, source de vérité opérationnelle. |
| `file-HR.md` | HR — pendant humain pour audit, dérivé du MR. Jamais injecté. |

> Modèle remplacé en v2 : plus de relation de dérivation. Chaque fichier est HR ou MR par style.

### Idées v4 — non retenues pour v3

**mobile-contribution** — permettre à l'user de contribuer depuis un mobile sans accès terminal. Piste : réagir à des edits GitHub. Spec initiale (`web-bridge`) rejetée — trop complexe, contre-principe.

### Section "Scope et sécurité" (supprimée)

**scope** — périmètre d'action autorisé pour une instance. Défini dans `home_claude_CLAUDE.md`. Violations détectables via scope enforcement hooks. Integrator est le seul agent autorisé à interagir avec le monde physique (flash, SSH device).

**L0–L4** — niveaux de directive. En cas de conflit : L4 gagne toujours.

> Contenu déplacé vers `#2_roles-agents.md` (scope par rôle) et § Savoir et mémoire (L0-L4).

### Sector (supprimé)

**Sector** — `[réservé — non défini en v3]` Terme Starfleet réservé. Abandonné — jamais défini.

### Correspondances et ton Starfleet (cosmétique dashboard)

**Correspondances** : date/timestamp → Stardate, canal IPC → Relay/Comm Channel, session → Mission. Usage dashboard/UI uniquement.

**Ton Starfleet** : `"Confirmed." "Acknowledged." "On screen." "Standby." "Negative." "Relay received."` — habillage tmux uniquement. Interdit dans les logs fonctionnels.

### Section "Protocole utilisateur — mots-clés" (supprimée)

Contenu déplacé dans `#4-1_protocole-user.md` (seul fichier faisant foi pour le protocole user).

**Distinction clé** : `évalue` = contenu/sémantique d'un artefact. `qualifie` = forme/qualité d'un document. `avis` = sur une décision/option. `analyse` = exploration large, lit les sources par défaut.

### Callouts GFM retirés

Tous les blocs `> [!IMPORTANT]`, `> [!WARNING]`, `> [!TIP]`, `> [!CAUTION]`, `> [!NOTE] VALIDÉ` ont été retirés — dans les directives canoniques, tout est important par défaut.
