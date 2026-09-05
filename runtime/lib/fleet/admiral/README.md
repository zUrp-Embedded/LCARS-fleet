# Fleet.Admiral — le domaine sysadmin, côté système

**Date**: 2026-08-19
**Last revised**: 2026-09-04
**Status**: active — the card of the `Fleet.Admiral` domain
**Referenced by**: `lib/fleet/admiral.ex` (the facade)

## Doctrine (une ligne)

Le système **détecte, logge et tickette** (`error_system` — la boîte de réception d'admiral) ;
**aucune action automatique, aucun spawn, aucune décision** derrière le ticket. Un humain traite,
hors de la boîte. La seule moitié automatisée est le rail d'outillage, parce que son objet est
*déclarable*. Production → arch ; défauts du système → sysadmin ; tout traversant est un bug.

## Modules

- `Fleet.Admiral` — la façade : `boot_orchestrate/0` (déclenché par la racine APRÈS le boot
  complet) ; le domaine porte le nom de sa fonction, pas d'un rôle [BL-6-103].
- `Fleet.Admiral.Application` — superviseur du domaine ; enfants opt-in, un knob
  `:admiral_start_*` chacun (`shutdown`, `audit_consumer`, `mcp_monitor`,
  `toolchain_reconciler` ; `boot_orchestrator` est lu par la racine) — tous `false` en test.
- `Fleet.Admiral.AuditConsumer` — consumer du Bus, log AUDIT (cycle de vie + sécurité).
- `Fleet.Admiral.BootOrchestrator` — l'orchestrateur post-readiness (Task non liée, jamais
  fatale ; spawn des permanents = vraie dépense claude, donc jamais en mi-boot).
- `Fleet.Admiral.MCPMonitor` — liveness du substrat MCP pod-facing (`Process.whereis` local,
  zéro réseau), sur `PeriodicCheck`.
- `Fleet.PeriodicCheck` (foundation, pas ce domaine) — la plomberie de tick des deux clients
  ci-dessus : re-arm EN DERNIER, filet sous la passe (`rescue` + `catch`, état gardé),
  `:check_now` rejoue le chemin complet sans re-armer ni filet.
- `Fleet.Admiral.Shutdown` (+ `Dispatcher`, `NoOpDispatcher`, `AggregateDispatcher`) — quiesce +
  drain borné du BEAM.
- `Fleet.Admiral.ToolchainReconciler` — le déclencheur du rail d'outillage : compare la tête de
  `tool_request` au SHA appliqué (marqueur à durée de vie CONTENEUR — `LCARS_TOOLCHAIN_RUN_STATE`),
  ouvre la socket du service privilégié (`toolchain.sock`, servie par `lcars-privileged`, qui
  joue `lcars-toolchain-converge`), draine les work-items (verrou `lcars-awaits-toolchain`) au
  merge comme au refus.

## Config & deps

Knobs sous `:lcars_fleet` : `:admiral_start_{shutdown,audit_consumer,mcp_monitor,toolchain_reconciler,boot_orchestrator}` ·
`:admiral_mcp_monitor_{check_interval_ms,target}` · `:admiral_shutdown_{dispatcher,grace_ms}` ·
`:admiral_toolchain_reconcile_interval_ms` · `:admiral_task_queue_mod` ·
`:admiral_completion_inflight_fun` (seam déclaré, cf. `@seams` de la topologie) ·
`:toolchain_converger` (seam du geste, défaut : la demande sur `toolchain.sock`) ·
`:toolchain_socket` · `:admiral_forge_client` (lecture).

Boundary : exports `[Shutdown]` et rien d'autre. La valeur wire est `source: :admiral`.

## Ce que ce domaine n'est PAS

Le **pod** `starfleet` (front desk, chef de portefeuille, `role_index 0`) n'a aucun rapport avec
ce domaine : le mot `starfleet` désigne le pod, jamais ce domaine.
