# Fleet.Pilot — domain card

**Date**: 2026-05-26
**Last revised**: 2026-08-13
**Status**: active — forge driver (client of the core)
**Referenced by**: —

Self-orchestration of Gitea issues (forge driver, `:step_dispatch?` off by default).
A **client of the core**, not the core: the forge IS the state machine (the route label engraved
on the issue), and this domain reacts to it — it discovers the fleet-org repos (`list_org_repos`, WS3),
spawns the current step's role, drives the PR review lifecycle, and escalates to the human
(architect) when a PR can no longer advance on its own.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Pilot.StepDispatcher` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

**Reactor & dispatch**
- `Fleet.Pilot.Poller` — the reactor: discovers org repos each tick, reads the route, dispatches the step's role. Sub-modules `Poller.{Backoff, Lease, Reconciliation}` = tick timing / repo-serialized lease / orphan-lock reconciliation.
- `Fleet.Pilot.StepDispatcher` — `decide/1` (pure gate) + `dispatch_issue/2` / `dispatch_review/2`. Sub-modules `{ProjectResolver, ArchEscalation, Spawn}` + `ReviewLifecycle{, .RoleDispatch, .Remediation}` (the PR review lifecycle).
- `Fleet.Pilot.BriefBuilder` — the authority on brief FORMAT (worker / judge / rework / conflict).

**Step-run completion**
- `Fleet.Pilot.StepRunConsumer` — Bus consumer of step-run end (`pod.completed`). Sub-modules `{Verdict, GateEngine, GatekeeperEscalation, TerminalEscalation, StepRunBuild}`.
- `Fleet.Pilot.StepRunCompleter` — PR-native completion orchestrator (`complete_pr/2`). Sub-modules `{Texts, Emissions}`.
- `Fleet.Pilot.GatekeeperSeal` — the SINGLE merge seal (`seal_and_merge/6`), shared by both merge points.

**Forge — NOT here any more**
- The client and the wire protocol are their own domain: `Fleet.Forge` (`lib/fleet/forge/`, own map). The pilot DRIVES it and declares it as a dep; it does not contain it. What made the move necessary: `Req`/`Req.Response` were deps of THIS boundary, so "one HTTP exit" was a convention any new call could break — it is compiled over there now.
- `Fleet.Pilot.MergeOutcome` — pure structural classification of a merge failure. Stays: it reads a forge failure to decide what the PILOT does next.

**Incidents & onboarding**
- `Fleet.Pilot.IncidentConsumer` — Bus consumer of pod-failure events (`pod.failed` / `wake.failed`) → `IncidentRegistry`.
- `Fleet.Pilot.IncidentRegistry` — persistent cross-session incident memory (GenServer + WAL + forge sync). Sub-module `Escalation` (the sysadmin issue).
- `Fleet.Pilot.ArchWake` — SINGLE authority for waking a project's architect on an `lcars-awaits-arch` escalation: the ordered offer-then-wake pair, shared by both rails.
- `Fleet.Pilot.ArchFeed` — Bus consumer appending one short line per fleet milestone into the PROJECT's architect pod (`<arch pod_dir>/fleet.feed`).
- `Fleet.Pilot.FleetFeed` — twin of `ArchFeed` for the FRONT DESK: one line per ESCALATED incident into the permanent starfleet pod, plus the typed flag notify. Escalations only — a raw failure rail here would build a roster out of `pod.failed`.
- `Fleet.Pilot.PodFeed` — the feed FILE primitive shared by both (name, `HH:MM` stamp, 200-line bound). The format has one owner; the log prefix stays with each facade's rail.
- `Fleet.Pilot.WakeRecovery` — hardening of `Spawner.wake_pod/1` (re-roll / escalate).
- `Fleet.Project.Architect` — the PER-PROJECT architect: pod-id authority + idempotent `ensure/2` (one architect per repo, project-bound identity).
- `Fleet.Project.Intensity` — single owner of the per-project criticality declaration (`<project>/.lcars.json`, schema `intensity-v1`): written at onboarding, read at the workflow-map burn.
- `Fleet.Project.Onboard` — `onboard/2` / `import/2`: mechanically create/import a dual-dir project. Sub-module `Scaffold` (pure templates).

**Primitives (single-authority utils)**
- `Fleet.Pilot.Application` — supervisor; `step_status/0` exposes rail liveness (consumed by the api domain's readiness).
- `Fleet.PodId` (FOUNDATION depuis le 2026-08-11 — le format des pod_id est lu par Spawner et Project, qui sont sous Pilot)
- `Fleet.Project.Roles` / `Opts` / `Offload` / `IssueId` / `WorkflowMapNav` / `WorktreeSync` / `GitOps` / `WriteSpacing` — roles accessor, opt idioms, supervised Bus offload, id formats, workflow-map nav, post-merge projection, bounded git, inter-write spacing.

## Config & deps

- Boot: `:step_dispatch?` (default `false`; `LCARS_PILOT_STEP=true` starts the step rail — fail-loud on the forge `base_url`, the single required config). The full knob catalogue lives in `config/runtime.exs` + `etc/fleet_v2.env.template` (the SSoT); each knob is read by the module named in its own `@moduledoc`.
- Deps (all descending): the truth is the `use Boundary` of `lib/fleet/pilot.ex` — notably workflow (workflow-map nav + gate briefs), spawner, credentials, cap_profile, task_queue, event_router. Upward runtime seams (duck-typed, NOT compile deps): `:forge_client` and `:project_onboard` consumed by mcp, readiness probed by api.
- Not core: the core can be driven manually OR by pilot afterwards — decoupled by design.
