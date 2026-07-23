#!/usr/bin/env bats
# SOURCE: test/claude_launch/claude_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: bats tests for bin/claude_launch.sh v2 (ADR-G, interactive RC)
#
# Integration tests for bin/claude_launch.sh (the N1 vendor frontier) against the CURRENT ADR-G
# contract: 3 positional args <role> <pod_id> <pod_dir>. The SP is NOT an arg any more — it was pulled
# out of the argv to stop it leaking through /proc/cmdline. The launcher reads it from
# $POD_DIR/.lcars/system-prompt.md (written by the spawner in do_project) and passes it through
# --system-prompt-file (replace + TRUSTED). The pre-allocated session UUID and the RC name prefix travel
# through the ENV (LCARS_POD_SESSION_ID / _RESUME / _SESSION_NAME_PREFIX). Permissions default to
# --permission-mode default (#kill-yolo: the lists are ENFORCED, no more --dangerously-skip). It execs
# `claude --remote-control` interactively (NOT -p/stream-json/budget). Since the launcher execs
# directly, the claude stub echoes its args and we assert on the STUB_ARGS line.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/claude_launch.sh"
  TMP_BASE="$(mktemp -d)"
  POD_DIR="$TMP_BASE/pod-engineer-test"
  mkdir -p "$POD_DIR/.claude" "$POD_DIR/.lcars"

  # Resolved cap-profile JSON (the fleet_spawner shape). No spec.invocation → the launcher falls back on
  # its defaults (permission_mode "default", remote_control true, model/effort omitted).
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

  # claude vendor stub: answers --version (for the .claude.json provisioning) then echoes its args.
  CLAUDE_STUB="$TMP_BASE/claude-stub"
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.159 (Claude Code)"; exit 0; fi
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
printf 'STUB_ENV: ENABLE_TOOL_SEARCH=%s\n' "${ENABLE_TOOL_SEARCH:-unset}"
exit 0
EOF
  chmod +x "$CLAUDE_STUB"

  export LCARS_CLAUDE_BIN="$CLAUDE_STUB"
  # Session: pre-allocated UUID + RC name prefix (set by the spawner through bwrap --setenv in prod).
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"

  # SP OUT of the argv: the launcher reads it from $POD_DIR/.lcars/system-prompt.md through
  # --system-prompt-file (written by the spawner in do_project). So we provision it LIKE the spawner
  # does, not as an arg.
  SP_FILE="$POD_DIR/.lcars/system-prompt.md"
  printf '%s\n' "# Engineer test SP" > "$SP_FILE"
}

teardown() {
  rm -rf "$TMP_BASE"
}

# =============================================================
# Args validation — STRICT 3-arg contract (the SP is no longer positional)
# =============================================================

@test "args: exit 1 with no argument" {
  run "$SCRIPT"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 with 4 args (the SP is NO LONGER positional — strict $# -ne 3)" {
  # The old contract took the SP as argv 4. Pulling it out of the argv (anti-leak hardening) makes a
  # 4th arg one arg too many: usage error.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "# one SP too many"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 when role is an empty string" {
  run "$SCRIPT" "" pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"must be non-empty"* ]]
}

@test "args: exit 1 when the SP file (.lcars/system-prompt.md) is missing or empty" {
  # The SP is read from a file ([[ ! -s ]] = missing OR empty). We truncate it to exercise the -s.
  : > "$SP_FILE"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"SP file"* ]]
  [[ "$output" == *"missing or empty"* ]]
}

# =============================================================
# Session env (strict :? — set by the spawner)
# =============================================================

@test "session: non-zero exit + message when LCARS_POD_SESSION_ID is absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"session UUID required"* ]]
}

@test "session: non-zero exit + message when LCARS_POD_SESSION_NAME_PREFIX is absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"RC name prefix required"* ]]
}

# =============================================================
# Setup checks
# =============================================================

@test "setup: exit 1 when the claude binary is missing" {
  export LCARS_CLAUDE_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"claude binary missing"* ]]
}

@test "setup: exit 1 when the jq binary is missing" {
  export LCARS_JQ_BIN="/nonexistent/jq"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"jq binary missing"* ]]
}

@test "setup: exit 1 when the cap-profile JSON is missing" {
  rm -f "$POD_DIR/.cap-profile.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"cap-profile"* ]]
  [[ "$output" == *"missing"* ]]
}

# =============================================================
# Happy path + ADR-G flag assembly (the stub echoes its args)
# =============================================================

@test "happy path: exit 0" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
}

# =============================================================
# Setting-sources guard — 'user' is FORBIDDEN in ANY source list (the human's settings must
# never bleed into the pod); the env override is validated, not trusted.
# =============================================================

@test "setting-sources: override containing 'user' -> REFUSED (exit 1, named knob)" {
  LCARS_SETTING_SOURCES="user,project,local" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"LCARS_SETTING_SOURCES"* ]]
  [[ "$output" == *"user"* ]]
}

