#!/usr/bin/env bash
# SOURCE: test/gate-r0.1-bwrap.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: REAL e2e isolation probe, ADR-G detached model
#
# gate-r0.1-bwrap.sh — R0.1 (kernel mechanic: the bwrap primitive). exit 0 iff the REAL
# bin/bwrap_launch.sh projects a sandbox where, seen FROM THE INSIDE:
#   env_home        the intra-pod HOME is the pod home (--setenv HOME, a side channel independent of HOME)
#   iso_home        the host home is MASKED (--tmpfs /home: a sentinel dropped in ~ is INVISIBLE)
#   iso_tmp         the host /tmp is MASKED (--tmpfs /tmp: a host canary is INVISIBLE)
#   iso_env         the env is CLOSED (--clearenv: a var exported at launch is INVISIBLE)
#   env_forward     the CONTRACTUAL env crosses (--setenv: GIT_AUTHOR_NAME == the value set)
#   env_git_global  GIT_CONFIG_GLOBAL=/dev/null (git identity = the forwarded env, never the global)
#   env_pod_id      LCARS_POD_ID is wired (--setenv = the pod_id passed to the launcher)
#   creds_bind      the bound creds are THE RIGHT BYTES (nonce round-trip — FAKE creds, never the real
#                   ones: this gate does NOT touch ~/.claude)
#   creds_rw_pod    an IN-PLACE append on the creds is accepted in-pod (RW single-file bind)…
#   vendor_native   the vendor is provisioned at its native location ($HOME/.local/bin/<vendor>)
#   vendor_exec     ... and EXECUTES in the pod (--version, zero network, zero token)
#   ro_vendor_bind  the vendor bind is RO (touch refused) — see the note on discriminating power below
#   ro_usr          /usr is not writable from inside — see the note below, this one is WEAK
#   etc_shadow      SELECTIVE /etc: /etc/shadow is ABSENT from the projected world (no wholesale bind)
#   etc_dns         ... but resolv.conf IS present (DNS projected, or claude hangs on the API)
#   pid_ns          the gate's host PID is INVISIBLE in /proc (--unshare-all → PID namespace)
#   rw_home         the pod $HOME is RW
# + HOLDER: the launcher (bwrap-PID1) is still ALIVE after the probe (the detached model holds).
# + creds_rw_host (judged HOST-SIDE, outside the probe count): …and the in-pod append PROPAGATES to
#   the host file — that IS the ADR-F OAuth refresh path (an in-place write that survives the bind).
#
# HOW MUCH EACH CHECK DISCRIMINATES — two of them look alike and are not:
#   ro_vendor_bind is STRONG. The host vendor file is owned by the invoking user and writable on the
#     host, so a refusal inside can only come from --ro-bind. Flip that bind to --bind and it goes red.
#   ro_usr is WEAK, and is kept as a floor rather than as a bind-mode test. bwrap_launch.sh passes no
#     --uid/--gid, so the probe runs as the same unprivileged user as the gate, for whom /usr is
#     unwritable anyway. Measured: with `--bind /usr /usr` (READ-WRITE) the write is STILL refused.
#     So this check establishes "the agent cannot scribble on /usr", NOT "the bind is read-only" —
#     ro_vendor_bind is the one that establishes that.
#
# SCOPE OF THE ENV CONTRACT: the mandatory inputs are served in full, but the OPTIONAL spawner inputs
# are deliberately neutralised below (LCARS_POD_MOUNTS, LCARS_SKILLS_PLUGINS, LCARS_POD_HOME,
# LCARS_POD_CWD…). They are part of the real contract, and each of them legitimately re-shapes the
# projected world — catalogue mounts restore masked paths, LCARS_POD_HOME moves SANDBOX_HOME and would
# hide the side-channel report. So what is proven here is the isolation of the BASE world. Catalogue
# binds, plugin binds and the relocated SANDBOX_HOME are NOT covered by this gate.
#
# WHY AN INSIDE PROBE (side channel) rather than the exit code: the launcher does
# `exec bwrap … tmux new-session -d … exec sleep infinity` and NEVER returns (the ADR-G holder) — the
# COMMAND's stdout goes to the tmux pane and its exit is never propagated. The old gate judged on the
# launcher's exit: it took "launcher died during setup" for "sentinel masked" → a lying ISO PASS (the
# false-green family, F-C166). Here the COMMAND launched INSIDE the pod IS the probe: it inspects the
# world from within and writes its verdict into $POD_DIR (bound RW) → readable host-side. The gate
# judges on that report, with a REQUIRED CHECK COUNT (never green on an empty or partial report), then
# kills the launcher.
#
# The bats (test/bwrap_launch/bwrap_launch.bats) stub bwrap and test ONLY the flag assembly: THIS gate
# is the e2e proof of real isolation (real bwrap + tmux + namespaces).
# Requirements: bwrap + tmux USABLE (unshare/mount syscalls — preflight below); a resolvable vendor
# (claude on PATH, or LCARS_VENDOR_BIN/_SHARE), otherwise a --version STUB is substituted (the probe
# proves the SANDBOX, not the vendor).
# Debug: KEEP=1 keeps the workdir. Manual/opt-in (outside mix gate: it needs the bwrap syscalls).
#
# 3 STATES — an incapable environment NEVER manufactures a green:
#   exit 0  PASS — probe ran INSIDE bwrap, report COMPLETE, every check green (+ holder + host rw)
#   exit 1  FAIL — isolation broken: a red check (even on a partial report), an incomplete count, a
#           broken holder, or no host creds propagation — the real alarm
#   exit 3  SKIP — bwrap/tmux/syscalls unavailable (WSL or a container without cap-add), launcher died
#           during setup, or a probe with neither verdict nor finding: isolation NOT VERIFIED — an
#           EXPLICIT state, never a disguised PASS (the old gate took exactly this path for green)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BWRAP_LAUNCH="$HERE/../bin/bwrap_launch.sh"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

