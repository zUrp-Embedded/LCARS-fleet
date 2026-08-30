#!/usr/bin/env bats
# SOURCE: fleet/test/bin/claude_launch.bats
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
  [[ "$output" == *"pod label required"* ]]
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
# No trace in the pod — user arbitration 2026-08-15.
#
# This launcher runs INSIDE bwrap: every path it can write is a path the confined agent can read.
# A boot trace therefore handed the agent the recipe of its own box (permission mode and flags,
# model, effort, setting-sources, the vendor surface that was cut, whether creds are present).
# Redacting it field by field was tried and is the wrong shape — one forgotten field re-opens it
# silently. The witness is written on the DIRECTORY, not on a filename: a trace under a new name
# is the same defect, and asserting `! -f claude_launch.dbg` would miss it.
# =============================================================

@test "no trace: a full run leaves NO new readable file in the pod home" {
  local before after
  before="$(find "$POD_DIR" -maxdepth 1 -type f | sort)"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  after="$(find "$POD_DIR" -maxdepth 1 -type f | sort)"
  # .claude.json is provisioned by design (onboarding/trust skip, documented at its site).
  [[ "$(comm -13 <(echo "$before") <(echo "$after") | grep -v '/\.claude\.json$' || true)" == "" ]]
}

@test "no trace: the launcher source carries no writer into POD_DIR" {
  # Belt to the braces above: the run-time witness only sees what a stubbed run produces, and the
  # exposing lines sat on paths a stub never reaches (jq failures, MCP absent, version fallback).
  ! grep -qE '>>?[[:space:]]*"?\$\{?POD_DIR' "$SCRIPT"
  ! grep -q 'claude_launch\.dbg' "$SCRIPT"
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

# Rewrites the fixture profile with an explicit spec.invocation.remote_control. The setup fixture
# declares none on purpose (that is the "says nothing" case), so a test that needs a DECLARED value
# has to write one — the role name argument is the RC label, it selects no profile.
declare_remote_control() {
  cat > "$POD_DIR/.cap-profile.json" <<EOF
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "engineer"},
  "spec": {
    "invocation": {"remote_control": $1},
    "scope": {
      "allowedTools": ["Read", "Glob", "Grep"],
      "disallowedTools": ["web_search", "tool_search_internal"]
    }
  }
}
EOF
}

# --- Desktop visibility: the runtime decides, this script obeys ---
# Visibility used to be derived TWICE — here from the profile, and in Elixir for the slot capture
# and the slot resume. Two derivations of one fact agree until something tries to change it: the
# half not reached then yields a pod visible in Desktop whose slot is never captured nor resumed.

@test "RC: LCARS_POD_REMOTE_CONTROL=false hides the pod even though its profile says nothing" {
  # `engineer` declares no `remote_control`, so the standalone derivation says visible. The env
  # says otherwise and WINS — that is what "the runtime decides" has to mean to be worth anything.
  LCARS_POD_REMOTE_CONTROL=false run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"--remote-control"* ]]
  run cat "$POD_DIR/.claude.json"
  [[ "$output" == *'"remoteControlAtStartup": false'* ]]
}

@test "RC: LCARS_POD_REMOTE_CONTROL=true shows a pod its profile declares invisible" {
  # The symmetric direction, and the one a widening will use. The profile declares
  # `remote_control: false`; the env opens it, and BOTH levers must follow — a flag without
  # remoteControlAtStartup (or the reverse) is the half-applied state this pins against.
  declare_remote_control false
  LCARS_POD_REMOTE_CONTROL=true run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--remote-control"* ]]
  run cat "$POD_DIR/.claude.json"
  [[ "$output" == *'"remoteControlAtStartup": true'* ]]
}

@test "RC: no env → the profile read stands (standalone fallback, invoked by hand)" {
  # This script is the N1 vendor frontier and runs without a runtime around it. The fallback is the
  # NARROWER answer by construction (the declaration is the floor), so an absent env is a missing
  # widening, never a wrongly-opened door.
  declare_remote_control false
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"--remote-control"* ]]
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

@test "the marketplace auto-install is gated in .claude.json — where it actually bites" {
  # Every spawn cloned Anthropic's plugin marketplace from GitHub to install zero plugin: 7.2 MB
  # and a network fetch at boot, inside a sandbox whose whole point is a projected world. The
  # settings file declared `extensions.marketplace.autoInstall: false` and it did NOTHING —
  # measured on a bench 2026-08-09 (CLI 2.1.221), both directions: two pods with that key had
  # plugins/ at 7.2 MB, a pod with these two config keys had no plugins/ at all.
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  run cat "$POD_DIR/.claude.json"
  [[ "$output" == *'"officialMarketplaceAutoInstalled": true'* ]]
  [[ "$output" == *'"officialMarketplaceAutoInstallAttempted": true'* ]]
}

