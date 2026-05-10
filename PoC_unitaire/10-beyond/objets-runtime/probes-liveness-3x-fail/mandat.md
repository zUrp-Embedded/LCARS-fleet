# probes-liveness-3x-fail

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §4 "Probes pod"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

La probe liveness pod a une seuil de tolérance : **3 échecs consécutifs** → Pod transitionne en Failed.

- 1 ou 2 échecs de liveness (isolés ou transitoires) : pas d'action, juste log
- 3 consécutifs : action décisive — Pod → Failed, reason `liveness_failed`

Le compteur se reset à chaque succès de liveness.

## Observable

- `LivenessTracker` : état {pod_id: consecutive_failures}
- `on_probe_result(pod_id, result)` : incrémente si False, reset à 0 si True
- À 3 → retourne action `kill_and_fail`

## Ce que le test vérifie

- 1 fail → pas d'action
- 2 fails → pas d'action
- 3 fails consécutifs → action `kill_and_fail`
- Fail, succès, fail, fail → 2 fails consécutifs seulement (reset à la réussite), pas d'action
- Fail, fail, succès, fail → 1 consécutif, pas d'action

## Pourquoi DRAFT

Logique triviale une fois isolée (compteur par pod) — mais demande de définir l'interface probe et le runner. Mieux de la coder quand le skeleton fleet-pilot prend forme. Pour l'instant, mandat pose le contrat précisément.
