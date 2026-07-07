# Fleet.TaskQueue

**Date**: 2026-06-01
**Last revised**: 2026-07-07 (translated to EN. Previous resync 2026-07-05 against the code: ring 1, ephemeral broker in prod, full API — `pod_active_issue_id`/`last_poll`, real flow, Configuration section; Server split → Store + Broadcast)
**Status**: implemented (initial build commit `f971d2b3`)
**Derived from**: DN `orchestration/task-queue` §C

LCARS cross-pod orchestration broker (Ring 1). **A single writer** (GenServer),
work-item distribution/collection, **event-driven** completion. Replaces the in-mem stub
`Fleet.MCP.TaskQueue` (since removed, commit `58cf8d89`).

**Single-source AXIOM**: the forge is the truth of the work (issues/routes/PR); the broker is
only its FRONT in RAM. In prod it runs **EPHEMERAL** (`persist: false`, set by
`Fleet.TaskQueue.Application`): no `state.json` written, no stale persisted tasks
cross-reboot — on restart the queue re-derives itself from the forge polls. Store persistence
remains an **opt-in** mechanism (tested) for a future broker-only-durable state, nonexistent to
date.

Flow: `fleet_spawner` (`Pod.Brief`) and `fleet_pilot` (StepDispatcher / gatekeeper escalation, seam
`:task_queue`) **enqueue** (sources) → `fleet_task_queue` distributes/collects (broker) →
`fleet_mcp` serves the pods via the `get_work_item`/`submit_result` tools (vendor boundary) →
`fleet_pilot` (`StepRunConsumer`) consumes `work_item.completed` post-result.

## Sub-modules

- `Fleet.TaskQueue` — public API facade. Every function has a test-seam variant (explicit `server`, e.g. `enqueue/3`) for isolation via an anonymous server (`name: nil`).
- `Fleet.TaskQueue.Server` — the broker GenServer (a single writer; command/query; per-task deadline; **bounded retention** of terminal tasks, knob `:retention_terminal_max` default 500). Per-instance options: `:name` (nil = anonymous, tests), `:state_path`, `:persist`, `:topic`, `:bus` (seam), `:retention_terminal_max`. Keeps the ORCHESTRATION of persistence and broadcast (when to persist, which broadcast regime); the mechanics live in the two modules below. The deadline-watchdog and retention/prune stay INSIDE the Server (extraction refusals argued in the moduledoc: timer pair coupled to the process, 20-LOC prune sharing the `@active_states` authority).
- `Fleet.TaskQueue.Store` — `state.json` persistence (serialization + FS, no GenServer state): atomic tmp+rename write v:1 best-effort logged error, fail-loud read `{:corrupt, _}` (never a silent drop), `default_path/0` (config `:state_path`, default `~/.lcars/task-queue/state.json` — unresolvable HOME = fail-loud). Inert in prod as long as the broker boots `persist: false`.
- `Fleet.TaskQueue.Broadcast` — broadcast policy (no GenServer state): `best_effort/3` (observability, failure swallowed + logged) vs `required/3` (lifecycle `work_item.completed`, failure propagated `{:error, {:broadcast_failed, _}}`) + canonical envelope `event/3`. Outside `Bus.safe_emit` (the per-instance `:bus`/`:topic` seams must carry both paths; same exclusion as `Fleet.Spawner.Pod.Events`).
- `Fleet.TaskQueue.WorkItem` — task struct + `to_map/1` / `from_map/1` (state.json serialization).
- `Fleet.TaskQueue.Application` — supervisor (starts the named `Server` **with `persist: false`** — the ephemeral prod mode, cf. AXIOM above; `:one_for_one`, 3/60).

## Public API (`Fleet.TaskQueue`)

