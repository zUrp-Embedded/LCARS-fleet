# schemas-authority

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §1 "Noyau minimal de schémas obligatoires"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT — contrat écrit, test à construire avec les schémas YAML
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

7 schémas, chacun avec owner / writer / reader définis :

| Schéma | Owner | Writer | Reader |
|---|---|---|---|
| FleetSystem | user (versionné) | fleet-update | fleet-pilot, provision |
| CapabilityProfile | user | fleet-update | fleet-pilot (spawn) |
| Pipeline | user | fleet-update | fleet-pilot (orchestration) |
| ProbeSet | user | fleet-update | fleet-pilot (health) |
| Job | fleet-pilot | fleet-pilot | fleet-pilot, gatekeeper |
| Attempt | fleet-pilot | fleet-pilot | fleet-pilot |
| PodStatus | fleet-pilot | fleet-pilot | fleet-pilot, monitoring |

**Invariant clé** : un pod ne peut JAMAIS être writer d'aucun de ces
schémas. Les pods écrivent dans leur home + dans `work-ops-inbox/`.
Jamais directement dans `/home/fleet-state/` ni dans `/local/LCARS/fleet/`.

## Observable

- [GAP] Structure YAML : charger chaque schéma via un parser YAML strict
  avec jsonschema → chaque exemple canonique du corpus valide
- [GAP] Write-authority : un pod (capability limité) tente d'écrire dans
  `/home/fleet-state/jobs/` → écrase sur permission OS (pod n'a pas les
  droits write sur ce chemin)
- [GAP] Read-authority : un non-fleet-pilot tente de lire un schéma dont
  il n'est pas reader autorisé → confronter à la permission OS

## Ce que le test vérifiera (quand construit)

1. Parser JSON-Schema pour chacun des 7 schémas (peut être un draft)
2. Exemples minimaux valides / invalides
3. Permissions FS sur les chemins /home/fleet-state/* et
   /local/LCARS/fleet/* : qui peut lire, qui peut écrire, par rôle

## Pourquoi c'est DRAFT

Les schémas JSON eux-mêmes ne sont pas encore écrits (ils sont dans
`10-beyond/beyond-objets-runtime-v2.md` et `beyond-objets-canoniques-v2.md`
sous forme YAML exemple, pas JSON Schema strict). L'extraction vers
JSON Schema est une tâche B1 round 1.
