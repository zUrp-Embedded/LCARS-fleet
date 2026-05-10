#!/bin/bash
# DEPLOY: instance-util
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-dispatch.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-DISPATCH  | SUBSYSTEM: DISPATCH             |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091.6            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Hybrid agent dispatcher.                                 |
#     |  If target has a live tmux pane: deposits prompt into     |
#     |  spool inbox and wakes via wake-instance.sh (async).      |
#     |  No live pane: spawns claude -p headless, captures        |
#     |  output, returns result via fleet-send.sh (sync).         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#
#     [FR]
#     Dispatcher hybride. Pane tmux active = async spool. Sinon = claude -p headless.
#
#     [EN]
#     NAME
#         fleet-dispatch.sh — dispatcher hybride (spool async ou headless sync)
#
#     SYNOPSIS
#         fleet-dispatch.sh <role> <subject> [file]
#
#     DESCRIPTION
#         Achemine une tâche vers l'agent adapté automatiquement :
#         - Pane tmux active → dépôt spool + wake-instance.sh (async)
#         - Pas de pane → claude -p headless (sync, résultat en retour)
#         Config headless lue depuis fleet.yaml (max_turns, timeout, allowed_tools).
#
#     INTERFACE
#         Ring:    3 (kernel)
#         Input:   <role> + <subject> + optional file/stdin prompt,
#                  fleet.yaml (headless config: max_turns, timeout, allowed_tools)
#         Output:  async: message in spool + wake signal
#                  sync: headless result on stdout + fleet-send.sh to caller
#         JSON:    non (planned: --output-format json v7)
#
#     OPTIONS
#         <role>       Rôle cible (doit exister dans fleet.yaml)
#         <subject>    Sujet de la tâche
#         [file]       Fichier prompt (stdin si absent)
#
#     EXIT CODES
#         0    Dispatch réussi (message déposé ou réponse headless reçue)
#         1    Rôle introuvable ou pas de prompt
#
#     EXAMPLES
#         fleet-dispatch.sh qualifier "Validate PR #42" procedure.md
#         echo "Review this" | fleet-dispatch.sh reviewer "Code review"
#         fleet-dispatch.sh reviewer "Plan audit" plan.md
#
#     SEE ALSO
#         fleet-send.sh, wake-instance.sh, fleet.yaml
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

# --- Args ---
OPT_MAX_TURNS=""
OPT_TIMEOUT=""
OPT_HEADLESS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-turns) OPT_MAX_TURNS="$2"; shift 2 ;;
        --timeout)   OPT_TIMEOUT="$2"; shift 2 ;;
        --headless)  OPT_HEADLESS="1"; shift ;;
        --)          shift; break ;;
        *)           break ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "usage: fleet-dispatch.sh [--headless] [--max-turns N] [--timeout N] <role> <subject> [file]" >&2
    exit 1
fi

role="$1"
subject="$2"
prompt_file="${3:-}"

