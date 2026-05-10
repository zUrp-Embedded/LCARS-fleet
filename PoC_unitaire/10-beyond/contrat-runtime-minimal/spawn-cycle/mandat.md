# spawn-cycle

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §2 "Cycle spawn" + `10-beyond/beyond-spawn-pod-v2.md`
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT (Tier 2 PoC-06 prévu)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

8 étapes, ordre strict, chacune émet un event canonique :

1. **ALLOCATE** — lock interne fleet-pilot, trouver pod_N libre, event `pod.allocated`
2. **CLEAN** — `rm -rf /home/pod_N/{*,.*}`, event `pod.cleaned`
3. **PROJECT** — mounts (repo/work/knowledge/context), `~/output/`, compose `CLAUDE.md`, copie `system-prompt.md`, `settings*.json`, event `pod.projected`, condition `HomeProjected=True`
4. **INJECT** — credentials, gh-hosts, env vars (CLAUDE_AGENT_NAME, JOB_ID, POD_ID, kill switches), event `pod.injected`, condition `ContextInjected=True`
5. **LAUNCH** — `sudo -u pod_N … claude -p --stream-json`, event `pod.launched`, condition `ProcessLaunched=True`, `PodStatus.phase=Running`
6. **MONITOR** — lecture stream NDJSON async, can_use_tool, MCP tool routing, métriques, events
7. **EXTRACT** — copie `~/output/` vers `/home/fleet-state/events/<attempt>/`, vérif git push si code scope, event `pod.output_extracted`, condition `OutputExtracted=True`
8. **RELEASE** — `rm -rf /home/pod_N/{*,.*}`, pool mark free, event `pod.released`, condition `HomeReleased=True`

Interlocking : chaque étape n ne peut démarrer tant que n-1 n'a pas
posé sa condition. Fail d'une étape → status transition vers Failed
(pour Pending→Running) ou rollback pour les idempotents (CLEAN/RELEASE).

## Observable

- Ordre strict : jamais `pod.launched` sans `pod.injected` avant
  dans l'event log
- Atomicité extract : voir unité `extract-atomicity/`
- Idempotence CLEAN et RELEASE : relancer 2x → pas d'erreur
- Isolation home : à la fin de RELEASE, `/home/pod_N/` est vide

## Ce que le test vérifiera

- Harness qui simule les 8 étapes avec un worker trivial ("hello")
- Vérifie séquence d'events dans le log
- Test rollback sur chaque fail point
- Test idempotence CLEAN et RELEASE

## Pourquoi DRAFT

C'est un test d'intégration de 8 primitives — impossible sans les
primitives. Chacune a sa propre unité (à créer dans `spawn-pod/`
quand on miroire `beyond-spawn-pod-v2.md`). Ici c'est le nœud qui
combine les 8.
