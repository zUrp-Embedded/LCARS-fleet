#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN (flock seul)
set -u
HERE=$(dirname "$(readlink -f "$0")")
T=$(mktemp -d /tmp/work-ops-XXXXXX)

python3 - <<PY
import sys, os, time, subprocess
sys.path.insert(0, "$HERE/impl-python")
from inbox_flock import exclusive_lock

LOCKFILE = "$T/lock"

# T1 : on prend le lock en parent
with exclusive_lock(LOCKFILE):
    # T2 : subprocess enfant tente le meme lock -> BlockingIOError
    code = '''
import sys
sys.path.insert(0, "$HERE/impl-python")
from inbox_flock import exclusive_lock
try:
    with exclusive_lock("$T/lock"):
        print("CHILD_GOT_LOCK")
except BlockingIOError:
    print("CHILD_BLOCKED")
'''
    r = subprocess.run(["python3", "-c", code], capture_output=True, text=True, timeout=5)
    out = r.stdout.strip()
    if out == "CHILD_BLOCKED":
        print("[PASS] flock exclusif : 2e tentative concurrente bloquee")
    else:
        print(f"[FAIL] flock exclusif: child output={out!r}")
        sys.exit(1)

# T3 : apres release, nouvelle tentative passe
code2 = '''
import sys
sys.path.insert(0, "$HERE/impl-python")
from inbox_flock import exclusive_lock
with exclusive_lock("$T/lock"):
    print("CHILD_GOT_LOCK")
'''
r = subprocess.run(["python3", "-c", code2], capture_output=True, text=True, timeout=5)
if r.stdout.strip() == "CHILD_GOT_LOCK":
    print("[PASS] apres release parent, child prend le lock")
else:
    print(f"[FAIL] release ne libere pas: {r.stdout!r}")
    sys.exit(1)
PY
RC=$?
rm -rf "$T"

echo "[GAP] inbox state machine (inbox -> .processing -> .consumed) : a coder quand fleet-pilot prend forme"
echo "[GAP] pod sans droit git push work/ops : a tester sous provisioning B1"

exit $RC
