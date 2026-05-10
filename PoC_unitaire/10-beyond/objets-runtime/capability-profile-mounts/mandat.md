# capability-profile-mounts

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §1 "CapabilityProfile" (mounts)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Chaque mount du CapabilityProfile déclare :
- `name` (str, unique dans le profile)
- `target` (path dans le home pod, ex. `~/repo`)
- `mode` (`read-only` | `read-write`)
- `method` (`clone-reference` | `worktree` | `copy` | `checkout` | `create`)
- `ref` (optionnel, pour les méthodes git : branche, sha, ou `from-job`)
- `selector` (optionnel, pour `copy` filtré : `from-job`, patterns)

Invariants :
1. `name` unique
2. `target` absolu ou `~/` (pas de `..` relatifs)
3. `method` valide
4. `method=create` implique `mode=read-write` (crée un répertoire vide, obligé writable)
5. `method ∈ {clone-reference, worktree, checkout}` implique `ref` défini

## Observable

- Liste de mounts typée parsable + validable
- Les 5 méthodes ont chacune une sémantique testable en isolation (mais demande impl mount runtime)
- `method=copy` + `selector=from-job` + `ref=from-job` = mount paramétré par fleet-pilot à partir du Job

## Gaps à combler

- [GAP] impl-python `validate_mounts(mounts: list) -> None`
- [GAP] impl-python `mount_execute(mount_spec, context) -> dict` (runtime)
- [GAP] fixtures : profile qualifier + profile engineer pour tester variétés de mounts
- [GAP] test runtime mount : spawner un pod, vérifier que les mounts sont en place avec le bon mode
