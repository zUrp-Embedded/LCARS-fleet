---
name: drift-audit
description: >
  Drift audit for LCARS fleet directives and configuration.
  Detects divergence between documented rules and actual code/state.
  Produces a structured report with severity-tagged findings.
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(cat:*)
  - Bash(git:*)
  - Bash(wc:*)
when_to_use: >
  Use when the DRIFT AUDIT DUE alert appears at session start, or when
  the user requests a drift audit after major toolkit changes.
  Examples: '/drift-audit', 'check for drift', 'audit LCARS coherence'.
---
# Skill: /drift-audit

Automated drift audit for LCARS. Runs 5 parallel Explore agents to detect drift between
implemented plans and actual system state. Compiles a report, notifies engineer.

Invoke when: `/drift-audit` — typically triggered by the starfleet after seeing the DRIFT AUDIT DUE
alert at boot, or manually after major toolkit changes.

---

## Step 0 — Confirm context

Read current commit counts:
```bash
cat /home/fleet-state/fleet-state/lcars-commit-count
cat /home/fleet-state/fleet-state/lcars-commit-count-at-audit
```

The difference is the number of commits since last audit. Proceed regardless of value.

---

## Step 1 — Audit 5 groups sequentially

Execute each audit group sequentially. Read the files, check the rules, log findings.
NO sub-agents — each group is audited directly by the executing agent.

**Group A — Hardcoded paths and fleet-env.sh sourcing**
Look for:
- Hardcoded paths like `$ARCHITECT_HOME`, `/local/LCARS`, `~/.lcars` that should use variables
- Scripts that use fleet paths without sourcing `fleet-env.sh`
- References to old paths (`#0_directives`, `#1_docs`, `#2_fleet`, `#7_exchange`, `#8_handoffs` in code)
- `$HOME/.lcars` used inconsistently vs the canonical symlink

Search in: `fleet/`, `.claude/hooks/`, `*.sh`, `fleet/provisioning_v2/provision`

**Group B — Provisioning coherence**
Look for:
- Discrepancies between `fleet/provisioning_v2/provision` and its `modules.d/` steps (the three v1 scripts this named were retired 2026-08-06 with the v1 tree; no v2 file carries their names)
- Steps documented in guides but not implemented (or vice versa)
- Ordering issues in post-install scripts (sourcing before definition, subshell calls losing context)
- CLAUDE.md directives referenced in scripts that don't match current file content

Search in: `fleet/provisioning_v2/`, `docs/`

**Group C — CLAUDE.md directives vs code reality**
Look for:
- Instance scope rules (who can write which channel) violated in scripts
- Non-wakeable instances (architect) referenced in `wake-instance.sh`
- IPC protocol documented rules not reflected in actual handoff file writes
- Role capabilities (dev/qualifier/starfleet/engineer/builder) mismatched with script behavior

Search in: `.claude/CLAUDE*.md`, `fleet/wake-instance.sh`, `.claude/hooks/`, `fleet/fleet-send.sh`

**Group D — Atomicity patterns**
Look for:
- `sed -i` used on any file in `$FLEET_HANDOFFS` or on source files in the repo
- Missing `set -euo pipefail` in scripts that perform destructive operations
- IPC writes to `/home/fleet-state/` that are not atomic (write-then-rename pattern)
- Temporary files not cleaned up on exit (missing trap)

Search in: all `*.sh` files

**Group E — LCARS compliance (GO checklist)**
Look for:
- GO-7: versioned files missing ship's manifest header (source .sh/.py or .md Date/Statut block)
- GO-5: raw `cat >>` or `echo >>` to IPC files (to-*.md, *-handoff.md) instead of fleet helpers
- Auditabilite: machine-readable files without human-readable counterpart (or vice versa)

Search in: `fleet/`, `.claude/`

---

## Step 2 — Compile report

Write atomically to `/home/fleet-state/drift-audit-report.md`:

```bash
REPORT_TMP="/home/fleet-state/drift-audit-report.md.tmp"
REPORT="/home/fleet-state/drift-audit-report.md"
# ... write to REPORT_TMP ...
mv "$REPORT_TMP" "$REPORT"
```

Report format:
```markdown
# Drift audit report — YYYY-MM-DD
Commits since last audit: N

## Findings
| Group | File:line | Description | Severity |
|-------|-----------|-------------|----------|
| A | fleet/foo.sh:42 | Hardcoded path instead of /home/fleet-state | LOW |
| D | .claude/hooks/bar.sh:15 | sed -i on IPC file | HIGH |

## No drift
- Group X: PASS — no issues found
```

Severity:
- **LOW**: cosmetic, documentation, non-breaking inconsistency
- **HIGH**: runtime risk, data corruption risk, role boundary violation

If no findings in any group, still write the report with all groups as PASS.

---

## Step 3 — Log findings

Afficher le résumé inline pour starfleet. Pas de notification IPC — starfleet traite directement les findings LCARS.

---

## Step 4 — If 0 findings: update at-audit counter

Write atomically:
```bash
cat /home/fleet-state/fleet-state/lcars-commit-count > /home/fleet-state/fleet-state/lcars-commit-count-at-audit.tmp \
    && mv /home/fleet-state/fleet-state/lcars-commit-count-at-audit.tmp \
          /home/fleet-state/fleet-state/lcars-commit-count-at-audit
```

If findings > 0: do NOT update at-audit — starfleet traite les findings directement.
