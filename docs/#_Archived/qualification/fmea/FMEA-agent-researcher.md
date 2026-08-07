# FMEA — Agent researcher (Tier 2, scope research)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/researcher.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 2 — worker projet |
| Scope | research (lecture codebase contexte, recherche externe, output structuré) |
| Stateless | true (headless) |
| Interlocuteur | engineer (dispatch) |
| Privilèges | aucune écriture fichier, aucune commande, lecture seule |

**Particularité** : researcher est l'agent le plus contraint du système. Aucune écriture
fichier, aucune exécution de commande. Son seul output est du texte structuré. Le risque
est purement informationnel.

---

## Table FMEA

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| RS-01 | Recherche | Researcher rapporte des informations incorrectes (source obsolète, mauvaise interprétation) | Décision archi basée sur de fausses prémisses. | 6 | 4 | 6 | 144 | Sources citées dans le rapport (vérifiables). Directive deepsearch : multi-sources. | D=6 : une info fausse avec source citée est vérifiable mais rarement vérifiée en pratique. |
| RS-02 | Recherche | Researcher ne trouve pas l'info pertinente (recherche trop étroite) | Décision prise sans l'info qui aurait changé la direction. | 5 | 4 | 8 | 160 | Dispatch avec contexte large. Mais la qualité de la recherche dépend du prompt. | D=8 : on ne sait pas ce qu'on n'a pas trouvé. Mitigation : re-dispatch avec un angle différent si le résultat semble pauvre. |
| RS-03 | Scope | Researcher exécute des commandes (interdit) | Exécution non autorisée. | 7 | 1 | 2 | 14 | Scope research = aucune commande. Pas de Bash dans allowed-tools. | Très bien couvert. Le modèle n'a pas les outils. |
| RS-04 | Scope | Researcher écrit des fichiers (interdit) | Écriture non autorisée. | 7 | 1 | 2 | 14 | Scope research = aucune écriture. Pas de Write/Edit dans allowed-tools. | Très bien couvert. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 0 | |
| RPN 100-199 | 2 | RS-02 (160), RS-01 (144) |
| RPN < 100 | 2 | RS-03, RS-04 |

**Risque dominant** : qualité de l'information, pas sécurité. L'agent le moins dangereux
du système. Ses modes de défaillance sont des biais informationnels, pas des actions
destructives.
