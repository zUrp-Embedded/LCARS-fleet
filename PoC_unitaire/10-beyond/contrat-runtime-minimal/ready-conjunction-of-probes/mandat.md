# ready-conjunction-of-probes

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §3 "Système READY"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN (logique booléenne)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

`READY = ∧ (toutes les startup probes True)`.

La conjonction est la définition. Pas un champ écrit quelque part.
Si une seule probe est False → système non READY → mode dégradé.

6 probes (voir unité `boot-startup-probes/`) : runtime_exists,
specs_readable, credentials_avail, event_log_writable,
pool_users_exist, fleet_pilot_up.

## Observable

- Fonction `is_ready(probe_results: dict) -> bool` = `all(probe_results.values())`
- Si `probe_results = {6 True}` → `is_ready` True
- Si `probe_results = {5 True + 1 False}` → `is_ready` False
- Même si 5/6 réussissent, la conjonction rejette

## Pourquoi cette unité sépare `boot-startup-probes`

- `boot-startup-probes/` teste CHAQUE probe individuellement
- Cette unité teste que **la conjonction est stricte** et qu'il n'y
  a pas de "mode dégradé partiel" qui accepterait les spawns avec 5/6.
