# FMEA — Synthèse fleet (tous agents)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe consolidée
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : FMEA-agent-*.md (11 fichiers)

---

## Vue d'ensemble

11 agents analysés. 78 modes de défaillance identifiés au total.

### Répartition RPN par agent

| Agent | Tier | RPN >= 200 | RPN 100-199 | RPN < 100 | Modes total | RPN max |
|---|---|---|---|---|---|---|
| **starfleet** | T0 | 2 | 5 | 7 | 14 | 256 |
| **architect** | T0 | 1 | 4 | 5 | 10 | 210 |
| **engineer** | T1 | 1 | 4 | 6 | 11 | 210 |
| **dev** | T2 | 4 | 3 | 6 | 13 | 252 |
| **qualifier** | T2 | 2 | 1 | 4 | 7 (+1 shared) | 280 |
| **reviewer** | T2 | 2 | 2 | 2 | 6 | 245 |
| **quality** | T2 | 0 | 3 | 1 | 4 | 189 |
| **compliance** | T2 | 1 | 1 | 3 | 5 | 224 |
| **documenter** | T2 | 0 | 2 | 2 | 4 | 168 |
| **researcher** | T2 | 0 | 2 | 2 | 4 | 160 |
| **consultant** | T2 | 0 | 2 | 2 | 4 | 120 |

---

## Top 15 RPN — modes les plus critiques de la fleet

| Rank | RPN | Ref | Agent | Mode de défaillance | Catégorie |
|---|---|---|---|---|---|
| 1 | **360** | — | tous | GO-0 escalade non déclenchée (risk fondamental LLM) | Comportement |
| 2 | **294** | SF-06 | starfleet | GO-0 inférence infra sans règle (avec sudo) | Comportement |
| 3 | **294** | — | tous | Perte contexte compact (qualité handoff circulaire) | Continuité |
| 4 | **280** | QA-03 | qualifier | Teste happy path seulement, rate les edge cases | QA |
| 5 | **256** | SF-06 | starfleet | GO-0 inférence sans règle (boundary-os) | Comportement |
| 6 | **252** | DV-11 | dev | Infère un choix d'architecture sans convention | Comportement |
| 7 | **245** | RV-04 | reviewer | Review sans contexte métier (headless) | QA |
| 8 | **240** | DV-06 | dev | Ne signale pas une règle manquante | Comportement |
| 9 | **224** | QA-01 | qualifier | Faux PASS (rate un bug) | QA |
| 10 | **224** | CP-02 | compliance | Rate un comportement non couvert par directives | QA |
| 11 | **216** | RV-01 | reviewer | Rate un bug que qualifier a aussi raté (double gate fail) | QA |
| 12 | **210** | AR-02 | architect | Valide un plan sans identifier une dépendance critique | Décision |
| 13 | **210** | EN-03 | engineer | Perd le suivi de tâches parallèles | Coordination |
| 14 | **210** | DV-02 | dev | Code fragile (fonctionne mais pas robuste) | Code |
| 15 | **210** | QA-05 | qualifier | Qualifier headless sans contexte suffisant | QA |

---

## Analyse par catégorie de risque

### Catégorie 1 — Comportement LLM (irréductible)

**Modes** : GO-0 inférence, GO-0 escalade non déclenchée, GO-1 convention non persistée,
GO-3 bug mentionné pas tracké, perte contexte compact.

**Caractéristique** : ces modes sont intrinsèques au fonctionnement d'un LLM. Le modèle
ne peut pas introspecter pour savoir quand il improvise. Aucune mitigation mécanique
complète possible.

**Mitigations partielles** :
- Hooks sur actions (runtime-guard, agent-guard, check-secrets) → couvrent les ACTIONS
- Directives claires et explicites → réduisent la SURFACE d'inférence
- Reviewer/qualifier/compliance → détection POST-HOC
- FMEA + REQ → réduisent les zones non couvertes par les directives

**Résidu** : risque accepté. Réduit par l'empilement de mitigations, jamais éliminé.
C'est le "bruit de fond" d'un système agent-centric.

### Catégorie 2 — Qualité de la QA (amplificateur)

**Modes** : faux PASS, edge cases non testés, review sans contexte, double gate fail.

