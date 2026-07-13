# FMEA — Agent dev (Tier 2, scope code)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/dev.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker projet |
| Scope | code (L1 R+W, commits, tests unitaires, documentation code) |
| Stateless | false (session interactive + headless) |
| Interlocuteur | engineer (dispatch), starfleet (escalade système) |
| Privilèges | pas de sudo, write L1 projet uniquement |
| SPOF | non — remplaçable par un autre dev |

**Particularité critique** : dev est le seul agent qui écrit du code applicatif et
qui commit. C'est la dernière ligne avant le code versionné. Ses modes de défaillance
se retrouvent directement dans le livrable.

---

## Table FMEA

### Production de code

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| DV-01 | Code | Dev écrit du code avec un bug logique | Bug dans le livrable. Découvert en test (qualifier) ou en review (reviewer), ou pas du tout. | 7 | 6 | 4 | 168 | Qualifier (tests). Reviewer (analyse). Pipeline qualifier→reviewer avant merge. | D=4 si le pipeline QA existe. D=8 sans QA. Le risque résiduel est le bug subtil que ni les tests ni la review ne détectent. |
| DV-02 | Code | Dev écrit du code qui fonctionne mais qui est fragile (pas de gestion d'erreur, paths hardcodés, etc.) | Dette technique. Fonctionne aujourd'hui, casse demain sur un autre environnement ou un edge case. | 5 | 7 | 6 | 210 | Directives "set -euo pipefail", "pas de chemins hardcodés", "exit codes explicites". Shellcheck en CI. | L'agent peut produire du code conforme aux directives sur la forme mais fragile sur le fond (logique incorrecte protégée par set -e). |
| DV-03 | Code | Dev écrit du code qui introduit une faille de sécurité (injection, permissions laxistes) | Vulnérabilité dans le livrable. | 9 | 3 | 5 | 135 | Directive "sécurité OWASP top 10". check-secrets.sh. Reviewer devrait détecter. | D=5 : une injection subtile peut passer la review. Candidat : analyse statique de sécurité dans CI (selon le langage). |
| DV-04 | Commit | Dev commit des fichiers qui ne devraient pas être versionnés (.env, credentials, binaires) | Fuite de secrets (si push). Bloat du repo (binaires). | 9 | 2 | 2 | 36 | check-secrets.sh (hook). .gitignore. pre-commit hook. | Bien couvert mécaniquement. Triple protection. |

### Scope et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| DV-05 | INTERDIT LCARS | Dev modifie des fichiers LCARS (directives, scripts fleet, config) | Modification non autorisée de la source de vérité L4. Incohérence fleet si propagée. | 8 | 2 | 2 | 32 | runtime-guard.sh bloque écriture sur /local/LCARS/ et ~/.claude/. Permissions Linux (dev n'a pas write sur LCARS/). | Bien couvert. Double protection hook + permissions. |
| DV-06 | Escalade | Dev ne signale pas une règle manquante (directive "DOIT signaler via fleet-send") | Convention implicite persiste. Pas de règle écrite. Non-déterminisme entre sessions. | 5 | 6 | 8 | 240 | Directive explicite "retenir des règles INTERDIT — signaler". | D=8 : indétectable mécaniquement. L'agent "apprend" en session et applique sans signaler. C'est le GO-0 violation classique au niveau Tier 2. Risque fondamental LLM. |
| DV-07 | Cross-pushing | Dev push sur LCARS main (interdit) | Commit non audité sur LCARS. Contourne starfleet + QA. | 9 | 1 | 2 | 18 | Directive "cross-pushing INTERDIT". Permissions git (dev n'a pas push sur LCARS main). Branch protection GitHub. | Triple protection. Quasi impossible. |

### Headless et dispatch

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| DV-08 | Headless | Dev headless atteint max_turns sans finir | Travail incomplet. Fichiers partiellement écrits. | 5 | 4 | 4 | 80 | fleet-dispatch.sh traite INCOMPLETE. Atomic write protège les fichiers. Après 2 interruptions : FAIL + escalade. | Acceptable. Le mécanisme INCOMPLETE est explicite. |
| DV-09 | Headless hooks | Hooks PreToolUse bloquent le dev headless (settings.local.json) | fleet-dispatch.sh --headless échoue. Tâche non exécutée. | 5 | 5 | 3 | 75 | Connu (action dans handoff starfleet). Fix : settings headless dédié ou adaptation des hooks. | D=3 : erreur immédiatement visible (exit non-zero). En attente de fix. |
| DV-10 | Context | Dev headless sans contexte suffisant (pas de L2, pas de plan) | Code produit sans connaissance du domaine ou des contraintes. Résultat médiocre. | 6 | 4 | 7 | 168 | fleet-dispatch.sh peut injecter du contexte via stdin. L2 symlink dans le home. | D=7 : le résultat "semble correct" mais manque de nuance métier. Détectable uniquement par review. |

### Comportement agent

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| DV-11 | GO-0 | Dev infère un choix d'architecture (structure de fichiers, pattern, lib) sans règle | Code structuré selon les préférences du modèle, pas selon les conventions projet. Incohérence avec le reste du codebase. | 6 | 6 | 7 | 252 | GO-0 escalade. Directives projet dans CLAUDE.md. L2 knowledge. | D=7 : le code fonctionne mais ne suit pas les conventions. Détectable en review. Risque élevé car dev prend beaucoup de micro-décisions d'architecture. |
| DV-12 | GO-3 | Dev remarque un bug existant mais ne le signale pas (continue sa tâche) | Bug connu non tracké. | 5 | 5 | 8 | 200 | GO-3 "fix maintenant OU backlog". Scratchpad. | D=8 : si l'agent ne verbalise pas l'observation, personne ne sait. Même risque que SF-08. |
| DV-13 | Over-engineering | Dev ajoute des features non demandées, refactor du code adjacent, "améliore" au-delà du scope | Scope creep. Code modifié inutilement, risque de régression sur du code qui marchait. | 4 | 5 | 4 | 80 | Directives "pas de features non demandées", "pas de refactoring non demandé", "pas de commentaires sur du code non modifié". | D=4 : visible en diff/review. Les directives sont très explicites sur ce point. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 3 | DV-11 (252), DV-06 (240), DV-02 (210), DV-12 (200) |
| RPN 100-199 | 3 | DV-01 (168), DV-10 (168), DV-03 (135) |
| RPN < 100 | 7 | DV-08, DV-13, DV-09, EN-05, DV-04, DV-05, DV-07 |

**Risque dominant** : qualité du code produit et respect des conventions non écrites.
Dev est le seul agent qui produit le livrable final — chaque micro-décision d'architecture
est un GO-0 potentiel. Les mitigations mécaniques couvrent les actions (write, push) mais
pas le raisonnement (choix de pattern, conventions implicites).

**Actions prioritaires** :
1. DV-06 (RPN 240) : hook post-session qui vérifie si des conventions ont été appliquées sans être dans CLAUDE.md
2. DV-11 (RPN 252) : enrichir L2 et CLAUDE.md projet pour réduire les zones d'inférence
3. DV-02 (RPN 210) : shellcheck + checklist de robustesse dans le pipeline QA