@test "setting-sources: 'user' alone -> REFUSED" {
  LCARS_SETTING_SOURCES="user" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
}

@test "setting-sources: 'user' in the middle -> REFUSED" {
  LCARS_SETTING_SOURCES="project,user,local" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
}

@test "setting-sources: legitimate override (project only) -> accepted, forwarded" {
  LCARS_SETTING_SOURCES="project" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--setting-sources project"* ]]
}

@test "setting-sources: 'project, user' (space-padded token) -> REFUSED" {
  LCARS_SETTING_SOURCES="project, user" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"REFUSED"* ]]
}

@test "setting-sources: 'user ,project' (leading space on user) -> REFUSED" {
  LCARS_SETTING_SOURCES="user ,project" run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
}

@test "flags: --remote-control present (RC-at-startup)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--remote-control"* ]]
}

@test "env: ENABLE_TOOL_SEARCH not exported (the vendor default is kept)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"STUB_ENV: ENABLE_TOOL_SEARCH=unset"* ]]
}

@test "F115/F157: the provisioned .claude.json carries the 3 remote-control keys (single N1 writer)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  # The launcher is the ONLY writer of .claude.json: without these keys the RC dialog blocks the boot
  # again (pod.ex N0 no longer sets them — its version was clobbered by this `cat >`).
  [[ -f "$POD_DIR/.claude.json" ]]
  run cat "$POD_DIR/.claude.json"
  [[ "$output" == *'"remoteControlAtStartup": true'* ]]
  [[ "$output" == *'"hasUsedRemoteControl": true'* ]]
  [[ "$output" == *'"remoteDialogSeen": true'* ]]
}

@test "flags: first creation → --session-id <UUID> (not --resume)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "flags: recovery (LCARS_POD_RESUME=1) → --resume <UUID> (not --session-id)" {
  export LCARS_POD_RESUME=1
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--resume test-session-uuid"* ]]
  [[ "$output" != *"--session-id"* ]]
}

@test "flags: RC name = the human_role prefix (--remote-control's positional, NOT an auto suffix)" {
  # The Desktop-readable RC name is --remote-control's positional (= SESSION_NAME_PREFIX =
  # <project>_<role>), NOT --remote-control-session-name-prefix, which would glue on a random auto
  # suffix that stacks up.
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--remote-control lordzurp_engineer"* ]]
}

@test "flags: SP through --system-prompt-file (OUT of the argv, /proc/cmdline anti-leak) — not inline" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  # The launcher passes the SP file's PATH, not its content → the SP does not leak into the exec'd argv.
  [[ "$output" == *"--system-prompt-file $POD_DIR/.lcars/system-prompt.md"* ]]
  [[ "$output" != *"Engineer test SP"* ]]
}

@test "flags: --permission-mode default by default (#kill-yolo: lists ENFORCED, no skip)" {
  # The world is already shaped (bwrap RO/RW + cap-profile allow/deny), so we no longer use
  # --dangerously-skip-permissions, which neutralized the lists. With no
  # spec.invocation.permission_mode, the default is "default".
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--permission-mode default"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "flags: LCARS_PERMISSION_MODE override → --permission-mode <mode> (restricted role)" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--permission-mode plan"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "flags: --allowedTools = cap-profile + the universal fleet MCP protocol (get_work_item/submit_result)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--allowedTools Read,Glob,Grep"* ]]
  # #kill-yolo: the fleet MCP protocol (get_work_item/submit_result) is APPENDED to the allowlist —
  # otherwise an unlisted MCP tool PROMPTS under --permission-mode default, which hangs headless.
  [[ "$output" == *"mcp__fleet__get_work_item"* ]]
  [[ "$output" == *"mcp__fleet__submit_result"* ]]
}

@test "flags: --disallowedTools extracted from the cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--disallowedTools web_search,tool_search_internal"* ]]
}

@test "flags: --setting-sources project,local UNCONDITIONAL (excludes 'user')" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--setting-sources project,local"* ]]
}

@test "flags: --settings points at .lcars/settings.json (additive flagSettings)" {
  # The pod settings are provisioned UNCONDITIONALLY (cf. the settings section) → --settings is always emitted.
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "flags: --mcp-config --strict-mcp-config when .mcp-fleet.json is present" {
  echo '{"mcpServers":{}}' > "$POD_DIR/.mcp-fleet.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--mcp-config $POD_DIR/.mcp-fleet.json"* ]]
  [[ "$output" == *"--strict-mcp-config"* ]]
}

# =============================================================
# Pod settings (.lcars/settings.json): UNCONDITIONAL provisioning + --settings pass-through
# (flagSettings). #kill-yolo: PERM_MODE default → no --dangerously-skip-permissions and no
# skipDangerousModePermissionPrompt on the default path. The file carries autoMemoryEnabled:false
# (F-POD-AUTOMEM: pod auto-memory off). The skip-dialog is reserved for PERM_MODE=bypassPermissions —
# the real enum value, since PERM_MODE is NEVER empty (it defaults to "default") and the old `-z` guard
# was therefore dead code. --settings is the flagSettings source, independent of --setting-sources.
# =============================================================