@test "flags: first creation → --session-id <UUID> (not --resume)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "flags: recovery (LCARS_POD_RESUME=1) on a REAL transcript → --resume <UUID> (not --session-id)" {
  export LCARS_POD_RESUME=1
  mkdir -p "$POD_DIR/.claude/projects/-home--pod"
  cat > "$POD_DIR/.claude/projects/-home--pod/test-session-uuid.jsonl" <<'EOF'
{"type":"mode","mode":"normal","sessionId":"test-session-uuid"}
{"type":"user","message":{"role":"user","content":"engage"},"sessionId":"test-session-uuid"}
{"type":"assistant","message":{"role":"assistant","content":"ok"},"sessionId":"test-session-uuid"}
EOF
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--resume test-session-uuid"* ]]
  [[ "$output" != *"--session-id"* ]]
}

@test "flags: recovery with NO transcript at all → --session-id, never --resume into the void" {
  export LCARS_POD_RESUME=1
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "flags: recovery on a STUB transcript (no conversation turn) → --session-id, and the stub is REMOVED" {
  # The trap measured 2026-08-11: a pod dies at its first start and leaves a transcript holding only
  # `mode`/`permission-mode`/`bridge-session`. `--resume` on it is fatal ("No conversation found with
  # session ID") and every retry dies the same way, so the fleet re-briefs a corpse forever and the
  # ORIGINAL cause is gone. A transcript with no turn is not a session — start fresh, and take the
  # stub with us so the fallback does not depend on how the vendor reacts to a pre-existing file.
  export LCARS_POD_RESUME=1
  STUB="$POD_DIR/.claude/projects/-home--pod/test-session-uuid.jsonl"
  mkdir -p "$(dirname "$STUB")"
  cat > "$STUB" <<'EOF'
{"type":"mode","mode":"normal","sessionId":"test-session-uuid"}
{"type":"permission-mode","permissionMode":"default","sessionId":"test-session-uuid"}
{"type":"bridge-session","sessionId":"test-session-uuid","bridgeSessionId":"cse_01","lastSequenceNum":0}
EOF
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
  [[ ! -f "$STUB" ]]
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

# =============================================================
# DEBUG EXCEPTION — A/B ON THE ARCHITECT'S SP — POSTED 2026-08-21 — LEAVES WITH IT
#
# These two witnesses do not defend a contract, they stop an EMPTY TRIAL: an A/B whose two arms
# pass the same flag measures nothing, and its conclusion — whatever it is — would be noise taken
# for a result. The measured block lives in `claude_launch.sh`, just above the `exec`; when it
# goes, these two tests go with it.
# =============================================================

@test "DEBUG A/B: the architect gets --append-system-prompt-file (vendor SP stays upstream)" {
  # ⚠ THE ARM IS CHOSEN ON THE CAP-PROFILE'S `metadata.name`, not on the positional — so it is the
  # PROFILE we flip here, and the positional stays `engineer` to prove exactly that.
  cat > "$POD_DIR/.cap-profile.json" <<'EOF'
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "architect"},
  "spec": {"scope": {"allowedTools": ["Read"], "disallowedTools": ["web_search"]}}
}
EOF
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--append-system-prompt-file $POD_DIR/.lcars/system-prompt.md"* ]]

  # THE TWO ARMS ARE EXCLUSIVE. Passing both flags would let the vendor arbitrate an order we did
  # not choose, and the trial would no longer say which one it measured.
  [[ "$output" != *" --system-prompt-file "* ]]

  # The SP still does not leak into the argv — the exception changes the flag, never the doctrine.
  [[ "$output" != *"Engineer test SP"* ]]
}

