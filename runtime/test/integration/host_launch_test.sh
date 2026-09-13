#!/bin/bash
#
# SOURCE: test/integration/host_launch_test.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: PROTO-V2 — integration test for bin/host_launch.sh (LAUNCH-Q, containment: none)
#
# A REALITY datum for host_launch.sh: it actually runs it against tmux, rather than asserting on a
# stubbed argv. The COMMAND is FAKE (no claude, no OAuth, no real agent), so it is safe in CI/dev. What
# the tmux-holder-without-bwrap mechanism is checked to do:
#   1. host_launch creates the per-pod sock-dir (0700) + a `lcars-pod-<id>` tmux session.
#   2. host_launch forwards its opaque COMMAND array VERBATIM ("$@"). The real command is
#      `claude_launch <role> <pod_id> <pod_dir>` (3 args) — the SP is OUT of argv (read from
#      pod_dir/.lcars/system-prompt.md via --system-prompt-file), NOT a 4th positional. We append a
#      synthetic trailing token to PROVE verbatim passthrough (arg count + spaces preserved).
#   3. The holder stays alive (it IS the pod's liveness handle).
#   4. SIGTERM to the holder → trap → `tmux kill-server`: the COMMAND process is reaped and the sock-dir
#      is removed.
#
# WHAT STEP 4 CAN AND CANNOT DECIDE. host_launch.sh's cleanup runs `kill-server` and THEN
# `rm -rf "$POD_SOCK_DIR"` — and the socket file lives inside that dir. So `tmux -S <sock> has-session`
# goes false the moment the directory is removed, whether or not kill-server did anything: on its own it
# cannot tell a working teardown from a broken kill-server plus a working rm. The check that actually
# decides it is on the COMMAND PROCESS: the fake command records its own pid, and after the teardown
# that pid must be gone. That is also the failure the mechanism exists to prevent — an orphaned claude
# outliving its pod.
#
# "No namespace cascade on the host" is a property of the LAUNCHER, not something measured here:
# host_launch.sh contains no --unshare at all (containment: none is the whole point). It is verified by
# reading the file, so it is stated here rather than dressed up as an assertion.
#
# Standalone (needs tmux) — not part of `mix test`. Usage: bash test/integration/host_launch_test.sh

set -uo pipefail          # PAS -e : ce temoin ENCHAINE des cas et compte les echecs pour rendre
                          # un bilan. `-e` s'arreterait au premier, et le compte n'existerait plus.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="${ROOT}/bin/host_launch.sh"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

PASS=0
FAIL=0
step() { echo "==> $*"; }
ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
ko()   { echo "  KO: $*" >&2; FAIL=$((FAIL + 1)); }

# ------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------
step "0. Preconditions"
[ -x "$LAUNCHER" ] && ok "host_launch.sh +x" || { ko "host_launch.sh missing/not-x: $LAUNCHER"; exit 1; }
command -v "$TMUX_BIN" >/dev/null 2>&1 && ok "tmux present ($TMUX_BIN)" || { ko "tmux missing (this test needs it)"; exit 1; }

# ------------------------------------------------------------------
# Ephemeral fixtures
# ------------------------------------------------------------------
WORK="$(mktemp -d)"
SOCK_BASE="$WORK/sock"
POD_DIR="$WORK/pod"
MARKER="$WORK/command_ran.txt"
POD_ID="itest-$$"
SESSION="lcars-pod-$POD_ID"
SOCK="$SOCK_BASE/$POD_ID/pod.sock"
HOLDER_PID=""

