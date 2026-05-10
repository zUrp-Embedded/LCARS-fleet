# extract-pipeline

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 AC-01 (pipeline complet)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT (extraite de l'ancien `extract-atomicity/` après reprise consultant R-03a)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

L'étape EXTRACT écrit 3 choses dans un ordre strict garanti atomique :

```
1. Copier ~/output/*      → /home/fleet-state/attempts/<attempt>/.staging/  (cp puis mv atomique)
2. rename .staging/       → /home/fleet-state/attempts/<attempt>/
3. fsync sur le dossier parent
4. Append event pod.output_extracted au fichier unique /home/fleet-state/events.ndjson
5. fsync event log
6. Update PodStatus.yaml via rename-after-write (.tmp, fsync, rename)
7. Transition PodStatus.phase → Succeeded
```

**Règle de recovery** :
- Event `pod.output_extracted` existe + artefacts présents → OK
- Artefacts présents sans event → rollback (supprimer artefacts orphelins)
- Event existe sans artefacts → erreur fatale, escalade

## Ce que le test devra vérifier

Harness Python qui :
- Joue les 7 étapes dans un env `/tmp/fleet-state-test/` simulé
- À chaque étape N : crée un subprocess qui répète les N-1 premières étapes puis se SIGKILL avant la N-ième
- Après crash : vérifier l'invariant (artefacts+event cohérents, ou absents, jamais partiel)
- Vérifie la règle de recovery appliquée à chaque cas de crash
- Vérifie l'idempotence de la transition phase Succeeded

## Pourquoi DRAFT

Nécessite un skeleton Python exécutable du pipeline extract (module `fleet_pilot.extract` ou équivalent). Ce module n'existe pas encore. À écrire en B1 round 1.

## Gaps à combler avant PROVEN

- [GAP] `impl-python/extract_pipeline.py` qui joue les 7 étapes
- [GAP] harness crash-injection via `multiprocessing.Process` + `os.kill(pid, SIGKILL)` à N-ième étape
- [GAP] simulateur de cleanup recovery qui lit event log + artefacts et applique la règle
- [GAP] test d'idempotence : relance pipeline complet deux fois, même result

## Croisement avec d'autres unités

- `extract-primitives-fs/` : prouve que les briques (rename, fsync parent, inode preserve) marchent — **préréquis** mais pas suffisant
- `event-log-ndjson/` : prouve l'append+rotation NDJSON — **préréquis** pour l'étape 4
- `pod-phase-transitions/` : prouve la validité de la transition Running→Succeeded — **préréquis** pour l'étape 7

Quand ces 3 sont PROVEN **et** le pipeline existe, cette unité peut être tentée.
