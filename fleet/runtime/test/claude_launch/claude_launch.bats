#!/usr/bin/env bats
# SOURCE: test/claude_launch/claude_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: beyond_#5 chantier 3 — tests bats bin/claude_launch.sh v2 (ADR-G, RC interactif)
#
# Tests intégration bin/claude_launch.sh (Ring 1, frontière vendor N1) au contrat ADR-G :
# 4 args positionnels <role> <pod_id> <pod_dir> <sp>, session UUID pré-allouée (env), exec
# `claude --remote-control` interactif (PAS -p/stream-json/budget). Le launcher exec direct →
# le stub claude echo ses args, on asserte sur la ligne STUB_ARGS.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/claude_launch.sh"
  TMP_BASE="$(mktemp -d)"
  POD_DIR="$TMP_BASE/pod-engineer-test"
  mkdir -p "$POD_DIR/.claude"

  # Cap-profile JSON resolved (forme fleet_spawner chantier 6)
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

  # Stub vendor claude : répond à --version (provisioning .claude.json) puis echo ses args.
  CLAUDE_STUB="$TMP_BASE/claude-stub"
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.159 (Claude Code)"; exit 0; fi
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$CLAUDE_STUB"

  export LCARS_CLAUDE_BIN="$CLAUDE_STUB"
  # Session : UUID pré-alloué + préfixe nom RC (posés par le spawner via bwrap --setenv en prod).
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"
  # SP inline (argv 4)
  SP="# Engineer SP de test"
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

@test "args: exit 1 quand 3 args (SP manquant)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 quand role est string vide" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"non-vides"* ]]
}

@test "args: exit 1 quand SP (argv 4) est vide" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" ""
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"SP inline"* ]]
}

# =============================================================
# Session env (:? strict — posés par le spawner)
# =============================================================

@test "session: exit non-zéro + message quand LCARS_POD_SESSION_ID absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"UUID de session requis"* ]]
}

@test "session: exit non-zéro + message quand LCARS_POD_SESSION_NAME_PREFIX absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"préfixe nom RC requis"* ]]
}

# =============================================================
# Setup checks
# =============================================================

@test "setup: exit 1 quand claude binary missing" {
  export LCARS_CLAUDE_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"claude binary missing"* ]]
}

@test "setup: exit 1 quand jq binary missing" {
  export LCARS_JQ_BIN="/nonexistent/jq"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"jq binary missing"* ]]
}

@test "setup: exit 1 quand cap-profile JSON missing" {
  rm -f "$POD_DIR/.cap-profile.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"cap-profile"* ]]
  [[ "$output" == *"missing"* ]]
}

# =============================================================
# Happy path + assemblage flags ADR-G (le stub echo ses args)
# =============================================================

@test "happy path: exit 0" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 0 ]]
}

@test "flags: --remote-control présent (RC-at-startup)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--remote-control"* ]]
}

@test "flags: 1ʳᵉ création → --session-id <UUID> (pas --resume)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "flags: recovery (LCARS_POD_RESUME=1) → --resume <UUID> (pas --session-id)" {
  export LCARS_POD_RESUME=1
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--resume test-session-uuid"* ]]
  [[ "$output" != *"--session-id"* ]]
}

@test "flags: --remote-control-session-name-prefix = préfixe humain_role" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--remote-control-session-name-prefix lordzurp_engineer"* ]]
}

@test "flags: --system-prompt inline porte le SP (pas de --system-prompt-file)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--system-prompt"* ]]
  [[ "$output" == *"Engineer SP de test"* ]]
  [[ "$output" != *"--system-prompt-file"* ]]
}

@test "flags: --dangerously-skip-permissions par défaut (sanctuaire = liberté, les murs portent la sécu)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--dangerously-skip-permissions"* ]]
  [[ "$output" != *"--permission-mode"* ]]
}

