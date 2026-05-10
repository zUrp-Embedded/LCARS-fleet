# pod-phase-transitions

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §3 "PodStatus.phase"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN — machine à états Python pure, exhaustif 25 paires
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

États : `Pending → Running → {Succeeded, Failed, Unknown}`.
`Unknown` = fleet-pilot a perdu le contact. Recovery → `Failed`.

Transitions autorisées (7) :

| De | Vers | Condition |
|---|---|---|
| (rien) | Pending | pod alloué |
| Pending | Running | process lancé |
| Pending | Failed | erreur projection/injection |
| Running | Succeeded | process terminé + outputs extraits |
| Running | Failed | process erreur, timeout, abort, liveness fail 3x |
| Running | Unknown | fleet-pilot crash (détecté au recovery) |
| Unknown | Failed | recovery fleet-pilot |

**Terminales** : `Succeeded`, `Failed`. Toute transition depuis
terminal est **interdite** — Succeeded→X et Failed→X sont des bugs.

## Observable

- Machine à états Python : toute transition est soit dans la table,
  soit rejetée
- Invariant : un PodStatus.phase ne peut pas passer par Unknown sans
  provenir de Running
- Invariant : Unknown n'est atteint qu'au recovery, jamais émis
  directement par une étape du spawn cycle

## Ce que le test vérifiera

`impl-python/pod_phase.py` — une classe state machine avec :
- `transition(from, to) → raise if not in autorisées`
- Un exhaustif : les 25 (5×5) paires, dont seulement 7 doivent
  passer, 18 doivent raise

## Commit initial

Je peux écrire le test.sh + impl-python tout de suite. C'est du code
pur, pas de dépendance à fleet-pilot.
