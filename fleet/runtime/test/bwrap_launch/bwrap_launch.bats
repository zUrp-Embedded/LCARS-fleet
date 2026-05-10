#!/usr/bin/env bats
# SOURCE: test/bwrap_launch/bwrap_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: chantier #4 run #3.1 — tests bats bin/bwrap_launch.sh
#
# Tests intégration bin/bwrap_launch.sh (Ring 1 pod primitive).
# Couvre args validation, setup checks, ENV defaults, durcissement
# bwrap PoC-3 T2, ADR-B Q4 (random pod_id namespace), ADR-B Q5
# (git mirror RO).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/bwrap_launch.sh"

  TMP_BASE="$(mktemp -d)"
  export LCARS_CREDS_ROOT="$TMP_BASE/credentials"
  export LCARS_GIT_MIRROR="$TMP_BASE/git-mirror"
  export LCARS_BWRAP_NO_CLEANUP=1

  mkdir -p "$LCARS_CREDS_ROOT/engineer"
  mkdir -p "$LCARS_GIT_MIRROR"

  POD_DIR="$TMP_BASE/pod-engineer-test"
  mkdir -p "$POD_DIR"
}

teardown() {
  rm -rf "$TMP_BASE"
}

# =============================================================
# Args validation
# =============================================================

@test "args: exit 1 quand aucun argument" {
  run "$SCRIPT"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 quand role manquant (1 arg seul)" {
  run "$SCRIPT" engineer
  [[ "$status" -eq 1 ]]
}

@test "args: exit 1 quand command manquant (3 args sans command)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
}

@test "args: exit 1 quand role est string vide" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"non-empty"* ]]
}

# =============================================================
# Setup checks
# =============================================================

@test "setup: exit 2 quand bwrap binary missing" {
  export LCARS_BWRAP_BIN="/nonexistent/bwrap"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"bwrap binary missing"* ]]
}

@test "setup: exit 1 quand coffre role missing" {
  rm -rf "$LCARS_CREDS_ROOT/engineer"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"coffre"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "setup: exit 1 quand coffre role autre que demandé manque" {
  run "$SCRIPT" architect pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"architect"* ]]
}

@test "setup: exit 1 quand git mirror missing" {
  rm -rf "$LCARS_GIT_MIRROR"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"git mirror"* ]]
}

@test "setup: exit 1 quand pod_dir missing" {
  rm -rf "$POD_DIR"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"pod_dir"* ]]
}

# =============================================================
# Happy path : exec bwrap + propagation exit code command
# =============================================================

@test "happy path: command /bin/true → exit 0" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
}

@test "happy path: command /bin/false → exit 1 propagé" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/false
  [[ "$status" -eq 1 ]]
}

@test "happy path: command exit 42 propagé" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'exit 42'
  [[ "$status" -eq 42 ]]
}

# =============================================================
# ENV defaults LCARS v2 hardcoded
# =============================================================

@test "env: LCARS_POD_ID est exposé dans le pod" {
  run "$SCRIPT" engineer my-pod-id-42 "$POD_DIR" bash -c 'echo "$LCARS_POD_ID"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"my-pod-id-42"* ]]
}

@test "env: LCARS_ROLE est exposé dans le pod" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$LCARS_ROLE"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"engineer"* ]]
}

@test "env: DISABLE_TELEMETRY=1 (LCARS v2 default)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$DISABLE_TELEMETRY"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"1"* ]]
}

@test "env: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 (PoC-3)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"1"* ]]
}

@test "env: DISABLE_AUTOUPDATER=1 (LCARS v2 default)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$DISABLE_AUTOUPDATER"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"1"* ]]
}

@test "env: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=100 (PoC-24)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"100"* ]]
}

@test "env: HOME pointe vers POD_DIR" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "$HOME"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"$POD_DIR"* ]]
}

# =============================================================
# Durcissement bwrap PoC-3 T2
# =============================================================

@test "bwrap: pod ne peut pas écrire dans / (root RO)" {
  # /etc est sous --ro-bind / / → écriture doit échouer.
  # Le inner bash propage le status du redirect via `exit $?` final ; le script
  # bwrap_launch propage cet exit via exec → status global non-zero.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'echo "boom" > /etc/lcars-injection; exit $?'
  [[ "$status" -ne 0 ]]
  [[ ! -e /etc/lcars-injection ]]
}

