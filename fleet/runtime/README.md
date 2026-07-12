# LCARS Fleet Runtime

**Date** : 2026-05-09
**Dernière révision** : 2026-07-12
**Statut** : runtime v2 consolidé sur `main` (cf. tag `remise-au-propre-2026-06-12`)
**Référencé par** : 04_design-notes/

App OTP unique `:lcars_fleet` du runtime LCARS v2 — implémentation Elixir des 16 design notes
PROMOTED du run #3.1.

## Layout

- `lib/fleet/<dom>/` : 14 domaines (ex-apps OTP collapsées en app unique) — inventaire + rings dans `CLAUDE.md` §Architecture
- `config/` : configuration mix (app unique)
- Branche : `main` (code) ; doctrine sur `work/ops`

## Build

```
mix deps.get
mix compile --warnings-as-errors
mix test
```
