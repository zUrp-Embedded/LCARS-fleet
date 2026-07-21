#!/bin/bash
#
# SOURCE: test/integration/sandbox_notrace_test.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: MANUAL INTEGRATION PROBE — standalone, outside mix gate (needs bwrap+userns+tmux). Run by hand.
#
# F094 (a CARDINAL invariant, not testable hermetically): "the agent sees NO LCARS trace". It depends on
# the bwrap sandbox VIEW, so only a REAL bwrap can prove it. This test runs `bin/bwrap_launch.sh` — the
# REAL launcher, UNMODIFIED, we EXECUTE it — with a FAKE COMMAND (no claude, no OAuth) that inspects its
# OWN view from inside the sandbox and writes its findings into POD_DIR (RW bind → readable host-side).
#
# What is asserted (the agent's view):
#   - the host LCARS runtime tree (`/home/projects/LCARS`, `/etc/fleet`) is INVISIBLE;
#   - `/home` is a tmpfs, not the host /home — see the CONFIGURATION CAVEAT below;
#   - HOME = POD_DIR (a closed world);
#   - `:bind` auth happened (`.credentials.json` bound under `$HOME/.claude/`);
#   - the host's ambient env does NOT cross (--clearenv), proven by a canary variable.
#
# CONFIGURATION CAVEAT — read before quoting `home_entries=[]` as the production property. This probe
# roots the pod under `$(mktemp -d)`, i.e. /tmp. In PRODUCTION the pod_dir is `~/pods/pod_<id>`
# (config/runtime.exs, Pod.Paths.pod_dir_for), so bwrap's `--bind $POD_DIR $SANDBOX_HOME` re-creates
# `/home/<human>/pods/pod_<id>` INSIDE the pod and `ls -A /home` returns the human's directory name.
# `home_entries=[]` therefore proves "the tmpfs masked the host /home and nothing else was restored" for
# THIS layout. It does NOT prove the production /home is empty — it is not, by design. The masking of
# the OTHER humans and the OTHER pods is what the invariant is about, and that part does hold in
# production: the tmpfs wipes /home and only this pod's own dir is bound back.
#
# The catalogue mounts are ALSO neutralised below (unset LCARS_POD_MOUNTS & co). A cap-profile catalogue
# can legitimately restore /home/projects with `--ro-bind` (bwrap_launch.sh, CATALOGUE mounts), which
# would make `host_projects=VISIBLE` correct rather than a leak. So this probe establishes the no-trace
# invariant for the EMPTY catalogue — the floor, not every configuration.
#
# Standalone (needs bwrap + userns + tmux) — outside `mix test`. bwrap is NOT edited here: read and run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BWRAP_LAUNCH="${ROOT}/bin/bwrap_launch.sh"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

PASS=0
FAIL=0
step() { echo "==> $*"; }
ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
ko()   { echo "  KO: $*" >&2; FAIL=$((FAIL + 1)); }

# ------------------------------------------------------------------
step "0. Preconditions"
[ -x "$BWRAP_LAUNCH" ] && ok "bwrap_launch.sh +x" || { ko "missing: $BWRAP_LAUNCH"; exit 1; }
command -v "$BWRAP_BIN" >/dev/null 2>&1 && ok "bwrap present" || { ko "bwrap missing"; exit 1; }
command -v "$TMUX_BIN"  >/dev/null 2>&1 && ok "tmux present"  || { ko "tmux missing"; exit 1; }
# userns available? (a trivial bwrap unshare — usrmerge-aware: /bin,/lib are symlinks → --symlink, not --ro-bind)
if timeout 10 "$BWRAP_BIN" --unshare-all --ro-bind /usr /usr \
     --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
     --proc /proc --dev /dev /usr/bin/true 2>/dev/null; then
  ok "bwrap userns works"
else
  # Codex audit F-09 (2026-07-19): SKIP used to exit 0 — any wrapper keyed on the exit code
  # counted "proof not executed" as "proof passed" (repro: LCARS_BWRAP_BIN=/bin/false → 0).
  # Three-state convention: 0 = proven, 77 = skipped (automake standard), anything else = fail.
  # A caller MUST count 77 explicitly — never fold it into green.
  ko "bwrap userns unavailable (this environment does not support it — SKIP)"; echo "SKIP"; exit 77
fi