@test "settings: provisions .lcars/settings.json (autoMemory off) + passes it through --settings" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ -f "$POD_DIR/.lcars/settings.json" ]]
  grep -q "autoMemoryEnabled" "$POD_DIR/.lcars/settings.json"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "settings: non-destructive merge (pre-existing pod settings kept + fleet key added)" {
  echo '{"hooks":{"PreToolUse":[]}}' > "$POD_DIR/.lcars/settings.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  grep -q "autoMemoryEnabled" "$POD_DIR/.lcars/settings.json"   # the fleet key is added
  grep -q "PreToolUse" "$POD_DIR/.lcars/settings.json"          # the existing content is NOT clobbered
}

@test "settings: a restricted role (LCARS_PERMISSION_MODE) does NOT provision the skip-dialog" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  # The file exists (autoMemoryEnabled is UNCONDITIONAL) but WITHOUT
  # skipDangerousModePermissionPrompt: the skip-dialog is reserved for PERM_MODE=bypassPermissions,
  # never for a restricted or default mode.
  ! grep -q "skipDangerousModePermissionPrompt" "$POD_DIR/.lcars/settings.json"
}

@test "settings: PERM_MODE=bypassPermissions (env override) provisions the skip-dialog (pre-accepted, no hang)" {
  # Regression: the historical `-z "$PERM_MODE"` guard was DEAD (PERM_MODE is never empty, it defaults
  # to "default"), so a bypassPermissions pod hung at boot on the "Yes I accept" dialog. The guard is
  # now keyed on the real enum value (launch_spec.ex @permission_modes).
  export LCARS_PERMISSION_MODE=bypassPermissions
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
  grep -q '"skipDangerousModePermissionPrompt":true' "$POD_DIR/.lcars/settings.json"
}

@test "settings: cap-profile permission_mode=bypassPermissions provisions the skip-dialog (in-sandbox channel)" {
  # Same invariant as above but through the PROD channel: the cap-profile JSON's
  # `.spec.invocation.permission_mode`. bwrap --clearenv strips the env, so the JSON IS the mode's channel.
  cat > "$POD_DIR/.cap-profile.json" <<'EOF'
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "engineer"},
  "spec": {
    "invocation": {"permission_mode": "bypassPermissions"},
    "scope": {"allowedTools": ["Read"], "disallowedTools": []}
  }
}
EOF
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
  grep -q '"skipDangerousModePermissionPrompt":true' "$POD_DIR/.lcars/settings.json"
}

@test "version: claude --version in an unexpected format → fallback 2.1.150, NOT a pipefail death" {
  # Regression: `VER=$(... | grep ...)` under `set -euo pipefail` died (opaque exit 1, for EVERY pod)
  # whenever the --version format changed — the ${VER:-2.1.150} fallback was unreachable on that path.
  # The pipeline must be non-fatal and the fallback must actually apply.
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "Claude Code (dev build, no semver here)"; exit 0; fi
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$CLAUDE_STUB"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  grep -q '"lastOnboardingVersion": "2.1.150"' "$POD_DIR/.claude.json"
}

# =============================================================
# ADR-G prohibitions (IV.1/IV.2: no -p/stream-json/budget)
# =============================================================

@test "ADR-G: no -p/--print/--output-format/stream-json/--max-budget-usd" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" != *"--print"* ]]
  [[ "$output" != *"--output-format"* ]]
  [[ "$output" != *"stream-json"* ]]
  [[ "$output" != *"--max-budget-usd"* ]]
}

# =============================================================
# N1 vendor frontier — claude_* only, never bwrap/tmux
# =============================================================

@test "vendor frontier: no functional containment (bwrap flags / bwrap|tmux executed)" {
  # MENTIONS in doc or strings ("LCARS_CLAUDE_BIN set by bwrap", "the PTY is tmux") are legitimate —
  # the N0/N1 frontier is documented. What is forbidden is the FUNCTIONAL use: bwrap flags
  # (--ro-bind/--unshare/--clearenv/--tmpfs) or bwrap/tmux executed (line start, or after exec).
  ! grep -vE "^\s*#" "$SCRIPT" | grep -E "(^|exec +)(bwrap|tmux)\b|--ro-bind|--unshare|--clearenv|--tmpfs"
}

@test "vendor frontier: no functional --bare or anthropic_api_key (comments excluded)" {
  ! grep -vE "^\s*#" "$SCRIPT" | grep -iE "openai|anthropic_api_key|--bare"
}

@test "vendor frontier: the script knows only claude (N1 vendor)" {
  grep -q "claude" "$SCRIPT"
}

# =============================================================
# Standard LCARS header
# =============================================================

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SCRIPT"
  grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"
  grep -q "^# STATUS:" "$SCRIPT"
}
