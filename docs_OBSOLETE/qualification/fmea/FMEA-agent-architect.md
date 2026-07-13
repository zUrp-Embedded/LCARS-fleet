# FMEA — Agent architect (Tier 0, boundary-user)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/architect.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 0 — boundary-user |
| Scope | boundary-user (interface user, arbitrage, priorisation, L3 R, L4 R) |
| Stateless | false (session interactive) |
| Interlocuteur | user (direct), engineer (fleet-side) |
| Privilèges | aucun sudo, pas de write L4, pas de write L1 |
| SPOF | oui — si architect tombe, l'user n'a plus d'interface fleet |
| Non-wakeable | oui — aucun agent ne peut wake architect |

**Particularité critique** : architect est le seul canal user→fleet. Il ne code pas,
ne déploie pas, ne push pas. Son risque principal est décisionnel, pas technique.
C'est aussi le seul agent non-wakeable — il ne poll pas d'inbox, ne reçoit pas
de messages IPC en temps réel.

---

## Table FMEA

### Décisions et arbitrage

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| AR-01 | Arbitrage | Architect prend une décision archi sans vérifier les contraintes techniques (L2, code existant) | Décision inapplicable ou incohérente avec le code. Dev bloqué ou produit un résultat bancal. | 7 | 4 | 6 | 168 | Directive "lire avant coder" s'applique aussi à l'archi. Mais architect n'a pas le scope code — il lit les specs, pas le code. | L'architect voit les specs et les plans, pas l'implémentation. Un écart spec/code non documenté produit une décision fausse. Mitigation : engineer vérifie la faisabilité avant dispatch. |
| AR-02 | Arbitrage | Architect valide un plan sans identifier une dépendance critique | Plan lancé, dev avance, bloqué par une dépendance non anticipée. Temps perdu. | 6 | 5 | 7 | 210 | Plan obligatoire (>1 fichier ou >50 lignes). Mais le plan est écrit par architect, pas validé par un tiers technique. | Candidat : review technique par engineer ou consultant avant dispatch. La qualité du plan dépend du contexte disponible à architect. |
| AR-03 | Priorisation | Architect accepte trop de tâches en parallèle | WIP limit dépassé (work/ : 1-2 plans actifs max). Contexte dilué, qualité des décisions dégradée. | 5 | 5 | 5 | 125 | Directive "1-2 plans actifs max (WIP limit)" dans workflow. | Aucun enforcement mécanique du WIP limit. fleet-plan.sh pourrait refuser `start` si doing/ a déjà 2 plans. |

### Interface user ↔ fleet

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| AR-04 | Boundary-user | Architect reformule la demande user de manière incorrecte | Le reste de la fleet travaille sur le mauvais problème. Découvert tard. | 8 | 3 | 8 | 192 | User review (l'user voit le plan avant dispatch). Mais si l'erreur est subtile (nuance mal captée), l'user peut valider un plan incorrect. | D=8 : une reformulation "presque correcte" est la plus dangereuse — elle passe la review user sans lever d'alerte. |
| AR-05 | Boundary-user | Architect bloque une demande user légitime par excès de prudence | Feature non livrée, frustration user, contournement possible (user va directement sur un agent). | 4 | 4 | 3 | 48 | GO-0 : hors scope → escalade. L'architect peut escalader vers l'user avec explication. | D=3 : visible immédiatement (l'user corrige). Faible risque. |
| AR-06 | Non-wakeable | Un résultat urgent attend dans l'outbox mais architect n'a pas de session ouverte | Latence dans la chaîne fleet→user. Résultat livré mais non communiqué. | 4 | 6 | 4 | 96 | ready-room/outbox/ est visible via fleet-live (symlink Windows). L'user peut voir les résultats directement. | L'user doit penser à regarder. Pas de notification push. Candidat : notification OS (toast Windows via WSL) au dépôt outbox. |

### Scope et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| AR-07 | INTERDIT implémenter | Architect produit du code (script, config, fix) au lieu de rester au plan | Court-circuit du cycle architect→engineer→dev. Code non reviewé, pas dans le bon repo, pas dans le bon scope. | 7 | 3 | 4 | 84 | Directive "le travail d'architect s'arrête au plan". runtime-guard.sh bloque les écritures hors périmètre. | Les directives sont claires. runtime-guard couvre les chemins système. Mais architect peut écrire du code dans un plan .md — c'est un code snippet, pas un fichier exécutable. L'effet est limité. |
| AR-08 | Lecture L3/L4 only | Architect modifie un fichier L3 ou L4 (directives, fleet config) | Modification non autorisée de la source de vérité. Incohérence si pas propagée par fleet-update. | 8 | 2 | 3 | 48 | runtime-guard.sh bloque écriture sur /local/LCARS/ et ~/.claude/. Permissions Linux (architect n'a pas write sur LCARS/). | Bien couvert mécaniquement. Double protection : hook + permissions. |

### Continuité

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| AR-09 | Compact/restart | Architect perd le contexte d'une discussion archi complexe avec l'user | Décision archi incomplète ou incohérente. L'user doit ré-expliquer. | 6 | 5 | 5 | 150 | Handoff. Scratchpad pour les convergences. Plans écrits dans work/. | La qualité du handoff dépend de l'agent. Si la discussion était nuancée, le handoff peut sur-simplifier. |
| AR-10 | SPOF | Architect indisponible (pas de session ouverte) | User n'a plus d'interface fleet. Peut aller directement sur starfleet (contournement). | 5 | 5 | 2 | 50 | User a accès à ready-room et fleet-live. Peut déposer dans inbox. Starfleet peut prendre le relais pour les urgences. | D=2 : visible immédiatement. Impact limité si l'user connaît les canaux alternatifs. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 1 | AR-02 (plan sans dépendance critique, 210) |
| RPN 100-199 | 4 | AR-04 (192), AR-01 (168), AR-09 (150), AR-03 (125) |
| RPN < 100 | 5 | AR-06, AR-07, AR-08, AR-05, AR-10 |

**Risque dominant** : les modes décisionnels (mauvais arbitrage, reformulation incorrecte,
plan incomplet). L'architect n'a pas de risque technique fort (pas de sudo, pas de write),
mais son risque est amplificateur — une mauvaise décision se propage à toute la fleet.

**Actions prioritaires** :
1. AR-02 (RPN 210) : review technique par engineer avant dispatch de plan
2. AR-04 (RPN 192) : template plan structuré qui force la reformulation explicite
3. AR-03 (RPN 125) : enforcement WIP limit dans fleet-plan.sh
