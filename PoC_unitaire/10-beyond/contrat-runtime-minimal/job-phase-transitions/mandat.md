# job-phase-transitions

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §3 "Job.status.phase"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN (machine à états Python pure)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

États : `Pending → Running → {Succeeded, Failed, Aborted, Suspended}`.
`Suspended` peut repasser à `Running` (resume) ou aller à `Aborted`.

Transitions autorisées (9) :

| De | Vers | Condition |
|---|---|---|
| (rien) | Pending | job créé |
| Pending | Running | premier attempt lancé |
| Running | Succeeded | delivery créée et promue |
| Running | Failed | maxAttempts atteint OU noRetryOn match |
| Running | Aborted | user ou gatekeeper abort explicite |
| Running | Suspended | user ou gatekeeper suspend |
| Suspended | Running | user ou gatekeeper resume |
| Suspended | Aborted | user abort pendant suspension |
| Running | Running | retry (nouveau attempt, même job) |

**Terminales** : `Succeeded`, `Failed`, `Aborted`. Pas de résurrection —
créer un nouveau Job.

`Aborted` ≠ `Failed` :
- `Failed` = système a épuisé ses options (maxAttempts, noRetryOn)
- `Aborted` = décision explicite user/gatekeeper

## Observable

- Toute transition non listée est rejetée
- `Running → Running` (retry) autorisé, c'est une particularité
- `Suspended` est une zone d'attente, pas terminale

## Ce que le test vérifie

Exhaustif 6×6 avec distinction Running→Running explicite.