**Caractéristique** : si la QA est défaillante, les bugs de catégorie 1 passent en
production. La QA est le dernier filet — ses modes de défaillance sont des amplificateurs.

**Mitigations** :
- REQ explicites avec cas de test attendus (pas juste "teste ce script")
- Contexte riche injecté dans les dispatches headless
- Diversification des modèles (Sonnet/Opus) pour réduire les biais communs
- Hook post-session vérifiant que les outils Read/Bash ont été utilisés

**Actions concrètes à implémenter** :
1. Template de dispatch qualifier avec REQ + edge cases listés
2. Template de dispatch reviewer avec specs + contexte métier
3. Hook PostToolUse sur qualifier/reviewer vérifiant l'usage de Read et Bash

### Catégorie 3 — Coordination et suivi (engineer)

**Modes** : suivi perdu, dispatch multi-scope, écriture concurrente, escalade manquée.

**Mitigations** :
- Lock file par repo dans fleet-dispatch.sh
- Validation mono-scope dans fleet-dispatch.sh
- Dashboard tâches en vol dans on-prompt engineer

### Catégorie 4 — Décisions et arbitrage (architect)

**Modes** : reformulation incorrecte, plan sans dépendance critique, WIP limit dépassé.

**Mitigations** :
- Template plan structuré avec checklist dépendances
- Review technique engineer avant dispatch
- Enforcement WIP limit dans fleet-plan.sh

### Catégorie 5 — Privilèges et propagation (starfleet)

**Modes** : commande sudo destructive, push avec regression, deploy partiel, secret en clair.

**Mitigations** :
- pre-push hook bloquant push direct sur main
- Lock file pendant git pull
- Validation sémantique fleet.yaml
- check-secrets.sh (déjà opérationnel)

---

## Actions prioritaires consolidées

### Hooks à créer ou modifier

| Action | Cible | RPN couvert | Effort |
|---|---|---|---|
| pre-push hook : bloquer push direct sur main | starfleet | SF-05 (144) | Faible |
| post-hook qualifier : vérifier Read+Bash avant PASS | qualifier, quality | QA-04 (162), QL-04 (120) | Moyen |
| scan secrets sur outbox | consultant | CT-02 (105) | Faible |
| lock file par repo dans fleet-dispatch | engineer | EN-04 (120) | Moyen |

### Directives à renforcer

| Action | Cible | RPN couvert |
|---|---|---|
| REQ explicites dans les dispatches QA | qualifier, reviewer | QA-03 (280), QA-05 (210), RV-04 (245) |
| Template plan avec checklist dépendances | architect | AR-02 (210) |
| Validation mono-scope dans fleet-dispatch | engineer | EN-02 (144) |

### Infra à ajouter

| Action | Cible | RPN couvert |
|---|---|---|
| Lock file pendant fleet-update git pull | starfleet | SF-14 (147) |
| Validation sémantique fleet.yaml | starfleet | SF-04 (90) |
| WIP limit enforcement dans fleet-plan.sh | architect | AR-03 (125) |
| Dashboard tâches en vol (on-prompt engineer) | engineer | EN-03 (210) |

---

## Risques acceptés (irréductibles)

| Ref | Mode | RPN | Justification |
|---|---|---|---|
| ALL | GO-0 escalade non déclenchée | 360 | Risque fondamental LLM. Mitigé par empilement : hooks + directives + QA. Irréductible par design. |
| ALL | Perte contexte compact | 294 | Mitigé par handoff + harvest + scratchpad. Qualité dépend de l'agent (circulaire). Accepté. |
| DV-11 | Dev infère architecture | 252 | Réduit par L2 + CLAUDE.md + conventions. Résidu : micro-décisions non couvertes. Acceptable car détectable en review. |
| DV-06 | Dev ne signale pas règle manquante | 240 | GO-0 appliqué au Tier 2. Même risque fondamental que GO-0 global. Accepté avec mitigation review. |

---

## Métriques

- **78 modes de défaillance** identifiés sur 11 agents
- **13 modes RPN >= 200** (correction obligatoire ou risque accepté documenté)
- **29 modes RPN 100-199** (correction recommandée)
- **36 modes RPN < 100** (acceptable)
- **4 risques acceptés** documentés (irréductibles LLM)
- **4 hooks** à créer/modifier
- **3 directives** à renforcer
- **4 infra** à ajouter
