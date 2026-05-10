#!/bin/bash
# DEPLOY: instance-util
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: build-sp.sh
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
#     | MODULE: BUILD-SP          | SUBSYSTEM: SYSTEM-PROMPT      |
#     | LICENSE: AGPL-3           | STARDATE: 2026.090            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Assemble per-agent system-prompt.md from modular sources.|
#     |  Reads manifest.yaml for block definitions + fleet.yaml   |
#     |  for per-instance assignments. No hardcoded case.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Assemble le system-prompt.md de chaque agent depuis les sources modulaires.
#     Lit manifest.yaml (blocs disponibles) + fleet.yaml (assignation par role).
#
#     [EN]
#     NAME
#         build-sp.sh — assemble per-agent system-prompt.md from manifest
#
#     SYNOPSIS
#         build-sp.sh
#         build-sp.sh <role> "<sp_keys>" <home_dir>
#
#     DESCRIPTION
#         Reads manifest.yaml for block definitions (paths, types, separators)
#         and fleet.yaml for per-instance system_prompt lists. Assembles each
#         agent's system-prompt.md by resolving block keys to source files.
#         Single-agent mode for targeted rebuild.
#
#     INTERFACE
#         Ring:    0 (kernel)
#         Input:   manifest.yaml (block definitions),
#                  fleet.yaml (instances + system_prompt lists),
#                  sources/ directory (core/*.md, organisation/*.md, etc.)
#         Output:  <home>/.claude/system-prompt.md per agent
#         JSON:    non
#
#     OPTIONS
#         (no flags)     Batch mode: build all agents from fleet.yaml
#         <role>         Single-agent mode: role name
#         "<sp_keys>"    Space-separated source keys (e.g. "anthropic-lcars core")
#         <home_dir>     Target home directory
#
#     ENVIRONMENT
#         FLEET_YAML      Override fleet.yaml path (default: auto-resolved)
#
#     EXIT CODES
#         0    All system prompts built
#         1    fleet.yaml/manifest.yaml not found, no instances, source missing
#
#     EXAMPLES
#         build-sp.sh
#         build-sp.sh starfleet "anthropic-lcars core organisation/topologie" /home/starfleet
#
#     SEE ALSO
#         fleet-env.sh, fleet-update.sh, deploy.sh, sources/manifest.yaml
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SP_DIR="${BUILD_SP_DIR:-$SCRIPT_DIR}"
SOURCES="${BUILD_SP_SOURCES:-$SP_DIR/sources}"
MANIFEST="${BUILD_SP_MANIFEST:-$SOURCES/manifest.yaml}"
readonly SCRIPT_DIR SP_DIR SOURCES MANIFEST

# Validate manifest
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest.yaml not found at $MANIFEST" >&2
    exit 1
fi

# Resolve FLEET_YAML: env (fleet-env.sh) > runtime > hardcoded fallback
if [[ -n "${FLEET_YAML:-}" && -f "$FLEET_YAML" ]]; then
    : # FLEET_YAML from fleet-env.sh — already correct
elif [[ -f "/local/LCARS/fleet/fleet.yaml" ]]; then
    FLEET_YAML="/local/LCARS/fleet/fleet.yaml"
elif [[ -f "$SCRIPT_DIR/../fleet.yaml" ]]; then
    FLEET_YAML="$SCRIPT_DIR/../fleet.yaml"
else
    FLEET_YAML=""
fi