@test "bwrap: /home est tmpfs vide (isolation cross-role)" {
  # /home doit exister mais ne contenir aucun home utilisateur du host
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'ls /home | wc -l'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"0"* ]]
}

@test "bwrap: pod_dir RW (le pod peut écrire dedans via \$HOME)" {
  # Le pod expose POD_DIR via HOME (--setenv HOME "$POD_DIR")
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c 'touch "$HOME/canary" && ls "$HOME"'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"canary"* ]]
}

@test "bwrap: coffre role accessible RO (lecture)" {
  echo "rt-test" > "$LCARS_CREDS_ROOT/engineer/oauth_refresh_token"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c "cat $LCARS_CREDS_ROOT/engineer/oauth_refresh_token"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"rt-test"* ]]
}

@test "bwrap: coffre role est RO (pod ne peut pas écrire)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c "echo bad > $LCARS_CREDS_ROOT/engineer/oauth_refresh_token 2>&1; echo exit=\$?"
  [[ "$output" != *"exit=0"* ]]
}

@test "bwrap: git mirror accessible RO" {
  echo "marker" > "$LCARS_GIT_MIRROR/canary"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" bash -c "cat $LCARS_GIT_MIRROR/canary"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"marker"* ]]
}

# =============================================================
# ADR-B Q4 — random pod_id via bwrap user namespace
# =============================================================

@test "adr-b q4: bwrap user namespace différent du host (isolation kernel)" {
  # --unshare-all inclut --unshare-user. La visible UID peut rester identique
  # (mapping default identity), mais le user namespace kernel-side est nouveau
  # → le pod a une inode user-namespace différente de l'host. Vérifie via
  # `readlink /proc/self/ns/user` (kernel-stable).
  HOST_NS="$(readlink /proc/self/ns/user)"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" readlink /proc/self/ns/user
  [[ "$status" -eq 0 ]]
  POD_NS="$(echo "$output" | tail -1 | tr -d '\r')"
  [[ -n "$POD_NS" ]]
  [[ "$POD_NS" != "$HOST_NS" ]]
}

# =============================================================
# F-CRIT-3 trap cleanup (default: trap actif si LCARS_BWRAP_NO_CLEANUP non-set)
# =============================================================

@test "trap F-CRIT-3: pod_dir nettoyé sur exit setup error (default cleanup)" {
  # Désactive le NO_CLEANUP par défaut du setup() pour ce test.
  unset LCARS_BWRAP_NO_CLEANUP
  TRAP_POD_DIR="$TMP_BASE/pod-trap-test"
  mkdir -p "$TRAP_POD_DIR"
  # Force un exit 1 setup error (coffre missing) AVANT exec → trap doit firer.
  rm -rf "$LCARS_CREDS_ROOT/no-such-role"
  run "$SCRIPT" no-such-role pod-trap "$TRAP_POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ ! -d "$TRAP_POD_DIR" ]]
}

@test "trap F-CRIT-3: pod_dir préservé quand LCARS_BWRAP_NO_CLEANUP=1" {
  export LCARS_BWRAP_NO_CLEANUP=1
  PRESERVED_POD_DIR="$TMP_BASE/pod-preserve-test"
  mkdir -p "$PRESERVED_POD_DIR"
  rm -rf "$LCARS_CREDS_ROOT/no-such-role"
  run "$SCRIPT" no-such-role pod-preserve "$PRESERVED_POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ -d "$PRESERVED_POD_DIR" ]]
}

# =============================================================
# Frontière vendor — bwrap_launch.sh est vendor-agnostic
# =============================================================

@test "frontière vendor: aucun flag claude/anthropic dans le script" {
  ! grep -E "claude -p|--system-prompt-file|--append-system-prompt|--allowedTools|ANTHROPIC_API_KEY" "$SCRIPT"
}

@test "frontière vendor: invocable avec n'importe quel command (echo, cat, etc.)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/echo "hello-vendor-agnostic"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"hello-vendor-agnostic"* ]]
}
