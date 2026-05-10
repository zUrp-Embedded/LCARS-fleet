# spec-status-event-frontiere

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §1 "Frontière spec/status/event" + "Règle de non-redondance"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Trois strates avec autorité disjointe :

- **SPECS** (FleetSystem, CapabilityProfile, Pipeline, ProbeSet) —
  déclaratif, versionné, immuable au runtime. Fleet-pilot les lit,
  **jamais ne les écrit**.
- **STATUS** (Job.status, Attempt.status, PodStatus) — observé,
  écrit exclusivement par fleet-pilot. Reflète ce qui EST.
- **EVENTS** (event-log.ndjson) — append-only, source de vérité
  temporelle. Jamais édités, jamais supprimés.

**Règle de non-redondance** : une info vit dans UN seul endroit.
Le status est une **projection** calculable des events. Maintenu
en live pour la perf, mais recalculable depuis le log.

## Observable

- [GAP] Test projection : étant donné un event log NDJSON {N events},
  reconstruire le PodStatus final ; il doit matcher le fichier
  PodStatus.yaml (bit-a-bit sur les champs projetés)
- [GAP] Invariant runtime : si `PodStatus.phase` ≠ dernière transition
  implicite dans l'event log → corruption ou bug fleet-pilot
- [GAP] Read-only sur specs : détecter toute écriture sur
  `/local/LCARS/fleet/*.yaml` pendant fleet-pilot running

## Ce que le test vérifiera

Reconstruction: script Python qui prend un event log sample + applique
les transitions → produit un PodStatus reconstruit ; compare au
PodStatus de référence.

Invariant: sanity check fleet-pilot à écrire (quand le code existe) —
projection reconstruite doit toujours matcher status live.

## Pourquoi DRAFT

Besoin d'un event log sample canonique et d'une spec de projection
(les règles « event X → status.phase = Y »). Pas encore extraites
du corpus en forme exécutable.
