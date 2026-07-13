# Phase 1 Audit Report — Independent Review

**Date** : 2026-03-25
**Dernière révision** : 2026-03-25
**Statut** : COMPLETE
**Référencé par** : phase1-audit-brief.md
**Dérivé de** : —

**Auditor**: consultant (Tier 2, advisory scope)
**Commit audited**: eaa635d (main)
**Scope**: Phase 1 (Tooling) deliverables only

---

## Verdict: CONDITIONAL GO

Phase 2 peut démarrer sous réserve que les 2 findings soient reconnus et planifiés.
Aucun des findings ne bloque techniquement le travail Phase 2.
Détails ci-dessous.

---

## A. Completeness

### 1. All promised deliverables present and functional?

**PASS (with finding)**

| Plan item | Artifact | Present | Functional |
|-----------|----------|---------|------------|
| 1.1 shellcheck | apt install | ✅ | ✅ |
| 1.1 kcov | built from source (CI) | ✅ | ✅ |
| 1.2 bats submodules | tests/.bats/ (3 submodules) | ✅ | ✅ |
| 1.3 mock_fleet_env | tests/helpers/mock_fleet_env.bash | ✅ | ✅ |
| 1.4 mock_tmux | tests/helpers/mock_tmux.bash | ✅ | ✅ |
| 1.5 mock_yq | tests/helpers/mock_yq.bash | ✅ | ✅ |
| 1.6 mock_claude | tests/helpers/mock_claude.bash | ✅ | ✅ |
| 1.7 test_helpers | tests/helpers/test_helpers.bash | ✅ | ✅ |
| 1.8 fixtures | tests/fixtures/ (4 files) | ✅ | ✅ |
| 1.9 run-tests.sh | tests/run-tests.sh | ✅ | ✅ |
| 1.10 run-shellcheck.sh | tests/run-shellcheck.sh | ✅ | ✅ |
| 1.11 smoke test | tests/unit/test_smoke.bats (21 tests) | ✅ | ✅ |
| 1.12 CI workflow | .github/workflows/quality.yml (3 jobs) | ✅ | ✅* |

\* ShellCheck job fails — see Finding #2.

**Note**: the brief lists a 5th deliverable "Pre-commit hook: shellcheck validation on staged .sh files before commit" which is NOT in the qualification plan's Phase 1 items 1.1–1.12. The actual qualification plan places `pre-commit-lcars.sh` in Phase 3 (Safety). The hook exists on main and works, but it does GO-7 header enforcement — not shellcheck. See Finding #1.

**Note**: Plan item 1.8 mentions `fleet-system.yaml` as a fixture. Only `fleet.yaml` is present. This is acceptable — `fleet.yaml` is sufficient for testing and fleet-system.yaml (the source from which fleet.yaml is generated) is not needed by the test harness.

### 2. Smoke test suite validates what it claims?

**PASS**

21 tests organized in 5 groups:
- Mock loading (10 tests): vars, functions, tier queries, pane lookup
- Mock tmux (3 tests): session detection, logging
- Mock yq (2 tests): path queries, unknown queries
- Test filesystem (4 tests): spool dirs, processing/consumed, homes, fixtures
- bats-assert self-test (2 tests): assert_equal, assert_output

Each test name accurately describes what the assertion checks. No misleading names.

### 3. Mocks accurately reflect real interfaces?

**PASS**

**mock_fleet_env.bash vs fleet-env.sh:**
- Variables: 23/23 exported variables present ✅
  - Verified: LCARS_ROOT, HOMES_ROOT, FLEET_YAML, FLEET_DIR, FLEET_DIRECTIVES, FLEET_DOCS, FLEET_KNOWLEDGE, FLEET_HANDOFFS, FLEET_STATE_DIR, FLEET_LOGS, FLEET_READY_ROOM, FLEET_TMUX_SOCK, FLEET_HUB_PORT, FLEET_SPOOL, FLEET_SPOOL_INBOX, FLEET_SPOOL_OUTBOX, FLEET_PENDING_WAKES, FLEET_INSTANCE, FLEET_USER, FLEET_USER_HOME, ARCHITECT_USER, ARCHITECT_HOME, LCARS_REPO
