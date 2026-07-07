# fleet_mcp

**Date**: 2026-05-18
**Last revision**: 2026-07-07 (contract resync against the code: ring 2, PodSocketRegistry + readiness probe documented, delegation knobs added; PodTools split → WorkItems + Delegation, dispatch kept)
**Status**: implemented — pod-facing MCP server (`get_work_item` / `submit_result`)
**Referenced by**: `04_design-notes/` (ring4/fleet_mcp)

LCARS MCP server (Ring 2) — vendor boundary `mcp_*`: wraps the `ex_mcp` SDK
behind an opaque contract and exposes the runtime's MCP tools to the pods.

## Modules

- `Fleet.MCP.PodTools` — the **routing table** of the pod-facing MCP tools: `deftool`
  schemas + `handle_tool_call/3` dispatch (argument guards, typed refusals
  `:invalid_arguments`/`:pod_id_required`/`:project_required`, MCP content format
  `json`/`text`). Pure functions, reusable outside the transport; the pod's identity arrives
  through the `state` (`%{pod_id: ...}`), never through the arguments. Stays wrapped behind
  `use ExMCP.Server` for the `deftool` / `json` / `text` DSL. The domain logic lives in two
  sub-modules with disjoint consumers:
  - `Fleet.MCP.PodTools.WorkItems` — work-item drive (every pod): `get_work_item` (the pod
    pulls its brief from the TaskQueue), `submit_result` (the pod returns its deliverable,
    MANDATORY `work_item_id` correlator + mapping of the typed refusals).
  - `Fleet.MCP.PodTools.Delegation` — forge delegation (architect only): `create_issue`
    (the arch delegates an implementation), `create_project` (the arch onboards a fresh
    project), `import_project` (the arch imports an EXISTING repo, without touching `main`),
    `get_issue_status` (the arch tracks a delegation) + the common `require_architect` gate.
- `Fleet.MCP.PodSocketAcceptor` — acceptor of **one** AF_UNIX socket per pod. One pod = one
  process = one socket: every line received comes from THIS pod (its `pod_id` is the acceptor's
  immutable state, carried at startup). Decodes the newline-framed JSON-RPC and dispatches the
  `tools/call` to `PodTools.handle_tool_call/3`. **Each accepted connection is served in its
  own `Task`** (via `Fleet.MCP.ConnectionTaskSupervisor`, socket handed over by
  `controlling_process`) and the acceptor re-`accept`s immediately: a slow handler (e.g. a
  hanging forge call) does NOT freeze the pod — the following connections are served in
  parallel, not stuck in the kernel backlog (otherwise `readline` timeout on the bridge side,
  cf. the "accepteur CONCURRENT" test). Wire contract: 1 MiB line buffer (a longer line arrives
  truncated); invalid JSON line → `-32700` response + warning, NEVER silently swallowed;
  `tools/call` > 5 s logged SLOW (server-side forensics).
- `Fleet.MCP.ConnectionTaskSupervisor` — `Task.Supervisor` (`restart: :temporary`,
  `max_children: 32`) of the connection workers, one per accepted connection. Separates the
  SERVICE of a connection (potentially slow) from the `accept` LOOP; the bound refuses (logged)
  the excess connection of a leaking bridge, instead of accumulating tasks+FDs without limit.
- `Fleet.MCP.PodSocketRegistry` — single Registry (key = `pod_id` → acceptor, `:via` names):
  idempotent resolution of the acceptors, started BEFORE the DynamicSupervisor that registers
  into it.
- `Fleet.MCP.PodSocketSupervisor` — DynamicSupervisor of the acceptors (one-per-pod fan-out) +
  lifecycle API for the spawner (`ensure_pod_socket` / `release_pod_socket`) +
  `base_dir/0`/`socket_path/1` (paths).
