# FMEA Ring 0 — CORE

**Date** : 2026-03-27
**Dernière révision** : 2026-03-27
**Statut** : initial — post-qualification Ring 0
**Référencé par** : v6-rings-and-interfaces.md
**Dérivé de** : N² matrix, tests Ring 0, session 2026-03-26

---

## Périmètre

Ring 0 = fleet-env.sh, fleet-build-yaml.sh, fleet-update.sh.
39 scripts dépendent de Ring 0 (source fleet-env.sh). Défaillance = fleet down.

## Scoring

- **S** (Sévérité) : 1-10. Impact si le mode se produit.
- **O** (Occurrence) : 1-10. Probabilité d'occurrence.
- **D** (Détection) : 1-10. Capacité à détecter AVANT impact. 1=détecté, 10=invisible.
- **RPN** = S × O × D. Seuil action : RPN ≥ 100 ou S ≥ 9.

---

## Modes de défaillance — Ring 0

### R0-01 : fleet-env.sh exporte une valeur fausse (dégradation silencieuse)

| Facteur | Score | Justification |
|---|---|---|
| S | **10** | Tout Ring 1-4 utilise des paths/variables faux. Messages envoyés au mauvais endroit, deploy dans le mauvais répertoire. Cascade systémique. |
| O | 3 | Les valeurs viennent de fleet.yaml (statique) ou de fallbacks hardcodés. Faux = fleet.yaml corrompu ou cache stale. |
| D | 4 | Le test `--json` + mock coherence détecte les clés manquantes. Mais une valeur PRÉSENTE MAIS FAUSSE (path qui existe mais n'est pas le bon) n'est pas détectée. |
| **RPN** | **120** | |

**Mitigation existante** : cache invalidation par fleet-update.sh, mock coherence tests.
**Mitigation manquante** : test d'intégration qui vérifie que les paths exportés EXISTENT sur le filesystem. Ajouté dans test_fleet_env.bats (test "lcars_root path exists", skip en CI).
**Résiduel** : si fleet.yaml pointe vers un path valide mais mauvais (/home au lieu de /home/handoffs), aucun test ne le détecte. Risque accepté — fleet.yaml est édité manuellement par l'user.

### R0-02 : fleet-env.sh cache stale après deploy

| Facteur | Score | Justification |
|---|---|---|
| S | 8 | Agents utilisent l'ancienne config après un fleet-update. Paths obsolètes, rôles manquants. |
| O | 2 | fleet-update.sh invalide explicitement le cache (rm cache + unset guard). |
| D | 3 | Test existant vérifie que le cache est créé. Pas de test vérifiant l'invalidation post-deploy. |
| **RPN** | **48** | |

**Mitigation existante** : invalidation explicite dans fleet-update.sh (commit 0bf0d18).
**Mitigation manquante** : test d'intégration fleet-update → fleet-env (hors scope unit tests).

### R0-03 : fleet-build-yaml.sh génère un fleet.yaml invalide

| Facteur | Score | Justification |
|---|---|---|
| S | **9** | fleet.yaml invalide = fleet-env.sh fallbacks, tous les agents en mode dégradé. |
| O | 2 | Validation post-génération (rôles uniques, clés requises, champs instances). |
| D | 2 | 3 tests dédiés (BLD-10/11/12) + test YAML valid (FMEA SF-04). |
| **RPN** | **36** | |

**Mitigation existante** : validation post-génération supprime le fichier si invalide.

### R0-04 : fleet-build-yaml.sh extends chain circulaire

| Facteur | Score | Justification |
|---|---|---|
| S | 7 | Boucle infinie → script ne termine pas → fleet.yaml pas généré. |
| O | 1 | Détecté par guard MAX_DEPTH=10. Test BLD-05 vérifie. |
| D | 1 | Le script exit 1 avec message explicite. |
| **RPN** | **7** | |

### R0-05 : fleet-update.sh pull échoue (réseau, auth, conflit)

| Facteur | Score | Justification |
|---|---|---|
| S | 5 | Pas de mise à jour, mais le système existant continue de tourner. |
| O | 3 | Réseau WSL occasionnellement instable. Auth PAT peut expirer. |
| D | 1 | git pull --ff-only échoue bruyamment. Le script s'arrête. |
| **RPN** | **15** | |

### R0-06 : fleet-update.sh deploy.sh absent ou cassé

| Facteur | Score | Justification |
|---|---|---|
| S | 8 | Pull réussit mais deploy ne s'exécute pas. Runtime désynchronisé du repo. |
| O | 1 | deploy.sh est dans le repo, versionné. Absent = clone corrompu. |
| D | 2 | Le script vérifie `-x "$DEPLOY"` et exit 1 si absent. |
| **RPN** | **16** | |

### R0-07 : yq absent ou version incompatible

| Facteur | Score | Justification |
|---|---|---|
| S | **10** | fleet-env.sh et fleet-build-yaml.sh ne fonctionnent pas. Fleet down. |
| O | 1 | Installé par provision-packages.sh. Absent = install ratée. |
| D | 1 | Guard-at-entry dans fleet-env.sh (test ENV-01). |
| **RPN** | **10** | |

### R0-08 : --json self-source récursion infinie

| Facteur | Score | Justification |
|---|---|---|
| S | 3 | Segfault du shell. N'affecte que le mode --json, pas le source normal. |
| O | 1 | Guard _FLEET_ENV_JSON empêche la récursion (fix cette session). |
| D | 1 | Le segfault est immédiat et visible. |
| **RPN** | **3** | |

---

## Résumé

| Mode | RPN | S≥9 | Action |
|---|---|---|---|
| R0-01 valeur fausse silencieuse | **120** | oui | Test intégration paths (Phase 3) |
| R0-02 cache stale | 48 | non | Test intégration update→env (Phase 3) |
| R0-03 fleet.yaml invalide | 36 | oui | Couvert par BLD-10/11/12 |
| R0-04 extends circulaire | 7 | non | Couvert par BLD-05 |
| R0-05 pull échoue | 15 | non | Comportement nominal (fail-fast) |
| R0-06 deploy absent | 16 | non | Guard existant |
| R0-07 yq absent | 10 | oui | Guard + test ENV-01 |
| R0-08 --json récursion | 3 | non | Guard _FLEET_ENV_JSON |

**RPN max : 120** (R0-01). Mitigation complète requiert tests d'intégration (Phase 3).
**Modes S≥9 : 3** (R0-01, R0-03, R0-07). Tous ont des tests ou mitigations.
