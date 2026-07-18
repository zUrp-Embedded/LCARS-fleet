# fleet_task_queue

**Date**: 2026-07-13
**Last revised**: 2026-07-18
**Status**: active — get_work_item/submit_result work-item broker
**Referenced by**: —

Cross-pod orchestration broker (pod primitive): a single-writer GenServer that distributes work
items to pods and collects their results, event-driven completion. Ephemeral in prod — the
forge is the source of truth, the broker is only its RAM front (`persist: false`).

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.TaskQueue` in IEx, or `lib/`). Nothing here is restated,
only pointed at.

## Modules
- `Fleet.TaskQueue` — public-API facade (`enqueue`/`get_for_pod`/`submit_result` + queries); every fn has a test-seam variant (explicit `server`)
- `Fleet.TaskQueue.Server` — the broker GenServer (single writer; per-task deadline watchdog; bounded terminal-task retention; persistence + broadcast orchestration). Watchdog and prune kept in-Server on purpose (extraction refusals argued in its `@moduledoc`)
- `Fleet.TaskQueue.Store` — `state.json` persistence (atomic write, write failure logged error and non-fatal — the forge is the truth, re-derived by its polls; fail-loud `:corrupt` read); inert in prod while `persist: false`
- `Fleet.TaskQueue.Broadcast` — broadcast policy: lossy `lossy/3` (observability) vs `required/3` (load-bearing `work_item.completed`); deliberately outside `Bus.safe_emit`
- `Fleet.TaskQueue.WorkItem` — the task struct + `to_map/1`/`from_map/1` (state.json serialization); `id` = the canonical `correlation_id`
- `Fleet.TaskQueue.Application` — supervisor; boots the named `Server` with `persist: false` (the ephemeral prod mode)

## Config & deps
- Knob `:fleet_task_queue, :retention_terminal_max` — read by `Server` (default 500; per-instance override via `Server.start_link/1`).
- Knob `:fleet_task_queue, :state_path` — read by `Store`/`Server`, set by `runtime.exs` from `LCARS_STATE_PATH` (no effect while the broker boots `persist: false`).
- Deps: see `mix.exs`.
