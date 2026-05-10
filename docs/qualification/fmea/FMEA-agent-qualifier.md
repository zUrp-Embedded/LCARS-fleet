# FMEA — Agent qualifier (Tier 2, scope test)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/qualifier.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker éphémère |
| Scope | test (L1 R, W rapports uniquement) |
| Stateless | true (headless) |
| Interlocuteur | engineer (dispatch) |
| Privilèges | pas de sudo, lecture code, écriture rapports uniquement |
| SPOF | non — remplaçable, mais SANS qualifier = PASS silencieux |

**Particularité critique** : qualifier est la gate QA. Si qualifier dit PASS, le code
avance. Si qualifier est défaillant (faux PASS), le bug passe en production. C'est
un rôle où le faux négatif (rater un bug) est plus dangereux que le faux positif
(signaler un non-bug).

---

## Table FMEA

### Qualité de la validation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| QA-01 | Test | Qualifier déclare PASS alors qu'il y a un bug (faux négatif) | Bug passe la gate QA. Découvert plus tard (reviewer, production, user). | 8 | 4 | 7 | 224 | Reviewer indépendant après qualifier. Mais si les deux ratent le même bug, il passe. | D=7 : un faux PASS est invisible par définition — on ne sait pas qu'on a raté quelque chose. Risque fondamental de tout processus QA. |
| QA-02 | Test | Qualifier déclare FAIL sur du code correct (faux positif) | Dev retravaille inutilement. Temps perdu. Mais pas de bug en production. | 3 | 4 | 2 | 24 | D=2 : le dev vérifie le finding et conteste si incorrect. Circuit de feedback. | Faible risque. Le coût est du temps, pas de la qualité. |
| QA-03 | Couverture | Qualifier teste le happy path mais pas les edge cases | Bugs dans les chemins d'erreur non détectés. | 7 | 5 | 8 | 280 | Directive "au moins 1 test nominal + 1 test d'erreur". Mais l'exhaustivité des edge cases dépend du contexte fourni au qualifier. | D=8 : on ne sait pas ce qu'on n'a pas testé. Le qualifier headless n'a que le code + le prompt de dispatch pour deviner les edge cases. Candidat : REQ explicites par script avec cas de test attendus. |
| QA-04 | Hallucination | Qualifier "invente" des résultats de test (affirme avoir testé sans exécuter) | Faux PASS basé sur du raisonnement, pas sur une exécution réelle. | 9 | 3 | 6 | 162 | Directive "exécuter les tests existants AVANT de déclarer terminé". Bash tool logs montrent les exécutions réelles. | D=6 : détectable en vérifiant les logs de la session headless. Mais personne ne vérifie systématiquement. Candidat : post-hook qui vérifie que Bash a été appelé avant un verdict PASS. |
| QA-05 | Context | Qualifier headless sans contexte suffisant (pas de specs, pas de REQ) | Tests superficiels, couverture apparente sans profondeur. | 6 | 5 | 7 | 210 | fleet-dispatch.sh injecte le contexte. Mais la qualité du contexte dépend de l'engineer. | D=7 : le rapport PASS "semble correct" mais les tests sont trivaux. Détectable uniquement par review du rapport. |

### Scope et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| QA-06 | INTERDIT modifier | Qualifier modifie le code au lieu de juste le tester | Code modifié sans passer par le cycle dev→qualifier→reviewer. Modification non trackée. | 7 | 2 | 3 | 42 | Directive "INTERDIT modifier du code, commiter". runtime-guard (scope test = W rapports uniquement). | Bien couvert. Scope write limité aux rapports. |
| QA-07 | Rapport | Qualifier écrit un rapport ambigu (ni PASS ni FAIL clair) | Engineer ne sait pas comment router. Bloque le pipeline ou prend une décision arbitraire. | 4 | 3 | 4 | 48 | Directive "rapports structurés PASS/FAIL". Template de rapport. | D=4 : visible à la lecture du rapport. Engineer peut demander clarification. |

### Disponibilité

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| QA-08 | Indisponible | Qualifier headless échoue (max_turns, erreur) | Pas de QA. Directive "validation FAIL par défaut" = code bloqué. | 5 | 3 | 2 | 30 | "Si reviewer indisponible, résultat FAIL" (pas PASS silencieux). Re-dispatch possible. | Bien couvert. FAIL par défaut est la bonne politique. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 2 | QA-03 (280), QA-01 (224), QA-05 (210) |
| RPN 100-199 | 1 | QA-04 (162) |
| RPN < 100 | 4 | QA-07, QA-06, QA-08, QA-02 |

**Risque dominant** : la qualité de la qualification elle-même. Les pires modes sont les
faux négatifs (rater un bug) et l'insuffisance de couverture (tester le happy path
seulement). La mitigation principale est la chaîne qualifier→reviewer (double gate).

**Actions prioritaires** :
1. QA-03 (RPN 280) : REQ explicites avec cas de test attendus, pas juste "teste ce script"
2. QA-01 (RPN 224) : reviewer indépendant systématique après qualifier
3. QA-04 (RPN 162) : post-hook vérifiant que Bash a été appelé avant verdict PASS
