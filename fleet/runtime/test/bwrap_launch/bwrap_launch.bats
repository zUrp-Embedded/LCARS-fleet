#!/usr/bin/env bats
# SOURCE: test/bwrap_launch/bwrap_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: beyond_#5 chantier 3 — tests bats bin/bwrap_launch.sh v2 (sanctuaire ADR-G)
#
# Modèle v2 = ASYNC détaché (bwrap → tmux new-session -d → command ; bwrap rend 0, exit non propagé).
# Donc on stube bwrap (echo de l'invocation) et on asserte l'ASSEMBLAGE des flags v2. La vraie
# isolation-sanctuaire (/ RO, /home tmpfs, env exposé) passe en e2e (real bwrap+tmux+pod), pas en bats
# sur du détaché. Couvre : args, session :?, setup checks, assemblage (clearenv/die-with-parent/binds/
# setenv/sock-dir/tmux), trap pré-exec, frontière N0/N1.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/bwrap_launch.sh"
  TMP_BASE="$(mktemp -d)"

  POD_DIR="$TMP_BASE/pod-engineer-test"; mkdir -p "$POD_DIR/.claude"
  export CLAUDE_DIR="$TMP_BASE/claudedir"; mkdir -p "$CLAUDE_DIR"
  export LCARS_GIT_MIRROR="$TMP_BASE/git-mirror"; mkdir -p "$LCARS_GIT_MIRROR"
  export LCARS_TMUX_SOCK_BASE="$TMP_BASE/sock"; mkdir -p "$LCARS_TMUX_SOCK_BASE"

  # Vendor stub (juste -x + un share dir). Autorité explicite (pas de résolution PATH).
  export LCARS_VENDOR_NAME="claude"
  export LCARS_VENDOR_BIN="$TMP_BASE/vendor/bin/claude"
  export LCARS_VENDOR_SHARE="$TMP_BASE/vendor/share"
  mkdir -p "$(dirname "$LCARS_VENDOR_BIN")" "$LCARS_VENDOR_SHARE"
  echo '#!/usr/bin/env bash' > "$LCARS_VENDOR_BIN"; chmod +x "$LCARS_VENDOR_BIN"

  # Session : posées par le spawner en prod.
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"

  # Stub bwrap : echo l'invocation complète (incl la commande tmux) → assertions d'assemblage.
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

@test "args: exit 1 quand aucun argument" {
  run "$SCRIPT"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 quand 3 args (command manquant)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 quand role est string vide" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"non-empty"* ]]
}

# ===================== Session (:? strict) ====================

@test "session: exit non-zéro + message quand LCARS_POD_SESSION_ID absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"UUID de session requis"* ]]
}
@test "session: exit non-zéro + message quand LCARS_POD_SESSION_NAME_PREFIX absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"préfixe nom RC requis"* ]]
}

# ======================= Setup checks ========================

@test "setup: exit 2 quand bwrap missing" {
  export LCARS_BWRAP_BIN="/nonexistent/bwrap"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"bwrap missing"* ]]
}
@test "setup: exit 2 quand tmux missing" {
  export LCARS_TMUX_BIN="/nonexistent/tmux"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"tmux missing"* ]]
}
@test "setup: exit 2 quand vendor missing" {
  export LCARS_VENDOR_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"vendor"* ]]
}
@test "setup: exit 1 quand claudeDir missing" {
  export CLAUDE_DIR="/nonexistent/claudedir"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"claudeDir"* ]]
}
@test "setup: exit 1 quand git mirror missing" {
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"git mirror"* ]]
}
@test "setup: exit 1 quand pod_dir missing" {
  run "$SCRIPT" engineer pod-1 "$TMP_BASE/nope" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"pod_dir"* ]]
}
@test "setup: exit 1 quand sock parent missing" {
  export LCARS_TMUX_SOCK_BASE="/nonexistent/sock-base"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"sock parent"* ]]
}

# ============== Assemblage bwrap (stub echo) — v2 ==============

@test "asm: --clearenv (env clos)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--clearenv"* ]]
}
@test "asm: --die-with-parent (orphan-safe)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--die-with-parent"* ]]
}
@test "asm: --unshare-all --share-net" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--unshare-all"* ]]; [[ "$output" == *"--share-net"* ]]
}
@test "asm: bind pod_dir + claudeDir→.claude + git-mirror RO" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $POD_DIR $POD_DIR"* ]]
  [[ "$output" == *"--bind $CLAUDE_DIR $POD_DIR/.claude"* ]]
  [[ "$output" == *"--ro-bind $LCARS_GIT_MIRROR $LCARS_GIT_MIRROR"* ]]
}
@test "asm: relocation vendor → pod/.local/bin (binaire per-user)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--ro-bind $LCARS_VENDOR_BIN $POD_DIR/.local/bin/claude"* ]]
}
@test "asm: bind socket-dir par-pod" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $LCARS_TMUX_SOCK_BASE/pod-1 $LCARS_TMUX_SOCK_BASE/pod-1"* ]]
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
@test "asm: --chdir = pod_dir par défaut" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR"* ]]
}
@test "asm: --chdir = LCARS_POD_CWD si fourni (cwd=racine branche)" {
  export LCARS_POD_CWD="$POD_DIR/repo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR/repo"* ]]
}
@test "asm: HOLDER = sh -c (tmux new-session -d + exec sleep infinity) — bwrap reste vivant" {
  # Le holder garde bwrap-PID1 → namespace + serveur tmux survivent (corr. terrain : sans lui, bwrap
  # sort dès que new-session -d rend la main et tue le namespace). Le -d daemonise, le sleep tient.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"/bin/sh -c"* ]]
  [[ "$output" == *"new-session -d -s"* ]]
  [[ "$output" == *"exec sleep infinity"* ]]
}
@test "asm: session name + command passés en ARGS du holder (argv préservé, lcars-pod-<id> + command)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"lcars-pod-pod-1"* ]]
  [[ "$output" == *"/bin/true"* ]]
}

# ======================= Trap (pré-exec) =====================

@test "trap: setup error nettoie pod_dir (default)" {
  export LCARS_GIT_MIRROR="/nonexistent/mirror"   # déclenche exit 1 PRÉ-exec
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ ! -d "$POD_DIR" ]]
}
@test "trap: pod_dir préservé avec LCARS_BWRAP_NO_CLEANUP=1" {
  export LCARS_BWRAP_NO_CLEANUP=1
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ -d "$POD_DIR" ]]
}

# ==================== Frontière N0/N1 ========================

@test "frontière: aucun flag claude/vendor (N0 ne connaît pas claude)" {
  ! grep -vE "^\s*#" "$SCRIPT" | grep -E "\-\-remote-control|\-\-system-prompt|\-\-mcp-config|\-\-allowedTools|\-\-permission-mode|\-p |\-\-print"
}
@test "frontière: invocable avec n'importe quel command (vendor-agnostic)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /usr/bin/env FOO=bar
  [[ "$status" -eq 0 ]]; [[ "$output" == *"/usr/bin/env FOO=bar"* ]]
}

@test "header LCARS: SOURCE/AUTHOR/STARDATE/STATUS présents" {
  grep -q "^# SOURCE:" "$SCRIPT"; grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"; grep -q "^# STATUS:" "$SCRIPT"
}