# --- Manifest-driven block resolver ---
# Reads block definition from manifest.yaml and appends content to output file.
resolve_block() {
    local key="$1"
    local role="$2"
    local out="$3"
    local block_path block_type block_sep src

    # Read block definition from manifest (|| true: protect against set -e in subshells)
    block_path=$(yq ".blocks.\"${key}\".path" "$MANIFEST" 2>/dev/null) || block_path="null"
    block_type=$(yq ".blocks.\"${key}\".type // \"file\"" "$MANIFEST" 2>/dev/null) || block_type="file"
    block_sep=$(yq ".blocks.\"${key}\".separator // \"\"" "$MANIFEST" 2>/dev/null) || block_sep=""

    if [[ "$block_path" == "null" || -z "$block_path" ]]; then
        echo "WARN: [build-sp] $role: block '$key' not found in manifest" >&2
        return 1
    fi

    # Emit separator if defined
    if [[ -n "$block_sep" && "$block_sep" != "null" ]]; then
        printf '%b' "$block_sep" >> "$out"
    fi

    # Resolve path relative to sources/ (or SP_DIR for ../ paths)
    if [[ "$block_path" == ../* ]]; then
        src="$SOURCES/$block_path"
    else
        src="$SOURCES/$block_path"
    fi

    # Handle role template substitution
    src="${src//\{role\}/$role}"

    case "$block_type" in
        glob)
            local count=0
            for f in $src; do
                [[ -f "$f" ]] && cat "$f" >> "$out" && echo "" >> "$out" && count=$((count + 1))
            done
            [[ $count -eq 0 ]] && { echo "WARN: [build-sp] $role: no files for glob '$block_path'" >&2; return 1; }
            ;;
        *)
            # Single file
            if [[ ! -f "$src" ]]; then
                echo "WARN: [build-sp] $role: source missing: $src" >&2
                return 1
            fi
            cat "$src" >> "$out"
            echo "" >> "$out"
            ;;
    esac
    return 0
}

# --- Build one agent ---
build_agent() {
    local role="$1"
    local sp_list="$2"   # space-separated list of source keys
    local home_dir="$3"
    local out="${home_dir}/.claude/system-prompt.md"
    local missing=0

    # Validate inputs
    [[ -z "$role" ]] && { echo "ERROR: build_agent: role is empty" >&2; return 1; }
    [[ -z "$home_dir" ]] && { echo "ERROR: build_agent: home_dir is empty" >&2; return 1; }

    mkdir -p "$(dirname "$out")"

    # JUPITER-005: build to temp file, promote atomically.
    # Old SP survives if build is interrupted or fails.
    local _tmp_out="${out}.tmp.$$"
    trap 'rm -f "${_tmp_out:-}" 2>/dev/null' INT TERM EXIT
    : > "$_tmp_out"
    chmod 640 "$_tmp_out" 2>/dev/null || true

    # Resolve each block from manifest
    # Word-split intentional: sp_list is space-separated. Keys must NOT contain spaces.
    for key in $sp_list; do
        resolve_block "$key" "$role" "$_tmp_out" || missing=$((missing + 1))
    done

    # Role block (always, implicit — position: last in manifest)
    resolve_block "role" "$role" "$_tmp_out" || missing=$((missing + 1))

    # Metrics
    local chars tokens_est
    chars=$(wc -c < "$_tmp_out")
    tokens_est=$((chars / 4))

    # Promote only if non-empty
    if [[ $chars -gt 0 ]]; then
        mv -f "$_tmp_out" "$out"
        # Config lockdown: SP owned by fleet_user, not agent (prevents self-modification)
        local _fleet_user
        _fleet_user="${FLEET_USER:-lordzurp}"
        chown "$_fleet_user:fleet" "$out" 2>/dev/null || true
        chmod 644 "$out" 2>/dev/null || true
    else
        echo "  [build-sp] $role: EMPTY — keeping previous SP" >&2
        rm -f "$_tmp_out"
        return 1
    fi

    if [[ $missing -gt 0 ]]; then
        echo "  [build-sp] $role: ${chars}c / ~${tokens_est} tokens → $out (${missing} source(s) missing)" >&2
    else
        echo "  [build-sp] $role: ${chars}c / ~${tokens_est} tokens → $out"
    fi
}

# --- Main ---

echo "[build-sp] sources: $SOURCES"
echo "[build-sp] manifest: $MANIFEST"
echo ""

if [ "$#" -gt 0 ]; then
    # Reject unknown flags
    [[ "${1:-}" == -* ]] && { echo "ERROR: unknown flag '${1}'. Usage: build-sp.sh [<role> <sp_keys> <home_dir>]" >&2; exit 1; }
    # Single agent mode: build-sp.sh <role> "<sp key1 key2...>" <home>
    [[ -z "${1:-}" ]] && { echo "ERROR: single-agent mode requires: <role> <sp_keys> <home_dir>" >&2; exit 1; }
    [[ -z "${2:-}" ]] && { echo "ERROR: single-agent mode requires: <role> <sp_keys> <home_dir>" >&2; exit 1; }
    [[ -z "${3:-}" ]] && { echo "ERROR: single-agent mode requires: <role> <sp_keys> <home_dir>" >&2; exit 1; }
    build_agent "$1" "$2" "$3"
    exit 0
fi

# Batch mode: read all instances from fleet.yaml
if [[ -z "$FLEET_YAML" || ! -f "$FLEET_YAML" ]]; then
    echo "ERROR: fleet.yaml not found at $FLEET_YAML" >&2
    exit 1
fi

INSTANCE_COUNT=$(yq '.instances | length' "$FLEET_YAML" 2>/dev/null || echo "")
if [[ -z "$INSTANCE_COUNT" || "$INSTANCE_COUNT" == "null" || ! "$INSTANCE_COUNT" =~ ^[0-9]+$ || "$INSTANCE_COUNT" -eq 0 ]]; then
    echo "ERROR: no instances in fleet.yaml" >&2
    exit 1
fi

for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
    role=$(yq ".instances[$i].role" "$FLEET_YAML" 2>/dev/null)
    sp_list=$(yq ".instances[$i].system_prompt // [] | join(\" \")" "$FLEET_YAML" 2>/dev/null)
    home_dir="/home/$role"

    [ "$role" = "null" ] && continue
    [ ! -d "$home_dir" ] && continue

    build_agent "$role" "$sp_list" "$home_dir"
done

echo ""
echo "[build-sp] done."
