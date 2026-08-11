#!/usr/bin/env bats
# SOURCE: test/bwrap_launch/bwrap_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: bats tests for bin/bwrap_launch.sh v2 (ADR-G sanctuary)
#
# The v2 model is ASYNC and detached (bwrap → tmux new-session -d → command; bwrap returns 0, the exit
# code is not propagated). So we stub bwrap (echoing its invocation) and assert the ASSEMBLY of the v2
# flags. The real sanctuary isolation (/ RO, /home tmpfs, closed env) is NOT tested here: its e2e proof
# is test/gate-r0.1-bwrap.sh (an INSIDE probe against a real bwrap+tmux+vendor — manual/opt-in, it needs
# the bwrap syscalls). What IS covered here: args, the `:?` session guards, setup checks, assembly
# (clearenv/die-with-parent/binds/setenv/sock-dir/tmux), the pre-exec trap, and the N0/N1 frontier.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/bwrap_launch.sh"
  TMP_BASE="$(mktemp -d)"

  POD_DIR="$TMP_BASE/pod-engineer-test"; mkdir -p "$POD_DIR/.claude"
  export CLAUDE_DIR="$TMP_BASE/claudedir"; mkdir -p "$CLAUDE_DIR"
  # Human creds: the launcher binds `.credentials.json` (auth :bind, native in-place OAuth refresh), so
  # the file MUST exist host-side or the launcher fails at the boundary. Empty fixture — the bwrap stub
  # does not read it, we only test the assembly.
  : > "$CLAUDE_DIR/.credentials.json"
  export LCARS_GIT_MIRROR="$TMP_BASE/git-mirror"; mkdir -p "$LCARS_GIT_MIRROR"
  export LCARS_TMUX_SOCK_BASE="$TMP_BASE/sock"; mkdir -p "$LCARS_TMUX_SOCK_BASE"

  # Per-pod MCP socket: central provisions it BEFORE the launch (the dir MUST pre-exist — bwrap MOUNTS
  # it, it does not create it). We simulate that provisioning here for the `pod-1` id the tests use.
  export LCARS_FLEET_MCP_SOCK_BASE="$TMP_BASE/mcp-sock"; mkdir -p "$LCARS_FLEET_MCP_SOCK_BASE/pod-1"

  # Vendor stub (just -x + a share dir). Explicit authority, no PATH resolution.
  export LCARS_VENDOR_NAME="claude"
  export LCARS_VENDOR_BIN="$TMP_BASE/vendor/bin/claude"
  export LCARS_VENDOR_SHARE="$TMP_BASE/vendor/share"
  mkdir -p "$(dirname "$LCARS_VENDOR_BIN")" "$LCARS_VENDOR_SHARE"
  echo '#!/usr/bin/env bash' > "$LCARS_VENDOR_BIN"; chmod +x "$LCARS_VENDOR_BIN"

  # Session: set by the spawner in prod.
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"

  # The mandate's git identity is the HUMAN (set by the spawner through ForgeIdentity; read with a
  # strict `:?` by the launcher, so `--setenv GIT_*` no-boots without it). Deterministic fixture, so the
  # tests reach the assembly.
  export GIT_AUTHOR_NAME="Test Human"
  export GIT_AUTHOR_EMAIL="test-human@lcars.invalid"
  export GIT_COMMITTER_NAME="Test Human"
  export GIT_COMMITTER_EMAIL="test-human@lcars.invalid"

  # bwrap stub: echoes the full invocation (including the tmux command) → assembly assertions.
  export LCARS_BWRAP_BIN="$TMP_BASE/bwrap-stub"
  cat > "$LCARS_BWRAP_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'BWRAP_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$LCARS_BWRAP_BIN"
}

teardown() { rm -rf "$TMP_BASE"; }

# ============================ Args ============================

@test "args: exit 1 with no argument" {
  run "$SCRIPT"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 with 3 args (command missing)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 when role is an empty string" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"non-empty"* ]]
}

# ===================== Session (strict :?) ====================

