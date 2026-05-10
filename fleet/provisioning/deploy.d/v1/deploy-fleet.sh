#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-fleet.sh
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
#     | MODULE: DEPLOY-FLEET    | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploy fleet/ to agent homes + instance-utils to ~/.local/bin/.|
#     |  Sourced by deploy.sh. Auto-discovers scripts via DEPLOY marker.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Déploie fleet/ vers les homes agents + instance-utils vers ~/.local/bin/.
#     Auto-découvre les scripts à déployer via le marqueur DEPLOY dans les headers.
#
#     [EN]
#     NAME
#         deploy-fleet.sh — deploy fleet scripts to agent homes and ~/.local/bin/
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   $FLEET_SRC (fleet/ directory), DEPLOY markers in script headers
#         Output:  scripts in $HOMES_ROOT/<role>/fleet/, symlinks in ~/.local/bin/
#
#     EXIT CODES
#         N/A (sourced by deploy.sh)
#
# --- END HEADER ---

if [ ! -d "$FLEET_SRC" ]; then
    echo "  $_WARN fleet/ source not found at $FLEET_SRC"
    return 0 2>/dev/null || exit 0
fi

# --- fleet/ → ~/fleet/ for all instances ---
FLEET_TARGETS=()
while IFS= read -r _role; do
    FLEET_TARGETS+=("$HOMES_ROOT/$_role")
done < <(fleet_roles)

for FLEET_TARGET_HOME in "${FLEET_TARGETS[@]}"; do
    [ -d "$FLEET_TARGET_HOME" ] || continue
    FLEET_TARGET_LABEL="${FLEET_TARGET_HOME##*/}"
    echo ""
    echo "=== fleet/ → ${FLEET_TARGET_LABEL} ==="
    sync_tree "$FLEET_SRC" "$FLEET_TARGET_HOME/fleet" "exec" "tmux\.conf|__pycache__|\.pyc$|build-scripts"
done

# --- Instance utils → ~/.local/bin/ ---
mapfile -t INSTANCE_UTILS < <(find "$FLEET_SRC" -maxdepth 1 -name '*.sh' -exec grep -l '# DEPLOY: instance-util' {} \; 2>/dev/null | xargs -I{} basename {} | sort -u)
INSTANCE_HOMES=()
while IFS= read -r _role; do
    INSTANCE_HOMES+=("$HOMES_ROOT/$_role")
done < <(fleet_roles)
echo ""
echo "=== instance-utils → ~/.local/bin/ (${#INSTANCE_UTILS[@]} scripts) ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    [[ -d "$IHOME" ]] || continue  # Home not provisioned — skip silently
    UTILS_DST="$IHOME/.local/bin"
    [[ -d "$UTILS_DST" && -w "$UTILS_DST" ]] || { echo "  $_SKIP — .local/bin not provisioned] $IHOME (run provision-user.sh first)"; continue; }
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$UTILS_DST"
    for UTIL in "${INSTANCE_UTILS[@]}"; do
        SRC="$FLEET_SRC/$UTIL"
        [[ -f "$SRC" ]] || continue
        DST_FILE="$UTILS_DST/$UTIL"
        if [ "$DRY_RUN" -eq 0 ]; then
            if ! cmp -s "$SRC" "$DST_FILE" 2>/dev/null; then
                fleet_cp_exec "$SRC" "$DST_FILE"
                deployed
            fi
        else
            if ! cmp -s "$SRC" "$DST_FILE" 2>/dev/null; then
                echo "  $_dryrun copierait $(basename "$IHOME")/.local/bin/$UTIL"
            fi
        fi
    done
done

# Export INSTANCE_HOMES for deploy-bashrc.sh
export _DEPLOY_INSTANCE_HOMES="${INSTANCE_HOMES[*]}"