# ------------------------------------------------------------------
# Fixtures (every bwrap_launch.sh precondition, without claude)
# ------------------------------------------------------------------
WORK="$(mktemp -d)"
POD_DIR="$WORK/pod"
SOCK_BASE="$WORK/sock"
CLAUDE_DIR="$WORK/claudedir"
GIT_MIRROR="$WORK/gitmirror"
VENDOR_SHARE="$WORK/vendor-share"
VENDOR_BIN="$WORK/fake-claude"
MCP_SOCK_BASE="$WORK/mcp-sock"
POD_ID="ntrace-$$"
SESSION="lcars-pod-$POD_ID"
SOCK="$SOCK_BASE/$POD_ID/pod.sock"
OUT="$POD_DIR/output/notrace.txt"
HOLDER_PID=""

cleanup() {
  [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null && kill -TERM "$HOLDER_PID" 2>/dev/null
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

# The per-pod MCP socket dir must PRE-EXIST: central provisions it before the launch and bwrap MOUNTS
# it without creating it (bwrap_launch.sh). Nothing here plays central, so we provision it ourselves.
# Without this the probe dies at the boundary on the /run/lcars/mcp default, before a sandbox is ever
# projected -- which is how it had been failing: a manual probe nobody ran had gone stale against a
# launcher precondition added with the AF_UNIX transport.
mkdir -p "$POD_DIR" "$SOCK_BASE" "$CLAUDE_DIR" "$GIT_MIRROR" "$VENDOR_SHARE" "$MCP_SOCK_BASE/$POD_ID"
# `:bind` auth (ADR-F, the only mode since token_arg was removed): the launcher binds THIS file, so it
# must exist host-side or the launcher fails at the boundary. Empty fixture — we only prove the view.
: > "$CLAUDE_DIR/.credentials.json"
printf '#!/bin/sh\necho fake-vendor\n' > "$VENDOR_BIN"; chmod +x "$VENDOR_BIN"

# FAKE COMMAND (standing in for claude_launch.sh). It lives UNDER POD_DIR (RW bind → visible inside the
# sandbox at the same path). It inspects the agent's view and writes its findings into POD_DIR/output.
INSPECT="$POD_DIR/inspect.sh"
cat > "$INSPECT" <<'INS'
#!/bin/sh
out="$HOME/output"
mkdir -p "$out"
{
  echo "home_entries=[$(ls -A /home 2>/dev/null | tr '\n' ',')]"
  echo "host_lcars_repo=$([ -e /home/projects/LCARS ] && echo VISIBLE || echo absent)"
  echo "host_projects=$([ -e /home/projects ] && echo VISIBLE || echo absent)"
  echo "etc_fleet=$([ -e /etc/fleet ] && echo VISIBLE || echo absent)"
  echo "home_env=$HOME"
  echo "cwd=$(pwd)"
  # :bind auth (ADR-F): the launcher binds `.credentials.json` under `$HOME/.claude/`. (token_arg was
  # REMOVED, so there is no CLAUDE_CODE_OAUTH_TOKEN in the env leaking into the argv.) We prove the
  # bound file is there.
  echo "creds_bound=$([ -f "$HOME/.claude/.credentials.json" ] && echo set || echo unset)"
  # --clearenv canary: LCARS_NOTRACE_CANARY is exported host-side just before the launch and is NOT in
  # bwrap_launch.sh's --setenv list. If it reaches the agent, --clearenv is not holding and the whole
  # ambient env of the spawner is crossing with it. Without this line the header's --clearenv claim had
  # no assertion behind it at all.
  echo "env_canary=$([ -n "${LCARS_NOTRACE_CANARY:-}" ] && echo LEAKED || echo absent)"
  echo "DONE"
} > "$out/notrace.txt" 2>&1
exec sleep 30
INS
chmod +x "$INSPECT"

# ------------------------------------------------------------------
step "1. Run bwrap_launch.sh (the real launcher) with the fake COMMAND"

# Neutralise the optional spawner inputs that would legitimately change the projected world (catalogue
# mounts, plugin binds, home/cwd relocation). They are part of the real contract, but each one restores
# paths the assertions below declare absent — inheriting one from the caller's shell would turn a real
# behaviour into a spurious KO. Same neutralisation as gate-r0.1-bwrap.sh, and the reason the header
# scopes the invariant to the empty catalogue.
unset LCARS_POD_MOUNTS LCARS_SKILLS_PLUGINS LCARS_POD_HOME LCARS_POD_CWD LCARS_POD_CWD_SRC

LCARS_NOTRACE_CANARY="this-must-not-cross-clearenv" \
LCARS_BWRAP_NO_CLEANUP=1 \
LCARS_BWRAP_BIN="$BWRAP_BIN" \
LCARS_TMUX_BIN="$TMUX_BIN" \
LCARS_TMUX_SOCK_BASE="$SOCK_BASE" \
LCARS_FLEET_MCP_SOCK_BASE="$MCP_SOCK_BASE" \
CLAUDE_DIR="$CLAUDE_DIR" \
LCARS_GIT_MIRROR="$GIT_MIRROR" \
LCARS_VENDOR_NAME="claude" \
LCARS_VENDOR_BIN="$VENDOR_BIN" \
LCARS_VENDOR_SHARE="$VENDOR_SHARE" \
LCARS_POD_SESSION_ID="sess-$$" \
LCARS_POD_SESSION_NAME_PREFIX="tester_role" \
GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@t" \
  "$BWRAP_LAUNCH" "role" "$POD_ID" "$POD_DIR" \
                  "$INSPECT" "role" "$POD_ID" "$POD_DIR" "SP test" &
HOLDER_PID=$!

for _ in $(seq 1 20); do "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null && break; sleep 0.3; done
if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ok "tmux session created inside bwrap"
else
  ko "no tmux session — bwrap_launch did not start (see stderr above)"
fi

# ------------------------------------------------------------------
step "2. No-trace invariant — the agent's view, from the inside"

for _ in $(seq 1 20); do [ -f "$OUT" ] && break; sleep 0.3; done

if [ -f "$OUT" ]; then
  ok "the COMMAND inspected its view (findings written)"
  echo "    --- agent view ---"; sed 's/^/    /' "$OUT"
  # Heart of the no-trace invariant: the host LCARS runtime tree is invisible. That is F094's point.
  grep -qxF "host_lcars_repo=absent" "$OUT" && ok "host LCARS runtime tree INVISIBLE (/home/projects/LCARS)" || ko "LEAK: /home/projects/LCARS visible in the pod"
  grep -qxF "host_projects=absent"   "$OUT" && ok "host /home/projects invisible"                            || ko "LEAK: /home/projects visible"
  grep -qxF "home_entries=[]"        "$OUT" && ok "/home tmpfs empty (host /home masked — this layout, cf. caveat)" || ko "/home not empty: $(grep home_entries= "$OUT")"
  grep -qxF "home_env=$POD_DIR"      "$OUT" && ok "HOME = POD_DIR (closed world)"                            || ko "unexpected HOME: $(grep home_env= "$OUT")"
  grep -qxF "creds_bound=set"        "$OUT" && ok ".credentials.json bound under \$HOME/.claude (:bind auth, ADR-F)" || ko "no creds in the pod (:bind auth broken)"
  grep -qxF "env_canary=absent"      "$OUT" && ok "host ambient env does NOT cross (--clearenv holds)"       || ko "LEAK: the canary crossed — --clearenv is not holding"

  # The historical "/etc/fleet VISIBLE" finding is RESOLVED BY CONSTRUCTION: bwrap_launch no longer does
  # `--ro-bind /etc /etc` but SELECTIVE /etc binds (resolv.conf/ssl/ca-certificates/passwd/group/…), and
  # `/etc/fleet` — which holds FORGE_TOKEN and the *-secret files — is not among them. Hard assertion now.
  grep -qxF "etc_fleet=absent" "$OUT" &&
    ok "/etc/fleet invisible (selective /etc binds — no fleet secret leak)" ||
    ko "LEAK: /etc/fleet visible — bwrap must not bind /etc wholesale (selective-bind regression)"
else
  ko "the COMMAND never ran inside the sandbox (no findings)"
fi

# ------------------------------------------------------------------
step "3. Teardown"
kill -TERM "$HOLDER_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.3; done
kill -0 "$HOLDER_PID" 2>/dev/null && ko "the holder survived SIGTERM" || ok "holder gone (SIGTERM)"
# The holder's death must take the SANDBOX with it, which is a separate fact: the tmux server lives
# INSIDE the namespace, so if the namespace really collapsed the session is unreachable. Checking only
# the holder PID proved half the sentence the step name claims. NB the sock file itself is not removed
# here (the launcher's caller owns that), so this really is a server-liveness check, not a file check.
if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ko "the tmux server survived the holder — the namespace did not collapse"
else
  ok "tmux server gone with the holder (namespace collapsed)"
fi
HOLDER_PID=""

echo ""
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="
if [ "$FAIL" -eq 0 ]; then echo "all checks PASS"; exit 0; else echo "FAIL — $FAIL checks failed" >&2; exit 1; fi
