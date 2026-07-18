# fleet_pilot

**Date**: 2026-05-26
**Last revised**: 2026-07-18
**Status**: active — forge driver (steering, client of the core)
**Referenced by**: —

Self-orchestration of Gitea issues (forge driver, `:step_dispatch?` off by default).
A **client of the core**, not the core: the forge IS the state machine (the route label engraved
on the issue), and this app reacts to it — it discovers the fleet-org repos (`list_org_repos`, WS3),
spawns the current step's role, drives the PR review lifecycle, and escalates to the human
(architect) when a PR can no longer advance on its own.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Pilot.StepDispatcher` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

**Reactor & dispatch**
- `Fleet.Pilot.Poller` — the reactor: discovers org repos each tick, reads the route, dispatches the step's role. Sub-modules `Poller.{Backoff, Lease, Reconciliation}` = tick timing / repo-serialized lease / orphan-lock reconciliation.
- `Fleet.Pilot.StepDispatcher` — `decide/1` (pure gate) + `dispatch_issue/2` / `dispatch_review/2`. Sub-modules `{ProjectResolver, ArchEscalation, Spawn, Spawn.Naming}` + `ReviewLifecycle{, .RoleDispatch, .Remediation}` (the PR review lifecycle).
- `Fleet.Pilot.BriefBuilder` — the authority on brief FORMAT (worker / judge / rework / conflict).

**Step-run completion**
- `Fleet.Pilot.StepRunConsumer` — Bus consumer of step-run end (`pod.completed`). Sub-modules `{Verdict, GateEngine, GatekeeperEscalation, TerminalEscalation, StepRunBuild}`.
- `Fleet.Pilot.StepRunCompleter` — PR-native completion orchestrator (`complete_pr/2`). Sub-modules `{Texts, Emissions}`.
- `Fleet.Pilot.GatekeeperSeal` — the SINGLE merge seal (`seal_and_merge/6`), shared by both merge points.

**Forge client (domain layer)**
- `Fleet.Pilot.ForgeClient` — Gitea client, injected via the `:forge_client` seam. Sub-modules `{Transport, UrlSafe, Jury, Repo, Files}`.
- `Fleet.Pilot.ForgeProtocol` / `Fleet.Labels` — pure wire-protocol vocabulary (branch/route/step_run formats + lock-labels).
- `Fleet.Pilot.MergeOutcome` — pure structural classification of a merge failure.

**Incidents & onboarding**
- `Fleet.Pilot.IncidentConsumer` — Bus consumer of pod-failure events (`pod.failed` / `wake.failed`) → `IncidentRegistry`.
- `Fleet.Pilot.IncidentRegistry` — persistent cross-session incident memory (GenServer + WAL + forge sync). Sub-module `Escalation` (the sysadmin issue).
- `Fleet.Pilot.WakeRecovery` — hardening of `Spawner.wake_pod/1` (re-roll / escalate).
- `Fleet.Pilot.ProjectOnboard` — `onboard/2` / `import/2`: mechanically create/import a dual-dir project. Sub-module `Scaffold` (pure templates).

**Primitives (single-authority utils)**
- `Fleet.Pilot.Application` — supervisor; `step_status/0` exposes rail liveness (consumed by `fleet_api` readiness).
- `Fleet.Pilot.Roles` / `Opts` / `Offload` / `IssueId` / `PodId` / `WorkflowMapNav` / `WorktreeSync` / `GitOps` / `WriteSpacing` — roles accessor, opt idioms, supervised Bus offload, id formats, workflow-map nav, post-merge projection, bounded git, inter-write spacing.

## Config & deps

- Boot: `:step_dispatch?` (default `false`; `LCARS_PILOT_STEP=true` starts the step rail — fail-loud on the forge `base_url`, the single required config). The full knob catalogue lives in `config/runtime.exs` + `etc/fleet_v2.env.template` (the SSoT); each knob is read by the module named in its own `@moduledoc`.
- Deps (all descending — see `use Boundary`): `fleet_workflow` (workflow-map nav + gate briefs), `fleet_spawner`, `fleet_credentials`, `fleet_cap_profile`, `fleet_event_router`. Two upward runtime seams (duck-typed, NOT compile deps): `:forge_client` consumed by `fleet_mcp`, readiness probed by `fleet_api`. See `mix.exs`.
- Not core: the core can be driven manually OR by `fleet_pilot` afterwards — decoupled by design.
