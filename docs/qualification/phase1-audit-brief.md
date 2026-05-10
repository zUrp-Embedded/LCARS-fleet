# Phase 1 Audit Brief — Independent Review Request

**Date**: 2026-03-25
**From**: starfleet (Tier 0)
**To**: consultant (advisory scope, analysis)
**Subject**: Independent audit of LCARS v6 qualification Phase 1 deliverables

---

## Context

LCARS v6 qualification is an 8-phase plan to bring 77 fleet scripts (11 116 LOC) to
production quality. Phase 1 (Tooling) was implemented by StarFleet. Phase 2 (Kernel)
cannot start until Phase 1 is independently validated — the implementor does not
sign their own GO.

## Phase 1 scope — what was promised

Phase 1 deliverables per the qualification plan (`work/TODO/v6-qualification-plan.md`):

1. **Tooling installed**: shellcheck, bats-core (via git submodules), kcov (built from source)
2. **Test harness**: mocks, helpers, fixtures enabling isolated unit testing of fleet scripts
3. **Smoke tests**: validate the harness itself works (mocks load, filesystem created, assertions work)
4. **CI pipeline**: GitHub Actions workflow running shellcheck + bats + kcov on every push
5. **Pre-commit hook**: shellcheck validation on staged `.sh` files before commit

## Artifacts to audit

All artifacts are on `main` branch, commit `eaa635d`.

### Test infrastructure
| Artifact | Path | Description |
|----------|------|-------------|
| Smoke tests | `tests/unit/test_smoke.bats` | 21 tests validating harness |
| Test helpers | `tests/helpers/test_helpers.bash` | Shared setup/teardown, temp filesystem |
| Mock fleet-env | `tests/helpers/mock_fleet_env.bash` | 23 vars + 8 functions |
| Mock tmux | `tests/helpers/mock_tmux.bash` | Simulates tmux commands |
| Mock yq | `tests/helpers/mock_yq.bash` | Simulates yq queries |
| Mock claude | `tests/helpers/mock_claude.bash` | Simulates claude CLI |
| Fixture fleet.yaml | `tests/fixtures/fleet.yaml` | Minimal valid fleet config |
| Fixture valid msg | `tests/fixtures/valid-message.md` | Well-formed IPC message |
| Fixture malformed msg | `tests/fixtures/malformed-message.md` | Broken IPC message |
| Fixture ping msg | `tests/fixtures/ping-message.md` | PING message |

### CI pipeline
| Artifact | Path | Description |
|----------|------|-------------|
| Workflow | `.github/workflows/quality.yml` | 3 jobs: shellcheck, bats, kcov |
| Shellcheck runner | `tests/run-shellcheck.sh` | Wraps shellcheck across fleet scripts |

### Pre-commit hook
| Artifact | Path | Description |
|----------|------|-------------|
| Hook source | `fleet/hooks/pre-commit-lcars.sh` | Versioned source of truth |
| Installed hook | `.git/hooks/pre-commit` | Deployed copy (not versioned) |

### Submodules
| Submodule | Path | Version |
|-----------|------|---------|
| bats-core | `tests/.bats/bats-core/` | v1.13.0-33 |
| bats-assert | `tests/.bats/bats-assert/` | v2.2.4-2 |
| bats-file | `tests/.bats/bats-file/` | v0.2.0-129 |

## Current state — observed facts

| Check | Result |
|-------|--------|
| `bats tests/unit/test_smoke.bats` | 21/21 pass |
| CI job: Bats Tests | success |
| CI job: Coverage (kcov) | success |
| CI job: ShellCheck | failure (expected — 65/87 scripts fail, Phase 2+ work) |
| Pre-commit hook installed | yes, shellcheck clean |

## What to verify — audit checklist

### A. Completeness
1. Are all promised deliverables present and functional?
2. Does the smoke test suite actually validate what it claims?
3. Do the mocks accurately reflect the real interfaces they replace?
   - `mock_fleet_env.bash`: compare exported vars/functions against real `fleet/fleet-env.sh`
   - `mock_yq.bash`: compare query patterns against actual yq usage in fleet scripts
   - `mock_tmux.bash`: compare simulated commands against actual tmux usage

### B. Correctness
4. Run `bats tests/unit/test_smoke.bats` — do all 21 tests pass?
5. Read each test: does the assertion actually test what the test name claims?
6. Are there obvious gaps — things that should be tested but aren't?
7. `test_helpers.bash`: does `_setup` create a clean isolated environment? Does `_teardown` clean up?

### C. CI pipeline
8. Read `.github/workflows/quality.yml` — are the 3 jobs correctly configured?
9. Is shellcheck failure correctly expected (not masking real issues)?
10. Is kcov measuring the right files?

### D. Pre-commit hook
11. Read `fleet/hooks/pre-commit-lcars.sh` — does it do what it should (shellcheck staged .sh)?
12. Any bypass paths (--no-verify is user's choice, but does the hook itself have holes)?

### E. Structural
13. Are submodules pinned to specific commits (not floating branches)?
14. Is the test directory structure clean and navigable?
15. Any circular dependencies or fragile assumptions in the harness?

## Deliverable expected

Structured report: PASS/FAIL per checklist item, with findings for any FAIL.
Overall verdict: GO / NO-GO for Phase 2.
File output: `/home/ready-room/outbox/audits/phase1-audit-report.md`

## Constraints

- Read-only audit. Do not modify any file.
- Scope is Phase 1 only. Do not audit the fleet scripts themselves (that's Phase 2+).
- The plan file is in `work/TODO/` (gitignored) — read it for context but it's not a deliverable.
- FMEA files in `docs/qualification/fmea/` are reference material, not Phase 1 deliverables.
