# event-log-ndjson

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §4 + `04-phase-1-core/event-schema-canonique.md`
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PARTIEL — PoC-04 couvre l'atomicité + rotation, reste à couvrir le schéma event (seq, ts, nodeId, kind, …)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Forme : NDJSON une ligne par event, append-only. Champs niveau 1
obligatoires : `seq`, `ts`, `nodeId`, `kind`. Conditionnels : `traceId`,
`jobId`, `attemptId`, `podId`, `role`, `agentId`, `runId`, `payload`.
Taxonomie `kind` : `job.*`, `attempt.*`, `pod.*`, `agent.*`, `delivery.*`,
`system.*`, `starfleet.*`, `escalation.*`, `protocol.*`.

L'event log est **la source de vérité temporelle**. Les status sont
des projections dérivées. Rotation via `FleetSystem.spec.event_log.rotation`
(size + retention). `apiVersion` bump → rotation + nouveau fichier.

## Observables couverts par PoC-04

- Append-only en `O_APPEND + fsync` préserve l'atomicité ligne-entière
  tant que `len(line) < PIPE_BUF` (4096 bytes)
- Rotation via `mv + touch + SIGHUP` → les writers reopen proprement,
  aucune perte, aucune interleaving entre lignes
- `stream.meta` écrit en postrotate sans race avec writers actifs
- Ordering monotone préservé dans le fichier actif et à la transition
  rotated→active

## Observables non encore couverts

- [GAP] Schéma exact d'un event (seq monotone global, ts format, kind taxonomie stricte)
- [GAP] Rotation via logrotate *externe* (pas interne fleet-pilot) — pattern
  logrotate avec create 0644 + postrotate `pkill -HUP fleet-pilot` à tester
  sous config /etc/logrotate.d/ réelle
- [GAP] Bump `apiVersion` → nouveau fichier — contrat de versioning
  d'enveloppe stream

## Ce que le test vérifie

`test.sh` relance PoC-04 et vérifie PASS sur intégrité, atomicité,
reopen après rotate. Les gaps sont listés en sortie `[GAP]` pour
qu'ils soient évidents dans le rapport global.