cleanup() {
  [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null && kill -TERM "$HOLDER_PID" 2>/dev/null
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$SOCK_BASE" "$POD_DIR"

# Fake COMMAND standing in for claude_launch.sh. Writes a marker proving it received the opaque argv
# VERBATIM, then stays alive (else tmux closes the session at once). The real vendor command is 3 args
# (role/pod_id/pod_dir); $4 here is the synthetic passthrough probe, NOT the SP (SP is out of argv).
FAKE_CMD="$WORK/fake_claude_launch.sh"
cat > "$FAKE_CMD" <<'FAKE'
#!/bin/sh
# expected argv: $1=role $2=pod_id $3=pod_dir $4=probe (synthetic passthrough token, not the SP)
{
  echo "argc=$#"
  echo "role=$1"
  echo "pod_id=$2"
  echo "pod_dir=$3"
  echo "probe=$4"
  # `exec` below REPLACES this shell, keeping the pid — so $$ recorded here IS the sleep's pid. It is
  # what step 3 checks: an orphaned COMMAND surviving its pod is the failure the teardown exists to
  # prevent, and the only observation that distinguishes a real kill-server from `rm -rf` on the sock.
  echo "cmd_pid=$$"
} > "$ITEST_MARKER"
exec sleep 30
FAKE
chmod +x "$FAKE_CMD"

# ------------------------------------------------------------------
# 1. Launch — host_launch runs in the background (it is a holder, it blocks)
# ------------------------------------------------------------------
step "1. host_launch.sh (containment: none) — launch"

# Argv mirrors the vector assembled by LauncherPortBackend.build_spawn (launcher + opaque command):
#   host_launch <role> <pod_id> <pod_dir>  <COMMAND = claude_launch role pod_id pod_dir>
# Here COMMAND = fake_cmd role pod_id pod_dir <probe>: the 4th token is the synthetic passthrough
# probe (spaces preserved), NOT the SP — prod's command is 3 args, SP read from a file out of argv.
ITEST_MARKER="$MARKER" \
LCARS_TMUX_SOCK_BASE="$SOCK_BASE" \
LCARS_TMUX_BIN="$TMUX_BIN" \
LCARS_POD_SESSION_ID="sess-$$" \
LCARS_POD_SESSION_NAME_PREFIX="tester_role" \
  "$LAUNCHER" "role" "$POD_ID" "$POD_DIR" \
              "$FAKE_CMD" "role" "$POD_ID" "$POD_DIR" "passthrough probe with spaces" &
HOLDER_PID=$!

# Wait for the session to appear (the fresh tmux server is created by new-session).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null && break
  sleep 0.3
done

if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ok "tmux session created ($SESSION)"
else
  ko "no tmux session after launch"
fi

[ -d "$SOCK_BASE/$POD_ID" ] && ok "per-pod sock-dir created" || ko "per-pod sock-dir missing"
# Permissions 0700 (install -d -m 0700).
perms="$(stat -c '%a' "$SOCK_BASE/$POD_ID" 2>/dev/null)"
[ "$perms" = "700" ] && ok "sock-dir 0700" || ko "sock-dir perms=$perms (expected 700)"

kill -0 "$HOLDER_PID" 2>/dev/null && ok "holder alive (Port handle)" || ko "holder died after launch"

# ------------------------------------------------------------------
# 2. Argv contract — the opaque COMMAND was forwarded VERBATIM: <role> <pod_id> <pod_dir> <probe>
# ------------------------------------------------------------------
step "2. Opaque COMMAND argv forwarded verbatim"

for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER" ] && break; sleep 0.3; done

if [ -f "$MARKER" ]; then
  ok "COMMAND ran (marker written)"
  grep -qx "argc=4" "$MARKER"              && ok "argc=4 (no argv pollution)" || ko "argc != 4: $(grep argc= "$MARKER")"
  grep -qx "role=role" "$MARKER"           && ok "argv[1]=role"     || ko "role: $(grep '^role=' "$MARKER")"
  grep -qx "pod_id=$POD_ID" "$MARKER"      && ok "argv[2]=pod_id"   || ko "pod_id: $(grep '^pod_id=' "$MARKER")"
  grep -qx "pod_dir=$POD_DIR" "$MARKER"    && ok "argv[3]=pod_dir"  || ko "pod_dir: $(grep '^pod_dir=' "$MARKER")"
  grep -qx "probe=passthrough probe with spaces" "$MARKER" && ok "argv[4]=probe (opaque tail, spaces preserved)" || ko "probe: $(grep '^probe=' "$MARKER")"
else
  ko "COMMAND never ran (no marker) — argv not forwarded?"
fi

# ------------------------------------------------------------------
# 3. Self-contained teardown — SIGTERM holder → trap → tmux kill-server
# ------------------------------------------------------------------
step "3. SIGTERM teardown"

CMD_PID="$(sed -n 's/^cmd_pid=//p' "$MARKER" 2>/dev/null)"
[ -n "$CMD_PID" ] && kill -0 "$CMD_PID" 2>/dev/null \
  && ok "COMMAND process alive before teardown (pid $CMD_PID)" \
  || ko "COMMAND pid unusable ($CMD_PID) — the orphan check below would be vacuous"

kill -TERM "$HOLDER_PID" 2>/dev/null

# The holder must exit (its sleep is interrupted by the trap).
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.3; done
kill -0 "$HOLDER_PID" 2>/dev/null && ko "holder still alive after SIGTERM" || ok "holder exited on SIGTERM"

# THE decisive check: no orphan. If kill-server silently failed, the COMMAND survives its pod — and
# that is invisible to a has-session probe, because cleanup's `rm -rf` unlinks the socket either way.
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CMD_PID" 2>/dev/null || break; sleep 0.3; done
if [ -n "$CMD_PID" ] && kill -0 "$CMD_PID" 2>/dev/null; then
  ko "COMMAND process $CMD_PID SURVIVED the teardown (orphan — kill-server did not reap it)"
else
  ok "COMMAND process reaped by the teardown (no orphan)"
fi

# The session must be gone too. Weaker than the check above (it also goes false on the `rm -rf` alone),
# kept because a surviving session is a distinct, louder symptom.
for _ in 1 2 3 4 5 6 7 8 9 10; do "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null || break; sleep 0.3; done
if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ko "tmux session SURVIVED the teardown (kill-server failed AND the sock-dir is still there)"
else
  ok "tmux session unreachable after teardown"
fi

# The per-pod sock-dir must be cleaned by the trap's cleanup.
[ -d "$SOCK_BASE/$POD_ID" ] && ko "per-pod sock-dir not cleaned after teardown" || ok "per-pod sock-dir cleaned"

HOLDER_PID=""  # already dead, do not re-kill in the EXIT trap

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="
if [ "$FAIL" -eq 0 ]; then
  echo "all checks PASS"
  exit 0
else
  echo "FAIL — $FAIL checks failed" >&2
  exit 1
fi
