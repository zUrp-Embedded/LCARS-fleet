# FMEA — Agent quality (Tier 2, scope test, LCARS)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/quality.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker LCARS |
| Scope | test (L4 R, rapports structurés PASS/FAIL) |
| Stateless | true (headless) |
| Interlocuteur | starfleet (dispatch) |
| Privilèges | lecture L4 uniquement, écriture rapports |
| Cible | LCARS (directives, scripts, skills, hooks) — PAS code projet |

**Particularité** : quality est le qualifier de LCARS lui-même. Il vérifie que les
directives, scripts fleet et hooks sont conformes. C'est le "test du framework" —
si quality est défaillant, les défauts dans LCARS passent et impactent tous les agents.

---

## Table FMEA

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| QL-01 | Conformité | Quality déclare PASS sur une directive incohérente | Directive déployée à tous les agents. Comportement non-déterministe fleet-wide. | 9 | 3 | 7 | 189 | Compliance (agent séparé) fait une deuxième passe. Starfleet review. | Même risque que QA-01 mais amplifié : un défaut LCARS impacte 11 agents, pas 1. |
| QL-02 | Scope L4 | Quality évalue des scripts fleet sans comprendre le contexte cross-agent | Findings incorrects : signale un "bug" qui est un comportement voulu, ou rate un bug cross-agent. | 6 | 4 | 7 | 168 | L3 en lecture (topologie, registre). Mais headless = contexte limité au prompt. | D=7 : les interactions cross-agent sont les plus difficiles à évaluer en isolation. |
| QL-03 | INTERDIT corriger | Quality corrige un défaut au lieu de le signaler | Correction non reviewée, pas dans le bon cycle (starfleet est propriétaire LCARS). | 7 | 2 | 3 | 42 | Directive "signaler les non-conformités, ne pas les corriger". Scope write = rapports uniquement. | Bien couvert. Même structure que QA-06. |
| QL-04 | Hallucination | Quality "vérifie" des fichiers sans les lire réellement | Rapport basé sur le souvenir du modèle, pas sur le contenu actuel. Faux PASS. | 8 | 3 | 5 | 120 | Le modèle DOIT utiliser Read tool avant de statuer. Vérifiable dans les logs. | Candidat : même hook que QA-04 (vérifier que Read a été appelé sur chaque fichier évalué). |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 0 | |
| RPN 100-199 | 3 | QL-01 (189), QL-02 (168), QL-04 (120) |
| RPN < 100 | 1 | QL-03 (42) |

**Actions prioritaires** :
1. QL-01 (RPN 189) : double gate quality + compliance systématique sur LCARS
2. QL-04 (RPN 120) : hook post vérifiant Read avant verdict
