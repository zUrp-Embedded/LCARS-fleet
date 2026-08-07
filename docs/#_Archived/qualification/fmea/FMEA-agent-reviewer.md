# FMEA — Agent reviewer (Tier 2, scope analysis)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/reviewer.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker éphémère |
| Scope | analysis (L1 R, output structuré uniquement) |
| Stateless | true (headless) |
| Interlocuteur | engineer (dispatch) |
| Privilèges | lecture seule, pas de write sauf output structuré |
| SPOF | non — mais dernier filet avant merge |

**Particularité critique** : reviewer est la dernière gate avant merge. Si reviewer
et qualifier ratent tous les deux le même défaut, il passe en production. Le reviewer
ne produit PAS de code correctif — il identifie seulement. C'est une séparation
de responsabilité intentionnelle (celui qui corrige ne review pas son propre fix).

---

## Table FMEA

### Qualité de la review

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| RV-01 | Review | Reviewer rate un bug que qualifier a aussi raté | Bug en production. Double gate franchie. | 9 | 3 | 8 | 216 | Indépendance reviewer/qualifier (agents différents, sessions différentes). Mais même modèle, mêmes biais potentiels. | D=8 : si les deux gates ratent, personne ne détecte. Risque fondamental de la revue par agents du même modèle. Mitigation : modèle différent pour reviewer (ex: Sonnet vs Opus). |
| RV-02 | Review | Reviewer produit une review superficielle (résumé du code au lieu d'analyse critique) | Fausse assurance qualité. Le rapport dit "PASS" sans analyse de fond. | 6 | 4 | 6 | 144 | Template de rapport structuré. Directive "analyse structurée : correctness, sécurité, performance, patterns, dette". | D=6 : un rapport structuré peut être rempli superficiellement. Détectable si engineer lit le rapport attentivement. |
| RV-03 | Review | Reviewer identifie un problème mais le sous-estime (classé mineur alors que critique) | Problème traité comme backlog au lieu de bloquant. Bug en production. | 7 | 3 | 7 | 147 | Scoring x/10 en closing gate. Mais le score dépend du jugement de l'agent. | D=7 : une sous-estimation est difficile à détecter sans revue de la review elle-même. |
| RV-04 | Context | Reviewer headless sans contexte métier (pas de REQ, pas de specs) | Review purement syntaxique, rate les bugs logiques et métier. | 7 | 5 | 7 | 245 | fleet-dispatch.sh injecte le contexte. L2 knowledge. | D=7 : même problème que QA-05 pour qualifier. Sans specs, le reviewer ne peut vérifier que la forme, pas le fond. |

### Scope et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| RV-05 | INTERDIT coder | Reviewer produit du code correctif dans son rapport | Code non tracké (dans un rapport .md), potentiellement copié-collé par dev sans review. Court-circuit du cycle. | 5 | 3 | 4 | 60 | Directive "INTERDIT produire du code correctif. Le reviewer identifie, il ne corrige pas." | D=4 : visible à la lecture du rapport. Si dev copie-colle, le code n'est quand même pas review (il vient du reviewer, pas du dev). |
| RV-06 | Conflit d'intérêt | Reviewer review du code qu'il a indirectement influencé (via un plan qu'il a reviewé avant) | Biais de confirmation. Moins critique sur le code car il a déjà "validé" l'approche. | 4 | 3 | 8 | 96 | Stateless (pas de mémoire inter-sessions). Chaque dispatch est une session fraîche. | Le stateless protège partiellement. Mais si le même prompt/contexte est injecté, le biais peut se reconstruire. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 2 | RV-04 (245), RV-01 (216) |
| RPN 100-199 | 2 | RV-03 (147), RV-02 (144) |
| RPN < 100 | 2 | RV-06, RV-05 |

**Risque dominant** : même structure que qualifier — la qualité de la review elle-même.
Le RPN le plus élevé (RV-04, 245) est le manque de contexte en headless. Sans REQ ni
specs, la review est cosmétique.

**Actions prioritaires** :
1. RV-04 (RPN 245) : REQ + specs injectées dans le contexte dispatch
2. RV-01 (RPN 216) : diversifier les modèles (Sonnet pour qualifier, Opus pour reviewer)
3. RV-02 (RPN 144) : checklist de review structurée obligatoire dans le template