- `enqueue/2` `(pod_id, attrs)` — pushes a work item (`%{brief, role, issue_id, deadline, metadata}`). Source. Generates `id` (UUID v4 = correlation_id).
- `get_for_pod/1` `(pod_id)` — returns the pod's active work item (**idempotent**: survives `/clear` / re-`get`).
- `submit_result/2` `(pod_id, result)` — delivers (**idempotent**: double submission ignored). The `result` carries the `work_item_id` of the work item being closed (correlator): ≠ the pod's active work item → `:work_item_id_mismatch` rejection, no mutation. This is the 2nd anti-impersonation lock after channel-borne identity on the `fleet_mcp` side (per-pod AF_UNIX socket — the old capability of the shared HTTP transport is REMOVED along with it): a pod can only close EXACTLY its own active work item, never "another pod's latest active" (on the `fleet_mcp` side, `submit_result` makes this `work_item_id` **MANDATORY**). The `work_item_id` is a transport correlator → **removed from the stored/broadcast `result`** (no pollution of the business deliverable). The `work_item.completed` broadcast is lifecycle load-bearing → a broadcast failure returns `{:error, {:broadcast_failed, _}}` (NOT a mute `:ok`; the step_run would never finish).
- `list_pending/0` — pending work items.
- `list_active/0` — ACTIVE work items (`:pending`/`:assigned`/`:in_progress`, `@active_states` authority). Consumed by the poller's lock reconciliation: a work unit under an active gatekeeper eval is owned; a `:cleared` (superseded) or `:completed` eval no longer is. Query.
- `clear_for_pod/1` `(pod_id)` — purges a pod's work item (and forgets its last-poll: the clear decommissions the pod, so its entry in the internal `polls` map must not survive).
- `pod_status/1` `(pod_id)` — current state on the broker side.
- `pod_active_issue_id/1` `(pod_id)` — issue of the pod's LAST task (covers `:completed` = the submit → push publication window). Serves the poller (slot-freeze): a project-scoped PIPE engineer (`<repo>-engineer`, without `-issue-N-`) does not carry its work unit in its pod_id — the lock is derived from its task. Query.
- `last_poll/1` `(pod_id)` — the pod's last `get_for_pod` (`DateTime | nil`) = **in-band ACK** (the agent is up + armed, even without a work item). In-mem, never persisted; purged by `clear_for_pod`. Consumed by the ack-driven wake loop (`Fleet.Spawner.Pod.TaskProbe` tests PRESENCE alone). Query.

(`*/N+1` variants with explicit `server` = test-seam.)

## Invariants

- **One active work item per pod**, held AT WRITE time: a fresh enqueue **supersedes** EVERY active item of the pod (`supersede_active` — every active, `:pending` included, transitions to `:cleared`; the old work item's `submit_result` then hits `:no_active_work_item`/`:double_submit_ignored`, never a mutation of the new one); `clear_for_pod` purges ALL actives. The wake of a long-lived pod therefore receives the single current work item (the fresh one replaces the old). `find_active` (`enqueued_at` DESC sort) remains the read but no longer masks stale items: by construction there is at most 1 active/pod.
- **Event-driven completion**: emits `%Fleet.Event{source: :task_queue}` on the `fleet.events` topic of the `Fleet.PubSub` PubSub, `correlation_id = work_item.id`. The 6 events: `work_item.enqueued`/`assigned`/`completed`/`cleared`/`failed` (deadline) + `state.corrupt` — `completed` alone is load-bearing (`Broadcast.required`), the rest best-effort. No more string-topic, no more file polling.
- **Bounded retention**: terminal tasks (`:completed`/`:failed`/`:cleared`) are pruned beyond `:retention_terminal_max` (default 500, most recent kept) → in-memory `work_items` and `state.json` are bounded. **Active** tasks are never pruned; a just-completed task (the most recent) survives → double-submit detection (`has_completed?`) stays correct.

## Configuration (`:fleet_task_queue`)

- `:retention_terminal_max` — bound on the terminal tasks kept (default 500; also overridable per-instance via the `Server.start_link/1` opt).
- `:state_path` — path of `state.json` (default `~/.lcars/task-queue/state.json`; env `LCARS_STATE_PATH` in `config/runtime.exs`). No effect in prod as long as the broker boots `persist: false`.

## Dependencies

- `fleet_event_router` (in_umbrella) — `%Fleet.Event{}` + the bus.
- `phoenix_pubsub`, `jason`, `uuid` (work items' UUID v4). `stream_data` (test).
