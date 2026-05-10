# Guides de référence — LCARS Fleet

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : index
**Référencé par** : session-startup.sh

Détail commandes : `<script> --help`. Les guides couvrent le pourquoi, le quand, et les invariants de travail. Ils ne remplacent pas les man-pages runtime.

---

## Doc opératoire

| Guide | Description |
|---|---|
| [Quick Start projet](#24) | Du zéro au premier projet livré. |
| [Guide utilisateur](#26) | Pilotage quotidien avec architect. |
| [Guide avancé](#27) | Rapports lourds, profils, hooks, skills, knowledge. |
| [Créer un projet](#21) | /new-project, /adopt-project, lien L2. |
| [Docker quickstart](#22) | Déploiement Docker et limites vs WSL natif. |
| [ONBOARDING](ONBOARDING.md) | Exploitation courte : démarrer, observer, intervenir. |
| [Troubleshooting](#19) | Reprise incident et arbres de décision. |

## Doc mainteneur / forkeur

| Guide | Description |
|---|---|
| [Architecture LCARS](#01) | Handoff STATE/ACTIONS/DONE, orchestrator, provisioning, design principles |
| [Hiérarchie du savoir](#02) | Fleet / Métier / Projet, flux, classification, escalade ascendante |
| [canon/](canon/) | Base canonique extensive : principes, frontières, conventions, vérité système |
| [LCARS-on-LCARS](#10) | Dev du framework par lui-même. Isolation L1/L4, procédure promotion |
| [Topologie IPC](#16) | Spool, dispatch hybride, routage, cycle de vie messages |
| [Work lifecycle](#17) | Plans, backlog, scratchpad. Pipeline + matrice agent×commande |
| [Runtime catalog](#18) | Hooks, skills, subagents — catalogue du runtime réel |
| [Provisioning](#23) | Profils fleet, deploy.sh, chaîne install, backup & restore |
| [Protocole cheatsheet](#09) | Résumé user du protocole actif : mots-clés, modificateurs, closing gate |
| [Usage fleet](#03) | Drift, resets, failure modes, TUI/Web split |

## Travailler sur LCARS

| Guide | Description |
|---|---|
| [LCARS-on-LCARS](#10) | Pourquoi la récursivité tient. Isolation L1/L4, procédure promotion |
| [Working on LCARS](#20) | Modifier la boîte elle-même sans bruteforce ni directives masquées |
| [Release process](#25) | Freeze → beta → RC → release. Gates, outils, rollback |
| [Sécurité et robustesse](#06) | Modèle de menace, patterns défensifs, décisions acceptées |
| [Token optimization](#07) | Techniques, arbitrages et coût de contexte |

## Qualité et qualification

| Guide | Description |
|---|---|
| [Procédure qualifier](#05) | Segmentation tests, escalade, checklist, artefacts déclencheurs |
| [Bug journal](#11) | Bugs résolus avec cause racine et fix |
| [Starfleet Protocols](#12) | IDIC, Holodeck, TPD, Shakedown |
| [Hello World test](#13) | Cycle engineer→dev→qualifier. Validation protocole IPC |
| [Qualification protocol](qualification/plans/qualification-protocol.md) | Cadre général de qualification projet |
| [v6 qualification plan](qualification/plans/v6-qualification-plan.md) | Plan détaillé de qualification LCARS |
| [FMEA synthesis](qualification/fmea/FMEA-fleet-synthesis.md) | Synthèse des modes de défaillance agents + runtime |

## Recherche et historique

| Guide | Description |
|---|---|
| [Captain_log](#6_diary/Captain_log.md) | Journal de conception complet. Pièce historique majeure du projet |
| [Captain_log-abstract](#6_diary/Captain_log-abstract.md) | Version courte du journal de conception |
| [Analyse CLAUDE.md IQ](#15) | Analyse externe IQ Project, delta LCARS |
| [design-history/](design-history/) | Couche gelée de preuve, de genèse et d'archives de conception |
| [archive/](archive/) | Audits externes, échanges, matières non canoniques |

---

**Man-pages** : scripts et commandes user-facing via `--help`. La doc n'a pas vocation à dupliquer le détail d'interface déjà porté par le runtime.

**Lecture agents** : pas de doc opératoire dédiée. Si un agent a besoin d'un mode d'emploi pour l'usage normal, l'information doit vivre dans le runtime ou les directives. Les docs de cadrage servent seulement quand on lui demande explicitement de travailler sur LCARS lui-même.

**Supprimés** : #04 (script archivé), #08 (absorbé #16), #14 (stub).