@test "DEBUG A/B: every other role keeps --system-prompt-file — the exception does not spread" {
  # The half that counts. An exception biting on the other roles would not be an A/B, it would be a
  # fleet-wide behaviour change posted without being named.
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--system-prompt-file $POD_DIR/.lcars/system-prompt.md"* ]]
  [[ "$output" != *"--append-system-prompt-file"* ]]
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

@test "flags: --settings points at .lcars/settings.json when the PROJECTION wrote it" {
  # BL-6-07: the launcher composes nothing — the file comes from the projection tier
  # (Assets.pod_settings_json/1). Present → passed through as flagSettings.
  mkdir -p "$POD_DIR/.lcars"
  echo '{"autoMemoryEnabled":false}' > "$POD_DIR/.lcars/settings.json"
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
# Pod settings (.lcars/settings.json): CONSUMED, never composed (BL-6-07). The file is written
# COMPLETE by the projection tier (Assets.pod_settings_json/1 — autoMemory off for every mode,
# skip-dialog reserved to bypassPermissions; the POLICY tests live Elixir-side with the owner).
# The launcher's whole contract: file present → --settings pass-through; file absent → no flag
# and NO write. The old in-launcher jq merge was a second composer with a second policy over
# one file — and the two disagreed on the skip-dialog.
# =============================================================

@test "settings: the launcher COMPOSES NOTHING — absent file, no flag, no write" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ ! -f "$POD_DIR/.lcars/settings.json" ]]
  [[ "$output" != *"--settings "* ]]
}

@test "settings: a projected file passes through BYTE-IDENTICAL (no merge, no fleet key added)" {
  mkdir -p "$POD_DIR/.lcars"
  echo '{"hooks":{"PreToolUse":[]}}' > "$POD_DIR/.lcars/settings.json"
  before="$(cat "$POD_DIR/.lcars/settings.json")"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$POD_DIR/.lcars/settings.json")" == "$before" ]]
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "settings: PERM_MODE=bypassPermissions still writes NOTHING (the policy owner is Elixir)" {
  # The --permission-mode flag passes; the skip-dialog provisioning is the projection tier's
  # (Assets.pod_settings_json/1, tested with the owner) — the launcher stays a pure executor.
  export LCARS_PERMISSION_MODE=bypassPermissions
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
  [[ ! -f "$POD_DIR/.lcars/settings.json" ]]
}

@test "settings: cap-profile bypassPermissions flows to --permission-mode, still ZERO settings write (BL-6-07)" {
  # The PROD channel for the mode stays the cap-profile JSON (bwrap --clearenv strips the env,
  # so the JSON IS the mode's channel) — but the skip-dialog PROVISIONING moved to the policy
  # owner (Assets.pod_settings_json/1, projection tier, tested Elixir-side). The launcher reads
  # the mode for the FLAG only and composes nothing.
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
  [[ ! -f "$POD_DIR/.lcars/settings.json" ]]
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

# =============================================================
# Surface vendor — `/init` et les skills sont DANS LE BINAIRE, pas dans un montage
# =============================================================
#
# Mesure du 2026-08-12 : `~/.local` ne porte que `bin/claude`, et le prompt de `/init` est compile
# dans l'executable. Le mecanisme qui borne tout le reste ici — les droits vivent dans le montage —
# ne peut structurellement pas l'atteindre ; le seul levier est `--disable-slash-commands`.
#
# Le predicat teste est « ce pod a un depot sous la main », PAS « il ne declare aucune skill ». Les
# deux coincident aujourd'hui (9 roles canon sur 10 ont `skills: []`, et le seul qui en declare une
# n'entre dans aucun projet), mais coincider n'est pas causer : equiper un producteur d'une skill de
# catalogue est legitime et rouvrirait `/init` sur le role le plus dangereux, en silence.

@test "vendor: un pod SANS depot au cwd garde sa surface (starfleet, l'arch)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"--disable-slash-commands"* ]]
}

@test "vendor: un depot au cwd coupe la surface — c'est la ou /init ferait des degats" {
  mkdir -p "$POD_DIR/workspace/.git"
  export LCARS_POD_CWD="$POD_DIR/workspace"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--disable-slash-commands"* ]]
}

@test "vendor: un cwd SANS .git ne coupe rien, meme si LCARS_POD_CWD est pose" {
  # Le cas de l'arch : son cwd est son propre pod_dir remonte sous le nom du projet, il n'y a
  # aucun depot dedans. `LCARS_POD_CWD` pose ne prouve donc pas qu'un depot est la.
  mkdir -p "$POD_DIR/chifoumi"
  export LCARS_POD_CWD="$POD_DIR/chifoumi"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"--disable-slash-commands"* ]]
}

@test "vendor: depot ET skill montee = REFUS loud (le flag coupe tout, il ne sert pas ce cas)" {
  mkdir -p "$POD_DIR/workspace/.git" "$POD_DIR/.claude/skills/card-revision"
  export LCARS_POD_CWD="$POD_DIR/workspace"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"card-revision"* ]]
  [[ "$output" == *"coupe TOUTES les skills"* ]]
}
