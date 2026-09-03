# Fleet.TaskQueue — domain card

**Date**: 2026-07-13
**Last revised**: 2026-09-04
**Status**: active — get_work_item/submit_result work-item broker
**Referenced by**: —

Cross-pod orchestration broker (pod primitive): a single-writer GenServer that distributes work
items to pods and collects their results, event-driven completion. **Ephemeral, period** — the
forge is the source of truth, the broker is only its RAM front. No state file, no recovery
constructor, no knob to turn one on (BL-6-113).

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.TaskQueue` in IEx, or `lib/`). Nothing here is restated,
only pointed at.

## Modules
- `Fleet.TaskQueue` — public-API facade (`enqueue`/`get_for_pod`/`submit_result` + queries); every fn has a test-seam variant (explicit `server`)
- `Fleet.TaskQueue.Server` — the broker GenServer (single writer; per-task deadline watchdog; bounded terminal-task retention; broadcast orchestration). Watchdog and prune kept in-Server on purpose (extraction refusals argued in its `@moduledoc`)
- `Fleet.TaskQueue.Broadcast` — broadcast policy: lossy `lossy/3` (observability) vs `required/3` (load-bearing `work_item.completed`); deliberately outside `Bus.safe_emit`
- `Fleet.TaskQueue.WorkItem` — the task struct + `new/2`, its ONE validated construction path; `id` = the canonical `correlation_id`
- `Fleet.TaskQueue.Application` — supervisor; boots the named `Server`

## Config & deps
- Knob `:lcars_fleet, :task_queue_retention_terminal_max` — read by `Server` (default 500; per-instance override via `Server.start_link/1`).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/task_queue.ex`).
