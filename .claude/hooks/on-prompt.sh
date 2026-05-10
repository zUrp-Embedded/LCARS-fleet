#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: on-prompt.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: PROMPT-HOOK     | SUBSYSTEM: HOOKS / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Executed on every Claude prompt submission.              |
#     |  Updates fleet state and manages context flow.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Exécuté à chaque soumission de prompt. Met à jour l'état fleet (thinking),
#     draine l'inbox pour les agents non-wakeable, vérifie le contexte window,
#     traite les sentinels FLEET-INBOX, filtre les inputs sur les workers.
#
#     [EN]
#     NAME
#         on-prompt.sh — per-prompt fleet state update and context management
#
#     INTERFACE
#         Ring:    CC Runtime (hook — UserPromptSubmit)
#         Input:   stdin JSON (session_id, prompt), CLAUDE_AGENT_NAME, handoff
#         Output:  fleet-state.sh action=thinking, inbox drain, context check warning
#
#     EXIT CODES
#         0    Prompt processed normally
#         2    Sentinel consumed (FLEET-INBOX) or worker input blocked
#
# --- END HEADER ---

set -uo pipefail

# Debug log — traces chaque run pour diagnostiquer les hook errors intermittents
_HOOK_LOG="/tmp/on-prompt-debug-${CLAUDE_AGENT_NAME:-unknown}.log"
exec 2>>"$_HOOK_LOG"
echo "=== $(date '+%H:%M:%S') ===" >&2

trap 'echo "TRAP: exit $? at line $LINENO" >&2' ERR

# Lire le payload stdin AVANT toute autre logique
HOOK_PAYLOAD=$(cat)
SESSION_ID=$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)

INSTANCE="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || hostname)}"

# ─── Non-wakeable inbox drain (BEFORE any early exit) ────────────────────────
# Must run regardless of handoff state — architect needs messages even after shutdown.
# --- Skip inbox for headless agents (ephemeral, no persistent session) ---
_HAS_HEADLESS=$(yq ".instances[] | select(.role == \"$INSTANCE\") | .headless" \
    "${FLEET_YAML:-$HOME/.lcars/fleet/fleet.yaml}" 2>/dev/null)
# A-007 fix: headless: false is string "false", not null/empty
if [[ "$_HAS_HEADLESS" != "null" && "$_HAS_HEADLESS" != "false" && -n "$_HAS_HEADLESS" ]]; then
    : # Headless agent — skip inbox entirely
