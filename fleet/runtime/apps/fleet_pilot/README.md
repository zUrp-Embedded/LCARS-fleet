# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-06-14 (mode stage A2/A3 + offload HopConsumer F067)
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

## Mode stage (forge-state-machine — A2/A3, actif)

Le mode **stage** (la forge EST la machine à états : ticket assigné à un rôle → spawn ce rôle)
double puis remplace le dispatch legacy ci-dessus. Activé par `:stage_dispatch?` + `:poll_repo` ;
le legacy par `:start_dispatcher` — **mutuellement exclusifs** (garde `Application`
`guard_no_duplicate_poller!`, F054 ; legacy `AutoDispatcher` retiré à F-09). Submodules :

- `Fleet.Pilot.StageDispatcher` — `decide/2` (assignee → `{:spawn, role, profile}`) + `dispatch_issue/2`
  (ordre canonique label → comment → pod).
- `Fleet.Pilot.Poller` — scanne le repo, dispatche assignee→spawn (+ Entry sur `type:`).
- `Fleet.Pilot.HopConsumer` — consumer Bus de la **fin-de-hop** (`pod.completed` → `HopCompleter`) ;
  gatekeeper §L441 (escalade soft/terminal → `resume_gate`). **Singleton** : la complétion lourde
  (git push ≤30s) est offloadée en `Task.Supervisor` (`:hop_runner` / `HopTaskSupervisor`, F067) → ne
  bloque pas la tête de ligne.
- `Fleet.Pilot.HopCompleter` — séquence §5 (publish livrable `git_native` + grave la route + reassign/close).

Knobs : `:start_dispatcher` (legacy), `:stage_dispatch?` + `:poll_repo` + `:poll_interval_ms` (stage),
`:hop_runner` (offload complétion, F067).

## Découplage core

Pas dans le core ring 1 (cf. doctrine `topologie-ring.md:173`). Le core
peut être invoqué manuellement OU par `fleet_pilot` après — découplage.
