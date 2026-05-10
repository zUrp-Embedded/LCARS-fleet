# capability-profile-schema

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §1 "CapabilityProfile — la spec"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Un CapabilityProfile est un YAML strict avec :
- `apiVersion: lcars/v1`
- `kind: CapabilityProfile`
- `metadata: {name, description}`
- `spec:` avec les champs du §1 (pool, homePolicy, systemPrompt, claudeMd, settings, mounts, skills, credentials, allowedTools, denyTools, mcpServers, env, outputs, resources)

Validable par JSON Schema. Lu par fleet-pilot au spawn.

Invariants :
- `apiVersion == "lcars/v1"`
- `kind == "CapabilityProfile"`
- `spec.pool ∈ {worker, named}`
- `spec.homePolicy ∈ {ephemeral, persistent}`
- `spec.mcpServers[].tools` référencent des tools fleet existants (croisement runtime)
- `spec.resources.maxTokens > 0`, `maxDuration > 0`

## Observable

- Un profile `qualifier.yaml` exemple (celui du doc) valide
- Un profile avec `apiVersion: v2` rejeté
- Un profile sans `spec.systemPrompt` rejeté
- Un profile avec `pool: invalid` rejeté

## Gaps à combler

- [GAP] JSON Schema formel pour CapabilityProfile (dérivable mécaniquement du §1)
- [GAP] Un exemple canonique par rôle (worker role vs named) dans le corpus
- [GAP] Impl Python `validate_capability_profile(yaml) -> None | raise`
- [GAP] Croisement runtime : `mcpServers[].tools` référence un tool réel de fleet-pilot