@test "session: non-zero exit + message when LCARS_POD_SESSION_ID is absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"session UUID required"* ]]
}
@test "session: non-zero exit + message when LCARS_POD_SESSION_NAME_PREFIX is absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"pod label required"* ]]
}

# ======================= Setup checks ========================

@test "setup: exit 2 when bwrap is missing" {
  export LCARS_BWRAP_BIN="/nonexistent/bwrap"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"bwrap missing"* ]]
}
@test "setup: exit 2 when tmux is missing" {
  export LCARS_TMUX_BIN="/nonexistent/tmux"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"tmux missing"* ]]
}
@test "setup: exit 2 when the vendor is missing" {
  export LCARS_VENDOR_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"vendor"* ]]
}
@test "setup: exit 1 when claudeDir is missing" {
  export CLAUDE_DIR="/nonexistent/claudedir"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"claudeDir"* ]]
}
@test "DR-023: git mirror DORMANT (LCARS_GIT_MIRROR unset) → INERT: no exit 1, no mirror bind" {
  # DR-023: a disabled feature is not a precondition any more. The old default pointed at the
  # /var/lib/lcars/git-mirror fossil, which killed the first spawn on a fresh home install.
  unset LCARS_GIT_MIRROR
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]                    # dormant is not fatal
  [[ "$output" == *"BWRAP_ARGS:"* ]]       # the launch reaches the bwrap exec
  [[ "$output" != *"ERR: git mirror"* ]]   # no mirror error
  [[ "$output" != *"git-mirror"* ]]        # NO mirror bind projected into the sandbox
}
@test "DR-023: git mirror SET but missing (LCARS_GIT_MIRROR=<nonexistent dir>) → fatal (an explicit ask cannot be met)" {
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"git mirror"* ]]
}
@test "mounts: mode+src binds in place (the ordinary form, unchanged)" {
  mkdir -p "$TMP_BASE/plain"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/plain"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $TMP_BASE/plain $TMP_BASE/plain"* ]]
}

@test "mounts: mode+src+dst binds the SOURCE at the DESTINATION (pinned reference face)" {
  # The pinned reference lives in the pod dir so it survives its source, but it is bound at the
  # canonical face path so a pointer written in a brief resolves unchanged. Source and destination
  # differ HERE and nowhere else.
  mkdir -p "$TMP_BASE/pinned"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/pinned:/home/projects.workshop/demo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $TMP_BASE/pinned /home/projects.workshop/demo"* ]]
}

@test "mounts: a RELATIVE destination is refused (the belt covers the target too)" {
  mkdir -p "$TMP_BASE/pinned"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/pinned:home/projects.workshop/demo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"mount target is not absolute"* ]]
}

@test "mounts: a RW translation onto a system root is refused on the DESTINATION" {
  # A translated mount could otherwise land a writable tree on /etc while its source looks innocent.
  mkdir -p "$TMP_BASE/innocent"
  export LCARS_POD_MOUNTS="rw:$TMP_BASE/innocent:/etc"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"RW forbidden on a system root"* ]]
}

@test "setup: exit 1 when pod_dir is missing" {
  run "$SCRIPT" engineer pod-1 "$TMP_BASE/nope" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"pod_dir"* ]]
}
@test "setup: exit 1 when the sock parent is missing" {
  export LCARS_TMUX_SOCK_BASE="/nonexistent/sock-base"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"sock parent"* ]]
}
@test "setup: exit 1 when the per-pod MCP socket dir is missing (central's provisioning contract)" {
  rm -rf "$LCARS_FLEET_MCP_SOCK_BASE/pod-1"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"dir socket MCP"* ]]
}

# ============== bwrap assembly (stub echo) — v2 ==============