skip3() {
  echo "GATE R0.1: SKIP — $*"
  echo "GATE R0.1: exit 3 — isolation NOT VERIFIED (explicit SKIP, never a PASS)"
  exit 3
}

echo "== Gate R0.1 — bwrap primitive (real bwrap_launch.sh, inside isolation probe) =="
echo "   launcher: $BWRAP_LAUNCH"

# ---------------------------------------------------------------------------
# Hardware preflight: bwrap being PRESENT is not enough — it needs the syscalls (unshare/mount/
# pivot_root), which WSL or a container without cap-add refuse. An impossible probe is an explicit
# SKIP, never an isolation verdict in either direction.
# ---------------------------------------------------------------------------
[[ -x "$BWRAP_LAUNCH" ]] || skip3 "launcher missing/not-x: $BWRAP_LAUNCH"
[[ -x "$BWRAP_BIN" ]] || skip3 "bwrap unavailable ($BWRAP_BIN) — install bubblewrap"
[[ -x "$TMUX_BIN" ]] || skip3 "tmux unavailable ($TMUX_BIN) — the N0 PTY is required in the sandbox"
"$BWRAP_BIN" --ro-bind / / true >/dev/null 2>&1 \
  || skip3 "bwrap present but the sandbox syscalls are refused (unshare/mount — container without cap-add/seccomp?)"
"$BWRAP_BIN" --unshare-all --share-net --die-with-parent --ro-bind / / --tmpfs /home --tmpfs /tmp \
  --dev /dev --proc /proc true >/dev/null 2>&1 \
  || skip3 "bwrap without full namespaces (--unshare-all/--proc) — real sandboxing is impossible here"

