#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-build-yaml.sh
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
#     | MODULE: BUILD-YAML      | SUBSYSTEM: FLEET / CONFIG       |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Generates fleet.yaml from template or profile.           |
#     |  Blueprint builder utility.                               |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-build-yaml.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-build-yaml.sh — Generates fleet.yaml from template or profile.
#     Blueprint builder utility.
#
#
# --- END HEADER ---



# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

# --json: after generation, output metadata as JSON (Ring 0 API)
_BUILD_JSON=0
if [[ "${1:-}" == "--json" ]]; then
    _BUILD_JSON=1
    shift
fi

set -euo pipefail

# Resolve FLEET_DIR: env (fleet-env.sh) > runtime > dirname (source repo)
if [[ -n "${FLEET_DIR:-}" && -f "$FLEET_DIR/fleet-system.yaml" ]]; then
    : # FLEET_DIR from fleet-env.sh — already correct
elif [[ -f "/local/LCARS/fleet/fleet-system.yaml" ]]; then
    FLEET_DIR="/local/LCARS/fleet"
else
    FLEET_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
# Profile: CLI arg > fleet-system.yaml > default (projects)
_SYSTEM_PROFILE="$(yq '.fleet.profile' "$FLEET_DIR/fleet-system.yaml" 2>/dev/null)" || _SYSTEM_PROFILE=""
[[ "$_SYSTEM_PROFILE" == "null" || -z "$_SYSTEM_PROFILE" ]] && _SYSTEM_PROFILE="projects"
PROFILE="${1:-$_SYSTEM_PROFILE}"
SYSTEM="$FLEET_DIR/fleet-system.yaml"
PROFILE_FILE="$FLEET_DIR/profiles/${PROFILE}.yaml"
OUTPUT="$FLEET_DIR/fleet.yaml"
readonly SYSTEM PROFILE_FILE OUTPUT

command -v yq &>/dev/null || { echo "ERROR: yq introuvable — installer via install.sh" >&2; exit 1; }
[[ -f "$SYSTEM" ]] || { echo "ERROR: $SYSTEM introuvable" >&2; exit 1; }
[[ -f "$PROFILE_FILE" ]] || { echo "ERROR: profil '$PROFILE' introuvable ($PROFILE_FILE)" >&2; exit 1; }


# JUPITER-005: do NOT delete existing fleet.yaml before build.
# The old file stays until the new one is validated and atomically promoted (mv).
# Ownership issue handled by chgrp fleet after mv.

# Profile inheritance: recursive extends chain (embedded → projects → fleet)
CHAIN=("$PROFILE_FILE")
CURRENT="$PROFILE_FILE"
MAX_DEPTH=10
DEPTH=0
while true; do
    EXT=$(yq '.extends // ""' "$CURRENT" 2>/dev/null)
    [[ -z "$EXT" || "$EXT" == "null" ]] && break
    DEPTH=$((DEPTH + 1))
    if [[ $DEPTH -gt $MAX_DEPTH ]]; then
        echo "ERROR: extends chain exceeds $MAX_DEPTH levels — circular reference?" >&2
        exit 1
    fi
    PARENT="$FLEET_DIR/profiles/${EXT}.yaml"
    [[ -f "$PARENT" ]] || { echo "ERROR: base profile '$EXT' not found ($PARENT)" >&2; exit 1; }
    CHAIN=("$PARENT" "${CHAIN[@]}")
    CURRENT="$PARENT"
done

CHAIN_NAMES=$(printf '%s ' "${CHAIN[@]}" | sed "s|$FLEET_DIR/profiles/||g; s/ $//")
# Write to temp, validate, then mv atomically (prevents concurrent reads of partial file)
_OUTPUT_TMP="${OUTPUT}.tmp.$$"
trap 'rm -f "$_OUTPUT_TMP" 2>/dev/null' INT TERM EXIT
{ echo "# GENERATED — do not edit. Source: fleet-system.yaml + $CHAIN_NAMES"
  yq eval-all '. as $item ireduce ({}; . *+ $item)' "$SYSTEM" "${CHAIN[@]}"
} | yq 'del(.extends)' > "$_OUTPUT_TMP"

