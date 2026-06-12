# LCARS Fleet Runtime

**Date** : 2026-05-09
**Dernière révision** : 2026-06-12
**Statut** : runtime v2 consolidé sur `main` (cf. tag `remise-au-propre-2026-06-12`)
**Référencé par** : 04_design-notes/

Umbrella OTP du runtime LCARS v2 — implémentation Elixir des 16 design notes
PROMOTED du run #3.1.

## Layout

- `apps/fleet_*/` : applications par bloc (cf. STATUS.md du run #3.1)
- `config/` : configuration mix umbrella
- Branche : `main` (code) ; doctrine sur `work/ops`

## Build

```
mix deps.get
mix compile --warnings-as-errors
mix test
```