@test "asm: --clearenv (closed env)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--clearenv"* ]]
}
@test "asm: --die-with-parent (orphan-safe)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--die-with-parent"* ]]
}
@test "asm: --unshare-all --share-net" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--unshare-all"* ]]; [[ "$output" == *"--share-net"* ]]
}
@test "asm: bind pod_dir + creds (single-file .credentials.json) + git-mirror RO" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $POD_DIR $POD_DIR"* ]]
  # Auth :bind means ONLY `.credentials.json` is bound, NOT the human's whole `.claude` — otherwise
  # their hooks leak in as project settings and jam the boot. The native OAuth refresh writes in place
  # on this file. SANDBOX_HOME=$POD_DIR here (no LCARS_POD_HOME) → the target is under $POD_DIR/.claude/.
  [[ "$output" == *"--bind $CLAUDE_DIR/.credentials.json $POD_DIR/.claude/.credentials.json"* ]]
  [[ "$output" == *"--ro-bind $LCARS_GIT_MIRROR $LCARS_GIT_MIRROR"* ]]
}
@test "asm: vendor relocated → pod/.local/bin (per-user binary)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--ro-bind $LCARS_VENDOR_BIN $POD_DIR/.local/bin/claude"* ]]
}
@test "asm: bind the per-pod socket dir" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $LCARS_TMUX_SOCK_BASE/pod-1 $LCARS_TMUX_SOCK_BASE/pod-1"* ]]
}
@test "asm: per-pod MCP socket — bind the DIR + setenv the socket, NEVER the base wholesale (tenant frontier)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  # The per-pod DIR is bound at the same host==namespace path (central already created `sock` in it).
  [[ "$output" == *"--bind $LCARS_FLEET_MCP_SOCK_BASE/pod-1 $LCARS_FLEET_MCP_SOCK_BASE/pod-1"* ]]
  # The socket path, set for the bridge (read by bridge.py).
  [[ "$output" == *"--setenv LCARS_FLEET_MCP_SOCKET $LCARS_FLEET_MCP_SOCK_BASE/pod-1/sock"* ]]
  # NEVER the base wholesale: that would expose sibling pods' sockets (multi-human tenant leak).
  [[ "$output" != *"--bind $LCARS_FLEET_MCP_SOCK_BASE $LCARS_FLEET_MCP_SOCK_BASE"* ]]
}
@test "asm: --setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY 1 (pod stateless)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY 1"* ]]
}
@test "asm: --setenv HOME = pod_dir" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv HOME $POD_DIR"* ]]
}
@test "asm: --setenv session (SESSION_ID / RESUME / NAME_PREFIX)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--setenv LCARS_POD_SESSION_ID test-session-uuid"* ]]
  [[ "$output" == *"--setenv LCARS_POD_RESUME 0"* ]]
  [[ "$output" == *"--setenv LCARS_POD_SESSION_NAME_PREFIX lordzurp_engineer"* ]]
}
@test "asm: --setenv LCARS_CLAUDE_BIN = relocated vendor" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv LCARS_CLAUDE_BIN $POD_DIR/.local/bin/claude"* ]]
}
@test "asm: --chdir = pod_dir by default" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR"* ]]
}
@test "asm: --chdir = LCARS_POD_CWD when supplied (cwd = branch root)" {
  export LCARS_POD_CWD="$POD_DIR/repo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR/repo"* ]]
}
@test "asm: HOLDER = sh -c (tmux new-session -d + exec sleep infinity) — bwrap stays alive" {
  # The holder keeps bwrap-PID1 alive → the namespace and the tmux server survive. Without it, bwrap
  # exits the moment new-session -d returns and kills the namespace. The -d daemonizes, the sleep holds.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"/bin/sh -c"* ]]
  [[ "$output" == *"new-session -d -s"* ]]
  [[ "$output" == *"exec sleep infinity"* ]]
}
@test "asm: session name + command passed as the holder's ARGS (argv preserved, lcars-pod-<id> + command)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"lcars-pod-pod-1"* ]]
  [[ "$output" == *"/bin/true"* ]]
}

# ======================= Trap (pre-exec) =====================

@test "trap: a setup error cleans up pod_dir (default)" {
  export LCARS_GIT_MIRROR="/nonexistent/mirror"   # triggers a PRE-exec exit 1
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ ! -d "$POD_DIR" ]]
}
@test "trap: pod_dir preserved with LCARS_BWRAP_NO_CLEANUP=1" {
  export LCARS_BWRAP_NO_CLEANUP=1
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ -d "$POD_DIR" ]]
}