- `Fleet.MCP.Server` — **boot guard** (containment invariant): `start_link/1` refuses
  (`{:error, :forbidden_in_pod}`) if `boot_environment == :pod` → `fleet_mcp` never boots
  on the pod side. The former husk API `register_channel`/`list_channels` (push channel) is
  **removed** (dead, 0 prod callers).
- `Fleet.MCP.Supervisor` / `Fleet.MCP.Application` — supervision of the app (`:one_for_one`,
  `max_restarts: 3` / `max_seconds: 60`). `Fleet.MCP.Supervisor.pod_facing_status/0` = LIVE
  state of the pod-facing substrate for readiness (consumed by `Fleet.API.Readiness`): probes
  the REAL process + the socket files on disk (anti hollow-green: more socket files than live
  acceptors = deaf pods → `:degraded`, never a config-green).

## Pod identity — the identity IS the channel

The pod-facing transport is **one AF_UNIX socket per pod**: each pod has its own, mounted
into its sole sandbox. So "which socket receives" = "which pod" — the `pod_id` is carried
by the acceptor (from the socket name), it is **never** read off the wire. There is nothing
left to prove: no capability to present, no `pod_id` to compare. A pod cannot read another
pod's brief nor close its task, by **construction** (it does not have the other socket) —
even a `_lcars_pod_id` forged in the arguments is ignored (the central reads `state.pod_id`).

> Context: the former HTTP loopback transport was SHARED by all pods → the `pod_id` was
> guessable there (deterministic `<repo>-issue-<n>-<role>`), hence a per-pod **capability**
> (256-bit secret verified server-side) to close the impersonation hole. The per-pod socket
> makes that capability useless: the channel discriminates. HTTP loopback + capability **removed**.

`handle_tool_call/3` reads `state.pod_id` directly for `get_work_item`/`submit_result`. A `pod_id`
absent from the state = acceptor anomaly → `:pod_id_required` (fail-closed, never anonymous access).

## Socket API (seam `fleet_spawner → fleet_mcp`)

`Fleet.MCP.PodSocketSupervisor` exposes to the spawner:

- `ensure_pod_socket(pod_id) :: {:ok, socket_path} | {:error, _}` — starts this pod's
  acceptor (creates the listener + the socket file) and returns the **host path**. Idempotent
  (re-call = same path, no duplicate). The file exists on return (the bwrap bind would fail
  otherwise).
- `release_pod_socket(pod_id) :: :ok` — stops the acceptor AND **`File.rm`**s the socket file
  (closing the socket frees the FD, NOT the file → leak otherwise). Idempotent.

Path: `<base>/<pod_id>/sock` (`base` = config `:sock_base`, default `/run/lcars/mcp`). The
per-pod dir + the short filename keep the path under the `sun_path` limit (108 bytes) — same
structure as the pods' tmux socket-dir.

## Architect authorization — privileged tools (server-side gate)

`create_project`, `import_project`, `create_issue` and `get_issue_status` are **architect** acts:
creating/importing a forge repo, writing/pushing into `/home/projects`, delegating, tracking a
delegation. The `require_architect/1` guard (in `Fleet.MCP.PodTools.Delegation`, applied BEFORE any
forge mechanics) resolves the **role** from the channel identity (`state.pod_id` → Spawner
registry, `Fleet.Spawner.pod_info`, test seam `:pod_resolver`) **then** requires `architect`. The
role comes from the spawn, never from a wire field. Any other role (engineer, reviewer, nil/unknown
role) → `{:error, :forbidden_not_architect}`; pod absent from the registry → `:pod_unknown`;
state without pod_id → `:pod_id_required`. Fail-closed: no case falls back onto an authorized access.

## MCP tools (pod-facing)

