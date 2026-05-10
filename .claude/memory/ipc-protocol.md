# Inter-instance communication protocol

## Instances

| Instance | Role |
|---|---|
| `dev` | Code + commits on active project. No build, no toolkit. Escalates to starfleet + engineer. |
| `builder` | Cross-compile ARM64 or native x86-64 (--arch flag). Escalates to starfleet + engineer. |
| `qualifier` | Tests only (pytest, ctest). Reports PASS/FAIL. Manages test-queue.md. Escalates to starfleet + engineer. |
| `starfleet` | Orchestration, coordination. Writes directly to dev + qualifier when needed. Escalates to engineer. Does not modify LCARS. |
| `engineer` | Toolkit dev (LCARS). Can write to any worker channel operationally. Plans suffix: `-engineer`. |
| `architect` | Same scope as engineer. Interactive architect session only. Plans suffix: `-lead`. Does not intercept to-engineer.md. Cannot be auto-woken — absent from wake-instance.sh. |

Strict rule: **nothing implicit**. Each read/write channel is declared in the instance directives. Unlisted channels = prohibited.

## Handoff files

All in `/home/commons/`.

### Directional channels

| File | Writer(s) | Reader(s) | Session-startup injection |
|---|---|---|---|
| `to-build.md` | dev, starfleet, engineer | builder | yes (builder: full; starfleet: full) |
| `to-dev.md` | builder, qualifier, starfleet, engineer | dev | yes (dev: full; starfleet: full) |
| `to-qualifier.md` | dev, builder, starfleet, engineer | qualifier | yes (qualifier: full; starfleet: full) |
| `to-starfleet.md` | dev, builder, qualifier, engineer | starfleet | yes (starfleet: full) |
| `starfleet-notes.md` | starfleet | dev, builder, qualifier, engineer, architect | yes (all except starfleet) |
| `to-engineer.md` | dev, starfleet, builder, qualifier | engineer | yes (engineer only) |

Tag `[source]` mandatory in DONE entries for multi-writer channels.

### Routing matrix — who writes where

| | to-build | to-dev | to-qualifier | to-starfleet | starfleet-notes | to-engineer | bug-queue | test-queue | project-refs |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| dev | ✍ | — | ✍ ¹ | ✍ ² | — | ✍ ² | ✍ ✦ | — | ✍ |
| builder | — | ✍ | — | ✍ ² | — | ✍ ² | — | — | ✍ |
| qualifier | — | ✍ | — | ✍ ² | — | ✍ ² | — | ✍ ✦ | — |
| starfleet | ✍ ³ | ✍ ³ | ✍ ³ | — | ✍ | ✍ ² | — | — | ✍ |
| engineer | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | — | — | — | ✍ |
| architect | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | ✍ ⁴ | — | — | — | ✍ |

¹ dev → to-qualifier.md: triggers unit tests pre-commit
² escalation only (blocking issue, out-of-scope decision, toolkit problem)
³ starfleet → workers: direct instruction when a decision requires immediate action (not only starfleet-notes broadcast)
⁴ engineer → any: operational write (urgent fix, infra broadcast, contextualized instruction). deploy.sh covers normal interventions.
✦ read+write: dev manages bug-queue.md, qualifier manages test-queue.md

### State files (dashboard)

| File | Writer | Read by |
|---|---|---|
| `architect-handoff.md` | engineer | fleet-hub, fleet-monitor |
| `architect-handoff.md` | architect | fleet-hub, fleet-monitor |
| `dev-handoff.md` | dev | fleet-hub, fleet-monitor |
| `builder-handoff.md` | builder | fleet-hub, fleet-monitor |
| `qualifier-handoff.md` | qualifier | fleet-hub, fleet-monitor |
| `starfleet-handoff.md` | starfleet | fleet-hub, fleet-monitor |

### Shared files

| File | Writers | Usage |
|---|---|---|
| `bug-queue.md` | any | Pending bugs. dev resolves. |
| `test-queue.md` | qualifier | Test queue. qualifier manages. starfleet can read. |
| `qualifier-notes.md` | qualifier | QA broadcast notes (free format). |
| `project-refs.md` | any | Stable refs: IPs, SSH, build params, infra notes. |

Full file map (tmux layout, REST API): `/home/commons/fleet-files-map.md`.

## Bug queue

`/home/commons/bug-queue.md` — non-blocking bugs pending resolution.

