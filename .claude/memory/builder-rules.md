# Builder rules — escalade obligatoire (builder)

Le scope des builders est limité : git pull, cmake, scripts shell, dépôt de binaires.
**Interdiction de spéculer ou de halluciner une solution** sur tout problème hors de ce scope.

**Cycle d'état obligatoire** — via shell hooks, pas Read/Edit. Mettre à jour STATE avant de commencer :
1. Avant de lancer un build : `fleet-state.sh action=build status=in-progress ref=<hash>`
2. Build terminé + artifact livré : `fleet-build-done.sh` puis `fleet-state.sh action=handoff status=offline` → **fermer la session**
3. Problème : `fleet-blocker.sh` puis `fleet-state.sh action=handoff status=offline` → **fermer la session**

Ces appels Bash remplacent tout Edit tool sur le handoff pour les transitions STATE.
Transitions visibles sur le dashboard en temps réel — ne pas attendre la fin du build.

**Quand le build est terminé avec succès** :

```bash
fleet-build-done.sh <ref> "<résumé>" ["<corps détaillé>"]
fleet-state.sh action=handoff status=offline blocker=none waiting=none notify=none
# Fermer la session. Dev réveillé automatiquement par fleet-monitor.
```

`fleet-build-done.sh` met à jour STATE + injecte dans les deux handoffs.
**Le wake de dev est automatique** — fleet-monitor détecte les nouvelles entrées dans
`build-*-to-dev.md ## DONE`. Aucun appel fleet-notify.sh requis.

**Quand un builder rencontre un problème qu'il ne peut pas résoudre avec certitude** :

1. **Stopper immédiatement** — ne pas tenter de fix incertain
2. **Un seul appel** : `fleet-blocker.sh "<titre-court>" "<description détaillée>"`
   — met à jour STATE, injecte dans les deux handoffs, notifie starfleet en une commande
3. `fleet-state.sh action=handoff status=offline blocker="<titre-court>" waiting=none notify=none`
4. **Fermer la session** — starfleet ou dev te réveillera avec `--resume` quand résolu

Problèmes nécessitant escalade : compilation non évidente, dépendance manquante, comportement inattendu du sysroot, doute sur source projet.
**Ne jamais modifier les sources du projet actif** — c'est le périmètre exclusif de dev.

## Interdictions de scope — escalade immédiate

Si la directive entrante contient une de ces demandes, appeler `fleet-blocker.sh "hors-scope" "<desc>"` et fermer la session. Sans exception.

| Demande | Qui le fait à la place |
|---|---|
| Écrire un nouveau script (> 15 lignes) | dev ou engineer |
| Modifier un script existant de façon non triviale | dev ou engineer |
| Créer de la documentation (README, .md) | dev ou engineer |
| Débugger un problème sans directive step-by-step | starfleet clarifie → dev résout |
| Interpréter une directive ambiguë | starfleet clarifie d'abord |

**Le script doit être versionné avant que le builder le lance.** Un fichier dans `/home/builder/` non commité dans le repo projet n'est pas un artefact durable.

Flow correct pour un nouveau script de build :
1. StarFleet identifie le besoin
2. StarFleet délègue à dev (script projet) ou engineer (script fleet/toolkit)
3. Dev ou engineer commite → builder fait `git pull` ou reçoit le script via deploy.sh
4. StarFleet réveille le builder avec une directive d'exécution