- `get_work_item` — the pod fetches its brief (correlated to the channel's `pod_id`).
- `submit_result` — the pod submits its deliverable (`payload`); **`work_item_id` MANDATORY** = the `work_item_id`
  returned by `get_work_item` (the broker correlates on THIS specific brief, never on the pod's "most recent
  active" — a lock orthogonal to the transport). work_item_id absent → `:work_item_id_required`; ≠ active brief → `:work_item_id_mismatch`.
- `create_issue` (delegation, **architect only**) — creates the forge issue **ready for the poller**
  (`Fleet.Pilot.ForgeClient.create_issue`, runtime dispatch). `require_architect` gate. Fail-closed:
  worker → `:forbidden_not_architect`; unknown pod → `:pod_unknown`; role token absent →
  `:role_token_unavailable` (never as system). author=arch (role-account token), **assignee=human**
  owner (OS login), then **STOP** (the poller takes over). Test seams: `:forge_client`, `:pod_resolver`.
- `create_project` (onboarding, **architect only**) — `Fleet.Pilot.ProjectOnboard.onboard/2`
  (forge repo + dual-worktree `main`/`work/ops` + scaffold + push). `require_architect` gate **before**
  any creation/write. The created repo is RETURNED in the result (`repo`/`delegation_target`) → the arch
  passes it explicitly to `create_issue`/`get_issue_status`. Test seams: `:project_onboard`, `:pod_resolver`.
- `import_project` (**architect only**) — `Fleet.Pilot.ProjectOnboard.import/2` (EXISTING repo:
  SAME dual-worktree/gate, but `main` stays INTACT — no creation/scaffold). `require_architect` gate.
  Fail-loud preconditions on the `ProjectOnboard` side (already in the org, default branch `main`). `full_name`
  = `"owner/name"`. Same return contract as `create_project` (`status: "imported"`). Test seams:
  `:project_onboard`, `:pod_resolver`.
- `get_issue_status` (tracking, **architect only**) — reads the state of an issue (issue + PR) of the repo
  passed as `project` (**REQUIRED**; without it → `:project_required`, never state read on the wrong project).
  `require_architect` gate. Read-only (`ForgeClient`). Test seams: `:forge_client`, `:pod_resolver`.

NB **stdio bridge** (`bin/fleet_mcp_stdio_bridge.py`): serves `initialize`/`tools/list` locally and
forwards each `tools/call` to the central. Its tool surface (`TOOLS`, derived from the role) stays a
manual mirror of the central's schemas. The wiring of the bridge to the per-pod socket (and the spawner
provisioning `ensure_pod_socket`) lives in the adjacent sub-block, NOT here.

## Configuration

- `:fleet_mcp, :sock_base` — root of the pod-facing sockets (default `/run/lcars/mcp`; overridden
  by the env `LCARS_FLEET_MCP_SOCK_BASE` in `config/runtime.exs` — the fleet is launched by a human,
  `/run/lcars` is not writable without privilege → base under their home).
- `:fleet_mcp, :boot_environment` — environment injected at server boot (`:pod` → refusal).
- `:fleet_mcp, :pod_resolver` — test seam: `pod_id → {:ok, %{role: role}}`. Default = runtime dispatch
  to `Fleet.Spawner.pod_info/1`.
- `:fleet_mcp, :forge_client` — seam: forge client (default `Fleet.Pilot.ForgeClient`, runtime
  dispatch — no compile-time dep on fleet_pilot).
- `:fleet_mcp, :project_onboard` — seam: project onboarding sequence (default
  `Fleet.Pilot.ProjectOnboard`, runtime dispatch).
- `:fleet_mcp, :delegation_org` — forge org of the onboarded projects (default `"fleet"`).

## Vendor boundary

`mcp_*` = N1: the `ex_mcp` SDK is wrapped behind `Fleet.MCP.PodTools`
(`use ExMCP.Server`, tools `get_work_item`/`submit_result`) for the schemas + the content format.
The pod-facing **transport** is a per-pod AF_UNIX socket driven in raw `:gen_tcp`
(`Fleet.MCP.PodSocketAcceptor`) — ExMCP does not provide a per-pod socket; switching the
schema SDK (Hermes) is possible without touching the consumers.
