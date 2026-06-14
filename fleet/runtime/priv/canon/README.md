# priv/canon/ — données canon du runtime LCARS V2

**Date** : 2026-05-22 (bascule run #4)

## Contenu

- `cap-profiles/` — capability profiles (archivist, monk, à compléter : architect, engineer, consultant, qualifier, reviewer, gatekeeper, starfleet)
- `fleets/` — configurations d'instances de fleet (memory-alpha, memory-beta, à compléter selon DN ring1/fleet-as-instance.md)
- `sp/` — system prompts cap-profile (archivist, monk)

## Source

Ces fichiers sont issus de :
- Branche `feature/core-pod-runtime` (cap-profiles archivist/monk + configs memory alpha/beta)
- `/local/LCARS-v1.5/sp/` (copies SP archivist/monk)

Référencé par : DN `04_design-notes/ring1/fleet-as-instance.md` (DRAFT), DN `04_design-notes/ring2/cap-profiles.md`, DN `04_design-notes/ring2/fleet_memory.md`.

## Discovery

Au boot du runtime, `Fleet.Instance.Loader` (à implémenter post-bascule, cf. DN fleet-as-instance §2.4) glob `priv/canon/fleets/*.yaml` pour charger les instances de fleet. Les cap-profiles sont chargés par `fleet_cap_profile` depuis `LCARS_CAPPROFILES_ROOT` env var (cf. `config/runtime.exs`).

## Dette de migration

Les cap-profiles YAML actuels référencent encore `/local/LCARS-v1.5/sp/archivist.md` pour `invocation.systemPrompt`. Migration path résolution = ticket post-bascule.