# JUPITER-005: ALL validation runs on temp file BEFORE promotion.
# If validation fails, the old fleet.yaml survives intact.

# Non-empty check
if [[ ! -s "$_OUTPUT_TMP" ]]; then
    echo "ERROR: generated fleet.yaml is empty — merge failed" >&2
    rm -f "$_OUTPUT_TMP"
    exit 1
fi

# Unique roles (duplicate = merge error or profile bug)
_ROLES=$(yq '.instances[].role' "$_OUTPUT_TMP" 2>/dev/null)
_DUP_ROLES=$(printf '%s\n' "$_ROLES" | sort | uniq -d)
if [[ -n "$_DUP_ROLES" ]]; then
    echo "ERROR: duplicate roles in generated fleet.yaml: $_DUP_ROLES" >&2
    rm -f "$_OUTPUT_TMP"
    exit 1
fi

# Required top-level keys
for _KEY in fleet.version fleet.paths.lcars_root fleet.paths.homes_root fleet.identity.fleet_user; do
    _VAL=$(yq ".$_KEY" "$_OUTPUT_TMP" 2>/dev/null)
    if [[ -z "$_VAL" || "$_VAL" == "null" ]]; then
        echo "ERROR: missing required key '$_KEY' in generated fleet.yaml" >&2
        rm -f "$_OUTPUT_TMP"
        exit 1
    fi
done

# Every instance must have role, tier, scope
_BAD_INSTANCES=$(yq '.instances[] | select(.role == null or .tier == null or .scope == null) | .role // "unnamed"' "$_OUTPUT_TMP" 2>/dev/null)
if [[ -n "$_BAD_INSTANCES" ]]; then
    echo "ERROR: instances missing required fields (role/tier/scope): $_BAD_INSTANCES" >&2
    rm -f "$_OUTPUT_TMP"
    exit 1
fi

# --- Promote atomically (old fleet.yaml replaced only after ALL validation passed) ---
mv -f "$_OUTPUT_TMP" "$OUTPUT"
trap - INT TERM EXIT

# Ensure fleet group can read
if ! chgrp fleet "$OUTPUT" 2>/dev/null; then
    if [[ "$(stat -c %a "$OUTPUT" 2>/dev/null)" != *"6"* ]]; then
        echo "WARN: chgrp fleet failed on $OUTPUT — other agents may not be able to read it" >&2
    fi
fi
chmod 664 "$OUTPUT" 2>/dev/null || true

# Validate plan_type vs models — Opus on Pro = extra cost warning
PLAN_TYPE=$(yq '.plan.plan_type' "$SYSTEM" 2>/dev/null)
if [[ "$PLAN_TYPE" == "PRO" ]]; then
    OPUS_ROLES=$(yq '.instances[] | select(.model | test("^claude-opus")) | .role' "$OUTPUT" 2>/dev/null || true)
    if [[ -n "$OPUS_ROLES" ]]; then
        echo "WARN: plan_type=PRO but Opus models assigned (billed as extra usage):" >&2
        echo "  $OPUS_ROLES" >&2
        echo "  Consider: fleet-build-yaml.sh pro" >&2
    fi
fi

_VERSION=$(yq '.fleet.version' "$OUTPUT" 2>/dev/null)
_ROLE_COUNT=$(yq '.instances | length' "$OUTPUT" 2>/dev/null)

if [[ $_BUILD_JSON -eq 1 ]]; then
    cat <<JSON
{
  "output": "$OUTPUT",
  "profile": "$PROFILE",
  "version": "${_VERSION:-unknown}",
  "role_count": ${_ROLE_COUNT:-0},
  "chain": "$CHAIN_NAMES"
}
JSON
else
    echo "[fleet-build-yaml] fleet.yaml généré (system + $PROFILE) — v${_VERSION:-unknown}"
fi
