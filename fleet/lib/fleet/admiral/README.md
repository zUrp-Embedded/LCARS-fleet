# Fleet.Admiral — le domaine sysadmin, côté système

**Réécrit le 2026-08-19** (audit du chantier admiral). L'ancienne carte était une copie sed de
`starfleet/README.md` : elle promettait douze modules dont six morts avec la brouette du
2026-08-19 (le validateur de décision, DriftMonitor, l'escaladeur de sévérité max, AuditLog,
CoordBackend, `Fleet.Decision`) et des knobs `:starfleet_*` que le renommage venait de tuer.
Cette carte décrit **ce qui existe**.

## Doctrine (une ligne)

Le système **détecte, logge et tickette** (`error_system` — la boîte de réception d'admiral) ;
**aucune action automatique, aucun spawn, aucune décision** derrière le ticket. Un humain traite,
hors de la boîte. La seule moitié automatisée est le rail d'outillage, parce que son objet est
*déclarable*. Production → arch ; défauts du système → sysadmin ; tout traversant est un bug.

## Modules (7 + la façade)

- `Fleet.Admiral` — la façade : le renvoi [BL-6-53]→[BL-6-103], `boot_orchestrate/0` (déclenché
  par la racine APRÈS le boot complet).
- `Fleet.Admiral.Application` — superviseur du domaine ; enfants opt-in, un knob
  `:admiral_start_*` chacun (`shutdown`, `audit_consumer`, `mcp_monitor`,
  `toolchain_reconciler` ; `boot_orchestrator` est lu par la racine) — tous `false` en test.
- `Fleet.Admiral.AuditConsumer` — consumer du Bus, log AUDIT (cycle de vie + sécurité).
- `Fleet.Admiral.BootOrchestrator` — l'orchestrateur post-readiness (Task non liée, jamais
  fatale ; spawn des permanents = vraie dépense claude, donc jamais en mi-boot).
- `Fleet.Admiral.MCPMonitor` — liveness du substrat MCP pod-facing (`Process.whereis` local,
  zéro réseau), sur `PeriodicCheck`.
- `Fleet.Admiral.PeriodicCheck` — la plomberie de tick partagée (re-arm EN DERNIER,
  `:check_now` rejoue le chemin complet sans re-armer). Deux clients : `MCPMonitor`,
  `ToolchainReconciler`.
- `Fleet.Admiral.Shutdown` (+ `Dispatcher`, `NoOpDispatcher`, `AggregateDispatcher`) — quiesce +
  drain borné du BEAM.
- `Fleet.Admiral.ToolchainReconciler` — le déclencheur du rail d'outillage : compare
  `head(sysadmin)` au SHA appliqué (marqueur à durée de vie CONTENEUR — `LCARS_TOOLCHAIN_RUN_STATE`),
  appelle l'unique geste privilégié (`sudo -n lcars-toolchain-converge <sha>`), draine les
  work-items (verrou `lcars-awaits-toolchain`) au merge comme au refus.

## Config & deps

Knobs sous `:lcars_fleet` : `:admiral_start_{shutdown,audit_consumer,mcp_monitor,toolchain_reconciler,boot_orchestrator}` ·
`:admiral_mcp_monitor_{check_interval_ms,target}` · `:admiral_shutdown_{dispatcher,grace_ms}` ·
`:admiral_toolchain_reconcile_interval_ms` · `:admiral_task_queue_mod` ·
`:admiral_completion_inflight_fun` (seam déclaré, cf. `@seams` de la topologie) ·
`:toolchain_converger{,_bin}` (le geste root) · `:forge_client` (lecture).

Boundary : exports `[Shutdown]` et rien d'autre. La valeur wire est `source: :admiral`
(renommée dans son propre commit, `9090974d1`).

## Ce que ce domaine n'est PAS

Le **pod** `starfleet` (front desk, chef de portefeuille, `role_index 0`) n'a aucun rapport avec
ce domaine — c'est l'homonymie qui a coûté le renommage, et elle est morte : le mot `starfleet`
ne désigne plus que le pod.
