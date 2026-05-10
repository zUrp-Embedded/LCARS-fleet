---
name: project-audit
description: >
  Generic project audit for code quality, documentation drift, and security patterns.
  Works on any repo. Optional --lcars flag adds LCARS directive compliance.
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(git:*)
  - Bash(wc:*)
when_to_use: >
  Use when the user wants a comprehensive audit of a project repository.
  Examples: '/project-audit', 'audit this project', '/project-audit --lcars'.
argument-hint: "[--lcars] [path]"
arguments:
  - flags
---
# Skill: /project-audit

Generic project audit. Scans sequentially for code quality issues,
documentation drift, and security patterns. Works on any repo.

Optional `--lcars` flag adds LCARS directive compliance (GO-0 through GO-7 + 4 Starfleet Principles).

```
/project-audit                    ← audit cwd repo
/project-audit --lcars            ← + LCARS compliance (fleet projects)
/project-audit <github-url>       ← clone external repo + audit (no --lcars)
```

Invoke when: manual, by architect or engineer. No IPC notification — results displayed or written to project.

---

## Step 0 — Resolve target

- No args → `cwd` must be a git repo root (or find it via `git rev-parse --show-toplevel`)
- GitHub URL → clone to `/home/tmp/project-audit-<slug>`, cd into it
- Detect languages/stack: scan for `*.sh`, `*.py`, `*.cpp`, `CMakeLists.txt`, `package.json`, `Cargo.toml`, etc.
- If `--lcars`: GO definitions + Starfleet Principles are in the system prompt (core rules)

---

## Step 1 — Launch Explore agents in parallel

### Always (4 agents):

**Group A — Hardcoded paths & portability**
- Absolute paths (`/home/<user>`, `/usr/local/...`) that should be variables or relative
- Machine-specific assumptions (hardcoded usernames, hostnames, arch-specific paths)
- Missing env var fallbacks for configurable paths
- `$HOME` used where a project-relative path would be portable

Search in: all source files

**Group B — Code quality & robustness**
- Shell scripts missing `set -euo pipefail`
- `sed -i` without backup on shared/critical files
- Temp files without `trap` cleanup on EXIT
- Error masking: `2>/dev/null` on diagnostic commands
- Unquoted variables in shell (`$VAR` instead of `"$VAR"`)

Search in: `*.sh`, `*.bash`

**Group C — Documentation ↔ code drift**
- README references to files/features/APIs that no longer exist
- Documented CLI flags not implemented (or vice versa)
- Comments referencing old function/file names post-rename
- Stale TODO/FIXME/HACK markers older than 6 months (check git blame)

Search in: `*.md`, all source files for comments

**Group D — Security patterns**
- `.env` files committed (check `.gitignore`)
- Secrets/tokens/passwords in source (API keys, hardcoded credentials)
- Overly permissive file permissions set in scripts (`chmod 777`, `chmod a+w`)
- Unvalidated user input passed to shell commands (injection risk)

Search in: all files, `.gitignore`

### With `--lcars` (add 2 more agents):

**Group E — GO compliance**
- **GO-0**: implicit behavior — agents guessing instead of following explicit rules
- **GO-2**: MR files without HR counterpart, or HR without MR (captain's log chain)
- **GO-5**: raw `cat >>` or `echo >>` to IPC files instead of fleet helpers
- **GO-6**: directory/file names that don't express function (opaque numbers, acronyms)
- **GO-7**: versioned files missing ship's manifest header

Search in: all versioned files

**Group F — Starfleet Principles**
- **IDIC**: arch-specific code without portable fallback, hardcoded platform assumptions
- **Holodeck Containment**: scripts writing outside their declared scope boundaries
- **First Contact Protocol**: project missing onboarding artifacts (project.yaml, L2 domain files)
- **TPD**: `push --force`, `commit --amend` on shared branches, `rebase` on fetched branches

Search in: all source files, `.git/hooks/`, CI config

---

## Step 2 — Compile report

Write to outbox: `$FLEET_READY_ROOM/audit-report-<slug>-YYYY-MM-DD.md`

```markdown
# Project audit — YYYY-MM-DD
Target: <repo name>
Mode: standard | lcars
Languages: <detected>

## Findings
| Group | File:line | Description | Severity |
|-------|-----------|-------------|----------|
| A | src/config.sh:42 | Hardcoded /home/john | LOW |
| D | lib/auth.py:15 | API key in source | HIGH |

## Pass
- Group X: PASS — no issues found

## Summary
- HIGH: N findings (fix before merge/deploy)
- LOW: N findings (cleanup backlog)
```

---

## Step 3 — Display summary

Output to conversation:
- Total findings by severity
- Top 3 HIGH findings with file:line
- One-liner per PASS group
- If `--lcars`: which GO/Principles are violated vs clean
