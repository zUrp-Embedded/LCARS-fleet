# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-05-26
**Statut** : actif — service d'auto-orchestration tickets Gitea (ring 1 client du core).
**Référencé par** : `beyond_#4/01_architecture/topologie-ring.md` §Élagage

Service d'auto-orchestration tickets Gitea (M-033 backlog, doctrine
`beyond_#4/01_architecture/topologie-ring.md` §"Élagage" : **client du
core ring 1, pas core**).

Reçoit les events `gitea.*` du Bus (`Fleet.EventRouter.Bus`), filtre via
catalogue déclaratif `priv/config/forge-routing.yaml` (axes
`type:` × `state:` × `assignee`), puis invoke `Fleet.Pipeline.start_pipeline/2`
avec le ticket_id + le brief (issue.body) comme `ask`.

Idempotence inter-restart : label Gitea `lcars-dispatched` ajouté côté
forge avant invocation (lock atomique). Le poller reconciliateur
(brique 2, future) respectera ce label pour catch-up post-crash.

Pas dans le core ring 1 (cf. doctrine `topologie-ring.md:173`). Le core
peut être invoqué manuellement OU par `fleet_pilot` après — découplage.
