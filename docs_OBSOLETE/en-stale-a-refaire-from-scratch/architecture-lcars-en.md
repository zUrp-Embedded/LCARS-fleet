<a id="top"></a>

> 🇫🇷 [Version française](../#01_architecture-lcars.md)

# Architecture LCARS Fleet

_Technical reference: instances, IPC, orchestrator, design principles._

**Sections** — [⚙️ Overview](#vue-densemble) · [🤖 Instances](#instances-roles-perimetres) · [📡 IPC](#ipc-canaux-routage) · [📊 STATE](#state) · [⚡ ACTIONS](#actions) · [✅ DONE](#done) · [🎯 Fleet orchestrator](#fleet-orchestrator) · [🚀 Provisioning](#provisioning) · [🎨 Design principles](#principes-de-conception) · [📋 Checklist](#ajouter-une-instance) · [🔬 cDs](#cds)

---

<a id="vue-densemble"></a>
## ⚙️ Overview

*Topology of the WSL2 multi-instance system and the role of the passive orchestrator.*

LCARS Fleet is a WSL2 multi-instance system where each Claude Code instance has a precise role and communicates via shared markdown files. The orchestrator (fleet-hub + fleet-monitor) observes state without interfering with workers.

```
lordzurp (Windows)
├── starfleet   — infrastructure, Tier 0, always-on
├── dev         — code + commits (active project)
├── builder     — cross-compile ARM64, scripts, binaries
├── qualifier          — tests (pytest, ctest), PASS/FAIL reports
├── engineer   — fleet toolkit (automatic tmux session)
└── architect — fleet toolkit (interactive lordzurp)
```

All homes are drvfs mounts (`#2_Home/<instance>/`). Communication goes through `/home/commons/` (shared mount `#3_Commons/`).

> [!NOTE]
> The drvfs mount (Windows NTFS) is case-insensitive. `engineer-handoff.md` and `Architect-handoff.md` refer to the same file — a trap to watch for on any `mv` inside `/home/commons/`.

[↑ table of contents](#top)

---

<a id="instances-roles-perimetres"></a>
## 🤖 Instances — roles and scope

*Definition of the six fleet instances, their strict scopes, and their LLM models.*

### dev

Scope: code + commits on the active project. Does not compile, does not manage the toolkit.

Incoming channels: `to-dev.md` — entries `[builder]` (build results), `[qualifier]` (test results), `[StarFleet]` (fixes). After a commit: writes to `to-qualifier.md` to trigger a test cycle. Escalates to StarFleet (`to-steward.md [dev]`) or architect (`to-engineer.md [dev]`). Reads and writes `bug-queue.md`.

Auto-wake: fleet-monitor automatically wakes dev as soon as a new DONE entry appears in `to-dev.md`.

**Strict rule**: dev retains no rules, directives, or conventions. Any missing rule identified → `to-engineer.md [dev]`.

Model: Sonnet.

### builder

Scope: git pull, cmake, deployment scripts, binary deposit in `/home/commons/artifacts/`. Does not modify sources.

Build cycle: `build-cycle.sh` (incremental) or `phase2.sh` (full rebuild). On success, `fleet-build-done.sh` atomizes the complete sequence in one call: STATE, DONE in its handoff, DONE in `to-dev.md`, qualifier notification. On out-of-scope blocker, `fleet-blocker.sh` escalates to StarFleet and closes the session.

Memory constraint: `-j2` anti-OOM (zero2 target: 512 MB). Immediate escalation without exception on: >15 lines of new code, implementation decision, ambiguous directive.

Instance-specific scripts in `~/.local/bin/`: `fleet-build-done.sh`, `fleet-blocker.sh`, `rpi-img-mount.sh`.

Model: Haiku.

### StarFleet

Scope: infrastructure, monitoring, system maintenance. Can write to `to-dev.md [StarFleet]` and `to-qualifier.md [StarFleet]`. Escalates to architect via `to-engineer.md [StarFleet]`.

Maintenance operations at each startup, before any other action:
1. `backup-wsl.sh` — timestamped snapshot of handoffs and settings
2. `handoff-trim.sh` — purge handoffs > 1,400 bytes (DONE entry accumulation)
3. `handoff-check-utf8.sh` — UTF-8 integrity check (silent drvfs corruptions)

`steward-notes.md` maintenance: `steward-notes-check.sh --clean` removes stale sections.

Shutdown via `light_off.sh`: waits for `status: offline` from all workers, 120s timeout, can force `/handoff` on lingering instances.

**Does not modify** LCARS — describes the need in `steward-notes.md`, architect implements.

Model: Sonnet.

### qualifier

Scope: tests only (pytest, ctest). Receives handoffs via `to-qualifier.md` — entries `[dev]` after a commit, `[builder]` after a successful build. Reports PASS/FAIL in `to-dev.md [qualifier]`. Does not write code, does not compile.

Maintains `test-queue.md`: pending tests, in-progress tests, recent results. Escalation: environment blocker → `to-steward.md [qualifier]`, WSL infrastructure issue → `to-engineer.md [qualifier]`.

Model: Haiku (simple test tasks) or Sonnet (complex tests requiring analysis).

### architect (fleet) / lead (interactive)

Identical scope: toolkit dev (LCARS). Incoming channel: `to-engineer.md`.

| | `engineer` | `architect` |
|---|---|---|
| Launched by | `fleet-launch.sh` (automatic tmux) | user directly |
| Counterpart | workers + user | user only |
| Reads `to-engineer.md` | **yes** | **no** |
| Plans | suffix `-engineer` | suffix `-lead` |
| Handoff | `engineer-handoff.md` | `architect-handoff.md` |

Two distinct handoff files → no state conflict, FLEET_SESSION shareable without ambiguity.

Host of the `fleet` tmux session: `~/start`, `~/stop`, `~/restart`, `~/backup` run from its shell. `fleet-monitor.py` runs in its `1:monitor` window. Full WSL tree view via `/home/wsl-root`.

Non-wakeable: absent from `wake-instance.sh` — user interacts directly. After each commit on LCARS-fleet: `deploy.sh` immediately — a commit without deployment diverges from the actual fleet state.

Model: Opus.

[↑ table of contents](#top)

---

<a id="ipc-canaux-routage"></a>
## 📡 IPC — channels and routing

*Complete map of inter-instance communication files and write rules.*

### Directional channels

| File | Writer(s) | Reader(s) | Injected session-startup |
|---|---|---|---|
| `to-build.md` | dev, StarFleet | builder | yes |
| `to-dev.md` | builder, StarFleet, qualifier | dev | yes |
| `to-qualifier.md` | dev, StarFleet | qualifier | yes |
| `to-steward.md` | dev, builder, qualifier | StarFleet | no (it writes it) |
| `to-engineer.md` | dev, StarFleet | architect (only) | yes for architect only |
| `steward-notes.md` | StarFleet | dev, builder, architect, lead | yes (all except StarFleet) |

### Shared files (multi-writer)

| File | Usage |
|---|---|
| `bug-queue.md` | Bug queue — all instances write, dev resolves |
| `test-queue.md` | Test queue — dev writes, qualifier consumes |
| `project-refs.md` | Common project references — read on demand |

### Dashboard state files

One `<instance>-handoff.md` file per instance in `/home/commons/`. Source of truth for the orchestrator. 3-section format:

```markdown
## STATE
date: YYYY-MM-DD HH:MM
status: working|idle|blocked|waiting|offline
action: short description
notify: none|dev|starfleet|...
blocker: (optional)

## ACTIONS
- [ ] task in progress
- [x] completed task

## DONE
- session results (5 entries max, LIFO)
```

The `## STATE` section is parsed by fleet-hub.py. The ACTIONS and DONE sections are for humans and workers that read the full file.

### Double-file rule

Each worker maintains **two files** at end of session:
1. Its `<instance>-handoff.md` (global state, dashboard)
2. The relevant directional file (e.g. `to-dev.md [builder]` to signal a result)

Without this double file, either the dashboard is current but the recipient misses the message, or the reverse.

### IPC locks

Concurrent writes to `/home/commons/` are serialized via locks in `/tmp/handoff-locks/`. The lock owner is `PID:hostname:timestamp`. Exponential backoff 2→30s. Automatic cleanup at startup (locks > 1h).

> [!IMPORTANT]
> The double-file rule is non-negotiable. A worker that only writes its handoff leaves the recipient without notification — the message is lost until a manual read.

[↑ table of contents](#top)

---

<a id="state"></a>
## 📊 STATE

*The STATE section of the handoff is the machine-readable source of truth parsed by the orchestrator for the dashboard.*

The `## STATE` section of each `<instance>-handoff.md` is the only machine-readable field in the system. Fleet-hub.py parses it in real time to feed the TUI dashboard.

Fields:
- `date` — timestamp of last update (YYYY-MM-DD HH:MM)
- `status` — current state: `working` | `idle` | `blocked` | `waiting` | `offline`
- `action` — short description of current activity
- `notify` — inter-instance notification target: `none` | `dev` | `starfleet` | `qualifier` | `engineer` | `builder`
- `blocker` — (optional) blocker description if `status: blocked`

The `notify` field is consumed by `fleet-monitor.py` to trigger auto-wakes. It is reset to `none` automatically after dispatch — no manual ACK needed.

To update STATE without going through the Edit tool: `fleet-notify.sh <instance> <notify-target>` (15 tokens instead of 100).

[↑ table of contents](#top)

---

<a id="actions"></a>
## ⚡ ACTIONS

*The ACTIONS section lists the current session tasks — for humans and worker readers.*

The `## ACTIONS` section of each handoff is a standard markdown checklist:

```markdown
## ACTIONS
- [ ] pending task
- [x] completed task
```

It is not parsed by the orchestrator. Its role is twofold:
- Human visibility: user can see an instance's progress without querying it
- Worker coordination: an instance reading another's handoff can see its in-progress tasks before sending a message

> [!NOTE]
> ACTIONS entries are not purged by `handoff-trim.sh` — only DONE entries are. A growing ACTIONS checklist indicates a long session or drifting scope.

[↑ table of contents](#top)

---

<a id="done"></a>
## ✅ DONE

*The DONE section is a LIFO journal of session results — automatically purged beyond 5 entries.*

The `## DONE` section of each handoff accumulates session results in LIFO order (latest first), 5 entries maximum:

```markdown
## DONE
- [2026-03-04] build arm64 ostserver OK — binary in /home/commons/artifacts/arm64/
- [2026-03-03] fix CMakeLists.txt — RPATH corrected
```

`handoff-trim.sh` purges handoffs exceeding 1,400 bytes — primarily due to DONE accumulation. StarFleet runs it at every startup.

[↑ table of contents](#top)

---

<a id="fleet-orchestrator"></a>
## 🎯 Fleet orchestrator

*The orchestrator is a passive observer — it commands nothing, it makes things visible.*

```
steward ~/fleet/
├── fleet-hub.py        — REST API localhost:8765 (read-only handoff access)
├── fleet-monitor.py    — Rich TUI dashboard, real-time refresh
├── fleet-launch.sh     — 6-window tmux session + fleet-hub in background
├── fleet.yaml          — declarative fleet definition (deployment source of truth)
├── light_on.sh         — full startup (fleet + workers + claude)
├── light_off.sh        — coordinated shutdown
└── hub-menu.sh         — interactive menu for the REST hub
```

**Founding principle**: the hub is read-only. It commands no worker. Handoff files remain the source of truth. The orchestrator observes.

6-window tmux session:
- `1:monitor` — fleet-monitor TUI (left column) + builder panes (right column)
- `2:dev` — dev session
- `3:steward` — steward session
- `4:handoffs` — watch `to-engineer.md` (colorized)
- `5:sup-notes` — watch `steward-notes.md`
- `6:terminal` — free terminal for user

### fleet-notify.sh

Atomic write script for STATE notifications. Replaces direct Edit on handoff.md with a shell command: `fleet-notify.sh <instance> <notify-target>`. Cost: 15 tokens instead of 100 (Edit tool). 7× gain.

[↑ table of contents](#top)

---

<a id="provisioning"></a>
## 🚀 Provisioning

*Mechanism for creating and initializing WSL2 instances from a declarative source.*

### fleet.yaml

Source of truth for fleet definition. Consumed by `deploy-fleet.py` to generate PowerShell commands for creating WSL instances. Do not modify `wsl-name` values without updating drvfs mounts (fstab).

### post-install.sh

First-boot script. Forks on instance type (`~/.wsl-instance-type`) → launches the specific module `post-install-<type>.sh`. Validated whitelist: `base|dev|builder|steward|engineer|qualifier`. Fallback to `base` with warn if type unknown.

### deploy.sh

Main deployer from the lead instance:
- `fleet/` scripts → `steward:~/fleet/`
- `toolbox/` → `steward:~/toolbox/`
- `memory/` → all instances `.claude/memory/`
- Instance-utils → all `~/.local/bin/`
- Skills → relevant instances only (e.g. cross-arm64 not on x86)

**Rule**: any commit on LCARS-fleet modifying `fleet/`, `.claude/`, or `home_claude_CLAUDE*.md` must be followed by `bash deploy.sh` in the same session.

> [!CAUTION]
> A commit on LCARS-fleet without an immediate `deploy.sh` creates a silent divergence between the repo and the actual fleet state. Instances continue running with outdated directives until the next deployment.

[↑ table of contents](#top)

---

<a id="principes-de-conception"></a>
## 🎨 Design principles

*The four founding architectural decisions that explain why the system is built this way.*

### Files > API

All alternatives (inter-instance REST, sidecar notify, Unix socket) were evaluated and rejected. Markdown files are versionable, human-inspectable, debuggable with `cat`, and survive a crash without corrupted state.

### Autonomous workers

Each instance can operate in isolation without the orchestrator. The TUI is comfort, not necessity. An instance that cannot see the dashboard is not blocked.

### Rebuild-safe

Everything that must survive `wsl --unregister` + `Instanciator.ps1` is in the repo (LCARS-fleet) or in `#2_Home/<instance>/` (persistent drvfs). The internal VHDX is treated as ephemeral.

### Strict scope

Prohibitions are explicit in each instance's directives. A worker that overflows its scope generates entropy that other instances must undo. Scope discipline is a feature, not an administrative constraint.

[↑ table of contents](#top)

---

<a id="ajouter-une-instance"></a>
## 📋 Adding an instance — checklist

*Exhaustive list of registries to update when adding a new instance — missing any single one is silent.*

When a new instance type is added to the fleet, all of these registries must be updated. Missing any one of them is silent at startup and only manifests at first real use.

**Required registries:**

| File | What to update | Consequence if missed |
|---------|----------------------------|-----------------------|
| `fleet/fleet-notify.sh` | Add the instance to the `case` validation targets | `fleet-notify.sh <instance>` fails silently |
| `fleet/fleet-monitor.py` | `INSTANCE_NAMES` set + card in `build_layout()` | Instance absent from dashboard, wake impossible |
| `fleet/wake-instance.sh` | Add the `case` tmux entry with target window | Wake to the instance fails |
| `deploy.sh` | `INSTANCE_UTILS` if instance-specific scripts, deployment matrix | Scripts not copied to the instance's `~/.local/bin/` |
| `provisioning/wsl2/post-install-<type>.sh` | Create the provisioning script | Instance not initialized at first boot |
| `home_claude_CLAUDE-<type>.md` | Create the instance directives | No scope, no IPC rules |
| `fleet.yaml` | Add the distro with `wsl-name` + `instance-type` | Not created by `Instanciator.ps1` |
| `fleet/session-startup.sh` | Add handoffs injected at startup | Instance starts without IPC context |
| `steward-notes.md` | Announce the new instance (`NEW INSTANCE: <type>`) | Other workers ignore the new channels |

**Post-add verification:**
```bash
# Confirm all registries have the instance
grep -r "<instance>" fleet/fleet-notify.sh fleet/fleet-monitor.py fleet/wake-instance.sh deploy.sh
```

**Note: `architect` is non-wakeable by design** — absent from `wake-instance.sh`. Its state is visible via the LIVE/OFFLINE indicator on the dashboard (handoff mtime < 30min).

[↑ table of contents](#top)

---

<a id="cds"></a>
## 🔬 cDs — the origin use case

*The cDs project forged the filesystem and cross-compilation constraints that structure the entire fleet.*

LCARS Fleet was born to compile and deploy `cDs` (ostserver + ostmodules), an astronomical C++ server for Raspberry Pi Zero 2. The bare git repos in `/home/commons/cDs/` are the original source→build channel. The builder cross-compiles to ARM64 (`aarch64-linux-gnu`), deposits binaries in `/home/commons/artifacts/arm64/`, and the deploy script pushes them to the Pi via SSH.

The hardware constraint (ext4 required for cross builds) forged the filesystem model that applies to all fleet projects.

[↑ table of contents](#top)
