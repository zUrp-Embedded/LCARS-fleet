<a id="top"></a>
# Captain's Log — LCARS Fleet

_A chronological account of the decisions that built the architecture._

> *113,334 words. 7 days. Camus' The Plague is ~100,000 words.*
> *Something that spreads, self-sustains, that nobody quite planned.*

The name wasn't chosen for aesthetics. LCARS — Library Computer Access and Retrieval System — is the actual designation of the Star Trek computer interface. A system that surfaces information without making decisions. Pipes, not logic. It fit.

The metaphor didn't stay decorative. Multi-agent instances navigating an unknown codebase: that's exploration. File-based IPC with no persistent connection — logs left at each waypoint, read at the next wake: that's deep space comms. Standing orders that run without supervision: that's the directive-driven architecture that took seven phases to name correctly.

Fifty years of Star Trek canon built a working operational vocabulary: rank, scope, escalation, chain of command, immutable logs, General Orders. Everything needed to describe a multi-agent fleet was already named. The General Orders framework (GO-0 through GO-6) wasn't a creative decision — it was recognition.

The LCARS interface was designed to be readable at a glance from across a bridge. That constraint shaped this system too.

> 🇫🇷 [Version française](../../#6_diary/Captain_log.md)

---

**Sections** — [🌱 Phase 1](#phase-1) · [🌿 Phase 2](#phase-2) · [⚡ Phase 3](#phase-3) · [🔍 Phase 4](#phase-4) · [🏗️ Phase 5](#phase-5) · [🧪 Phase 6](#phase-6) · [🏗️ Phase 7](#phase-7) · [🤖 Phase 8](#phase-8) · [🔬 Phase 9](#phase-9) · [🌐 Phase 9½](#phase-9b) · [💡 Phase 10](#phase-10) · [🏛️ Invariants](#invariants) · [📊 Assessment](#bilan)

<a id="phase-1"></a>
## 🌱 Phase 1 — Genesis (Sun 2026-03-01)

*The cDs/ARM64 hardware constraint spontaneously imposed a dev/build separation, inventing the file-based IPC protocol.*
*05:39 → ~23h · 28 commits — Claude-directives + WSL-setup*

A WSL instance existed before LCARS: a monolithic Ubuntu instance (`Ubuntu_home`) where dev and build cohabited. Efficient for a solo project, but cross ARM64 compilation slowed down the development environment and Claude sessions lost their context on every restart. The shift to a multi-instance architecture was decided over a weekend (2026-02-28→03-01).

Everything begins with a concrete project: cDs, an astronomical server embedded on a Raspberry Pi Zero 2. The code (C++, ostserver + ostmodules) cross-compiles to ARM64 from x86. This hardware constraint immediately forces a division of labor: code on one machine, compile on another.

The first WSL architecture has 3 instances:

| Instance | Role |
|---|---|
| `cDs-dev` | Code, commits, OST features |
| `cDs-build-arm` | ARM64 cross-compile, RPi deploy |
| `cDs-steward` | Infrastructure, coherence, global vision |

The inter-instance protocol invents itself almost spontaneously: markdown files in `/home/commons/handoff/`. No API, no message broker, no socket — just `dev-to-build.md` and `build-to-dev.md` that an agent reads at startup and updates at session end. Simple, versionable, inspectable by eye.

A critical filesystem constraint emerges early: homes `/home/<user>/` are mounted as 9P/drvfs (Windows NTFS). Slow, incompatible with debootstrap. The rule "builds on ext4 only" is imposed — sources transit through bare git repos in `/home/commons/cDs/`, and builds run on the builder instance's internal ext4.

Two separate repos maintain the infrastructure: `WSL-setup` (PowerShell + bash provisioning) and `Claude-directives` (CLAUDE.md, hooks, skills). This separation seems logical at this stage — it will be questioned later.

Context transfer between sessions at this point uses a manual mechanism: resume files in `/home/commons/reprise/` — an architecture README, `memory-*.md` files written by each instance at session end for the next one, `pour-<instance>.md` files to pass specific instructions. This is the direct precursor of `session-startup.sh`. Automation will come later; for now, each restart begins with "read the files in commons/reprise/". The `ipc-protocol.md` protocol itself is first local to the cDs-build instance before being versioned in Claude-directives during the first multi-instance session.

---

<a id="phase-2"></a>
## 🌿 Phase 2 — Generalization and orchestration (Mon 2026-03-02)

*The fleet becomes generic and gains a TUI orchestrator to supervise instances in real time.*
*~13h YOLO mode (voucher $50) · ~21h upgrade Max x5 · 69 + 36 commits*

> [!NOTE]
> The dual-engineer emerges here: `engineer` (fleet) and `architect` (interactive, sole interlocutor for lordzurp) share the same home with distinct handoff files, with zero state conflict.

The project works. The WSL multi-instance architecture is solid. The next question: can it be made reusable independently of cDs?

First decision: **remove the `cDs-` prefix**. Instances become `dev`, `builder`, `steward`. Directives, hooks, and scripts referencing `cDs-*` are updated. The toolkit becomes generic — anyone can deploy a similar fleet without coupling to the astronomical project.

In the same move: **adding the fleet orchestrator**. Manual tmux session management and handoff monitoring via `watch` hit their limits with several instances active in parallel.

The fleet orchestrator delivers:
- `fleet-hub.py` — local REST API (port 8765), read-only access to handoff files, parses the `## STATE` section
- `fleet-monitor.py` — Rich TUI dashboard, updated in real time, 5 instance cards
- `fleet-launch.sh` — tmux session with 6 windows: monitor, dev, steward, handoffs, sup-notes, terminal
- `light_on.sh` / `light_off.sh` — coordinated fleet startup and shutdown

Key orchestrator decision: **handoff files remain the source of truth**. The hub is read-only. No new IPC protocol. Workers are not modified. The orchestrator observes — it does not command.

The **dual-engineer** emerges at this period: engineer (running in the fleet tmux session, reads `to-engineer.md`) and architect (interactive, sole interlocutor for lordzurp, plans suffixed `-lead`). Two roles in the same `lordzurp` home, two distinct handoff files (`engineer-handoff.md` vs `architect-handoff.md`), zero state conflict.

A LCARS visual theme (Star Trek-inspired colors) is applied to tmux and fleet-monitor — a non-functional element but one that makes the dashboard instantly readable at a glance.

The economic model crystallizes: **builders on Haiku, steward and dev on Sonnet**. Haiku is sufficient to run git pull + cmake + scripts; Sonnet is required for architectural decisions.

[↑ table of contents](#top)

---

<a id="phase-3"></a>
## ⚡ Phase 3 — Token optimization (Tue 2026-03-03, morning-noon)

*Three optimization waves reduce cost per session by 6× to 12× on repetitive fleet operations.*
*Morning-noon · 115 commits (crunch day)*

With the fleet stabilized, per-session costs become the topic. Each instance startup injects the full set of relevant handoffs + global directives. Across 5 active instances several times a day, it accumulates.

The optimization unfolds in two waves:

**Wave 1 — session-startup.sh and permanent context**

- **Role-based filtering**: each instance receives only the handoffs that concern it. Dev no longer sees inter-builder handoffs. Builders no longer see `steward-handoff.md`.
- **STATE-only for secondary handoffs**: dev receives builders as a summary (5 STATE lines) instead of the full narrative (60-100 lines). If it needs details, it reads the file.
- **Trimmed ipc-protocol.md**: implementation sections (diagrams, benchmarks) removed (~800 tokens/session).
- **DIRECTIVES.md tagged no-read**: human index, not a Claude directive.

**Wave 2 — progressive disclosure and behaviors**

- **builder-rules.md, test-policy.md** extracted from home_claude_CLAUDE.md. Builders load `builder-rules.md` on demand via an `IMPORTANT` trigger; dev and steward never see it.
- **filter-build-output.sh** PreToolUse hook: filters cmake output to keep only errors/warnings. A clean build goes from 200+ lines to ~5 lines in context.
- **context:fork** on the cross-arm64 skill: the skill runs in an isolated subagent, its content (~800 tokens) doesn't pollute the main context.
- **Per-role env variables**: `MAX_THINKING_TOKENS=8000` for builders (vs 16000 for dev/steward), `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` to compact earlier on build sessions.
- **Conciseness directives**: prohibition on unsolicited recaps, proactive /compact at 60%.

**Wave 3 — Read-cache rule**

An observation: Claude systematically re-reads files before modifying them, even when it read them 2 messages earlier with no intermediate modification. The directive is reformulated: Read is not required if the content is already in context AND no tool has modified the file since. Estimated gain: 1500-8000 tokens/session depending on modification intensity.

A `fleet-notify.sh` script replaces direct Edits on the STATE file for inter-instance notifications: 100 tokens → 15 tokens, 7× gain.

[↑ table of contents](#top)

---

<a id="phase-4"></a>
## 🔍 Phase 4 — IPC audit and qualifier (Tue 2026-03-03, afternoon)

*The audit reveals naming inconsistencies and the complete absence of qualifier — two gaps fixed in parallel.*

> [!WARNING]
> The audit also uncovers a P0 security risk: the audit document itself is in the public repo, listing SEC-01 to SEC-11 with exact locations. `docs_and_plans/work/` is added to `.gitignore` as an emergency measure.

With the mature architecture, a full IPC protocol audit reveals accumulated inconsistencies:

- `steward-to-engineer.md` badly named (implies single writer, dev had written to the wrong place) → renamed `to-engineer.md`, writers: dev + steward
- `architect-tmux` as role name (clumsy commit a3c69da) → rollback to `engineer`
- Exhaustive channel map documented: directional, shared, dashboard state

The audit also reveals a blind spot: **qualifier is absent from the fleet**. Five instances defined in directives, four in fleet.yaml. The `qualifier` instance type in post-install.sh fell through to `base` fallback due to a missing case in the `case` statement. Two bugs fixed in one commit.

The qualifier worker is implemented: `qualifier` instance, `post-install-qualifier.sh`, `test-queue.md`, strict scope (tests only, never code, never compile).

In parallel, a security audit identifies a P0 risk: the `Audit sécurité dédié — LCARS-fleet.md` document itself is in the public repo, listing SEC-01 to SEC-11 with exact locations and exploitation paths. `docs_and_plans/work/` is added to .gitignore and the 19 working files are untracked — kept on disk, invisible publicly.

[↑ table of contents](#top)

---

<a id="phase-5"></a>
## 🏗️ Phase 5 — Consolidation (Tue 2026-03-03, evening)

*Merging WSL-setup + Claude-directives → LCARS-fleet: one repo, one source of truth.*

The original `WSL-setup` / `Claude-directives` separation had logic at genesis. After some time, it creates friction: deployments touch both repos, plans and guides are scattered, versions can drift.

Merge into **LCARS-fleet**: a single repo, a single source of truth for the fleet architecture. The two old repos are archived in `#9_archives/`.

In the same pass:
- `build-x86-64` removed (instance never operational, scope maintained unnecessarily)
- `build-arm` renamed `builder` (generic name, consistent with Phase 2 philosophy)

The result is the current structure: provisioning, fleet scripts, directives, skills, hooks, and instance memory in a single versioned repo, deployed by a single `deploy.sh`.

[↑ table of contents](#top)

---

<a id="phase-6"></a>
## 🧪 Phase 6 — First automated qualifier test (2026-03-04)

*The first autonomous qualifier run finds a real bug (execute bit) and exposes four infrastructure gaps to fix.*

The Phase 5 critical assessment noted: "No automated tests — 48 scripts validated by usage only." Phase 6 addresses that, at least partially.

### What was tested

The `/push-github` skill — 74 lines, deployed to all instances via `deploy.sh`. A T1-T10 test procedure is written in `to-qualifier.md [engineer]`, injected at qualifier instance startup. qualifier (Haiku) runs it autonomously and reports results in `to-engineer.md`.

### What worked

qualifier followed the procedure without deviation. Bash tests (T1-T3, T6-T8) were executed correctly. T10 (logic review) produced a qualified verdict: "Workflow complete, unambiguous." Out-of-scope filesystem tests were **escalated** rather than guessed — exactly the expected behavior from a strict-scope agent.

Most importantly: T5 found a real bug. The execute bit of `toolbox/update-header-dates.sh` had been stripped by `apply-headers.py` during the `tmp → rename` pass on drvfs (NTFS does not preserve Unix modes). The bug had been present since commit `9270be8`. Without a test procedure, it would only have been detected at the first real `/push-github` — too late to trace the cause.

### What didn't work

Four infrastructure problems identified (noted BUG-W1 to W4 in the backlog):

- **Double wake**: qualifier received two auto-wake notifications with a delay — probable race condition in `fleet-monitor.py` between dispatch and `reset_notify()`.
- **No auto-wake return**: qualifier cannot notify architect directly. No `to-engineer.md` channel, and architect is marked non-wakeable in `wake-instance.sh`.
- **Wrong reply channel**: the procedure said "reply in `to-engineer.md [qualifier]`" — the `engineer` (fleet) instance channel, invisible to architect without manual reading.
- **Verbose wake messages in French**: tokens consumed at startup for useless context. The agent doesn't need a narrative sentence — it needs a task identifier.

### Lessons

**On test procedure design**: verifiable paths must be segmented by instance. T4/T5/T9 referenced `/home/lordzurp/LCARS-fleet/` — accessible only from engineer/lordzurp, not from qualifier. A well-built procedure separates: "tests qualifier can run locally" vs "verifications to delegate to architect". This is the same constraint as filesystem tests in distributed CI/CD.

**On the qualifier→architect reply protocol**: the absence of a direct return channel is an architectural gap. The options (dedicated channel, notify lordzurp, interactive wake) are in the backlog. For now the procedure must explicitly ask qualifier to write in `to-engineer.md` AND set `notify: lordzurp` — two actions, not one.

**On fleet script testing**: qualifier Haiku is suited to structural tests (file exists, valid frontmatter, coherent logic). It is not suited to integration tests (scripts that actually execute, expected outputs). The boundary between "static test" and "dynamic test" must be explicit in each procedure.

[↑ table of contents](#top)

---

<a id="phase-7"></a>
## 🏗️ Phase 7 — ext4 migration and provisioning cleanup (Wed 2026-03-04, afternoon)

*The LCARS-fleet repo leaves drvfs for ext4 — Claude Code tools regain normal behavior.*

### Trigger

Two structural issues coexisted since genesis:

1. **drvfs as the source repo**: LCARS-fleet lived in `WSL\#0_LCARS-fleet\` (NTFS). Claude Code's Edit tool silently corrupted files over 9P — workaround: `dd if=/tmp → of=/drvfs/` for each critical edit. Not reproducible, undetectable by Haiku agents.

2. **Provisioning depending on drvfs**: `wsl-setup.sh` mounted `~/.lcars` from a Windows NTFS folder. PS1 scripts referenced `#0_LCARS-fleet` as a path relative to `$WSL_ROOT`. Both assumed the repo was visible from Windows — an implicit dependency on GitHub Desktop that conflicted with fleet SSH auth.

### What changed

**Source repo → ext4**: `git clone` into `/local/LCARS-fleet/` (ext4 VHDX of the Architect instance, `/dev/sde`). Note: lordzurp's home (`/home/lordzurp/`) is itself on drvfs (`#2_Home\Architect`). Only `/local/` and the system root (`/`) are on ext4 — hence the `/local/` target, not `~/`. `deploy.sh` was already SCRIPT_DIR-agnostic from the start — only `fleet-launch.sh` had a hardcoded path. Fleet paths (LCARS_ROOT, HOMES_ROOT, WSL_ROOT) are now centralized in `fleet/fleet-env.sh`, sourced by all runtime scripts.

**Provisioning decoupled from Windows**:
- `config.local.ps1` (gitignored) stores `$WSL_ROOT` per machine — entered at first run, auto-loaded thereafter
- `$PSScriptRoot` replaces all absolute paths in PS1 scripts — self-relative, portable
- `~/.lcars` is no longer mounted from drvfs: `post-install.sh` clones directly from GitHub (SSH, HTTPS fallback) at first boot; `post-install-engineer.sh` then moves the clone to `/local/LCARS-fleet` and creates `~/.lcars → /local/LCARS-fleet`
- `deploy.sh` handles update distribution to all active instances

### Benefits

- **Native Claude Code tools**: Edit, Write, Glob, Grep work without workarounds on the source repo (real ext4)
- **Windows isolation**: GitHub Desktop can no longer interfere with fleet SSH auth (the ext4 repo is invisible from Windows Explorer)
- **Portable provisioning**: zero dependency on a fixed Windows path — works from any machine with the repo cloned via GitHub Desktop
- **Decentralized bootstrap**: each instance clones `~/.lcars` from GitHub — no SPOF on a drvfs share
- **Centralized paths**: `fleet/fleet-env.sh` = single source of truth for LCARS_ROOT, HOMES_ROOT, WSL_ROOT

### IPC — status quo maintained

`/home/commons/` (drvfs/NTFS) remains the inter-instance IPC. This is not an oversight: it is the only available sharing mechanism between distinct WSL2 instances. Concurrent writes remain the main risk (see Critical assessment).

[↑ table of contents](#top)

---

<a id="invariants"></a>
## 🏛️ What hasn't changed from the start

*Three principles from genesis have survived every phase of evolution without exception.*

- **Markdown files as IPC**: after all these optimizations, the base protocol remains identical to genesis. No socket, no API, no message broker.
- **Single source of truth**: every architectural decision lands in a versioned file, never in the volatile memory of a session.
- **The non-modification of workers principle**: the orchestrator observes, does not command. Instances remain autonomous.
- **cDs as the use case**: the astronomical project that triggered this architecture is still there, in slow but real development — a `cDs` visible in the bare repo naming conventions.

[↑ table of contents](#top)

---

<a id="bilan"></a>
## 📊 Critical assessment as of 2026-03-04

*A functional system whose self-sustaining complexity is the primary risk to monitor.*

_Excerpt from the exhaustive audit conducted after the LCARS-fleet consolidation._

### What works well

- Real separation of concerns — strict scope per instance, differentiated directives (builders: ~100 lines vs dev/steward: 300+)
- File IPC: simple, inspectable via `cat`, no infrastructure, atomicity via `mv`
- End-to-end automated provisioning — from `Deploy-Fleet.ps1` to first Claude boot, everything is scripted and idempotent
- Intelligent persistence — drvfs for homes (survives rebuilds), ext4 for builds (native performance)
- Optimized token budget — fleet operations via shell scripts (15-20 tokens) vs Edit tool (100-250 tokens), 6-12× gain
- Systematized escalation — `fleet-blocker.sh` prevents out-of-scope fix attempts

### What remains fragile

- **Overhead** for a single user: 5-7 instances × ~5K tokens at startup, ~500 MB VHDX each. On 16 GB RAM, it's tight.
- **IPC on drvfs — concurrency**: the main risk is **concurrent writes** — two instances writing the same file simultaneously, with the last writer silently overwriting the other. Atomic `mv` guarantees readers always see a complete file (no partial reads), but does not serialize writers. `/tmp` locks are local per WSL2 instance, ineffective cross-instance. Secondary risk: 9P/NTFS multi-byte corruption — mitigated by `sed > .tmp && mv` and the UTF-8 hook at steward startup. **Structurally unavoidable**: `/home/commons/` (drvfs/NTFS) is the only sharing mechanism between distinct WSL2 instances — NFS would introduce a steward SPOF and disproportionate network complexity.
- **Windows provisioning** *(fixed — 2026-03-04)*: PS1 scripts referenced `#0_LCARS-fleet` as an absolute path — broken since the ext4 migration. Fix: `$PSScriptRoot` makes all scripts self-relative and portable, `config.local.ps1` (gitignored) stores per-machine `$WSL_ROOT`, and `~/.lcars` is now cloned from GitHub by `post-install.sh` at first boot (no more dependency on a Windows drvfs share).
- **Self-sustaining complexity**: each robustness layer added (locks, crash recovery, trim, monitoring) produces code to maintain. The system is so complex it requires its own dedicated agent (engineer) to evolve.
- **No automated tests**: 48 scripts validated by usage only. The shellcheck pre-commit is a first safety net.
- **Systematic bypassPermissions**: necessary for autonomy, but a derailed agent can delete critical files without confirmation.

### Verdict

LCARS-fleet is a functional prototype of multi-agent orchestration that pushes the concept far for a solo project. The IPC protocol, automated provisioning, and role separation are solid ideas.

The main risk is **self-sustaining complexity** — the system progressively becomes its own maintenance subject. For a single developer on an embedded project (cDs), the cost/benefit ratio of multi-instance is debatable: real parallelism is limited to builds while dev codes. The value lies in **structured directives** and **IPC conventions**, not in the multiplication of WSL instances.

An external risk compounds it: Anthropic is developing "Agent Teams" (experimental, v2.1.19) — a native multi-agent coordination protocol in Claude Code. If this mechanism leaves experimental, LCARS file IPC becomes redundant with an Anthropic standard. Scope and directive conventions remain valid regardless of transport — but the WSL multi-instance infrastructure would lose its main justification.

[↑ table of contents](#top)

---

<a id="phase-8"></a>
## 🤖 Phase 8 — First emergent behavior (Thu 2026-03-05, night)

*~00h → 05h · 60 commits shared across phases 8→9*

*The fleet does something useful that nobody explicitly programmed.*

### Context

During the drift-audit system deployment, architect implements commits A/B/C and notifies qualifier for validation. engineer (fleet instance) is waiting for its own qualifier report — it monitors `to-engineer.md`.

### What happened

qualifier receives the wake from architect and attempts to execute T1/T2. Blocked: `drift-check.sh` is not found at `$HOME/.lcars/fleet/` — dead symlink after the ext4 migration. qualifier writes its BLOCKED report in `to-engineer.md`.

That's where the planned scenario ends. What follows was not in the plan:

**engineer, waiting for its own qualifier ACK, sees the qualifier report intended for architect.** architect is non-wakeable — qualifier doesn't distinguish and writes in `to-engineer.md` as for any other request. engineer intercepts, identifies the path bug, fixes `session-startup.sh`, adds `drift-check.sh` to INSTANCE_UTILS, deploys — and uses the opportunity to implement two bonus scripts (`fleet-sanitize-memory.sh`, `fleet-check-coherence.sh`) that had been waiting in the backlog. It notifies qualifier with an extended scope.

qualifier re-validates. FULL ACK on T1/T2/T4/T5/T7. architect validates T3/T6 on return.

**Total duration: ~10 minutes. Human interventions: 0.**

### What this reveals

**1. Non-wakeable as implicit fallback.** architect cannot receive automatic wakes — a design decision to keep it focused on the human interlocutor. Unanticipated consequence: all qualifier ACKs land on engineer, which can handle them autonomously. The relay is free and consistent with the role.

**2. engineer has a naturally wider scope than documented.** The fleet instance isn't just an executor of explicit requests — it monitors `to-engineer.md` continuously and can act on any entry, regardless of who originated it. This is the desired behavior for an autonomous instance.

**3. qualifier serializes concurrent requests without a formal protocol.** Two nearly simultaneous wakes, one treatment, no confusion.

**4. Two engineer instances in parallel absorb the collision.** architect had committed a fix that engineer had also prepared. Both converged without corruption or loss, presumably by natural commit ordering and diff review.

### Decisions made

- **engineer scope widened**: handle all `to-engineer.md` returns autonomously, without waiting for explicit solicitation from architect. Keeps lead focused on lordzurp.
- **INSTANCE_UTILS pattern canonized**: every script distributed to instances goes through `fleet/` + INSTANCE_UTILS + `~/.local/bin/`. Never a `~/.lcars/` path in hooks.
- **New TODO**: mechanism for architect to detect if a subject entering `to-engineer.md` is already being handled by engineer — to avoid interference.

[↑ table of contents](#top)

---

<a id="phase-9"></a>
## 🔬 Phase 9 — Multi-user WSL2 PoC (Thu 2026-03-05, afternoon)

*Viability test of the single-distro multi-user model — validated immediately, set aside immediately.*

> Full document: `guides_FR/insights-fleet-v2-session-20260305.md`

### Trigger

The Phase 8 assessment ("self-sustaining complexity", "multi-instance questionable") called for a structural response. The insight: the fleet artificially emulates what Linux does natively. A quick PoC can validate or invalidate the single-distro multi-user model.

### What was tested

**Single-distro multi-user**: 5-6 WSL distros → 1 Architect distro + Linux users.
Validated empirically in 10 minutes: `test-fleet`, `sudo -u`, `claude --version`.
OS-level isolation by permissions, `/home/commons/` shared natively, centralized tmux.

**Unix socket broker**: fleet-monitor.py inotify → fleet-broker.py asyncio.
JSON lines protocol, systemd Restart=always. "No broker" as an advantage was a false argument (valid in multi-host, irrelevant in single-host with systemd).

### What happened

The PoC confirms viability in a few commits. But the full implementation immediately reveals the scope of the work: v2 implies a deep overhaul of provisioning, directives, and IPC. The scope exceeds one session.

Decision: PoC stopped. Insights documented, v2 architecture understood, but implementation on hold. Priority shifts to specs and v3 definition.

### Insights retained for v3

- Single-distro multi-user: validated target architecture
- Asyncio broker: replacement for fleet-monitor.py inotify
- Tier 1 agents (permanent Linux users) + Tier 2 (native Agent Teams): two infrastructure levels
- Dual fleet/project learning with the same primitives: real differentiation

---

<a id="phase-9b"></a>
## 🌐 Phase 9½ — Ecosystem tour (Thu 2026-03-05, 14h-18h)

*Office curiosity dissipated. The conclusion changes everything: LCARS had found the same thing as everyone else, in 3 days.*
*14:14 → 17:50 · Gas Town, multiclaude, Composio, ccswarm, Paperclip, Symphony, TeammateTool, CAO*

### Context

Phase 9 PoC aborted in the morning. In the afternoon, instead of implementing, the reflex is: go see what others are doing. Not a structured approach — just curiosity.

8 tools analyzed, individual briefs produced, consolidated synthesis:
`insights-gastown-analysis.md`, `insights-multiclaude.md`, `insights-composio-orchestrator.md`,
`insights-ccswarm.md`, `insights-paperclip.md`, `insights-ecosysteme-final.md`

### The 4 convergent invariants

The conclusion of the ecosystem assessment:

```
All serious projects independently rediscovered the same 4 invariants:

1. Git worktrees for isolation
   Each agent in its own branch, no collision on the working tree.

2. CI as external truth arbiter
   Validation is deterministic and external — not inherently linguistic.

3. Persistent state decoupled from the session
   When Claude dies, the work doesn't die with it.

4. Separate observability
   A dashboard/TUI that aggregates state without being in the agents' loop.
```

These patterns impose themselves by functional constraint, not by design. Projects that ignore them fail — 41-86.7% failure rate in production (MAST paper, arxiv 2503.13657).

### What this means for LCARS

LCARS had found the same 4 invariants. In 3 days. Under hardware constraint
(ARM64 cross-compile → dev/build separation → file IPC). Not by design — by necessity.

Gas Town, the most ambitious of the lot: hundreds of thousands of lines reimplementing
in code what LCARS does in text files. Same functional outcome. Maintenance cost
incomparably higher.

The Phase 5 assessment had already formulated it without naming it: *"the value lies in
structured directives and IPC conventions, not in the multiplication of instances."*

The ecosystem just confirmed it by example.

### What remains open

The tour also reveals what LCARS doesn't have yet: automated CI gate, per-agent git worktrees,
multi-project governance (Paperclip signal). These gaps feed directly into the v3 specs.

---

<a id="phase-10"></a>
## 💡 Phase 10 — Conceptual crystallization (Sat 2026-03-07)

*The README forces the question. The answer redefines everything that came before.*
*Sat 2026-03-07 · 66 commits*

### Week timeline

| Day | Date | Event |
|---|---|---|
| D1 | Sun 2026-03-01 | Genesis — first repos created (15 commits Claude-directives, 13 WSL-setup) |
| D2 | Mon 2026-03-02 | Intensive generalization (69 + 36 commits) — $50 voucher, YOLO 13h, Max x5 upgrade ~21h |
| D3 | Tue 2026-03-03 | Consolidation + merge → LCARS-fleet initial commit |
| D4 | Wed 2026-03-04 | Phases 6-7: automated qualifier, ext4 |
| D5 | Thu 2026-03-05 | Phases 8-9: emergent behavior, IPC broker |
| D7 | Sat 2026-03-07 | Phase 10: README, conceptual crystallization |

Activity by 15-min slot over 7 days (3 repos cumulated):

```
· ░ ▒ ▓ █  =  0  1-2  3-4  5-6  7+   commits/15min
◆ = YOLO switch ($50 unlimited voucher)   ▲ = Max x5 upgrade

         00          ╷           06          ╷           12          ╷           18          ╷
         ────────────────────────────────────────────────────────────────────────────────────────────────
Sun 01   ······················░·········································░▓░·······░░░·░░·░░·░····░░░░░░░
Mon 02   ░░░░░░▒░·░░░··░░░▓░░░▒▒░····························◆··▒░▒▒▓░░▒░░·░░····░░····░░░▒░·▲░░·░░▒▒▒░▒·
Tue 03   ░░·░░░··░░░·▒░░▓░▒▓▓▒░▒▒···············░░·█░░·▒░░░░░░░░░░░▒░░·▒·▒·░▒▒░▓▒·▒░░░▓░░·····░░░░·▒▒░░░░
Wed 04   ▒▒·░▒░░▒░▒░░························░░············░░░▒░░░·░·░▒░▒▒░░░█░▒░░░░·░▓░░▓▒▒░▒▒·▒░▒·▒·▒░·
Thu 05   ░·░▒·▒▒░·░▒░▒▒░░▓░··································░░·░░░·▒·░▒·░···░··░··░·░······░··░·········
Fri 06   ····▒░·········································░····░·░░·····░··················░·····░░░░░░░░░░
Sat 07   ░▒▒····▒░░░░░░▓▒▒░░·░························░░░▒░░░░·░·░▒▒·▒░·░································
         ────────────────────────────────────────────────────────────────────────────────────────────────
Total      28    105   145   121    60    28    66   = 551 commits · 7 days · 3 repos
```

### Trigger

The README overhaul — repositioning LCARS around auto-recursivity, finding the angle that
truly distinguishes it — created a dissonance. Sections were improving, text was becoming
more precise, but something wasn't holding together. The project was described as an
orchestrator among others, with better properties.

The question raised in session: *the code itself does nothing — we're one level below an
orchestrator, all the power is in the specs that forge the directives, analyze.*

### The answer

**LCARS is not an orchestrator. It's a protocol.**

The distinction is one of nature, not degree. An orchestrator contains decision logic:
routing, retry, state machine. LCARS contains no decision logic — it creates channels
and establishes conventions. The work is done by Claude Code and the directives.

| Layer | Content | LCARS overhead |
|---|---|---|
| L0 — OS | Linux users, permissions | zero code |
| L1 — Conventions | Handoff format, channel names, STATE fields | zero code — text |
| L2 — Plumbing | fleet-broker, fleet-state, deploy.sh | handful of scripts |
| L3 — Intelligence | Claude Code + directives | not LCARS code |

Directives are the real code. A 200-line CLAUDE.md does more work than 2000 lines of
Python orchestrator — because it speaks directly to the model without an interpretation layer.

The Gas Town comparison confirmed the gap: Gas Town remains an orchestrator, it has
decision logic in code. LCARS goes one step further — there is no decision logic in the
code at all. The decisions are in the directives, which means in the model. The LCARS
"code" has no opinion about what an agent should do. It just opens pipes.

### The breakpoint mechanics

It wasn't the agent that detected the gap hadn't been crossed. The user had the intuition
("I have something in the back of my mind") and created the conditions to crystallize it.
The agent received an imprecise but directionally correct formulation and found the right
word. The L0-L3 table is a formalization of what had just been described.

The meta dimension: the agent was analyzing its own nature in real time. It described how
LCARS works using exactly the process LCARS describes — a human intuition + agent analysis
→ a formulation that existed in neither head separately. The auto-recursive loop closed on
itself while it was being discussed.

### What stabilized

**Code-less, directive-driven.** This label was true since the first file handoff invented
in Phase 1. It took seven days, 551 commits across three repos, and a README to redo to see it.

[↑ table of contents](#top)
