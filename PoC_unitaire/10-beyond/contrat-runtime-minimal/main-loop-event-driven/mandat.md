# main-loop-event-driven

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §2 "BOUCLE PRINCIPALE"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Fleet-pilot n'est **pas** un scheduler avec poll interval. C'est une
boucle `read-eval-apply` event-driven :

```
attendre un trigger :
  ├── requête spawn (MCP tool fleet_spawn)
  ├── event pod (stream NDJSON d'un pod actif)
  ├── trigger système (cron, health check failure, IPC)
  └── requête API (HTTP/WebSocket)

traiter → dispatch vers handler

après traitement :
  liveness probes (si intervalle dépassé)
  timeouts pods (maxDuration)
  retries jobs (strategy)
```

Pas de `while True: sleep(X)`. Pas de polling des pods. Les streams
NDJSON des pods alimentent la boucle via `asyncio` ; chaque nouveau
événement réveille la boucle.

## Observable

- Pas de CPU idle > ε quand aucun pod actif (vérifier via `top` ou
  `resource.getrusage`)
- Latence de réaction à un event pod : < 50ms entre write sur le
  pipe stdout du pod et transition status observable
- Les "checks périodiques" (liveness, timeout, retry) s'intercalent
  SANS réveiller toute la boucle inutilement — ils ont leur propre
  tasks asyncio

## Ce que le test vérifiera

Harness asyncio minimal qui simule N pods streamant des events,
mesure la latence réaction + l'usage CPU idle (doit être < 1% avec
N=0 pods actifs).

## Pourquoi DRAFT

Besoin d'un skeleton de fleet-pilot asyncio fonctionnel pour qu'il
soit testable. Deviendra `impl-python/loop.py`.
