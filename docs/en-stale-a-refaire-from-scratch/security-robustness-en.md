<a id="top"></a>

> 🇫🇷 [Version française](../#06_security-robustness.md)

# Security and robustness — patterns and decisions

_Full audit performed on 2026-03-03. Scope: ~25 fleet shell scripts (WSL-setup + LCARS-fleet). Single-user environment, not network-exposed._

**Sections** — [🎯 Threat model](#modele-de-menace) · [P1](#pattern-1) · [P2](#pattern-2) · [P3](#pattern-3) · [P4](#pattern-4) · [P5](#pattern-5) · [P6](#pattern-6) · [P7](#pattern-7) · [P8](#pattern-8) · [⚖️ Accepted decisions](#decisions-acceptees) · [👁️ Visibility rule](#visibilite-publique) · [⚠️ No error masking](#no-error-masking)

---

<a id="modele-de-menace"></a>
## 🎯 Threat model

_Overview of retained risks and design assumptions that define the security perimeter._

**In scope**:
- Command injection via user-controlled or file-sourced values
- Race conditions on IPC locks
- Zombie locks after crash
- Unvalidated inputs (instance type, notify target)
- Silent failure when an expected anchor is absent
- Hardcoded paths that break on a different setup

**Out of scope (accepted by design)**:
- Inter-instance authentication: cooperative fleet, single-user. Re-evaluate if network-exposed.
- Spoofable instance identity (hostname): all scripts use `CLAUDE_AGENT_NAME → instance-name → hostname` in priority order. Sufficient in single-user context.
- `wsl --wakeup` without IPC authentication: same justification.

[↑ table of contents](#top)

---

<a id="pattern-1"></a>
## 🔒 Pattern 1 — Escape values injected into sed

_Any special character in a value injected into a sed pattern must be escaped before substitution._

**File**: `fleet/fleet-state.sh`

**Problem**: sed injection via the VAL variable.
```bash
UPDATES+=("s|^${KEY}:.*|${KEY}: ${VAL}|")
```
If VAL contains `|`, the sed script is corrupted.

**Fix**:
```bash
VAL_ESC="${VAL//|/\\|}"
UPDATES+=("s|^${KEY}:.*|${KEY}: ${VAL_ESC}|")
```

**Commit**: 3e8568d. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-2"></a>
## ✅ Pattern 2 — Validation whitelist for uncontrolled inputs

_Any value from an external source must be validated against an exhaustive whitelist before being used in a command._

> [!WARNING]
> Any parameter coming from an external file (handoff, config, env) must pass through a whitelist before injection into a command. Unlisted values → `exit 1`, never silent.

**File**: `fleet/fleet-notify.sh`

**Problem**: the target was accepted without a whitelist.

**Fix**:
```bash
case "$TARGET" in
    dev|builder|steward|engineer|lordzurp|none) ;;
    *) echo "fleet-notify: unknown target '$TARGET'" >&2; exit 1 ;;
esac
```

**Also applied to**: `post-install.sh` (instance type validated by `case` with `base` fallback + warn).

**Commit**: 3e8568d. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-3"></a>
## 🔐 Pattern 3 — Robust lock lifecycle

_The owner token must be precise enough to detect usurpations, and acquire must handle stale locks without infinite blocking._

**Files**: `handoff-lock-acquire.sh`, `handoff-lock-release.sh`

### Acquire

**Initial problem**: fixed sleep, no backoff. Incomplete owner token (PPID alone).

**Fix**:
- Owner token: `PID:hostname:timestamp`
- Exponential backoff: 2s → 4s → 8s → 16s → 30s (cap)
- Stale lock detection: if owner process is dead → force release + log

### Release

**Initial problem**: PPID+hostname validation but `exit 0` even on mismatch (lock silently not released).

**Fix**:
- Validate `PID:hostname` from the owner token
- On mismatch: log to stderr `"lock mismatch: expected ... got ..."`, exit 1
- The caller is responsible for handling exit 1

**Commit**: 3e8568d + 2026-03-03. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-4"></a>
## 🧹 Pattern 4 — Zombie lock cleanup

_Orphaned locks after a crash must be detected and removed at session startup to prevent permanent blocking._

**Problem**: locks in `/tmp/handoff-locks/` persist after agent crash. Handoffs remained blocked until manual intervention.

**Fix**:
- `fleet/fleet-lock-cleanup.sh`: removes locks whose owner process no longer exists and locks older than 1h
- Called in `session-startup.sh` before any context injection

**Commit**: 3e8568d. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-5"></a>
## 🛡️ Pattern 5 — Startup sentinel cleanup

_Session sentinels must be time-bounded to avoid false detections after reboot._

**File**: `session-startup.sh`

**Problem**: sentinels in `/tmp/` accumulate. PPID reused after WSL reboot → false "already started" detection.

**Fix**:
- `trap EXIT` to clean up the current session's sentinel
- Cleanup of sentinels older than 24h at startup

**Commit**: 3e8568d. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-6"></a>
## 🔍 Pattern 6 — Structure validation before injection

_Verify the existence of the target anchor before any injection sed — a sed with no match is silent by default._

> [!CAUTION]
> A `sed` that matches no anchor writes nothing and returns no error. Without an explicit guard, an injection failure is undetectable.

**General problem**: several scripts injected content into files by assuming an anchor (markdown section) exists. If the anchor is absent, sed matches nothing — without error.

**Affected files**:
- `fleet-state.sh`: checks `grep -q "^## STATE"` before the sed operations
- `fleet-inject.sh`, `fleet-append.sh`, `fleet-done.sh`: check `grep -q anchor` before injection
- `on-prompt.sh`: logs to stderr if `fleet-state.sh` is absent or returns non-0 (instead of silent exit 0)

**Pattern**:
```bash
if ! grep -q "^## STATE" "$HANDOFF"; then
    echo "[fleet-state] WARNING: ## STATE section not found in $HANDOFF" >&2
    exit 1
fi
```

**Commit**: 3e8568d. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-7"></a>
## 🗺️ Pattern 7 — Guards on hardcoded paths

_System paths must be resolved dynamically with a fallback, never assumed fixed._

**File**: `fleet/wake-instance.sh`

**Problem**: hardcoded WSL path `C:\Windows\System32\wsl.exe`.

**Fix**:
```bash
WSL_EXE=$(command -v wsl.exe 2>/dev/null || echo "/mnt/c/Windows/System32/wsl.exe")
```

**File**: `deploy.sh`

**Problem**: hardcoded instance paths → crash if the instance does not exist.

**Fix**: `[SKIP — not found]` in the log, continues to other instances without interrupting the deployment.

**Commit**: 71c381a. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="pattern-8"></a>
## 💾 Pattern 8 — Backup validation

_A backup without verification of expected files is an unreliable backup — partial failure must be visible._

**File**: `toolbox/backup-wsl.sh`

**Problem**: backup without verification of expected files. A partially mounted home passed silently.

**Fix**: for each instance, checks `settings.local.json` + `instance-name`. If absent: WARN + increments error counter. Final report: N instances OK / M instances with warnings.

**Commit**: 71c381a. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="decisions-acceptees"></a>
## ⚖️ Accepted decisions (non-fixes)

_Risks explicitly evaluated and maintained as-is — each entry has a documented justification._

| Risk | Justification |
|---|---|
| IPC without authentication | Single-user, not network-exposed. Re-evaluate if network-exposed. |
| `wake-instance.sh`: ~~no message whitelist~~ | **FIXED** SEC-09 (e435ee1) — `tr -cd '[:print:]' \| head -c 500` at assignment. |
| `handoff-trim.sh`: hardcoded exemption list | 5 stable entries, premature abstraction |
| `deploy.sh`: non-generic skills filtering | 1 rule, 1 skill — premature abstraction |
| `curl\|bash` for Claude Code install | Hash not published by Anthropic. Verification impossible. Documented in post-install.sh. |
| `Instanciator.ps1`: ~~bulk .ssh copy~~ | **FIXED** SEC-06 — selective copy: `id_ed25519`, `id_rsa`, `known_hosts` only. `config` and `authorized_keys` excluded. |

[↑ table of contents](#top)

---

<a id="visibilite-publique"></a>
## 👁️ Public visibility rule

_Work plans are never versioned in a public repo — only guides, containing no exploitation information, are._

> [!IMPORTANT]
> Work plans (`todo/`, `doing/`, `done/`) are never versioned in a public repo. Guides (`guides/`) remain versioned — they contain no exploitation information.

**Context**: LCARS-fleet is a public repo. Work plans in `docs_and_plans/work/` contained the document `Audit sécurité dédié — LCARS-fleet.md` with SEC-01 to SEC-11 — exact locations and exploitation paths.

**Fix**: `docs_and_plans/work/` added to `.gitignore`, 19 files untracked via `git rm --cached`. Files remain on disk for local use.

**Commit**: 95c28e9. **Status**: implemented.

[↑ table of contents](#top)

---

<a id="no-error-masking"></a>
## ⚠️ General rule — No error masking

_Masking errors in a provisioning script turns a detectable problem into a silent incident._

Extracted from `home_claude_CLAUDE.md`, applicable to all fleet scripts:

> `2>/dev/null` is forbidden on diagnostic or exploratory commands. Acceptable only when failure is expected and non-informative (e.g. `git pull 2>/dev/null || true` on a non-critical sync).

Errors are information. Masking them in a provisioning or deployment script turns a detectable problem into a silent incident.

[↑ table of contents](#top)
