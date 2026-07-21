#!/usr/bin/env bash
# SOURCE: test/gate-r0.6-tooling.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: MANUAL PROBE v2 — standalone, outside `mix gate` (non-CI). `mix gate` is:
#         compile --warnings-as-errors + test + shell_gate[python+bats] + lcars.contracts.check +
#         lcars.topology --check + dialyzer.
# gate-r0.6-tooling.sh — R0.6. exit 0 iff the static tooling is usable from the runtime root.
#
# WHAT IS ACTUALLY ESTABLISHED, per tool — the three are NOT the same strength, and the difference is
# the point:
#   - Credo   RUNS TO COMPLETION. Signature `Analysis took`, which Credo emits at the END of its run.
#   - Sobelow RUNS TO COMPLETION. Signature `SCAN COMPLETE`, likewise emitted at the end.
#   - Dialyzer is only checked for AVAILABILITY (the mix task exists). It is NOT run here: a cold PLT
#     build is minutes, and `mix gate` runs the real `dialyzer` step anyway. This probe says "the task
#     is wired", nothing more.
# FINDINGS are a baseline, NOT gated to zero (cleanup is a separate job). Reading them is a manual act;
# this script does not compare them to anything.
#
# NO pipefail, and no `grep -q` on a pipe: `mix credo`/`sobelow` can exit non-zero ON FINDINGS, which is
# not an execution failure, so the verdict is the end-of-run signature rather than the exit code. The
# full output is CAPTURED first and matched afterwards — piping into `grep -q` made grep exit on the
# first match and SIGPIPE the tool, which for Sobelow (whose banner prints BEFORE the scan) killed it
# before it analysed a single file, and still scored PASS.
set -u
RT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RT" || exit 1
FAIL=0
echo "== Gate R0.6 — static tooling =="

credo_out="$(timeout 180 mix credo --strict 2>&1)"
if printf '%s' "$credo_out" | grep -q "Analysis took"; then
  echo "PASS CREDO    ran to completion (mix credo --strict)"
else
  echo "FAIL CREDO    did not complete (no 'Analysis took' — crash or timeout)"; FAIL=1
fi

sobelow_out="$(timeout 180 mix sobelow --root . 2>&1)"
if printf '%s' "$sobelow_out" | grep -q "SCAN COMPLETE"; then
  echo "PASS SOBELOW  ran to completion (mix sobelow --root .)"
else
  echo "FAIL SOBELOW  did not complete (no 'SCAN COMPLETE' — crash or timeout)"; FAIL=1
fi

# `mix help <task>` exits 0 when the task exists and 1 when it does not: that exit code is the
# discriminating predicate. The previous form, `mix help dialyzer 2>&1 | grep -qi dialyzer`, matched its
# OWN NEGATION — Mix interpolates the task name into `** (Mix) The task "dialyzer" could not be found`,
# so the grep hit whether or not dialyxir was a dependency. Measured both ways before replacing it.
if mix help dialyzer >/dev/null 2>&1; then
  echo "PASS DIALYZER task wired (NOT run here — PLT cost; mix gate runs it)"
else
  echo "FAIL DIALYZER task absent (dialyxir not a dependency?)"; FAIL=1
fi

echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R0.6: exit 0 — Credo + Sobelow complete, Dialyzer wired" || echo "GATE R0.6: exit 1"
exit "$FAIL"
