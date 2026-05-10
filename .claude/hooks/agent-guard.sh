#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: agent-guard.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: AGENT-GUARD       | SUBSYSTEM: HOOKS / PRETOOLUSE |
#     | LICENSE: AGPL-3           | STARDATE: 2026.087            |
#     +---------------------------+---------------------------------+
#     |                                                           |
#     |  PreToolUse hook — blocks Agent tool forks and subagents  |
#     |  that bypass fleet discipline. Allows Explore and Plan.   |
#     |  Implementation tasks must use fleet-dispatch.sh.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     agent-guard.sh — bloque les forks Agent tool et les subagents
#     qui contournent la discipline fleet. Autorise Explore et Plan
#     (read-only). Les tâches d'implémentation passent par fleet-dispatch.sh.
#
#     [EN]
#     NAME
#         agent-guard.sh — block Agent tool forks that bypass fleet discipline
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PreToolUse, matcher: Agent)
#         Input:   stdin JSON (tool_name, tool_input with subagent_type)
#         Output:  JSON decision: allow (Explore/Plan) or block (others)
#
#     EXIT CODES
#         0    Decision emitted (allow or block)
#
# --- END HEADER ---

set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

[[ "$TOOL" != "Agent" ]] && exit 0

SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty')

case "$SUBAGENT" in
    Explore|Plan)
        # Read-only specialized agents — allowed
        exit 0
        ;;
    "")
        # Fork (no subagent_type) — bypasses fleet SP, scope, hooks
        printf '{"decision":"block","reason":"Fork agents bypass fleet discipline (no SP, no scope check, no hooks). Use fleet-dispatch.sh --headless <role> for implementation tasks, or subagent_type=Explore for read-only exploration."}\n'
        exit 0
        ;;
    *)
        # Named subagent matching fleet role — must go through fleet-dispatch.sh
        printf '{"decision":"block","reason":"Fleet role '\''%s'\'' must be dispatched via fleet-dispatch.sh, not Agent tool. Run: fleet-dispatch.sh [--headless] %s <subject> [file]"}\n' "$SUBAGENT" "$SUBAGENT"
        exit 0
        ;;
esac
