# pod-conditions-canoniques

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §1 "Conditions canoniques"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `objets-runtime/README.md`

## Contrat

Six conditions nommées obligatoires dans PodStatus.conditions, émises dans un ordre fixé par le spawn cycle :

| Condition | Émise à étape | Signification |
|---|---|---|
| `HomeProjected` | PROJECT | home nettoyé, squelette posé |
| `ContextInjected` | INJECT | brief + creds + env en place |
| `ProcessLaunched` | LAUNCH | `claude -p` lancé, stream ouvert |
| `StreamAlive` | MONITOR (run) | stream NDJSON produit encore des events |
| `OutputExtracted` | EXTRACT | artefacts `~/output/` récupérés |
| `HomeReleased` | RELEASE | home nettoyé, pod rendu au pool |

Invariants :
- Une condition n'est émise **qu'une fois** (pas de toggle)
- L'ordre d'émission suit le spawn cycle 8 étapes (§ beyond-contrat-runtime-minimal §2)
- `StreamAlive` peut basculer `True → False` (liveness fail), les autres sont monotones `→ True`

## Observable

- Ensemble des conditions = {6 noms canoniques}
- Any nom hors de l'ensemble dans un PodStatus = bug de fleet-pilot ou spec corrompue
- Ordre fixé pour les 5 transitions monotones (pas StreamAlive)

## Ce que le test vérifie

Impl-python qui expose :
- `CANONICAL_CONDITIONS: set[str]` (6 noms)
- `MONOTONE_ORDER: list[str]` (5 noms sans StreamAlive, dans l'ordre du spawn)
- `is_monotone(condition_name) -> bool`

Test :
- Set égal au set corpus hardcoded
- Ordre monotone correspond
- `StreamAlive` détecté comme non-monotone (toggle autorisé)
