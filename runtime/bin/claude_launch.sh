#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — INTERACTIVE claude vendor launcher, PTY-puppet (N1 vendor frontier, subscription)
# Identity env (supplied by the spawner; not subject to masking, so env is fine here, unlike the SP):
#   LCARS_POD_SESSION_ID          PRE-ALLOCATED session UUID (uuidgen, state.json at spawn) — required
#   LCARS_POD_RESUME              0 = first creation (--session-id); 1 = recovery (--resume)
#   LCARS_POD_SESSION_NAME_PREFIX Desktop-readable pod label (<project>#<ticket>_<role>, or
#                                 <project>_<role> when not ticket-bound) — required, verbatim
# Exit codes:
#   0   : success (propagated through exec)
#   1   : setup error (cap-profile/jq/claude binary missing, empty args/SP, missing session env)
#   *   : propagated claude crash

set -euo pipefail


# LCARS_CLAUDE_BIN is set by bwrap: the owning human's per-user claude, relocated into the pod. The
# PATH fallback resolves $POD_DIR/.local/bin first ⇒ NEVER the system apt build (stale, no auto-update).
CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
: "${CLAUDE_BIN:?claude binary not found (LCARS_CLAUDE_BIN set by bwrap, or the per-user ~/.local PATH)}"
JQ_BIN="${LCARS_JQ_BIN:-/usr/bin/jq}"


if [[ $# -ne 3 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
# #monde-propre Stage B: under bwrap the REAL pod_dir ($3) is relocated behind LCARS_POD_HOME
# (/home/.pod), and this script runs INSIDE the sandbox — its paths must point at the INTRA-POD home.
POD_DIR="${LCARS_POD_HOME:-$3}"
SP_FILE="$POD_DIR/.lcars/system-prompt.md"


SESSION_ID="${LCARS_POD_SESSION_ID:?session UUID required (pre-allocated by the spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"                          # 0 = first creation; 1 = recovery
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?pod label required (Fleet.Layout.pod_label)}"

# Derivation DEFERRED until CAP_PROFILE_JSON below: here we only read the host override.
PERM_ENV_OVERRIDE="${LCARS_PERMISSION_MODE:-}"
# `--settings` is ADDITIVE ⇒ `--setting-sources` must exclude 'user', or the human's settings bleed in.
SETTING_SOURCES="${LCARS_SETTING_SOURCES:-project,local}"
SETTING_SOURCES="${SETTING_SOURCES// /}"
case ",${SETTING_SOURCES}," in
  *,user,*)
    echo "claude_launch: REFUSED — LCARS_SETTING_SOURCES contains 'user' (${SETTING_SOURCES})." >&2
    echo "claude_launch: 'user' would bleed the human's settings into the pod (forbidden, fleet_spawner v2 §G)." >&2
    exit 1
    ;;
esac

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  echo "ERR: role, pod_id and pod_dir must be non-empty" >&2
  exit 1
fi
if [[ ! -s "$SP_FILE" ]]; then
  echo "ERR: SP file $SP_FILE missing or empty (written by Fleet.Spawner do_project)" >&2
  exit 1
fi


if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "ERR: claude binary missing or not executable: $CLAUDE_BIN" >&2
  exit 1
fi

if [[ ! -x "$JQ_BIN" ]]; then
  echo "ERR: jq binary missing or not executable: $JQ_BIN (parsing cap-profile JSON)" >&2
  exit 1
fi

CAP_PROFILE_JSON="$POD_DIR/.cap-profile.json"
if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi

VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -z "$VER" ]]; then
  echo "WARN: claude --version in an unexpected format — falling back to lastOnboardingVersion 2.1.150" >&2
fi
POD_CWD="${LCARS_POD_CWD:-$POD_DIR}"

