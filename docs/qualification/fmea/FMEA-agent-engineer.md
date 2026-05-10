# FMEA — Agent engineer (Tier 1, sas-user)

**Date** : 2026-03-24
**Dernière révision** : 2026-03-24
**Statut** : initial — première passe
**Référencé par** : docs/qualification/fmea/, work/TODO/v6-qualification-plan.md
**Dérivé de** : fleet.yaml, roles/engineer.md, topologie.md

---

## Profil de risque

| Attribut | Valeur |
|---|---|
| Tier | 1 — sas-user (orchestrateur interne) |
| Scope | sas-user (L4 R, deploy, drift audit, dispatch, coordination) |
| Stateless | false (session interactive, inbox poll) |
| Interlocuteur | architect (upstream), tous Tier 2 (downstream) |
| Privilèges | pas de sudo, pas de code projet, pas de push projet |
| SPOF | oui — seul canal fleet→architect |

**Particularité critique** : engineer est le dispatcher central. Tout le travail Tier 2
transite par lui. Un engineer défaillant ne casse pas la fleet mais paralyse la
production. C'est aussi le seul agent à faire le lien fleet interne → architect.

---

## Table FMEA

### Dispatch et coordination

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| EN-01 | fleet-dispatch | Engineer dispatche une tâche au mauvais agent (scope mismatch) | Agent reçoit une tâche hors-scope. L'agent devrait refuser (filtre de réception) mais s'il ne le fait pas : exécution hors-cadre. | 7 | 3 | 4 | 84 | Filtre de réception universel (topologie.md). fleet-dispatch.sh valide le rôle. Mais pas de validation scope-vs-tâche automatique. | Le filtre de réception dépend de l'agent destinataire — c'est un LLM, pas un mécanisme. Si l'agent ne détecte pas le mismatch (GO-0), il exécute. |
| EN-02 | fleet-dispatch | Engineer dispatche une tâche multi-scope à un seul agent | Agent exécute partiellement, sort de son scope pour le reste, ou bloque. | 6 | 4 | 6 | 144 | Directive "tâche multi-scope : le dispatcher décompose en sous-tâches mono-scope". | Aucun enforcement mécanique. fleet-dispatch.sh ne vérifie pas si la tâche est mono-scope. |
| EN-03 | Coordination | Engineer perd le suivi de tâches parallèles | Tâches orphelines (dispatchées mais jamais vérifiées). Résultat jamais intégré. | 6 | 5 | 7 | 210 | fleet-plan.sh track les tâches. Inbox accumule les ACK. | Le tracking dépend de l'engineer qui consulte activement inbox et plan. Si context window chargé ou compact imminent, des ACK peuvent être manqués. |
| EN-04 | Écriture concurrente | Engineer dispatche deux tâches vers le même repo au même agent (ou deux agents) | Conflits git, écrasements de fichiers, merge conflicts non gérés. | 8 | 3 | 5 | 120 | Directive "jamais deux agents en écriture simultanée sur le même projet". | Aucun lock mécanique sur les repos projets. fleet-dispatch.sh ne vérifie pas si un agent est déjà en écriture sur le même repo. Candidat : lock file par repo. |

### Chaîne de communication

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| EN-05 | Sas user | Engineer ne remonte pas un résultat critique à architect | Architect et user ne savent pas qu'un problème est survenu. Décision prise sur info incomplète. | 7 | 3 | 7 | 147 | Directive "seul canal fleet→architect". Plans suffixés -architect. | D=7 : si engineer ne remonte pas, architect ne peut pas savoir ce qu'il ne sait pas. Candidat : ACK obligatoire architect sur tout résultat Tier 2 critique. |
| EN-06 | Escalade | Engineer escalade tout vers architect sans filtrer | Architect surchargé de détails opérationnels. Perd de vue les décisions stratégiques. | 4 | 4 | 5 | 80 | Directive "Tier 1 traite IN-scope sans approbation". | Le boundary entre "je traite" et "j'escalade" est un jugement LLM, pas une règle mécanique. |
| EN-07 | Escalade système | Engineer route une escalade système via la chaîne métier au lieu de court-circuit vers starfleet | Latence inutile. Problème système (permissions, service down) transite par architect alors que starfleet pourrait le résoudre directement. | 4 | 4 | 6 | 96 | Directive "escalade système = court-circuit direct vers starfleet". Critère : "le problème empêche-t-il à cause du système ou du projet ?" | Critère de discrimination est un jugement. Un agent qui hésite prend le chemin par défaut (chaîne métier). |

### Scope et isolation

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| EN-08 | INTERDIT code | Engineer écrit du code projet au lieu de dispatcher | Code non dans le bon contexte (pas le home dev, pas le bon repo). Pas de review, pas de tests. | 6 | 3 | 4 | 72 | Directive "code projet interdit". runtime-guard.sh bloque écriture hors périmètre. | Bien couvert. Engineer n'a pas write sur les repos projets (permissions Linux). |
| EN-09 | INTERDIT push | Engineer push sur un repo projet | Commit non reviewé dans le repo. Contourne le cycle dev→qualifier→reviewer. | 7 | 2 | 3 | 42 | Directive "push projet interdit". Permissions git (engineer n'a pas le push access configuré). | Bien couvert mécaniquement. |

### Continuité

| # | Composant | Mode de défaillance | Effet | S | O | D | RPN | Mitigation | Résidu |
|---|---|---|---|---|---|---|---|---|---|
| EN-10 | Compact | Engineer perd le contexte des dispatches en cours | Tâches en vol sans suivi. ACK reçus après compact non traités. | 6 | 4 | 5 | 120 | Handoff. fleet-plan.sh persiste l'état des plans. Inbox persiste les messages. | Le handoff capture l'état connu. Les messages inbox persistent. Au restart, engineer peut reconstruire l'état. D=5 : possible mais demande effort. |
| EN-11 | SPOF | Engineer indisponible | Aucun dispatch possible. Tier 2 idle. Architect ne reçoit plus de feedback fleet. | 6 | 4 | 2 | 48 | Fleet continue pour les tâches déjà dispatchées. Résultats s'accumulent dans inbox engineer. Reprise au restart. | D=2 : visible immédiatement (pas de dispatch, inbox grossit). Impact limité si les agents Tier 2 ont du travail en cours. |

---

## Synthèse

| Seuil | Count | Items |
|---|---|---|
| RPN >= 200 | 1 | EN-03 (suivi tâches perdues, 210) |
| RPN 100-199 | 4 | EN-05 (147), EN-02 (144), EN-04 (120), EN-10 (120) |
| RPN < 100 | 6 | EN-07, EN-01, EN-06, EN-08, EN-11, EN-09 |

**Risque dominant** : coordination et suivi. Engineer est un orchestrateur — ses modes de
défaillance sont des pertes de suivi, des mauvais routages, des communications manquées.
Les risques techniques (scope violation) sont bien couverts mécaniquement.

**Actions prioritaires** :
1. EN-03 (RPN 210) : dashboard des tâches en vol, auto-check dans on-prompt
2. EN-04 (RPN 120) : lock file par repo dans fleet-dispatch.sh
3. EN-02 (RPN 144) : validation mono-scope dans fleet-dispatch.sh