Writers: any instance. Reader + resolver: dev only.
Format: `[ ] YYYY-MM-DD | source | platform | description — ref`
After fix: `[x]` + `— fixed: <commit>`. Trigger: dev writes bug-journal entry (docs/#11_bug-journal.md) same session, then removes `[x]` from queue.

## Source sharing

Bare git repos on `/home/commons/<project>/`. Dev pushes, builders pull.
Build on ext4 only (`/home/builder/`), never on 9P.

## Session start — mandatory

**Step 0 — before any read**: signal presence on dashboard.
```
fleet-state.sh action=startup status=in-progress ref=none blocker=none waiting=none notify=none
```

1. Read `project-refs.md` + relevant incoming handoffs.
2. Identify instance from MEMORY.md.
3. **Crash check**: scan own `<instance>-handoff.md` ACTIONS for `[x]` items.
   If found: action WAS completed but move-to-DONE was interrupted. Move to DONE now.
   Next `[ ]` after the `[x]` = where execution was interrupted before the crash.
4. No pending task: `fleet-state.sh action=idle status=done` / task found: `fleet-state.sh action=<task> status=in-progress`
5. Update both: `<instance>-handoff.md` + relevant directional file.

**Dashboard rule**: dashboard reads `<instance>-handoff.md` only. Update on every status change.

## Session end — mandatory

Before letting Claude Code terminate:
1. Move any remaining `[x]` items in ACTIONS to DONE (cleanup).
2. Call:
```
fleet-state.sh action=handoff status=offline blocker=none waiting=none notify=none
```
Confirms clean session end on dashboard (no silent crash).
Add `## DONE` entry before this call if significant work was completed.

## File format

### STATE block — always overwrite, exactly 7 fields
```
date: YYYY-MM-DD HH:MM    ← real timestamp only
ref: <commit hash or branch>
action: code | build | deploy | validate | idle | handoff
status: pending | in-progress | blocked | done | offline
blocker: <reason or "none">
waiting: <what this instance waits for, or "none">
notify: architect | <instance-name> | none
```
`notify: architect` → herald.sh.  `notify: <instance>` → wake-instance.sh auto-wake.

### ACTIONS block
```
[ ] pending action — context
```
**Rule**: move to DONE **immediately** on completion — never leave `[x]` in ACTIONS.
`[x]` at startup = action was done but move-to-DONE was interrupted (crash during cleanup).
The next `[ ]` after the `[x]` = execution point where the crash occurred.

### BACKLOG block
Tasks blocked on **external dependency** (missing hardware, human decision, external event).
Not counted as pending by dashboard. Format: `[ ] YYYY-MM-DD | description — reason`.
Transition BACKLOG → ACTIONS: manual, when unblocked. Never put fleet-internal blocks here (use `status: blocked`).

### DONE block
Newest-first. Max 5 entries (archive older to `#9_archives/YYYYMMDD-<instance>.md`).
`status: offline` + `action: handoff` = clean session end.

## Protocol: builder → starfleet

When a builder is blocked on an out-of-scope decision:
```
1. Builder writes question in to-starfleet.md (## ACTIONS)
2. Builder handoff STATE: waiting: <topic>, notify: starfleet
   (fleet-monitor detects none → starfleet transition)

3. fleet-monitor → wake-instance.sh starfleet "[auto-wake] builder waits: <topic>..."
   → tmux send-keys → starfleet receives message

4. StarFleet reads to-starfleet.md, analyzes
   (if non-trivial → notify: architect for human validation)
   Writes response in starfleet-notes.md
   starfleet handoff STATE: notify: builder

5. fleet-monitor → wake-instance.sh builder "[auto-wake] starfleet replied..."
   → builder resumes

6. Builder resets: notify: none, waiting: none → continues build
```
**Reset rule**: after recipient processes, sender resets `notify: none` + `waiting: none` in own handoff.

## Protocol: worker → engineer (escalation)

Workers (dev, qualifier, builders) write directly to `to-engineer.md` for toolkit/infra issues:
```
1. Worker writes issue in to-engineer.md (## ACTIONS), fleet-notify.sh engineer
2. Worker handoff STATE: waiting: <topic>, notify: engineer

3. engineer reads to-engineer.md, analyzes
   Implements directly or writes back in to-engineer.md (## DONE)
   engineer handoff STATE: notify: <worker>

4. fleet-monitor → wake-instance.sh <worker> "[auto-wake] engineer replied..."
   → worker resumes

5. Worker resets: notify: none, waiting: none
```
StarFleet may also escalate on behalf of a worker — same channel, same format.

## Protocol: starfleet → builder directive

Before waking a builder, starfleet must verify the directive is **executable** by a Haiku builder.

**Executable**: script already committed in project repo or `~/fleet/` (post-deploy). Task = git pull + cmake/make/ninja + artifact.
**Not executable**: requires writing code (>15 lines) → delegate to dev or engineer (toolkit). Wait for commit. Wake builder only after script is available.

A builder receiving an implementation directive will call `fleet-blocker.sh "out-of-scope"` and close — this behavior is **correct and expected**.

## Lock limitation

**Decision 2026-03-04**: `handoff-lock-acquire.sh` and `handoff-lock-release.sh` removed from the repo. Rationale: lock used `/tmp/handoff-locks` (ext4, local per WSL instance) — no cross-instance protection. Overhead on every Edit/Write not justified for single-builder-active design.

Cross-instance protection: drvfs/9P filesystem atomicity via `sed ... > .tmp && mv .tmp file` (used in `fleet-state.sh`, `fleet-inject.sh`).

## Fleet maintenance — starfleet

Executed automatically at starfleet session start (via `session-startup.sh`):

**Backup** (`backup-wsl.sh`): timestamped snapshot of non-versioned files (`handoff/`, `settings.local.json`, `memory/`). Summary shown in startup context.

**Trim** (`handoff-trim.sh`): purges handoff files >1400 B to prevent DONE accumulation. Exempt: `starfleet-notes.md`, `to-engineer.md`, `project-refs.md`, `bug-queue.md`, `fleet-files-map.md`.

**UTF-8** (`handoff-check-utf8.sh`): detects drvfs 9P multi-byte corruption. Logs to stderr, non-blocking. Runs on all instances.

## Decommissioning

StarFleet writes `status: decommissioned` in the instance handoff. `session-startup.sh` injects absolute HALT — no tools, no commands. HALT overrides all other instructions. Lordzurp then runs `wsl --unregister`.
