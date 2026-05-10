#!/usr/bin/env bats
# SOURCE: test/claude_launch/claude_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: chantier #5 run #3.1 — tests bats bin/claude_launch.sh
#
# Tests intégration bin/claude_launch.sh (Ring 1 frontière vendor N1).
# Couvre args validation, setup checks, extraction cap-profile JSON,
# stream-json output, timeout enforcement, frontière vendor N1.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/claude_launch.sh"
  TMP_BASE="$(mktemp -d)"
  POD_DIR="$TMP_BASE/pod-engineer-test"
  mkdir -p "$POD_DIR/.claude" "$POD_DIR/context" "$POD_DIR/output"

  # Cap-profile JSON resolved (forme attendue chantier 6 fleet_spawner)
  cat > "$POD_DIR/.cap-profile.json" <<'EOF'
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "engineer"},
  "spec": {
    "scope": {
      "allowedTools": ["Read", "Glob", "Grep"],
      "disallowedTools": ["web_search", "tool_search_internal"]
    }
  }
}
EOF

  echo "# Engineer SP" > "$POD_DIR/.claude/system-prompt.md"
  echo "# Brief" > "$POD_DIR/context/brief.md"

  # Stub claude binary qui imite le comportement minimal (lit args, écrit
  # stream-json sur stdout, exit 0).
  CLAUDE_STUB="$TMP_BASE/claude-stub"
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
# Stub vendor claude -p pour tests
echo '{"type":"init","session_id":"stub-1"}'
echo '{"type":"result","subtype":"success"}'
# Echo args reçus pour assertions test
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$CLAUDE_STUB"
  export LCARS_CLAUDE_BIN="$CLAUDE_STUB"
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

@test "args: exit 1 quand 4 args (budget_usd manquant)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 quand role est string vide" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"non-vides"* ]]
}

@test "args: exit 1 quand budget_sec n'est pas un entier" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "not-a-number" 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"strictement positif"* ]]
}

@test "args: exit 1 quand budget_sec = 0 (non strictement positif)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 0 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"strictement positif"* ]]
}

# =============================================================
# Setup checks
# =============================================================

@test "setup: exit 1 quand claude binary missing" {
  export LCARS_CLAUDE_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"claude binary missing"* ]]
}

@test "setup: exit 1 quand jq binary missing" {
  export LCARS_JQ_BIN="/nonexistent/jq"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"jq binary missing"* ]]
}

@test "setup: exit 1 quand cap-profile JSON missing" {
  rm -f "$POD_DIR/.cap-profile.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"cap-profile"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "setup: exit 1 quand SP missing" {
  rm -f "$POD_DIR/.claude/system-prompt.md"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"SP"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "setup: exit 1 quand brief missing" {
  rm -f "$POD_DIR/context/brief.md"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"brief"* ]]
  [[ "$output" == *"missing"* ]]
}

# =============================================================
# Happy path : exec claude stub + stream-json output
# =============================================================

@test "happy path: claude stub exit 0 → status 0" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 0 ]]
}

@test "happy path: NDJSON output créé sous \$POD_DIR/output/" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 0 ]]
  [[ -f "$POD_DIR/output/.claude-stream.ndjson" ]]
}

@test "happy path: NDJSON contient stream-json events init+result" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *'"type":"init"'* ]]
  [[ "$ndjson" == *'"type":"result"'* ]]
}

@test "happy path: LCARS_NDJSON_LOG override redirige output" {
  CUSTOM_LOG="$TMP_BASE/custom.ndjson"
  export LCARS_NDJSON_LOG="$CUSTOM_LOG"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  [[ "$status" -eq 0 ]]
  [[ -f "$CUSTOM_LOG" ]]
  [[ ! -f "$POD_DIR/output/.claude-stream.ndjson" ]]
}

# =============================================================
# Flags claude -p : extraction cap-profile + injection
# =============================================================

@test "flags: --output-format stream-json passé au claude binary" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--output-format stream-json"* ]]
}

@test "flags: --verbose présent" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--verbose"* ]]
}

@test "flags: --system-prompt-file pointe vers SP path" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--system-prompt-file"* ]]
  [[ "$ndjson" == *"$POD_DIR/.claude/system-prompt.md"* ]]
}

@test "flags: --append-system-prompt-file pointe vers brief path" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--append-system-prompt-file"* ]]
  [[ "$ndjson" == *"$POD_DIR/context/brief.md"* ]]
}

@test "flags: --allowedTools extrait du cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--allowedTools Read,Glob,Grep"* ]]
}

@test "flags: --disallowedTools extrait du cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 1.0
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--disallowedTools web_search,tool_search_internal"* ]]
}

@test "flags: --max-budget-usd injecté depuis args" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 60 2.5
  ndjson="$(cat "$POD_DIR/output/.claude-stream.ndjson")"
  [[ "$ndjson" == *"--max-budget-usd 2.5"* ]]
}

# =============================================================
# Budget enforcement timeout bash (double étage)
# =============================================================

@test "timeout: claude stub qui sleep > budget → exit 124" {
  # Stub qui sleep 5s ; budget 1s → timeout doit firer
  cat > "$LCARS_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
  chmod +x "$LCARS_CLAUDE_BIN"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" 1 1.0
  [[ "$status" -eq 124 ]]
}

# =============================================================
# Frontière vendor N1 — préfixe claude_*, jamais bwrap
# =============================================================

@test "frontière vendor: aucune référence fonctionnelle bwrap (hors commentaires)" {
  # Le script peut mentionner "bwrap" en doc (header expliquant qu'il
  # est invoqué par bwrap_launch.sh) mais pas dans du code exécutable.
  # On filtre les lignes de commentaires (^# et trailing # comments).
  ! grep -vE "^\s*#" "$SCRIPT" | grep -E "bwrap|--ro-bind|--unshare"
}

@test "frontière vendor: aucune référence fonctionnelle openai/anthropic-sdk (hors commentaires)" {
  ! grep -vE "^\s*#" "$SCRIPT" | grep -iE "openai|anthropic_api_key|--bare"
}

@test "frontière vendor: script connaît juste claude (vendor N1)" {
  # Le script doit référencer "claude" (binary, flags) mais pas d'autres vendors.
  grep -q "claude" "$SCRIPT"
}

# =============================================================
# Header LCARS standard
# =============================================================

@test "header LCARS: SOURCE/AUTHOR/STARDATE/STATUS présents" {
  grep -q "^# SOURCE:" "$SCRIPT"
  grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"
  grep -q "^# STATUS:" "$SCRIPT"
}
