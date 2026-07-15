# priv/canon/ — données canon du runtime LCARS V2

> ⚠️ **LEGACY GELÉ — NON CHARGÉ PAR LE CODE (F-C156/F-C157/F-C153).**
> Ce répertoire (racine `runtime/priv/canon/`, run #4) est un **2e canon Memory-X en forme non-v2.5**,
> superseded par le canon d'app (`priv/cap_profile/canon/`, v2.5) et les monks GELÉS dans
> `priv/cap_profile/canon/_frozen-monks/`. **Aucun code runtime ne le lit** (vérifié : ni
> `Fleet.SPBuilder.Monk` — qui résout depuis `cap-profiles/monks/` — ni la découverte de cap-profiles ne
> pointent ici). `fleets/memory-alpha·beta.yaml` + `cap-profiles/{monk,archivist}.yaml` co-existent avec
> les définitions gelées de `_frozen-monks/` (rosters divergents, F-C157) : conservé À DESSEIN comme trace
> historique (décision keep+doc), pas de fusion. La « réactivation Memory-X » (F-C153) cible le registry
> `cap-profiles/monks/` (absent = monks gelés) → chemin **dormant par design** jusqu'à un dégel explicite.

**Date** : 2026-05-22 (bascule run #4)
**Dernière révision** : 2026-07-15
**Statut** : LEGACY GELÉ — non chargé par le code (cf. bannière ci-dessus)
**Référencé par** : —

## Contenu

- `cap-profiles/` — capability profiles (archivist, monk, à compléter : architect, engineer, consultant, qualifier, reviewer, gatekeeper, starfleet)
- `fleets/` — configurations d'instances de fleet (memory-alpha, memory-beta) — gelées (dir legacy)
- `sp/` — system prompts cap-profile (archivist, monk)

## Source

Ces fichiers sont issus de :
- Branche `feature/core-pod-runtime` (cap-profiles archivist/monk + configs memory alpha/beta)
- `/local/LCARS-v1.5/sp/` (copies SP archivist/monk)

Historique : issu de design-notes des runs #3/#4 (fleet-as-instance, cap-profiles, fleet_memory), aujourd'hui archivées hors runtime dans `work/beyond_#N/`. Aucune autorité courante — dir gelé.

## Discovery

Au boot du runtime, `Fleet.Instance.Loader` (à implémenter post-bascule, cf. DN fleet-as-instance §2.4) glob `priv/canon/fleets/*.yaml` pour charger les instances de fleet. Les cap-profiles sont chargés par `fleet_cap_profile` depuis `LCARS_CAPPROFILES_ROOT` env var (cf. `config/runtime.exs`).

## Dette de migration

Les cap-profiles YAML actuels référencent encore `/local/LCARS-v1.5/sp/archivist.md` pour `invocation.systemPrompt`. Migration path résolution = ticket post-bascule.