WORK="$(mktemp -d)"
POD_ID="gate-r01-$$"
POD_DIR="$WORK/pod"
SENTINEL="$HOME/.gate-r01-sentinel-$$"
TMP_CANARY="$(mktemp /tmp/gate-r01-canary.XXXXXX)"
LAUNCH_PID=""
cleanup() {
  if [[ -n "$LAUNCH_PID" ]]; then
    kill "$LAUNCH_PID" 2>/dev/null || true
    wait "$LAUNCH_PID" 2>/dev/null || true
  fi
  rm -f "$SENTINEL" "$TMP_CANARY"
  if [[ "${KEEP:-0}" = 1 ]]; then echo "KEEP $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# iso_home rests on `--tmpfs /home`: a $HOME outside /home would make the check meaningless.
# An inconclusive environment is not broken isolation → explicit SKIP (3 states), not a FAIL.
[[ "$HOME" == /home/* ]] || skip3 "\$HOME=$HOME is outside /home — iso_home (tmpfs /home) would prove nothing here"

# ---------------------------------------------------------------------------
# Minimal host world matching the launcher's CONTRACT (every :?/guard of bwrap_launch.sh served,
# EVERYTHING under $WORK — nothing from the real ~/.lcars or ~/.claude is used).
# ---------------------------------------------------------------------------
mkdir -p "$POD_DIR" "$WORK/claude-dir" "$WORK/mirror" "$WORK/sock" "$WORK/mcp/$POD_ID"
CREDS_NONCE="creds-nonce-$$-$RANDOM"
CREDS_RW_NONCE="creds-rw-$$-$RANDOM"     # appended in-pod, looked for HOST-side (ADR-F propagation)
printf '%s' "$CREDS_NONCE" > "$WORK/claude-dir/.credentials.json"   # FAKE — never the real creds
echo "gate-r01-secret" > "$SENTINEL"

export CLAUDE_DIR="$WORK/claude-dir"
export LCARS_GIT_MIRROR="$WORK/mirror"
export LCARS_TMUX_SOCK_BASE="$WORK/sock"
export LCARS_FLEET_MCP_SOCK_BASE="$WORK/mcp"
export LCARS_POD_SESSION_ID="gate-r01-session-$$"
export LCARS_POD_SESSION_NAME_PREFIX="gate_r01"
export GIT_AUTHOR_NAME="gate-r01" GIT_AUTHOR_EMAIL="gate-r01@lcars.local"
export GIT_COMMITTER_NAME="gate-r01" GIT_COMMITTER_EMAIL="gate-r01@lcars.local"
export LCARS_BWRAP_NO_CLEANUP=1          # setup failure → diagnostics kept (cleanup is OUR trap)
export LCARS_ISO_ENV_CANARY="leak-$$"    # MUST be invisible in the pod (--clearenv)

# Optional spawner inputs, neutralised: each would legitimately re-shape the projected world under the
# probe — and LCARS_POD_HOME would move SANDBOX_HOME, hiding the $POD_DIR/iso-report side channel.
# This is what scopes the gate to the BASE world (cf. the header).
unset LCARS_POD_MOUNTS LCARS_SKILLS_PLUGINS LCARS_POD_HOME LCARS_POD_CWD LCARS_POD_CWD_SRC \
      LCARS_POD_RESUME LCARS_AUTH_MODE LCARS_POD_DISABLE_TELEMETRY

# Vendor: the real claude if resolvable (this probes the actual native-install relocation); otherwise a
# STUB answering --version — a machine without claude is not a SKIP, the probe tests the sandbox.
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
if [[ -z "${LCARS_VENDOR_BIN:-}" ]] && ! command -v "$VENDOR_NAME" >/dev/null 2>&1; then
  export LCARS_VENDOR_BIN="$WORK/vendor/bin/$VENDOR_NAME" LCARS_VENDOR_SHARE="$WORK/vendor/share"
  mkdir -p "$WORK/vendor/bin" "$WORK/vendor/share"
  printf '#!/bin/sh\necho "gate-r01 vendor-stub 0.0.0"\n' > "$LCARS_VENDOR_BIN"
  chmod +x "$LCARS_VENDOR_BIN"
  echo "   vendor '$VENDOR_NAME' not resolvable → --version stub substituted"
fi

# ---------------------------------------------------------------------------
# The inside probe (POSIX sh — it IS the pod's COMMAND). UNQUOTED heredoc: the host paths and nonces
# ($SENTINEL, $TMP_CANARY, $CREDS_NONCE, $POD_ID, the gate's PID, the vendor) are FROZEN into the script
# at write time; the escaped \$ are evaluated INSIDE the sandbox. The report is ANCHORED on the EMBEDDED
# $POD_DIR path (= the same path in-sandbox, identity bind) and NOT on \$HOME: a broken HOME must become
# a RECORDED FAIL (env_home), never a lost report degraded into a SKIP.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=17
cat > "$POD_DIR/.iso-probe.sh" <<PROBE
#!/bin/sh
R="$POD_DIR/iso-report"
: > "\$R"
ck() { s=\$1; shift; if [ "\$s" = 0 ]; then echo "PASS \$1" >> "\$R"; else shift; echo "FAIL \$*" >> "\$R"; fi; }

[ "\${HOME:-}" = "$POD_DIR" ];            ck \$? env_home env_home "HOME='\${HOME:-}' != pod home $POD_DIR"
[ ! -e "$SENTINEL" ];                     ck \$? iso_home iso_home "host sentinel READABLE: $SENTINEL"
[ ! -e "$TMP_CANARY" ];                   ck \$? iso_tmp iso_tmp "host /tmp canary READABLE: $TMP_CANARY"
[ -z "\${LCARS_ISO_ENV_CANARY:-}" ];      ck \$? iso_env iso_env "ambient env LEAKED despite --clearenv"
[ "\${GIT_AUTHOR_NAME:-}" = "gate-r01" ]; ck \$? env_forward env_forward "GIT_AUTHOR_NAME='\${GIT_AUTHOR_NAME:-}'"
[ "\$(cat "\$HOME/.claude/.credentials.json" 2>/dev/null)" = "$CREDS_NONCE" ]; \
                                          ck \$? creds_bind creds_bind "creds content != expected nonce"
printf 'rw:%s' "$CREDS_RW_NONCE" >> "\$HOME/.claude/.credentials.json" 2>/dev/null; \
                                          ck \$? creds_rw_pod creds_rw_pod "creds append refused in-pod (bind not RW)"
[ -x "\$HOME/.local/bin/$VENDOR_NAME" ];  ck \$? vendor_native vendor_native "\$HOME/.local/bin/$VENDOR_NAME missing/not-x"
V="\$(timeout 20 "\$HOME/.local/bin/$VENDOR_NAME" --version 2>&1)"; \
                                          ck \$? vendor_exec vendor_exec "--version KO: \$V"
echo "INFO vendor_version: \$V" >> "\$R"
! touch "\$HOME/.local/bin/$VENDOR_NAME" 2>/dev/null; \
                                          ck \$? ro_vendor_bind ro_vendor_bind "vendor bind WRITABLE (RO broken)"
# WEAK check, deliberately kept as a floor: the probe runs unprivileged (bwrap_launch passes no --uid),
# so /usr is unwritable regardless of the bind mode — measured, a read-write bind of /usr is refused
# too. This says "the agent cannot scribble on /usr". ro_vendor_bind above tests the bind MODE.
# (No backticks in this heredoc: it is UNQUOTED, so a backtick would be command substitution at write
# time — shellcheck caught exactly that when this comment was first written.)
if ( : > /usr/.gate-r01-ro ) 2>/dev/null; then rm -f /usr/.gate-r01-ro; false; else true; fi; \
                                          ck \$? ro_usr ro_usr "/usr WRITABLE from inside the pod"
[ ! -e /etc/shadow ];                     ck \$? etc_shadow etc_shadow "/etc/shadow VISIBLE (/etc bind too wide)"
[ -e /etc/resolv.conf ];                  ck \$? etc_dns etc_dns "resolv.conf ABSENT (the pod's DNS is dead)"
[ "\${GIT_CONFIG_GLOBAL:-}" = "/dev/null" ]; \
                                          ck \$? env_git_global env_git_global "GIT_CONFIG_GLOBAL='\${GIT_CONFIG_GLOBAL:-}'"
[ "\${LCARS_POD_ID:-}" = "$POD_ID" ];     ck \$? env_pod_id env_pod_id "LCARS_POD_ID='\${LCARS_POD_ID:-}'"
[ ! -d /proc/$$ ];                        ck \$? pid_ns pid_ns "host PID $$ VISIBLE in /proc (unshare-pid KO)"
touch "\$HOME/.rw-check" 2>/dev/null;     ck \$? rw_home rw_home "write to \$HOME refused (pod bind not RW)"

echo "END $EXPECTED_CHECKS" >> "\$R"
PROBE
chmod +x "$POD_DIR/.iso-probe.sh"

# ---------------------------------------------------------------------------
# Detached launch: bwrap_launch does NOT return (holder) → background + poll the report.
# ---------------------------------------------------------------------------
"$BWRAP_LAUNCH" gate-r01-role "$POD_ID" "$POD_DIR" /bin/sh "$POD_DIR/.iso-probe.sh" \
  > "$WORK/launch.log" 2>&1 &
LAUNCH_PID=$!

REPORT="$POD_DIR/iso-report"
LAUNCHER_DIED=0
for _ in $(seq 1 60); do
  if [[ -f "$REPORT" ]] && grep -q '^END ' "$REPORT" 2>/dev/null; then break; fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCHER_DIED=1
    break
  fi
  sleep 0.5
done

# ---------------------------------------------------------------------------
# 3-state verdict on the REPORT — the count is required, never green on an empty/partial report (F-C166).
# ---------------------------------------------------------------------------
FAIL=0
if grep -q '^END ' "$REPORT" 2>/dev/null; then
  # HOLDER: the launcher must still be alive (bwrap-PID1 holds the namespace, ADR-G).
  if [[ "$LAUNCHER_DIED" -eq 0 ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "PASS HOLDER  bwrap-PID1 alive after the probe (the detached model holds)"
  else
    echo "FAIL HOLDER  launcher died after the probe (ADR-G holder broken)"; FAIL=1
  fi
  sed 's/^/   | /' "$REPORT"
  PASS_N="$(grep -c '^PASS ' "$REPORT" || true)"
  FAIL_N="$(grep -c '^FAIL ' "$REPORT" || true)"
  END_N="$(sed -n 's/^END //p' "$REPORT" | head -1)"
  if [[ "$FAIL_N" -gt 0 ]]; then
    echo "FAIL ISO     $FAIL_N red check(s) in the pod"; FAIL=1
  fi
  if [[ "$PASS_N" -ne "$EXPECTED_CHECKS" || "${END_N:-0}" -ne "$EXPECTED_CHECKS" ]]; then
    echo "FAIL COUNT   $PASS_N/$EXPECTED_CHECKS PASS (END=${END_N:-missing}) — a partial report is not green"; FAIL=1
  fi
  # creds_rw_host — judged HOST-SIDE: the append made INSIDE the pod must be visible in the host creds
  # file (RW single-file bind = THE ADR-F OAuth refresh path; without propagation, a long-running pod
  # would silently lose its auth).
  if grep -q "rw:$CREDS_RW_NONCE" "$WORK/claude-dir/.credentials.json" 2>/dev/null; then
    echo "PASS creds_rw_host  in-pod append propagated to the host creds file (ADR-F refresh viable)"
  else
    echo "FAIL creds_rw_host  in-pod append NOT propagated to the host creds file"; FAIL=1
  fi
elif grep -q '^FAIL ' "$REPORT" 2>/dev/null; then
  # UNFINISHED report but a red finding already recorded: a FAIL NEVER degrades into a SKIP.
  echo "FAIL PROBE   probe interrupted with invariant(s) already broken:"
  sed 's/^/   | /' "$REPORT"
  FAIL=1
elif [[ "$LAUNCHER_DIED" -eq 1 ]]; then
  # Dying BEFORE the detach = a launcher setup failure (the :? guards / exit 1|2): isolation was NEITHER
  # proven NOR disproven → SKIP with the real cause. The old gate took exactly this path for an ISO
  # PASS; dressing it as an isolation FAIL would be the opposite lie.
  echo "   bwrap_launch died during setup (no isolation tested) — launch.log:"
  sed 's/^/   | /' "$WORK/launch.log" 2>/dev/null || true
  skip3 "launcher died BEFORE bwrap (env/provisioning contract — see the log above, KEEP=1 to investigate)"
else
  # No verdict, no finding, launcher alive: the probe could not run (tmux or the probe broken inside the
  # sandbox?) → explicit SKIP, never a green.
  echo "   probe with no verdict after 30s — launch.log:"
  sed 's/^/   | /' "$WORK/launch.log" 2>/dev/null || true
  skip3 "the probe returned no verdict (no report, no FAIL recorded) — KEEP=1 to investigate"
fi

echo "---"
if [[ "$FAIL" -eq 0 ]]; then
  echo "GATE R0.1: exit 0 — the bwrap primitive holds (isolation proven from the inside, real launcher)"
else
  echo "GATE R0.1: exit 1 — it does not hold"
fi
exit "$FAIL"
