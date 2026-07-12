# fleet_mcp

**Date** : 2026-07-13
**Dernière révision** : 2026-07-12 (en-tête déclaratif LCARS ajouté — uniformisation acte3 vague A ; carte co-localisée `lib/fleet/<dom>/` depuis le collapse)
**Statut** : actif — serveur MCP pod-facing, socket AF_UNIX per-pod (Ring 2, frontière vendor)
**Référencé par** : `04_design-notes/fleet_mcp.md`

LCARS MCP server (Ring 2) — vendor boundary `mcp_*`: wraps the `ex_mcp` SDK behind an
opaque contract and exposes the runtime's MCP tools to the pods over one AF_UNIX socket
per pod (identity IS the channel), system-side, outside bwrap.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.MCP.PodTools` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules
- `Fleet.MCP.PodTools` — pod-facing TOOL layer: the `deftool` schemas + `handle_tool_call/3` routing table (wrapped behind `use ExMCP.Server`); the app entry point for the pod RPCs
  - `Fleet.MCP.PodTools.WorkItems` — work-item drive, every pod (`get_work_item` / `submit_result`)
  - `Fleet.MCP.PodTools.Delegation` — forge delegation, architect only (`create_issue` / `create_project` / `import_project` / `get_issue_status`) + the `require_architect` gate
  - `Fleet.MCP.PodTools.Delegation.ForgeClient` — behaviour = contract of the `:forge_client` runtime seam (up-seam to `fleet_pilot`)
  - `Fleet.MCP.PodTools.Delegation.ProjectOnboard` — behaviour = contract of the `:project_onboard` runtime seam (up-seam to `fleet_pilot`)
- `Fleet.MCP.PodSocketAcceptor` — one AF_UNIX socket acceptor per pod (identity IS the channel; each connection served in its own Task)
- `Fleet.MCP.PodSocketSupervisor` — DynamicSupervisor of the acceptors + the spawner-facing seam API (`ensure_pod_socket` / `release_pod_socket`, paths)
- `Fleet.MCP.Server` — boot guard: refuses `start_link` on the pod side (`:forbidden_in_pod`)
- `Fleet.MCP.Supervisor` / `Fleet.MCP.Application` — app supervision (`:one_for_one`); also starts the inline `PodSocketRegistry` (Registry) + `ConnectionTaskSupervisor` (Task.Supervisor); `pod_facing_status/0` = LIVE readiness probe consumed by `Fleet.API.Readiness`

## Config & deps
- Knob `:fleet_mcp, :sock_base` — read by `PodSocketSupervisor`, set by `runtime.exs` from `LCARS_FLEET_MCP_SOCK_BASE`.
- Knob `:fleet_mcp, :boot_environment` — read by `Server` (`:pod` → boot refusal).
- Knobs `:fleet_mcp, :pod_resolver` / `:forge_client` / `:project_onboard` / `:delegation_org` — read by `PodTools.Delegation` (runtime-dispatch seams + onboarded forge org).
- Deps: see `mix.exs`.
