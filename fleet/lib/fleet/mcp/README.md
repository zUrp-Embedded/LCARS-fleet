# Fleet.MCP — domain card

**Date**: 2026-07-13
**Last revised**: 2026-09-04
**Status**: active — pod-facing MCP server, per-pod AF_UNIX socket (vendor boundary)
**Referenced by**: —

LCARS MCP server — vendor boundary `mcp_*`: wraps the `ex_mcp` SDK behind an
opaque contract and exposes the runtime's MCP tools to the pods over one AF_UNIX socket
per pod (identity IS the channel), system-side, outside bwrap.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.MCP.PodTools` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules
- `Fleet.MCP.PodTools` — pod-facing TOOL layer: the `deftool` schemas + `handle_tool_call/3` routing table (wrapped behind `use ExMCP.Server`); the domain entry point for the pod RPCs
  - `Fleet.MCP.PodTools.WorkItems` — work-item drive, every pod (`get_work_item` / `submit_result`)
  - `Fleet.MCP.PodTools.Probe` — `run_probe`: the judge ASKS for a measurement, never gets access; the rail executes, reads, returns a FACT
  - `Fleet.MCP.PodTools.ProjectPublish` — ASYNC worker behind the `project_publish` tool
  - `Fleet.MCP.PodTools.PodResolver` — the "identity of a pod" seam: ONE key, ONE default, ONE contract
  - `Fleet.MCP.PodTools.Delegation` — the delegation channels, architect only (the `issue_*`, `project_*`, `dependency_*`, `deposit_*`, `forge_*` verbs, `escalation_list`, `scratch`, `toolchain_request`, `card_list`, `catalogue_list`) + the `require_architect` gate. Sub-modules, one per channel:
    - `Delegation.Gate` — the authorization base of the channels, and the resolution of what an authorized pod may touch
    - `Delegation.Issues` — DELEGATION / TRACKING / READ: placing a ticket for the poller, reading back what happened
    - `Delegation.IssuePR` — finding the PR that belongs to an issue; refusing a gesture whose target state is wrong
    - `Delegation.Retirement` — taking a delegated ticket OUT: retired, superseded, or swept away
    - `Delegation.Dependencies` / `DependencyForge` — the dependency edges between delegated tickets, and the behaviour of the forge ops that write and read them
    - `Delegation.Escalations` / `EscalationForge` — the architect's inbox (tickets a producer handed back), and its inspectable forge seam
    - `Delegation.Portfolio` — ONBOARDING: what it takes for a project to exist on this machine
    - `Delegation.Deposits` — a project published as a deposit others can install
    - `Delegation.Workshop` / `Scratchpad` — the `workshop` face on disk, and the architect's running notes kept there
    - `Delegation.Toolchain` — a pod asks for a change to the fleet's own tooling, from inside the work
    - `Delegation.ForgeWriter` — the surface that writes CONTENT on the forge: branch, file, pull request
    - `Delegation.Render` — what the channels put in the map they hand back to the pod
    - `Delegation.ForgeClient` / `ProjectOnboard` — behaviours = contracts of the `:forge_client` / `:project_onboard` seams (defaults `Fleet.Forge.Client` / `Fleet.Project.Onboard`, both compile deps of mcp; the seam is an injection point for tests)
- `Fleet.MCP.Idempotency` — single-flight coordinator for MCP mutations: concurrent calls with one logical key collapse into one execution
- `Fleet.MCP.PodSocketAcceptor` — one AF_UNIX socket acceptor per pod (identity IS the channel; each connection served in its own Task)
- `Fleet.MCP.PodSocketSupervisor` — DynamicSupervisor of the acceptors + the spawner-facing seam API (`ensure_pod_socket` / `release_pod_socket`, paths)
- `Fleet.MCP.SocketWarden` — periodic reconciler of the per-pod socket footprints (acceptor/listener/Registry/file) against the live pods (2-tick grace)
- `Fleet.MCP.Server` — boot guard: refuses `start_link` on the pod side (`:forbidden_in_pod`)
- `Fleet.MCP.Supervisor` — domain supervision (`:one_for_one`); also starts the inline `PodSocketRegistry` (Registry) + `ConnectionTaskSupervisor` (Task.Supervisor); `pod_facing_status/0` = LIVE readiness probe consumed by `Fleet.API.Readiness`

## Config & deps
- **COMPILE-TIME** `:lcars_fleet, :mcp_socket_idle_timeout_ms` (300_000) and `:mcp_max_conns_per_pod` (8) — the two protection ceilings of `PodSocketAcceptor`, and the ONLY `Application.compile_env` of the whole `lib/`. Frozen into the compiled module: a runtime `put_env` is ignored, silently. No env var exposes them. Listed here BECAUSE they look like the knobs below and are not — `compile_env` buys the module-attribute use and the release boot check, which is why they stay frozen.
- Knob `:lcars_fleet, :mcp_sock_base` — read by `PodSocketSupervisor`, set by `runtime.exs` from `LCARS_FLEET_MCP_SOCK_BASE`.
- Knob `:lcars_fleet, :mcp_boot_environment` — read by `Server` (`:pod` → boot refusal).
- Knobs `:lcars_fleet, :mcp_pod_resolver` / `:forge_client` / `:project_onboard` / `:delegation_org` — read by `PodTools.Delegation` (runtime-dispatch seams + onboarded forge org).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/mcp.ex`).
