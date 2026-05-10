# recovery-orphan-handling

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §5 "Procédure au restart fleet-pilot"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Au restart, fleet-pilot lit les `PodStatus` sur disque.
Pour chaque pod en phase `Running` :
1. Vérifier si `claude -p` est encore vivant (`kill -0 <PID>`)
2. **Kill systématique** du PID orphelin si vivant — pipe parent
   est mort, agent dans état indéfini. Fiabilité > préservation.
3. Marquer `PodStatus.phase = Unknown` puis transitionner :
   - Event log cohérent → extraire artefacts, `Failed` + reason
     `fleet_pilot_crash_recovery`, livraison partielle possible
   - Event log incohérent → `Lost`, aucune garantie

Pour chaque job en `Running` :
- Évaluer retry (strategy)
- Si retry → nouveau attempt from scratch, brief enrichi avec
  outputs partiels de l'event log. Pas de `--resume`.
- Sinon → `Failed`, escalade

## Observable

- Fonction `detect_orphan_pids(pod_status_list) → [pid]`
- Fonction `kill_orphans(pids)` — utilise `os.kill(pid, SIGKILL)`
- Fonction `classify_attempt_recovery(event_log, pod_status) →
  Failed | Lost` — selon cohérence event log
- Invariant : tout PID orphelin est killé avant transition d'état
  quel qu'il soit

## Ce que le test vérifiera

Harness qui :
- Spawne un processus "pod factice" (sleep 999)
- Construit un PodStatus simulé en `Running` avec ce PID
- Invoque la routine recovery
- Vérifie : PID tué, PodStatus marqué Unknown puis Failed/Lost selon
  event log fourni

## Pourquoi DRAFT

Les fonctions à tester n'existent pas encore. Partie 04-phase-1-core
/recovery-protocol.md pour le détail complet. À miroir quand on y arrive.
