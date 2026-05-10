# FMEA — Agent documenter (Tier 2, scope documentation)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/documenter.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker projet |
| Scope | documentation (L1 R, W docs uniquement) |
| Stateless | true (headless) |
| Interlocuteur | engineer (dispatch) |
| Privilèges | lecture code, écriture docs seulement |

**Particularité** : documenter est à faible risque technique (pas de code, pas de push)
mais à risque informatif : une doc incorrecte est pire que pas de doc — elle donne de
fausses assurances au lecteur.

---

## Table FMEA

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| DC-01 | Documentation | Documenter écrit de la doc qui contredit le code | Utilisateur externe suit la doc, obtient un comportement différent. Perte de confiance. | 7 | 4 | 6 | 168 | Directive "lire les fichiers existants AVANT de produire". Read tool obligatoire. | D=6 : détecter une divergence doc/code demande de lire les deux. Reviewer peut vérifier. |
| DC-02 | Documentation | Documenter hallucine des fonctionnalités inexistantes | Doc décrit des features qui n'existent pas. Utilisateur perdu. | 8 | 3 | 5 | 120 | Read tool + directives. Le modèle a tendance à "compléter" ce qu'il attend. | D=5 : détectable si quelqu'un essaie de suivre la doc. Candidat : test de la doc (exécuter les exemples). |
| DC-03 | Scope | Documenter modifie du code source au lieu de la doc | Code modifié sans cycle dev→QA→review. | 7 | 2 | 3 | 42 | runtime-guard (scope W docs uniquement). Permissions Linux. | Bien couvert mécaniquement. |
| DC-04 | Langue | Documenter mélange FR/EN dans la doc | Incohérence linguistique. | 2 | 4 | 3 | 24 | Convention "plans, docs = français. Code, identifiants = anglais." | Faible risque. Cosmétique. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 0 | |
| RPN 100-199 | 2 | DC-01 (168), DC-02 (120) |
| RPN < 100 | 2 | DC-03, DC-04 |

**Actions prioritaires** :
1. DC-01 (RPN 168) : reviewer systématique sur la doc produite
2. DC-02 (RPN 120) : tests de documentation (exécuter les exemples comme des tests)