- Functions: 8/8 exported functions present ✅
  - Verified: fleet_roles, fleet_roles_by_tier, fleet_roles_stateless, fleet_roles_stateful, fleet_role_field, fleet_tmux, fleet_find_pane, fleet_bin
- All paths redirect to BATS_TEST_TMPDIR (no real filesystem leakage) ✅
- FLEET_INSTANCE overridable via MOCK_FLEET_INSTANCE ✅
- The mock header references `test_mock_coherence.bats` for ongoing coherence — this test doesn't exist yet (future Phase work). Not a problem, just a forward reference.

**mock_yq.bash vs real yq usage in fleet-env.sh:**
- Handles 10 query patterns covering all fleet-env.sh queries
- Minor gap: `.fleet.runtime.hub_port` not in mock's case statement — returns "null" via fallback. Acceptable because fleet-env.sh has its own fallback for null/missing values.
- Logs unhandled queries to yq.log — good for debugging

**mock_tmux.bash vs real tmux usage:**
- Covers: has-session, send-keys, list-panes, list-sessions, new-window, split-window, select-pane, kill-pane
- All calls logged to tmux.log
- MOCK_TMUX_SESSIONS configurable (defaults to "fleet")
- Sufficient for Phase 2 script testing

**mock_claude.bash:**
- Covers headless mode (`claude -p`) — consumes stdin, returns mock output
- Logs all calls
- Minimal but sufficient for dispatch testing

---

## B. Correctness

### 4. All 21 tests pass?

**PASS**

```
1..21
ok 1 mock_fleet_env: FLEET_INSTANCE is set
ok 2 mock_fleet_env: FLEET_INSTANCE defaults to starfleet
ok 3 mock_fleet_env: all 23 exported variables are set
ok 4 mock_fleet_env: all paths point to tmpdir (no real filesystem)
ok 5 mock_fleet_env: fleet_roles returns known roles
ok 6 mock_fleet_env: fleet_roles_by_tier 0 returns tier 0 agents
ok 7 mock_fleet_env: fleet_role_field returns correct values
ok 8 mock_fleet_env: fleet_role_field unknown returns null
ok 9 mock_fleet_env: fleet_find_pane returns pane for known agents
ok 10 mock_fleet_env: fleet_find_pane returns empty for unknown agents
ok 11 mock_tmux: tmux has-session succeeds for fleet
ok 12 mock_tmux: tmux has-session fails for unknown session
ok 13 mock_tmux: tmux calls are logged
ok 14 mock_yq: returns fleet paths
ok 15 mock_yq: unknown query returns null
ok 16 test_helpers: spool inbox directories exist
ok 17 test_helpers: spool processing/consumed subdirs exist
ok 18 test_helpers: homes directories exist
ok 19 test_helpers: fixtures are copied
ok 20 bats-assert: assert_equal works
ok 21 bats-assert: assert_output works with run
```

21/21 pass. Zero flaky. Zero skip.

### 5. Each assertion tests what its name claims?

**PASS**

Reviewed all 21 tests individually. Every assertion matches its test name. Notable good practices:
- Test #3 checks all 23 variables individually (not just a count)
- Test #4 verifies paths are under BATS_TEST_TMPDIR (isolation proof)
- Tests #9-10 cover both positive and negative cases for fleet_find_pane
- Tests #11-12 cover both positive and negative cases for tmux has-session

### 6. Obvious gaps?

**PASS (with observations)**

For a *smoke* test suite, the coverage is appropriate. The purpose is to validate the harness works, not to exhaustively test mocks. Observations for future phases:

- mock_claude: no dedicated test (only indirectly loaded). Acceptable — it's 23 lines with trivial logic.
- fleet_roles_stateless, fleet_roles_stateful: not smoke-tested. These functions are straightforward echoes.
- fleet_bin, fleet_tmux: not smoke-tested. fleet_bin is PATH-based, fleet_tmux is a logging wrapper.
- mock_yq: only 2 tests (positive path + null). Could test more query patterns in Phase 2+ when scripts exercise them.

None of these are blocking — Phase 2 script tests will exercise these code paths naturally.

### 7. _setup creates clean isolated environment? _teardown cleans up?

**PASS**

