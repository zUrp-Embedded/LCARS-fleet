# FMEA — Agent starfleet (Tier 0, boundary-os)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/starfleet.md, topologie.md, session starfleet 2026-03-24

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 0 — boundary-os |
| Scope | boundary-os (sudo, infrastructure, L4 R+W, L3 R+W) |
| Stateless | true (headless) |
| Interlocuteur | architect (indirect), user (jamais direct sur L1) |
| Privilèges | sudo root, propriétaire exclusif LCARS, git push main |
| SPOF | oui — si starfleet tombe, la fleet est aveugle côté OS |

**Particularité critique** : starfleet est l'agent le plus privilégié du système.
Un mode de défaillance starfleet a potentiellement un impact sur TOUTE la fleet.
C'est aussi le seul agent à commiter/pusher sur LCARS main — une erreur est
propagée à tous les agents au prochain fleet-update.

---

## Table FMEA

### Scope et privilèges

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| SF-01 | sudo | Commande destructive (rm -rf, chmod -R 000) sur mauvais chemin | Perte de données système, fleet irrécupérable | 10 | 2 | 3 | 60 | Directives "opérations destructives : lire cible, confirmer existence ailleurs". Pas de hook mécanique sur sudo. | Le modèle peut toujours construire une commande destructive correcte syntaxiquement mais ciblant le mauvais chemin. D=3 car l'erreur est visible immédiatement. |
| SF-02 | git push main | Push d'un commit avec bug/regression sur LCARS main | Bug propagé à tous les agents au prochain fleet-update. Cascade. | 9 | 3 | 4 | 108 | pre-commit-lcars.sh (gate syntaxe + headers). QA qualifier/compliance avant merge. PR obligatoire (/lcars-fix, /lcars-feature). | Le pre-commit ne couvre que la forme (headers, bash -n), pas la logique. Un bug logique passe la gate. |
| SF-03 | git push main | Push d'un fichier contenant des secrets (tokens, clés) | Fuite de secrets sur GitHub. Irréversible (git history). | 10 | 2 | 2 | 40 | check-secrets.sh (hook PreToolUse). .gitignore couvre /home/private/. | Bien couvert mécaniquement. Le hook scanne les patterns de secrets. |
| SF-04 | fleet-update.sh | fleet-update exécuté avec un fleet.yaml corrompu | Déploiement partiel ou incohérent sur tous les agents | 9 | 2 | 5 | 90 | fleet-build-yaml.sh valide la syntaxe. Mais pas de validation sémantique (rôle manquant, scope invalide). | Candidat : ajouter validation sémantique dans fleet-build-yaml.sh. |
| SF-05 | LCARS main | Commit sur main sans passer par /lcars-fix ou /lcars-feature | Contourne la QA, la PR, la review. Commit non audité sur main. | 8 | 3 | 6 | 144 | Directive explicite "workflow obligatoire sans exception". Mais aucun hook technique ne bloque un commit direct. | Candidat : pre-push hook qui refuse push sur main sauf depuis une branche feature mergée. |

### GO — comportement agent

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| SF-06 | GO-0 | Starfleet infère une décision infrastructure sans règle explicite | Changement système non tracé, non reproductible. Au prochain reprovisioning, l'état diverge. | 8 | 4 | 8 | 256 | GO-0 escalade universelle. Mais : starfleet est souvent seul (boundary-os), pas d'interlocuteur immédiat pour escalader sauf architect/user. | Le risque est maximal en session autonome (auto-mode). Mitigation : scratchpad systématique pour tracer les décisions. |
| SF-07 | GO-1 | Starfleet "comprend" une convention mais ne l'écrit pas | Convention perdue au compact. Le prochain starfleet repart de zéro sur ce point. | 6 | 5 | 7 | 210 | Handoff + harvest. Directive GO-1 "Write → Commit → Deploy". | Handoff est rédigé par starfleet lui-même — qualité circulaire. Si la convention n'est pas identifiée comme importante, elle n'est pas dans le handoff. |
| SF-08 | GO-3 | Starfleet voit un problème infra mais continue sa tâche en cours | Problème non traité, resurface plus tard. En infra, un problème ignoré peut cascader. | 7 | 4 | 6 | 168 | GO-3 "fix maintenant OU backlog explicite". Scratchpad auto-trigger. | Le modèle peut mentionner le problème dans sa prose interne sans déclencher le pattern scratchpad. D=6. |
| SF-09 | GO-8 | Compact sans harvest — contexte perdu | Session suivante démarre sans contexte. Travail refait ou contraintes oubliées. | 6 | 3 | 4 | 72 | pre-compact-harvest.sh (hook). Handoff skill. | Hook mécanique, bien couvert. D=4 car le hook peut échouer silencieusement si fleet-done.sh plante. |

