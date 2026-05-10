# attempt-phase-transitions

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §3 "Attempt.status.phase"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

États : `Pending → Running → {Succeeded, Failed, Interrupted, Lost}`.

| De | Vers | Condition |
|---|---|---|
| (rien) | Pending | attempt créé |
| Pending | Running | premier stage lancé |
| Running | Succeeded | tous stages terminés + gatekeeper promote |
| Running | Failed | gate hard FAIL, timeout |
| Running | Interrupted | abort explicite (user/gatekeeper), pod tué proprement |
| Running | Lost | fleet-pilot crash, pod orphelin |
| Running | Running | passage au stage suivant |

**Terminales** : `Succeeded`, `Failed`, `Interrupted`, `Lost`.

Distinction sémantique :
- `Interrupted` = arrêt volontaire, état connu. Outputs partiels récupérables.
- `Lost` = arrêt involontaire, état incertain. Fleet-pilot tente la
  récupération au restart (recovery §5).

## Observable

- Exhaustif transition matrix
- `Running → Running` (stage suivant) autorisé
- 4 terminaux immuables
