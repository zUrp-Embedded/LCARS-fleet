# FMEA — Agent compliance (Tier 2, scope analysis, LCARS)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/compliance.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker LCARS |
| Scope | analysis (L4 R, rapports structurés) |
| Stateless | true (headless) |
| Interlocuteur | starfleet (dispatch) |
| Privilèges | lecture L4 uniquement, écriture rapports |
| Cible | LCARS — cohérence directives, conformité cross-agent |

**Particularité** : compliance est le reviewer de LCARS. Il évalue la cohérence des
directives, la complétude des règles, les contradictions inter-fichiers. C'est
l'auditeur interne — il ne teste pas (c'est quality), il analyse.

---

## Table FMEA

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| CP-01 | Cohérence | Compliance rate une contradiction entre deux directives | Agents reçoivent des instructions contradictoires. Comportement imprévisible (le modèle fait la moyenne des deux directives). | 8 | 3 | 7 | 168 | Axiome "non-recouvrement" : chaque fait en UN seul endroit. Compliance vérifie. | D=7 : les contradictions subtiles (même concept, mots différents, nuance opposée) sont les plus difficiles à détecter. C'est exactement le risque que compliance est censé couvrir — mais c'est aussi un LLM. |
| CP-02 | Complétude | Compliance ne détecte pas un comportement non couvert par les directives | Zone grise exploitable. Agent infère au lieu d'escalader (GO-0 violation). | 7 | 4 | 8 | 224 | GO-0 impose l'escalade. Mais compliance ne peut vérifier l'exhaustivité que sur les comportements qu'il imagine. | D=8 : un comportement non couvert est par définition absent — il faut imaginer le scénario pour le trouver. La FMEA elle-même est un outil pour ça. |
| CP-03 | Analyse | Compliance produit un rapport qui identifie des "risques" théoriques sans impact réel | Bruit. Starfleet perd du temps à traiter des findings non pertinents. | 3 | 5 | 3 | 45 | Scoring obligatoire dans les rapports. Starfleet filtre. | Faible risque. Le coût est du temps de tri, pas de la qualité. |
| CP-04 | INTERDIT modifier | Compliance modifie une directive au lieu de la signaler | Modification non autorisée de L4. Directive changée sans review. | 8 | 2 | 3 | 48 | Directive "évaluer et rapporter, jamais corriger". Scope write = rapports uniquement. Permissions Linux. | Bien couvert. Triple protection. |
| CP-05 | Context | Compliance headless sans vision de l'historique des décisions | Signale comme "incohérence" un choix délibéré documenté dans le scratchpad mais pas dans les directives. | 4 | 4 | 6 | 96 | Scratchpad accessible. Mais headless = contexte limité. | Mitigation partielle : injecter le scratchpad dans le contexte dispatch si pertinent. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 1 | CP-02 (224) |
| RPN 100-199 | 1 | CP-01 (168) |
| RPN < 100 | 3 | CP-05, CP-04, CP-03 |

**Actions prioritaires** :
1. CP-02 (RPN 224) : FMEA systématique comme input pour compliance (cette initiative)
2. CP-01 (RPN 168) : outil automatique de détection de duplication sémantique dans les directives