else
    _WAKEABLE=$(yq ".instances[] | select(.role == \"$INSTANCE\") | .wakeable" \
        "${FLEET_YAML:-$HOME/.lcars/fleet/fleet.yaml}" 2>/dev/null)
    [[ "$_WAKEABLE" == "null" || -z "$_WAKEABLE" ]] && _WAKEABLE="true"
    if [[ "$_WAKEABLE" == "false" ]]; then
        INBOX_READ=""
        command -v fleet-inbox-read.sh &>/dev/null && INBOX_READ="fleet-inbox-read.sh"
        [[ -z "$INBOX_READ" && -x "$HOME/.local/bin/fleet-inbox-read.sh" ]] && INBOX_READ="$HOME/.local/bin/fleet-inbox-read.sh"
        if [[ -n "$INBOX_READ" ]]; then
            INBOX_DIR="${FLEET_SPOOL_INBOX:-/var/spool/fleet/inbox}/$INSTANCE"
            if ls "$INBOX_DIR"/*.md &>/dev/null 2>&1; then
                "$INBOX_READ" "$INSTANCE"
            fi
        fi
    fi
fi

[[ -n "${FLEET_HANDOFFS:-}" ]] || { echo "[on-prompt] FLEET_HANDOFFS not set" >&2; exit 1; }
FILE="${FLEET_HANDOFFS}/${INSTANCE}-handoff.md"
[[ -f "$FILE" ]] || exit 0

CURRENT_ACTION=$(awk '/^action:/{print $2; exit}' "$FILE")
CURRENT_STATUS=$(awk '/^status:/{print $2; exit}' "$FILE")

# Ne pas écraser : états spéciaux en cours ou arrêts propres
case "$CURRENT_ACTION" in
    build|deploy|startup) exit 0 ;;
    shutdown|"forced shutdown"|handoff|crashed) exit 0 ;;
esac
case "$CURRENT_STATUS" in
    offline) exit 0 ;;
esac

# v7 #02: phase=active (session lane), activity=thinking (activity lane)
if [ -x "${HOME}/.local/bin/fleet-state.sh" ]; then
    "${HOME}/.local/bin/fleet-state.sh" phase=active activity=thinking || true
fi

# Persist session_id pour usage manuel (évite ls -t fragile)
[[ -n "${SESSION_ID:-}" ]] && printf '%s' "$SESSION_ID" > "/tmp/fleet-session-${INSTANCE}"

# Context window check — seuil soft = AUTOCOMPACT_PCT - 5 (défaut 65% pour interactif)
if [[ -n "${SESSION_ID:-}" ]]; then
    AUTOCOMPACT_PCT="${AUTOCOMPACT_PCT_OVERRIDE:-60}"
    [[ "$AUTOCOMPACT_PCT" =~ ^[0-9]+$ ]] || AUTOCOMPACT_PCT=60
    SOFT_THRESHOLD=$(( AUTOCOMPACT_PCT - 5 ))
    CTX_CHECK_BIN=""
    command -v fleet-context-check.sh &>/dev/null && CTX_CHECK_BIN="fleet-context-check.sh"
    [[ -z "$CTX_CHECK_BIN" && -x "$HOME/.local/bin/fleet-context-check.sh" ]] && CTX_CHECK_BIN="$HOME/.local/bin/fleet-context-check.sh"
    [[ -z "$CTX_CHECK_BIN" && -x "$HOME/fleet/fleet-context-check.sh" ]] && CTX_CHECK_BIN="$HOME/fleet/fleet-context-check.sh"
    [[ -n "$CTX_CHECK_BIN" ]] && "$CTX_CHECK_BIN" "$SESSION_ID" "$SOFT_THRESHOLD" 2>/dev/null || true
fi

# ─── Spool inbox — event-driven via [FLEET-INBOX] sentinel ───────────────────
# The sidecar (systemd path unit or inotifywait daemon) injects [FLEET-INBOX]
# into this pane when new messages arrive. Only drain on that sentinel.
# Polling removed — no unconditional inbox read on every prompt.
# FLEET_CONTEXT=fleet : inbox consumed (autonomous mode in fleet dashboard).
# FLEET_CONTEXT=standalone or unset : inbox ignored (interactive session).
PROMPT_TEXT=$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || true)

# Resolve inbox reader
INBOX_READ=""
command -v fleet-inbox-read.sh &>/dev/null && INBOX_READ="fleet-inbox-read.sh"
[[ -z "$INBOX_READ" && -x "$HOME/.local/bin/fleet-inbox-read.sh" ]] && INBOX_READ="$HOME/.local/bin/fleet-inbox-read.sh"

# ─── Fleet wake sentinel (FLEET::WAKE::<source>::<subject> or [FLEET-INBOX]) ──
if [[ "$PROMPT_TEXT" == FLEET::WAKE::* || "$PROMPT_TEXT" == "[FLEET-INBOX]" ]]; then
    if [[ "${FLEET_CONTEXT:-}" == "fleet" && -n "$INBOX_READ" ]]; then
        "$INBOX_READ" "$INSTANCE"
    fi
    exit 2
fi

# ─── Worker input filter — block non-fleet input on Tier 1+2 workers ─────────
# Tier 0 = interactive (no filter). Tier 1+2 in fleet context = filtered.
# Tier read from blueprint — no hardcoded role list.
_FLEET_YAML="${FLEET_YAML:-/local/LCARS/fleet/fleet.yaml}"
_TIER=""
if [[ -f "$_FLEET_YAML" ]] && command -v yq &>/dev/null; then
    _TIER="$(yq ".instances[] | select(.role == \"$INSTANCE\") | .tier" "$_FLEET_YAML" 2>/dev/null)" || _TIER=""
    [[ "$_TIER" == "null" ]] && _TIER=""
fi

if [[ "$_TIER" == "0" || -z "$_TIER" ]]; then
    :  # interactive or unknown — pass through
elif [[ "${FLEET_CONTEXT:-}" == "fleet" ]]; then
    case "$PROMPT_TEXT" in
        status|sitrep|yop|resume)
            ;;  # read-only keywords — allowed
        *)
            echo "Input direct interdit sur cette instance ($INSTANCE). Utiliser fleet-send.sh." >&2
            exit 2
            ;;
    esac
fi

exit 0
