# Guide d'usage — LCARS Fleet

**Date** : 2026-03-08
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

> Guide de cadrage sur le comportement réel des agents : drift, resets, failure modes et limites structurelles des directives.

---

## Ce que l'opérateur manipule

Les directives LCARS ne sont pas des "instructions" au sens classique — elles façonnent la distribution de probabilité du LLM. C'est du **context-layer training** : un niveau de contrôle entre le fine-tuning (permanent, coûteux) et le prompt engineering (éphémère).

Deux conséquences opérationnelles :

1. **Non-overlap critique** — deux règles similaires ne se renforcent pas, elles produisent une moyenne imprévisible. Une règle, un endroit.
2. **Les directives ne suffisent pas** — sous pression, un agent peut rationaliser à travers une règle explicite. C'est pourquoi les murs OS (permissions, isolation) existent.

### Deux classes de compliance

| Classe | Fiabilité | Exemples | Si ça échoue |
|---|---|---|---|
| **Structurelle** (scope, format, escalade) | >90% | Refus d'implémenter, routage IPC | Visible immédiatement dans l'output |
| **Exécution** (checklists, procédures multi-step) | Probabiliste | GO-7 headers, séquence /handoff | Dropout d'attention — l'agent acknowledge puis skip |

Implication : ce qui DOIT être exécuté devrait être un script déterministe, pas une checklist en langage naturel.

---

## Directives fantômes — pourquoi le drift arrive

Le contexte implicite (environnement, historique conversation, pression sociale) agit comme des **directives fantômes** — non versionnées, non auditables, qui participent au même blending probabiliste que les directives écrites.

Exemple : un agent sans role binding a inféré son rôle depuis le contexte (terminal interactif, user présent) au lieu d'escalader. L'environnement a outweighté la règle écrite.

C'est pourquoi le drift est silencieux : l'agent produit des outputs plausibles avec un modèle mental décalé.

---

## Modes de défaillance — 5 catégories

| # | Catégorie | Fix |
|---|---|---|
| 1 | Règle absente (decision space ouvert) | Ajouter la directive |
| 2 | Critère subjectif ("si ambiguïté ≥ 6/10") | Remplacer par critère binaire |
| 3 | Dispatch ambigu (case coverage incomplet) | Ajouter default case |
| 4 | Boundary sémantique non défini | Énumérer inclusion/exclusion |
| 5 | **Rationalisation à travers une règle explicite** | **Murs OS + escalade collaborative** |

Cat. 1-4 : fermer le decision space. Cat. 5 : aucune reformulation de règle ne suffit — seul le hard containment bloque.

---

## Détection de dérive

### Signaux faibles (l'accumulation est l'alerte)

**Comportementaux** : dérive de registre, verbosité accrue, reformulation du déjà-dit, confusion de scope, références déformées.

**Structurels** : compacts multiples, session trop longue, DONE vagues.

### Règles

| Type d'agent | Règle |
|---|---|
| Mécanique (qualifier, reviewer, headless) | Fermer et relancer à chaque invoke |
| Long (dev, architect) | Compact aux breakpoints sémantiques. Restart après 2-3 compacts. |

---

## `/clear` vs `/compact`

| | `/clear` | `/compact` |
|---|---|---|
| Historique | Supprimé | Résumé |
| CLAUDE.md, memory, skills | Persistants | Persistants |
| Cache résiduel (bug) | Fuite possible | n/a |
| Continuité | Coupée | Préservée |

**Reset garanti** : `/handoff` → quitter Claude Code → relancer. Seul le redémarrage du process purge le cache serveur.

**Heuristique** : < 50% du contexte pertinent → `/clear`. Sinon → `/compact`.

---

## Répartition TUI / Claude Web

**TUI** : tout ce qui touche le filesystem. **Web** : recherche documentaire, questions sans dépendance FS. Pattern : Web produit → paste MD → TUI intègre.
