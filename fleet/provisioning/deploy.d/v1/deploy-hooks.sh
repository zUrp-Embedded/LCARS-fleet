#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-hooks.sh
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
#     | MODULE: DEPLOY-HOOKS    | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploy protocol + wire hooks into settings.local.json.   |
#     |  Sourced by deploy.sh. Reads hooks.yaml manifest.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Déploie le protocole et câble les hooks dans settings.local.json.
#     Lit le manifeste hooks.yaml pour déterminer quels hooks câbler par agent.
#
#     [EN]
#     NAME
#         deploy-hooks.sh — deploy protocol and wire hooks into settings.local.json
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   hooks.yaml manifest, LCARS_ROOT, TARGETS (.claude/ dirs)
#         Output:  patched settings.local.json with hook registrations
#
#     EXIT CODES
#         N/A (sourced by deploy.sh)
#
# --- END HEADER ---

# protocole.md is injected via system-prompt.md (build-sp.sh) since v5.5.
# No separate file deployment needed.

# --- Hook wiring → settings.local.json ---
HOOKS_YAML="$SCRIPT_DIR/fleet/hooks.yaml"
echo ""
echo "=== hooks → settings.local.json ==="
if [ -f "$HOOKS_YAML" ]; then
    HOOK_COUNT=$(yq '.hooks | length' "$HOOKS_YAML")
    for TARGET in "${TARGETS[@]}"; do
        SETTINGS="$TARGET/settings.local.json"
        # Convergent deploy: reset all hooks then re-register from hooks.yaml
        if [ -f "$SETTINGS" ] && [ "$DRY_RUN" -eq 0 ]; then
            python3 "$PATCH_JSON" reset-hooks "$SETTINGS"
        fi
        for (( i=0; i<HOOK_COUNT; i++ )); do
            _event=$(yq ".hooks[$i].event" "$HOOKS_YAML")
            _matcher=$(yq ".hooks[$i].matcher" "$HOOKS_YAML")
            _cmd=$(yq ".hooks[$i].command" "$HOOKS_YAML")
            register_hook "$SETTINGS" "$_event" "$_matcher" "$_cmd"
        done
    done
else
    echo "  $_WARN hooks.yaml not found at $HOOKS_YAML — hooks not registered"
fi
