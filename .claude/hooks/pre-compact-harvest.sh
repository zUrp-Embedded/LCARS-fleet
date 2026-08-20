#!/usr/bin/env bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: pre-compact-harvest.sh
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
#     | MODULE: PRE-COMPACT       | SUBSYSTEM: HOOKS / PRECOMPACT |
#     | LICENSE: AGPL-3           | STARDATE: 2026.090            |
#     +---------------------------+-------------------------------+
#     |                                                           |
#     |  PreCompact hook: mechanical harvest before auto-compact. |
#     |  Captures git state for all projects into handoff DONE.   |
#     |  Budget: <5s, read-only except handoff append.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     pre-compact-harvest.sh — snapshot mecanique avant auto-compact.
#     Capture l'etat git de tous les projets, append dans le handoff DONE
#     via fleet-done.sh. Garanti <5s, aucun side effect lourd.
#
#     [EN]
#     NAME
#         pre-compact-harvest.sh — mechanical snapshot before auto-compact
#
#     SYNOPSIS
#         pre-compact-harvest.sh
#         (called automatically by Claude Code PreCompact hook)
#
#     DESCRIPTION
#         Triggered before context compaction (auto or manual). Collects
#         git state (branch, last 5 commits, diff stat, uncommitted files)
#         for every project in /home/projects/. Appends the snapshot to
#         the instance handoff via fleet-done.sh.
#
#         This ensures that even if compaction loses context, the handoff
#         retains a mechanical record of what was in-flight.
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PreCompact, matcher: "auto"|"manual")
#         Input:   stdin JSON (ignored — no useful data in PreCompact)
#         Output:  none (side effect: handoff append)
#         Env:     CLAUDE_AGENT_NAME (instance identity)
#
#     DEPENDENCIES
#         git, fleet-done.sh
#
#     EXIT CODES
#         0    Always (hook must not block compaction)
#
#     SEE ALSO
#         fleet-done.sh(1), fleet-state.sh(1)
#         harvest-emergency skill (manual trigger for low context)
#
# --- END HEADER ---

set -euo pipefail

# ── Dependency check ──────────────────────────────────────────────────────────
command -v git &>/dev/null || exit 0

# ── Constants ───────────────────────────────────────────────────────────────────
INSTANCE="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || echo "unknown")}"
readonly INSTANCE
readonly PROJECTS_DIR="${FLEET_PROJECTS_DIR:-/home/projects}"
readonly SNIPPET="/tmp/fleet-harvest-${INSTANCE}.md"

# ── Collect git state for all projects ──────────────────────────────────────────
collect_git_state() {
    local proj name branch log_lines diff_stat uncommitted

    for proj in "${PROJECTS_DIR}"/*/; do
        [[ -d "${proj}.git" ]] || continue

        name=$(basename "$proj")
        branch=$(git -C "$proj" branch --show-current 2>/dev/null || true)
        [[ -z "$branch" ]] && branch="detached"
        log_lines=$(git -C "$proj" log --oneline -5 2>/dev/null || echo "(empty)")
        diff_stat=$(git -C "$proj" diff --stat HEAD 2>/dev/null || echo "(clean)")
        uncommitted=$(git -C "$proj" status --short 2>/dev/null || echo "")

        # shellcheck disable=SC2016
        # Backticks are literal markdown fences, not expressions
        printf '### %s (%s)\n```\n%s\n```\n%s\n' "$name" "$branch" "$log_lines" "$diff_stat"
        if [[ -n "$uncommitted" ]]; then
            printf 'Uncommitted:\n%s\n' "$uncommitted"
        fi
        printf '\n'
    done
}

# ── Build snapshot ──────────────────────────────────────────────────────────────
{
    printf 'Auto-harvest (pre-compact) — %s\n\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '## Git state\n'
    collect_git_state
} > "$SNIPPET"

# ── Append to handoff DONE ──────────────────────────────────────────────────────
if command -v fleet-done.sh &>/dev/null; then
    BODY=$(cat "$SNIPPET")
    fleet-done.sh "Auto-harvest (pre-compact)" "$BODY" 2>/dev/null || true
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────────
rm -f "$SNIPPET"

exit 0