@test "flags: LCARS_PERMISSION_MODE override → --permission-mode <mode> (rôle bridé, pas skip)" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--permission-mode plan"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "flags: --allowedTools extrait du cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--allowedTools Read,Glob,Grep"* ]]
}

@test "flags: --disallowedTools extrait du cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--disallowedTools web_search,tool_search_internal"* ]]
}

@test "flags: --setting-sources project,local INCONDITIONNEL (exclut 'user')" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--setting-sources project,local"* ]]
}

@test "flags: --settings ajouté seulement si .lcars/settings.json présent" {
  mkdir -p "$POD_DIR/.lcars"
  echo '{}' > "$POD_DIR/.lcars/settings.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "flags: --mcp-config --strict-mcp-config si .mcp-fleet.json présent" {
  echo '{"mcpServers":{}}' > "$POD_DIR/.mcp-fleet.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" == *"--mcp-config $POD_DIR/.mcp-fleet.json"* ]]
  [[ "$output" == *"--strict-mcp-config"* ]]
}

# =============================================================
# Bypass dialog : levée du gate interactif (skipDangerousModePermissionPrompt en settings/flagSettings).
# PROVEN e2e sanctuaire 2026-06-01 : sans ça, claude RC hang sur « 1. No / 2. Yes I accept ».
# =============================================================

@test "bypass: mode skip provisionne skipDangerousModePermissionPrompt + le passe via --settings" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 0 ]]
  [[ -f "$POD_DIR/.lcars/settings.json" ]]
  grep -q "skipDangerousModePermissionPrompt" "$POD_DIR/.lcars/settings.json"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "bypass: merge non-destructif (settings pod préexistant conservé + flag ajouté)" {
  mkdir -p "$POD_DIR/.lcars"
  echo '{"hooks":{"PreToolUse":[]}}' > "$POD_DIR/.lcars/settings.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 0 ]]
  grep -q "skipDangerousModePermissionPrompt" "$POD_DIR/.lcars/settings.json"
  grep -q "PreToolUse" "$POD_DIR/.lcars/settings.json"   # l'existant n'est PAS clobberé
}

@test "bypass: rôle bridé (LCARS_PERMISSION_MODE) NE provisionne PAS le skip-dialog" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$status" -eq 0 ]]
  [[ ! -f "$POD_DIR/.lcars/settings.json" ]] || ! grep -q "skipDangerousModePermissionPrompt" "$POD_DIR/.lcars/settings.json"
}

# =============================================================
# Interdits ADR-G (IV.1/IV.2 : pas de -p/stream-json/budget)
# =============================================================

@test "ADR-G: aucun -p/--print/--output-format/stream-json/--max-budget-usd" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "$SP"
  [[ "$output" != *"--print"* ]]
  [[ "$output" != *"--output-format"* ]]
  [[ "$output" != *"stream-json"* ]]
  [[ "$output" != *"--max-budget-usd"* ]]
}

# =============================================================
# Frontière vendor N1 — préfixe claude_*, jamais bwrap/tmux
# =============================================================

@test "frontière vendor: aucun containment fonctionnel (flags bwrap / bwrap|tmux exécutés)" {
  # Les MENTIONS en doc/string (« LCARS_CLAUDE_BIN posé par bwrap », « le PTY est tmux ») sont
  # légitimes (frontière N0/N1 documentée). On interdit le FONCTIONNEL : flags bwrap
  # (--ro-bind/--unshare/--clearenv/--tmpfs) ou bwrap/tmux exécutés (début de ligne ou après exec).
  ! grep -vE "^\s*#" "$SCRIPT" | grep -E "(^|exec +)(bwrap|tmux)\b|--ro-bind|--unshare|--clearenv|--tmpfs"
}

@test "frontière vendor: pas de --bare ni anthropic_api_key fonctionnels (hors commentaires)" {
  ! grep -vE "^\s*#" "$SCRIPT" | grep -iE "openai|anthropic_api_key|--bare"
}

@test "frontière vendor: script connaît juste claude (vendor N1)" {
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
