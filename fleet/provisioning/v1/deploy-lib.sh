#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-lib.sh
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
#     | MODULE: DEPLOY-LIB      | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Shared functions for deploy.sh sub-scripts.              |
#     |  sync_tree, fleet_cp, register_hook, colors. Sourced, never called.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: deploy-lib.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     deploy-lib.sh — Shared functions for deploy.sh sub-scripts.
#     sync_tree, fleet_cp, register_hook, colors. Sourced, never called.
#
#
# --- END HEADER ---



# Shared library for deploy.sh sub-scripts.
# Sourced by deploy.sh orchestrator — never called directly.
# Provides: functions, colors, counters, paths.

# --- File operations ---
umask 002
fleet_cp() { install -m 664 "$1" "$2"; }
fleet_cp_exec() { install -m 775 "$1" "$2"; }
deployed() { TOTAL_COPIED=$((TOTAL_COPIED + 1)); }

# sync_tree <src> <dst> [exec] [exclude_regex]
sync_tree() {
    local src="$1" dst="$2" mode="${3:-}" exclude="${4:-}"
    local cp_func="fleet_cp"
    [[ "$mode" == "exec" ]] && cp_func="fleet_cp_exec"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$dst"
    while IFS= read -r -d '' FILE; do
        REL="${FILE#"$src"/}"
        [[ -n "$exclude" ]] && [[ "$REL" =~ $exclude ]] && continue
        DST_FILE="$dst/$REL"
        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p "$(dirname "$DST_FILE")"
            if ! cmp -s "$FILE" "$DST_FILE" 2>/dev/null; then
                $cp_func "$FILE" "$DST_FILE"
                deployed
            fi
        else
            if ! cmp -s "$FILE" "$DST_FILE" 2>/dev/null; then
                echo "  $_dryrun copierait $REL"
            fi
        fi
    done < <(find "$src" -type f -print0)
}

# register_hook <settings.local.json> <hook_key> <matcher> <command>
register_hook() {
    local settings="$1" hook_key="$2" matcher="$3" cmd="$4"
    [ -f "$settings" ] || { echo "  $_SKIP — absent] $settings"; return 0; }
    if [ "$DRY_RUN" -eq 0 ]; then
        python3 "$PATCH_JSON" register-hook "$settings" "$hook_key" "$matcher" "$cmd"
    else
        echo "  $_dryrun patcherait $settings — $hook_key"
    fi
}

# --- Colors ---
_G=$'\033[1;32m'; _Y=$'\033[1;33m'; _R=$'\033[1;31m'; _C=$'\033[0;36m'; _N=$'\033[0m'
_ok="${_G}[ok]${_N}"; _OK="${_G}[OK]${_N}"; _SKIP="${_Y}[SKIP]${_N}"; _FAIL="${_R}[FAIL]${_N}"
_WARN="${_Y}[WARN]${_N}"; _patched="${_C}[patché]${_N}"; _migrated="${_C}[migré]${_N}"
_present="${_G}[déjà présent]${_N}"; _symlink="${_C}[symlink]${_N}"; _created="${_G}[created]${_N}"
_dryrun="${_Y}[dry-run]${_N}"
