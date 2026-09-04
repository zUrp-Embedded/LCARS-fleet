# Fleet.Pilot — domain card

**Date**: 2026-05-26
**Last revised**: 2026-09-04
**Status**: active — forge driver (client of the core)
**Referenced by**: —

Self-orchestration of Gitea issues (forge driver, `:pilot_step_dispatch?` off by default).
A **client of the core**, not the core: the forge IS the state machine (the route label engraved
on the issue), and this domain reacts to it — it discovers the fleet-org repos (`list_org_repos`, WS3),
spawns the current step's role, drives the PR review lifecycle, and escalates to the human
(architect) when a PR can no longer advance on its own.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Pilot.StepDispatcher` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules

**Reactor & dispatch**
- `Fleet.Pilot.Poller` — the reactor: discovers org repos each tick, reads the route, dispatches the step's role. Sub-modules `Poller.{Backoff, Lease, Reconciliation, Admission}` = tick timing / per-repo admission ceiling (`max_fan`, ENGAGED/QUEUED) / orphan-lock reconciliation / THE passage point of the two dispatch rails (issues and pulls).
- `Fleet.Pilot.PollerTelemetry` — the poller's telemetry, attached (BL-6-40).
- `Fleet.Pilot.StepDispatcher` — `decide/1` (pure gate) + `dispatch_issue/2` / `dispatch_review/2`. Sub-modules `{ProjectResolver, ArchEscalation, Spawn}` + `ReviewLifecycle{, .Ctx, .RoleDispatch, .Remediation, .CiGate, .VerdictException}` (the PR review lifecycle; `Ctx` = the review context struct built once in `dispatch_review/2`; `CiGate` = the CI verdict as a PRE-CONDITION of summoning the jury; `VerdictException` = one gatekeeper arbitration pass on a gray zone, before a human).
- `Fleet.Pilot.BriefBuilder` — the authority on brief FORMAT (worker / judge / rework / conflict).
- `Fleet.Pilot.PodReaper` — reaps the pods bound to a DEAD ticket (the `:mcp_pod_reaper` seam MCP injects).

**Step-run completion**
- `Fleet.Pilot.StepRunConsumer` — Bus consumer of step-run end (`pod.completed`). Sub-modules `{Verdict, GateEngine, GatekeeperEscalation, TerminalEscalation, TerminalEscalation.Seams, StepRunBuild, VerdictCorrection}` (`Seams` = the completer and notification dependencies an escalation carries; `VerdictCorrection` = ONE correction pass for a judge whose ENVELOPE is invalid, before freezing the ticket).
- `Fleet.Pilot.StepRunCompleter` — PR-native completion orchestrator (`complete_pr/2`). Sub-modules `{Texts, Emissions}`.
- `Fleet.Pilot.CompletionOutbox` — durable journal of the step_run completions still owed to the forge (6-127).
- `Fleet.Pilot.MergeAndPromote` — the SINGLE merge seal (`merge_and_promote/7`), shared by both merge points.
- `Fleet.Pilot.ConflictProbe` / `ConflictApply` / `ConflictReport` — the tier-0 conflict rail: impure probe preserving raw blob bytes, write path re-checking every file in an isolated worktree, and the diagnosis rendered for a human on the PR.

**Forge and project — other domains, driven from here**
- `Fleet.Forge` (`lib/fleet/forge/`, own card): the client and the wire protocol. The pilot DRIVES it and declares it as a dep; `Req` lives only there, so "one HTTP exit" is compiled, not a convention.
- `Fleet.Project` (`lib/fleet/project/`, own card): onboarding, card, roles, declaration, architect, worktrees. Imperative and called on demand — the opposite nature of this reactive rail.
- `Fleet.Pilot.MergeOutcome` — pure structural classification of a merge failure. Stays: it reads a forge failure to decide what the PILOT does next.

**Incidents & wake**
- `Fleet.Pilot.IncidentConsumer` — Bus consumer of pod-failure events (`pod.failed` / `wake.failed`) → `IncidentRegistry`.
- `Fleet.Pilot.IncidentRegistry` — persistent cross-session incident memory (GenServer + WAL + forge sync). Sub-module `Escalation` (the sysadmin issue).
- `Fleet.Pilot.ArchWake` — SINGLE authority for waking a project's architect on an `lcars-awaits-arch` escalation: the ordered offer-then-wake pair, shared by both rails.
- `Fleet.Pilot.ArchFeed` — Bus consumer appending one short line per fleet milestone into the PROJECT's architect pod (`<arch pod_dir>/fleet.feed`).
- `Fleet.Pilot.PodFeed` — the feed FILE primitive shared by both (name, `HH:MM` stamp, 200-line bound). The format has one owner; the log prefix stays with each facade's rail.
- `Fleet.Pilot.WakeRecovery` — hardening of `Spawner.wake_pod/1` (re-roll / escalate).

**Primitives (single-authority utils)**
- `Fleet.Pilot.Application` — supervisor; `step_status/0` exposes rail liveness (consumed by the api domain's readiness).
- `Fleet.PodId` — FOUNDATION, not this domain: the pod_id format is read by Spawner and Project, which sit below Pilot
- `Fleet.Pilot.Offload` / `IssueId` / `WorkflowMapNav` — supervised Bus offload, id formats, workflow-map nav (`Fleet.Forge.WriteSpacing`, the inter-write spacing, is the forge's). `Fleet.Opts` (foundation) — the opt idioms.

## Config & deps

- Boot: `:pilot_step_dispatch?` (default `false`; `LCARS_PILOT_STEP=true` starts the step rail — fail-loud on the forge `base_url`, the single required config). The full knob catalogue lives in `config/runtime.exs` + `etc/fleet.env.template` (the SSoT); each knob is read by the module named in its own `@moduledoc`.
- Deps (all descending): the truth is the `use Boundary` of `lib/fleet/pilot.ex` — notably workflow (workflow-map nav + gate briefs), spawner, credentials, cap_profile, task_queue, event_router. Upward runtime seams (config-injected, NOT compile deps): `:mcp_pod_reaper` (mcp → `Fleet.Pilot.PodReaper`), and readiness probed by api. `:mcp_forge_client` / `:mcp_project_onboard` are not upward: their targets `Fleet.Forge` and `Fleet.Project` sit below mcp.
- Not core: the core can be driven manually OR by pilot afterwards — decoupled by design.