**_setup:**
- Creates full directory tree under BATS_TEST_TMPDIR (unique per test, bats-managed)
- Structure mirrors real fleet: lcars/, homes/, handoffs/, fleet-state/, ready-room/, spool/
- Loads bats-assert and bats-file for rich assertions
- Sources all 4 mocks in correct order (fleet_env first — sets paths)
- Copies fixtures into tmpdir
- Adds test bin dir + real fleet scripts to PATH
- No global state modified outside BATS_TEST_TMPDIR ✅

**_teardown:**
- Relies on bats automatic cleanup of BATS_TEST_TMPDIR ✅
- Explicit no-op function (`:`) — correct, extensible for future cleanup needs
- No leaked temp files, processes, or side effects

---

## C. CI Pipeline

### 8. Three jobs correctly configured?

**PASS**

| Job | Runner | Submodules | Action | Depends on |
|-----|--------|------------|--------|------------|
| ShellCheck | ubuntu-24.04 | ✅ | installs shellcheck, runs run-shellcheck.sh | — |
| Bats Tests | ubuntu-24.04 | ✅ | runs run-tests.sh | — |
| Coverage | ubuntu-24.04 | ✅ | builds kcov v43, runs kcov | tests |

- All 3 jobs checkout with `submodules: true` ✅
- Coverage correctly depends on tests (won't run if tests fail) ✅
- Coverage uploads artifact with 30-day retention ✅
- Trigger: push to main + PRs to main ✅

### 9. ShellCheck failure correctly expected?

**CONDITIONAL PASS — Finding #2**

The ShellCheck job runs `tests/run-shellcheck.sh` which exits 1 when any script has warnings. Currently 65/87 scripts fail (expected — these are the fleet scripts that Phase 2+ will fix).

**Problem**: the workflow does NOT use `continue-on-error: true` on the ShellCheck job. This means:
- Every push to main shows failed CI (red badge)
- Every PR shows failed checks
- The Phase 1 Gate criterion "CI GitHub Actions verte" is technically unmet

**Impact**: CI fatigue — a permanently red pipeline normalizes failure and can mask real regressions in bats tests or coverage. The bats and coverage jobs pass independently, but the overall workflow status is FAIL.

**Recommendation**: Either:
A) Add `continue-on-error: true` to the shellcheck job (remove when Phase 2 fixes all scripts)
B) Or adjust the gate criterion to "Bats + kcov jobs green, ShellCheck tracked separately"

### 10. kcov measuring the right files?

**PASS**

```yaml
kcov --include-path=fleet/ /tmp/kcov-report tests/.bats/bats-core/bin/bats tests/unit/
```

- `--include-path=fleet/` correctly targets fleet scripts only ✅
- Runs bats against `tests/unit/` ✅
- Coverage report uploaded as artifact ✅
- Coverage scope will grow automatically as Phase 2+ adds tests

---

## D. Pre-commit Hook

### 11. Does it do what it should?

**FAIL — Finding #1**

**Brief's deliverable #5**: "Pre-commit hook: shellcheck validation on staged .sh files before commit"

**Actual behavior**: The hook (`fleet/hooks/pre-commit-lcars.sh`) does:
- Pass 1: Date bookkeeping (auto-updates STARDATE or ISO dates on staged files)
- Pass 2: GO-7 header enforcement (blocks commit if .md or source files lack required headers)

**It does NOT run shellcheck on staged files.**

The hook is well-written, useful, and correctly implements GO-7 enforcement. But it's not the deliverable described in the brief.

**Mitigating factors**:
- The actual qualification plan (work/TODO/v6-qualification-plan.md) places `pre-commit-lcars.sh` in Phase 3, NOT Phase 1
- Phase 1 items 1.1–1.12 do not mention a pre-commit hook
- The brief's inclusion of the pre-commit hook as a Phase 1 deliverable appears to be a scope addition by the brief author

**Recommendation**: Acknowledge the mismatch. Two options:
A) Accept the GO-7 hook as a bonus deliverable and note that shellcheck pre-commit is deferred to Phase 3
B) Add shellcheck behavior to the existing hook (or as a separate hook) if it was truly intended for Phase 1

### 12. Any bypass paths?

**PASS**

- Only bypass: `git commit --no-verify` (git's own mechanism — user's explicit choice, not a hole)
- `hook-config.sh` sourced with safe fallback: if missing, defaults to `HOOK_REPO_TYPE="project"` and `HOOK_DATE_FORMAT="iso"`. File is indeed missing from the hooks directory, but the fallback is clean.
- Exception list (`is_ipc_exception`) correctly excludes: handoffs, IPC messages, MEMORY.md, scratchpad.md, archives, roles, skills, test fixtures
- No hidden bypass paths in the code