SKILL_FLAGS=()
if [[ -d "$POD_CWD/.git" ]]; then
  MOUNTED_SKILLS="$(ls -1 "$POD_DIR/.claude/skills" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "${MOUNTED_SKILLS// /}" ]]; then
    echo "ERR: ce pod a un depot au cwd ($POD_CWD) ET des skills montees ($MOUNTED_SKILLS)." >&2
    echo "     --disable-slash-commands coupe TOUTES les skills, catalogue compris : il ne peut pas" >&2
    echo "     servir ce cas. Retirer les skills de ce role, ou lui retirer son workspace." >&2
    exit 1
  fi
  SKILL_FLAGS=(--disable-slash-commands)
fi
# Read HERE because it GATES remoteControlAtStartup in the .claude.json below.
# jq TRAP: `.x // true` treats `false` AND null as "empty", so `false // true` = true — the old form
# SWALLOWED an explicit remote_control:false. Defaulting on null ONLY is what preserves it.
if [[ -n "${LCARS_POD_REMOTE_CONTROL:-}" ]]; then
  REMOTE_CONTROL="$LCARS_POD_REMOTE_CONTROL"
else
  REMOTE_CONTROL=$("$JQ_BIN" -r '.spec.invocation.remote_control | if . == null then true else . end' "$CAP_PROFILE_JSON" 2>/dev/null)
fi
RC_STARTUP=$([[ "$REMOTE_CONTROL" != "false" ]] && echo true || echo false)

# `projects` is the agent's REAL cwd ($POD_CWD), not $POD_DIR — otherwise /init runs in a
# non-onboarded dir. The two officialMarketplace* keys are vendor-INTERNAL: they are an anchor to
# re-measure, not a contract — the day the CLI stops reading them the plugins come back in silence.
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "officialMarketplaceAutoInstalled": true, "officialMarketplaceAutoInstallAttempted": true,
  "remoteControlAtStartup": $RC_STARTUP, "hasUsedRemoteControl": true, "remoteDialogSeen": true,
  "projects": { "$POD_CWD": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF


ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { echo "ERR: jq allowedTools failed on $CAP_PROFILE_JSON: $ALLOWED_TOOLS" >&2; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { echo "ERR: jq disallowedTools failed on $CAP_PROFILE_JSON: $DISALLOWED_TOOLS" >&2; exit 1; }
ALLOWED_TOOLS="${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}mcp__fleet__get_work_item,mcp__fleet__submit_result"

# No validation here: N0 (LaunchSpec.permission_mode) BOUNDS the mode to the CLI enum and REFUSES a
# present-but-out-of-enum value before any launch (DR-021). The `// "default"` covers ABSENCE only.
PERM_MODE="${PERM_ENV_OVERRIDE:-$("$JQ_BIN" -r '.spec.invocation.permission_mode // "default"' "$CAP_PROFILE_JSON" 2>/dev/null)}"
[[ -z "$PERM_MODE" ]] && PERM_MODE="default"
PERM_FLAGS=(--permission-mode "$PERM_MODE")

# `--effort` enum {low,medium,high,xhigh,max}; `--model` takes an alias ('opus'/'sonnet') or a full name.
MODEL=$("$JQ_BIN" -r '.spec.invocation.model // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
EFFORT=$("$JQ_BIN" -r '.spec.invocation.effort // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
MODEL_FLAGS=();  [[ -n "$MODEL"  ]] && MODEL_FLAGS=(--model "$MODEL")
EFFORT_FLAGS=(); [[ -n "$EFFORT" ]] && EFFORT_FLAGS=(--effort "$EFFORT")

RC_FLAGS=()
[[ "$REMOTE_CONTROL" != "false" ]] &&
  RC_FLAGS=(--remote-control "$SESSION_NAME_PREFIX")

POD_SETTINGS_FILE="$POD_DIR/.lcars/settings.json"

# P1/C9: this flag is NOT enough to close the hook leak — that one came through the `project`/`local`
# tiers, which it ALLOWS. The leak is closed at the BIND (.claude pod-owned), not by this flag.
SETTINGS_FLAGS=(--setting-sources "$SETTING_SOURCES")
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  SETTINGS_FLAGS+=(--settings "$POD_SETTINGS_FILE")
fi

# NAMED `.mcp-fleet.json`, NOT `.mcp.json`, to avoid auto-discovery and its trust dialog. The
# `alwaysLoad:true` the emitter carries is what keeps the MCP tools out of ToolSearch at turn 1.
MCP_CONFIG="$POD_DIR/.mcp-fleet.json"
MCP_FLAGS=()
if [[ -f "$MCP_CONFIG" ]]; then
  MCP_FLAGS=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
else
  echo "WARN: no MCP config ($MCP_CONFIG absent) — ABNORMAL for a real pod (upstream provisioning missing)" >&2
fi

# --session-id requires a UUID — the binary checks it, never a readable name.
# The predicate is POSITIVE (at least one `user` or `assistant` record) on purpose: enumerating the
# preamble types instead would re-open the trap the day the vendor adds one.
resumable_session() {
  local id=$1 f
  f=$(find "$POD_DIR/.claude/projects" -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null)
  [[ -n "$f" ]] || return 1
  if grep -qE '"type":"(user|assistant)"' "$f"; then
    return 0
  fi
  rm -f "$f"
  return 1
}

if [[ "$POD_RESUME" == "1" ]] && resumable_session "$SESSION_ID"; then
  SESSION_FLAGS=(--resume "$SESSION_ID")
else
  SESSION_FLAGS=(--session-id "$SESSION_ID")
fi

# `--remote-control` is accepted silently though ABSENT from --help, and with no TTY the binary falls
# back to --print-like: the tmux PTY (bwrap_launch, N0) is what guarantees interactive RC mode.

# `--system-prompt-file` that SP REPLACES the vendor's, so whatever discipline the vendor carries
# goes with it. Under `--append-system-prompt-file` the vendor's stays upstream and ours is added.
SP_FLAGS=(--system-prompt-file "$SP_FILE")
if [[ "$("$JQ_BIN" -r '.metadata.name // empty' "$CAP_PROFILE_JSON" 2>/dev/null)" == "architect" ]]; then
  SP_FLAGS=(--append-system-prompt-file "$SP_FILE")
  echo "claude_launch: DEBUG EXCEPTION — architect SP in APPEND mode (the vendor SP stays upstream)" >&2
fi


exec "$CLAUDE_BIN" \
    "${RC_FLAGS[@]}" \
    "${SESSION_FLAGS[@]}" \
    "${SP_FLAGS[@]}" \
    "${PERM_FLAGS[@]}" \
    --allowedTools "$ALLOWED_TOOLS" \
    --disallowedTools "$DISALLOWED_TOOLS" \
    ${SKILL_FLAGS[@]+"${SKILL_FLAGS[@]}"} \
    "${MODEL_FLAGS[@]+"${MODEL_FLAGS[@]}"}" \
    "${EFFORT_FLAGS[@]+"${EFFORT_FLAGS[@]}"}" \
    ${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"} \
    ${MCP_FLAGS[@]+"${MCP_FLAGS[@]}"}