# ==================== N0/N1 frontier ========================

@test "frontier: no claude/vendor flag (N0 does not know claude)" {
  # `mkdir -p` is excluded: that is a shell builtin (defensive creation of .claude/), NOT claude's print
  # flag. bwrap_launch passes claude flags ONLY through the opaque ${COMMAND[@]}, never as a literal in
  # the source → any remaining literal `-p ` would be suspect, except this mkdir.
  ! grep -vE "^\s*#" "$SCRIPT" | grep -vE "mkdir -p" | grep -E "\-\-remote-control|\-\-system-prompt|\-\-mcp-config|\-\-allowedTools|\-\-permission-mode|\-p |\-\-print"
}
@test "frontier: invocable with any command (vendor-agnostic)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /usr/bin/env FOO=bar
  [[ "$status" -eq 0 ]]; [[ "$output" == *"/usr/bin/env FOO=bar"* ]]
}

# ==================== Fleet skills rail (BL-6-22) =================

@test "skills: a name:path line binds RO into ~/.claude/skills/<name> — path spaces preserved, no host-side mkdir" {
  # Newline format, first `:` separates. The path CARRIES a space — the case a word-split loop
  # would shatter. NC3 invariant: bwrap CREATES the bind target inside the namespace (same as the
  # plugin loop) — the launcher must NOT pre-create it host-side.
  mkdir -p "$POD_DIR/sk root/card-revision"
  export LCARS_SKILLS_PATHS="card-revision:$POD_DIR/sk root/card-revision"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/sk root/card-revision"* ]]
  [[ "$output" == *".claude/skills/card-revision"* ]]
}

@test "skills: a path-traversal skill name is rejected before any bind" {
  export LCARS_SKILLS_PATHS="../evil:/tmp"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}

@test "skills: a missing skill dir fails LOUD (projection/launch skew, never a silent skip)" {
  export LCARS_SKILLS_PATHS="ghost:$POD_DIR/absent-skill"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"no dir"* ]]
}

@test "skills: absent var → zero skill bind (skill-less pods unchanged)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" != *".claude/skills/"* ]]
}

# ==================== Plugin security (S5) =================

@test "security: a path-traversal plugin name (../) is rejected before any bind (S5 allowlist)" {
  export LCARS_SKILLS_PLUGINS="../evil"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}
@test "security: a plugin name with a slash is rejected (S5 allowlist)" {
  export LCARS_SKILLS_PLUGINS="a/b"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}

@test "security: bwrap is started with an EMPTY environment (S2: /proc/1/environ leak)" {
  # bwrap is PID 1 of the pod's namespace and keeps its OWN env: --clearenv scrubs the CHILD,
  # not bwrap. Measured in a live pod, /proc/1/environ handed the agent RELEASE_COOKIE (the
  # Erlang distribution secret) + the central's topology. `env -i` closes it at the source.
  run grep -E '^exec env -i "\$BWRAP_BIN"' "$SCRIPT"
  [[ "$status" -eq 0 ]]
}

@test "security: a secret in the spawner's ambient env never reaches the bwrap process" {
  # End-to-end on the assembly: the stub records ITS OWN environment; with `env -i` the secret
  # exported here must not appear in it (the pod's /proc/1/environ is that very environment).
  # The dump path is BAKED IN (unquoted heredoc → expanded now): under `env -i` the stub itself
  # inherits nothing, so it could not read a variable to find where to write.
  cat > "$LCARS_BWRAP_BIN" <<STUB
#!/usr/bin/env bash
env > "$TMP_BASE/bwrap.env"
exit 0
STUB
  chmod +x "$LCARS_BWRAP_BIN"
  RELEASE_COOKIE="cookie-must-not-leak" run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  run grep -c 'cookie-must-not-leak' "$TMP_BASE/bwrap.env"
  [[ "$output" == "0" ]]
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SCRIPT"; grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"; grep -q "^# STATUS:" "$SCRIPT"
}