### Frontière et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| SF-10 | boundary-os | Starfleet exécute du code projet (L1) — scope interdit | Confusion des rôles. Starfleet n'est pas dev. Code projet potentiellement modifié par un agent sans contexte métier. | 7 | 3 | 5 | 105 | Directive "INTERDIT : code projet (L1)". runtime-guard.sh bloque écriture hors périmètre. | runtime-guard protège les chemins, mais starfleet a sudo — il peut contourner les guards. Risque résiduel inhérent au sudo. |
| SF-11 | boundary-os | Starfleet interagit directement avec l'user sur du L1 (contenu projet) | Court-circuit de la chaîne architect→engineer→dev. Décision projet prise sans contexte archi. | 5 | 3 | 7 | 105 | Directive "input user direct sur L1 interdit". | Aucune mitigation mécanique. Si l'user demande à starfleet de toucher du code projet, seule la directive l'empêche. |
| SF-12 | SPOF | Starfleet indisponible (crash, compact, session fermée) | Fleet aveugle côté OS. Pas d'escalade système possible. Agents bloqués sur des problèmes de permissions/services. | 8 | 4 | 2 | 64 | Fleet continue de fonctionner pour les tâches en cours. Agents accumulent les escalades système dans inbox. Reprise au restart. | D=2 : absence immédiatement visible (inbox non vidé, state "offline"). Mais pas de watchdog automatique. |

### Deploy et propagation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| SF-13 | deploy.sh | Deploy partiel (script plante au milieu) | Certains agents ont la nouvelle version, d'autres non. État fleet incohérent. | 8 | 3 | 4 | 96 | deploy.sh traite les agents séquentiellement. Si un agent échoue, les suivants ne sont pas déployés. Erreur visible dans le log. | Pas de rollback automatique. Un deploy partiel nécessite un re-deploy manuel. Candidat : flag --continue-on-error + rapport. |
| SF-14 | fleet-update | git pull pendant que des agents tournent | Agents en cours d'exécution avec des scripts partiellement mis à jour sur disque | 7 | 3 | 7 | 147 | fleet-update est appelé manuellement ou au boot — pas en continu. Les scripts sont sourcés au démarrage, pas rechargés à chaud. | Risque réel si un agent source fleet-env.sh pendant un git pull. Fenêtre de vulnérabilité courte mais non nulle. Candidat : lock file pendant pull. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 2 | SF-06 (GO-0 inférence, 256), SF-07 (GO-1 convention perdue, 210) |
| RPN 100-199 | 5 | SF-05 (144), SF-08 (168), SF-14 (147), SF-02 (108), SF-10 (105), SF-11 (105) |
| RPN < 100 | 7 | SF-01, SF-03, SF-04, SF-09, SF-12, SF-13 |

**Risque dominant** : les modes liés au comportement LLM (GO-0, GO-1, GO-3) sont les
plus difficiles à mitiger mécaniquement. Le privilège sudo amplifie tout mode de
défaillance comportemental.

**Actions prioritaires** :
1. SF-05 (RPN 144) : ajouter pre-push hook qui bloque push direct sur main
2. SF-14 (RPN 147) : lock file pendant git pull dans fleet-update.sh
3. SF-04 (RPN 90) : validation sémantique fleet.yaml dans fleet-build-yaml.sh
