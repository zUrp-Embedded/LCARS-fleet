# test/ — map

**Date**: 2026-07-18
**Last revised**: 2026-07-18
**Status**: active — index of the test tree (a map, not a contract)
**Referenced by**: —

**This file is a map, not the contract.** Each test file owns its intent in its own
`@moduledoc`/describes. Nothing here is restated, only pointed at.

## Layout

- `test/fleet/<domain>/` — one directory per lib domain (`foundation` modules test at
  `test/fleet/*_test.exs` top level, e.g. `slug_test.exs`). A domain's tests live WITH
  the domain — if you cannot find a test, grep the FUNCTION name, not a guessed filename.
- `test/*.exs` (root) — cross-domain/integration surfaces: `pod_tools_test.exs` +
  `pod_socket_test.exs` (MCP pod-facing wire), `cap_profile_v25_conformance_test.exs` +
  `monks_v25_conformance_test.exs` (canon conformance), `events_schema_test.exs` /
  `coord_policies_schema_test.exs` / `intensity_schema_test.exs` (priv schemas),
  `mcp_server_test.exs` / `mcp_supervisor_test.exs` / `poc_exmcp_native_test.exs` (MCP SDK
  boundary), `clone_test.exs` (project_bootstrap), `result_event_test.exs`.
- `test/support/<domain>/` — stubs/TestEnv, compiled via `elixirc_paths(:test)`.
- OUT-of-mix (run by `shell_gate` inside `mix gate`, invisible to `mix test`):
  `test/test_fleet_mcp_stdio_bridge.py` (MCP stdio bridge) and the launcher bats suites
  under `test/bwrap_launch/` + `test/claude_launch/`.

## Conventions that trip greppers

- **Admission pipelines are tested THROUGH their routers**, not in standalone files:
  `Fleet.API.SpawnAdmission` is covered by `test/fleet/api/control_router_test.exs`
  (socket bind + DTO + verdict→HTTP mapping). There is no `spawn_admission_test.exs` —
  do not create a twin; extend the router test.
- **The transverse reading entry point** is `test/fleet/pilot/chain_integration_test.exs`
  (real modules against a simulated forge, synchronous) — the executable specimen of the
  5-phase narrative in `Fleet.Pilot`'s @moduledoc.
- **Hermeticity is the baseline** (`config/test.exs`): no real socket (REST via
  `Plug.Test`, WS via direct callbacks), no real spawn (StubBackend), consumers off,
  `load_event_registry: false`. A test needing a real backend starts it itself
  (`start_supervised` with explicit opts) — never flips global config.
- **Regression anchors** (`F-…`, `DR-…`, `G…`, `WS…`, `MA-…`) in test/describe names are
  the LIVING side of the lib anchors — they correlate a test to the mechanism it locks.
  Keep them when touching a test; the prose around them stays present-tense.
- **Expected values pinning FR runtime output** (forge bodies, briefs, dashboard strings)
  stay FR — they test user-facing content that is FR by design. Test prose itself is EN.
