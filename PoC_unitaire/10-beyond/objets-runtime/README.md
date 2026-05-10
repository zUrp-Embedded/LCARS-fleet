# Objets runtime — PoC_unitaire

**Source corpus** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md`
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : arbre initialise, unites en cours
**Référencé par** : `PoC_unitaire/README.md`

## Ce qu'on ne re-teste PAS ici

Les unités suivantes sont déjà couvertes par `contrat-runtime-minimal/` :
- phases Pod/Job/Attempt (state machines)
- ready conjunction (6 probes startup système)
- MCP in-process (transport)
- can_use_tool (permission runtime)

Le mirror objets-runtime ne duplique pas. Il ajoute **la forme d'implémentation** des objets (YAML schemas, champs typés, logique retry, DAG pipeline, tiers probes).

## Unités

| Unité | Corpus | État |
|---|---|---|
| capability-profile-schema | §1 CapabilityProfile | mandat |
| pod-conditions-canoniques | §1 Conditions canoniques | mandat |
| capability-profile-mounts | §1 mounts | mandat |
| capability-profile-resources-limits | §1 resources | mandat |
| job-retry-strategy | §2 retry strategy + retryOn / noRetryOn | mandat |
| delivery-required-fields | §2 Delivery schema | mandat |
| pipeline-dag-no-cycle | §3 Invariant 1 DAG | mandat |
| pipeline-gate-types | §3 gate hard/soft/terminal | mandat |
| pipeline-condition-skip | §3 condition évaluée avant spawn | mandat |
| pipeline-outputs-typing | §3 Invariant 6 outputs nommés et typés | mandat |
| probes-tiers | §4 startup / readiness / liveness | mandat |
| probes-liveness-3x-fail | §4 liveness 3 échecs → Failed | mandat |
