# LCARS Fleet Runtime

**Date** : 2026-05-09
**Dernière révision** : 2026-05-09
**Statut** : umbrella en cours de bootstrap (run #3.1, chantier #1 fleet_capprofile)
**Référencé par** : work/beyond_#3.1/design-notes/promoted/

Umbrella OTP du runtime LCARS v2 — implémentation Elixir des 16 design notes
PROMOTED du run #3.1.

## Layout

- `apps/fleet_*/` : applications par bloc (cf. STATUS.md du run #3.1)
- `config/` : configuration mix umbrella
- Branche : `feature/core-pod-runtime`

## Build

```
mix deps.get
mix compile --warnings-as-errors
mix test
```