---

## E. Structural

### 13. Submodules pinned to specific commits?

**PASS**

```
697471b tests/.bats/bats-assert (v2.2.4-2-g697471b)
d9faff0 tests/.bats/bats-core   (v1.13.0-33-gd9faff0)
6bee58b tests/.bats/bats-file   (v0.2.0-129-g6bee58b)
```

All 3 submodules pinned to specific commit SHAs ✅. Not floating on branch HEAD. Versions match what the brief stated.

### 14. Test directory structure clean and navigable?

**PASS**

```
tests/
├── .bats/              ← submodules (bats-core, bats-assert, bats-file)
├── helpers/            ← mocks + test_helpers.bash
├── fixtures/           ← test data (fleet.yaml, IPC messages)
├── unit/               ← unit tests (.bats)
├── integration/        ← (empty, ready for Phase 2+)
├── system/             ← (empty, ready for Phase 2+)
├── run-tests.sh        ← entry point (supports unit|integration|system|all)
└── run-shellcheck.sh   ← static analysis runner
```

Clean separation of concerns. Names are self-evident. `run-tests.sh` supports level filtering. Integration and system directories exist as scaffolding for future phases.

### 15. Circular dependencies or fragile assumptions?

**PASS**

- No circular sourcing: test_helpers → mocks → (nothing)
- All paths derived from BATS_TEST_TMPDIR or REPO_ROOT — both set from BASH_SOURCE, portable
- Mock load order documented and enforced (fleet_env first)
- BATS_TEST_TMPDIR is per-test isolated (bats guarantee) — no cross-test contamination
- PATH augmentation is additive (prepend, not replace)
- One forward reference: mock_fleet_env.bash header mentions `test_mock_coherence.bats` — this test doesn't exist yet. It's a documentation note, not a runtime dependency. No impact.

---

## Findings Summary

| # | Severity | Item | Description |
|---|----------|------|-------------|
| **F1** | MEDIUM | Pre-commit hook (#11) | Hook does GO-7 header enforcement, not shellcheck. Brief's deliverable description doesn't match actual behavior. Plan places pre-commit in Phase 3, not Phase 1. |
| **F2** | LOW | CI permanently red (#9) | ShellCheck job fails (65/87 scripts). Gate criterion "CI green" technically unmet. Bats + kcov jobs pass. |

---

## Gate Criteria Evaluation (from qualification plan)

| Gate criterion | Status |
|----------------|--------|
| shellcheck installé et fonctionne | ✅ PASS |
| bats installé (submodule) et le test smoke passe | ✅ PASS (21/21) |
| kcov installé et produit un rapport | ✅ PASS (CI coverage job succeeds) |
| Mocks complets (4 fichiers + helpers) | ✅ PASS (4 mocks + test_helpers) |
| Fixtures présentes | ✅ PASS (4 fixtures) |
| run-tests.sh et run-shellcheck.sh fonctionnels | ✅ PASS |
| CI GitHub Actions verte | ⚠️ CONDITIONAL (bats+kcov green, shellcheck red as expected) |

6/7 gate criteria met. 1 conditional.

---

## Verdict: CONDITIONAL GO

Phase 1 deliverables are substantially complete and functional. The test harness is solid, mocks are faithful to real interfaces, and the CI pipeline works correctly for bats and coverage.

**Conditions for unconditional GO:**

1. **Acknowledge F1**: Confirm pre-commit hook is a Phase 3 deliverable (as per qualification plan) and that its inclusion in the brief was a scope error. OR add shellcheck behavior if it was truly intended.

2. **Resolve F2**: Either add `continue-on-error: true` to the ShellCheck CI job (temporary, until Phase 2 fixes scripts), or amend the gate criterion to "Bats + kcov green."

Neither finding blocks Phase 2 work technically. The harness, mocks, fixtures, and CI infrastructure are ready to support Phase 2 script-by-script qualification.

---

*Audit completed 2026-03-25 by consultant (Tier 2, advisory scope, cold-start review).*
*Read-only audit — no files modified.*