# --- Validate role format (prevent yq injection) ---
if [[ ! "$role" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "ERROR: invalid role format '$role' — must be lowercase alphanumeric" >&2
    exit 1
fi

# --- Validate role exists in fleet.yaml ---
role_check=$(fleet_role_field "$role" "role")
if [[ -z "$role_check" || "$role_check" == "null" ]]; then
    echo "ERROR: role '$role' not found in fleet.yaml" >&2
    exit 1
fi

# --- JUPITER-004: caller→target ACL ---
# Resolve caller identity from Linux UID (not FLEET_INSTANCE — env var is spoofable).
# Only tier 0 (starfleet) and tier 1 (engineer) may dispatch.
# Tier 0 can dispatch to any role. Tier 1 can dispatch to tier 2 only.
_caller_uid_user="$(whoami)"
_caller_role=""
while IFS= read -r _r; do
    _lu=$(fleet_role_field "$_r" "linux_user")
    [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$_r"
    if [[ "$_lu" == "$_caller_uid_user" ]]; then
        _caller_role="$_r"
        break
    fi
done < <(fleet_roles)
if [[ -z "$_caller_role" ]]; then
    echo "ERROR: caller '$_caller_uid_user' is not a fleet role — dispatch denied" >&2
    exit 1
fi
_caller_tier=$(fleet_role_field "$_caller_role" "tier")
_target_tier=$(fleet_role_field "$role" "tier")
if [[ "$_caller_tier" != "0" && "$_caller_tier" != "1" ]]; then
    echo "ERROR: caller '$_caller_role' (tier $_caller_tier) is not authorized to dispatch — only tier 0-1" >&2
    exit 1
fi
# Tier 1 can only dispatch to tier 2 (not to tier 0 or other tier 1)
if [[ "$_caller_tier" == "1" && "$_target_tier" != "2" ]]; then
    echo "ERROR: caller '$_caller_role' (tier 1) cannot dispatch to '$role' (tier $_target_tier) — tier 1 dispatches to tier 2 only" >&2
    exit 1
fi

# --- Resolve linux user (fallback: role name) ---
target_user=$(fleet_role_field "$role" "linux_user")
if [[ -z "$target_user" || "$target_user" == "null" ]]; then
    target_user="$role"
fi

# --- Verify linux user exists ---
if ! id "$target_user" &>/dev/null; then
    echo "ERROR: linux user '$target_user' does not exist" >&2
    exit 1
fi

# --- Read prompt ---
if [[ -n "$prompt_file" ]]; then
    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: prompt file '$prompt_file' not found" >&2
        exit 1
    fi
    prompt=$(cat "$prompt_file")
elif [[ ! -t 0 ]]; then
    prompt=$(cat)
else
    echo "ERROR: no prompt provided (file or stdin required)" >&2
    exit 1
fi

# --- Hybrid routing: tmux pane check (fleet_find_pane from fleet-env.sh) ---
# --headless flag skips pane lookup → force headless path
pane_id=""
if [[ -z "$OPT_HEADLESS" ]]; then
    pane_id=$(fleet_find_pane "$role")
fi

if [[ -n "$pane_id" ]]; then
    # Tmux path — target is interactive. Drop prompt into inbox and wake.
    tmp_prompt=$(mktemp /tmp/fleet-dispatch-prompt-XXXXXX)
    printf '%s' "$prompt" > "$tmp_prompt"
    "$(dirname "${BASH_SOURCE[0]}")/fleet-send.sh" \
        --type "task" --ref "$subject" \
        "$role" "$subject" "$tmp_prompt"
    rm -f "$tmp_prompt"
    echo "dispatch: tmux path — pane $pane_id woken for role '$role'" >&2
    log_file="$HOME/.local/log/dispatch-${role}-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$(dirname "$log_file")"
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] role=$role subject=$subject mode=tmux pane=$pane_id OK" >> "$log_file"
    exit 0
fi

# --- Read headless params from fleet.yaml (with fallbacks), CLI overrides win ---
max_turns=$(_yq ".instances[] | select(.role == \"$role\") | .headless.max_turns // 20")
timeout_sec=$(_yq ".instances[] | select(.role == \"$role\") | .headless.timeout // 300")
allowed_tools=$(_yq ".instances[] | select(.role == \"$role\") | .headless.allowed_tools // \"Read,Grep,Glob,Bash,Agent\"")

# Strip yq null returns
[[ "$max_turns" == "null" ]] && max_turns=20
[[ "$timeout_sec" == "null" ]] && timeout_sec=300
[[ "$allowed_tools" == "null" ]] && allowed_tools="Read,Grep,Glob,Bash,Agent"

# CLI overrides (from caller like fleet-plan.sh)
[[ -n "$OPT_MAX_TURNS" ]] && max_turns="$OPT_MAX_TURNS"
[[ -n "$OPT_TIMEOUT" ]] && timeout_sec="$OPT_TIMEOUT"

# --- Prepare log ---
log_file="$HOME/.local/log/dispatch-${role}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$log_file")"

# --- Prepare temp files ---
result_file=$(mktemp /tmp/fleet-dispatch-result-XXXXXX)
_tmp_prompt=$(mktemp /tmp/fleet-dispatch-prompt-XXXXXX)
# A-004 fix: cleanup on ALL exits (timeout, error, success)
trap 'rm -f "$result_file" "$_tmp_prompt" "$PID_FILE"' EXIT
printf '%s' "$prompt" > "$_tmp_prompt"

# --- Dispatch ---
# F-C1 FIX: reuse _caller_role resolved at ACL check (lines 126-134), not raw whoami
caller_role="$_caller_role"
start_time=$SECONDS
exit_code=0
PID_DIR="${FLEET_STATE_DIR:-/home/fleet-state}/run/fleet-headless"
mkdir -p "$PID_DIR"
PID_FILE="$PID_DIR/${role}-$(date +%Y%m%d-%H%M%S).pid"

# --- Refresh credentials: caller (active session) → target (headless) ---
# OAuth tokens expire after 1h. The caller has a live session with fresh tokens.
# Copy before each dispatch — no daemon, no cron, deterministic.
_caller_creds="$HOME/.claude/.credentials.json"
_target_creds="/home/$target_user/.claude/.credentials.json"
if [ -f "$_caller_creds" ]; then
    sudo cp "$_caller_creds" "$_target_creds"
    sudo chown "$target_user:$(id -gn "$target_user")" "$_target_creds"
    sudo chmod 640 "$_target_creds"
fi

# Redirects intentionally owned by caller, not sudo target
# shellcheck disable=SC2024
# C2-FIX: no -i (avoids needing /bin/bash in sudoers whitelist)
# HOME set explicitly so claude finds ~/.claude/
# --bare removed: incompatible with OAuth (Max subscription).
# Individual controls replace --bare's blanket disable.
sudo -u "$target_user" \
    env HOME="/home/$target_user" \
        CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
        CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
        CLAUDE_CODE_DISABLE_CRON=1 \
        CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
        CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 \
        PATH="/usr/local/bin:/usr/bin:/bin" \
    timeout "$timeout_sec" \
    claude -p \
    --disable-slash-commands \
    --no-session-persistence \
    --tools "$allowed_tools" \
    --max-turns "$max_turns" \
    --output-format text \
    --system-prompt-file "/home/$target_user/.claude/system-prompt.md" \
    2>>"$log_file" < "$_tmp_prompt" > "$result_file" &
HEADLESS_PID=$!
echo "$HEADLESS_PID" > "$PID_FILE"
wait "$HEADLESS_PID" || exit_code=$?
result=$(cat "$result_file")

duration=$(( SECONDS - start_time ))
rm -f "$PID_FILE"

# Timeout: caller can retry (fleet-plan.sh handles via || exit_code).
# No automatic retry here — dispatch is a primitive, retry is policy.
if [[ $exit_code -eq 124 ]]; then
    echo "ERROR: dispatch to '$role' timed out after ${timeout_sec}s" >&2
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] role=$role subject=$subject exit=124 duration=${duration}s TIMEOUT" >> "$log_file"
    exit 124
