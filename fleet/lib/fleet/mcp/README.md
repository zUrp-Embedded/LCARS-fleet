# Fleet.MCP — domain card

**Date**: 2026-07-13
**Last revised**: 2026-08-14
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
  - `Fleet.MCP.PodTools.Delegation` — forge delegation, architect only (`issue_create` / `project_create` / `project_install` / `issue_status` / `list_escalations` / `issue_comment`) + the `require_architect` gate
  - `Fleet.MCP.PodTools.Delegation.ForgeClient` — behaviour = contract of the `:forge_client` runtime seam (up-seam to pilot)
  - `Fleet.MCP.PodTools.Delegation.ProjectOnboard` — behaviour = contract of the `:project_onboard` runtime seam (up-seam to pilot)
  - `Fleet.MCP.PodTools.Delegation.EscalationForge` — behaviour = contract of the escalation-read seam (`list_escalations` backend)
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