fi

if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: claude exited with code $exit_code for role '$role'" >&2
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] role=$role subject=$subject exit=$exit_code duration=${duration}s ERROR" >> "$log_file"
    exit 1
fi

# --- Write result and send via fleet-send.sh ---
printf '%s' "$result" > "$result_file"
# Only send result via IPC if caller has a persistent session
_CALLER_HEADLESS=$(yq ".instances[] | select(.role == \"$caller_role\") | .headless" "$FLEET_YAML" 2>/dev/null)
# A-007 fix: headless: false is string "false", not null/empty — treat as interactive
if [[ "$_CALLER_HEADLESS" == "null" || "$_CALLER_HEADLESS" == "false" || -z "$_CALLER_HEADLESS" ]]; then
    if ! "$(dirname "${BASH_SOURCE[0]}")/fleet-send.sh" "$caller_role" "$subject" "$result_file" >/dev/null 2>&1; then
        echo "WARN: [fleet-dispatch] IPC send to $caller_role failed — result on stdout only" >&2
    fi
fi

# --- Output result on stdout for synchronous callers ---
printf '%s\n' "$result"

# --- Cleanup handled by EXIT trap ---

# --- Log ---
echo "[$(date +%Y-%m-%dT%H:%M:%S)] role=$role subject=$subject mode=headless exit=$exit_code duration=${duration}s OK" >> "$log_file"

exit 0
