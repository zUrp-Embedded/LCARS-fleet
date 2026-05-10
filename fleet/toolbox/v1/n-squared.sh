#!/bin/bash
# DEPLOY: instance-util
# SOURCE: n-squared.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.087
#
#     [FR]
#     Génère la matrice N² (dépendances inter-scripts) pour les scripts fleet.
#
#     [EN]
#     NAME
#         n-squared.sh — generate N-squared dependency matrix for fleet scripts
#
#     SYNOPSIS
#         n-squared.sh [directory]
#
#     DESCRIPTION
#         Parses fleet scripts for source/call dependencies and generates
#         an N-squared matrix (ICD pattern from aerospace). Output is a
#         markdown table showing which script depends on which.
#         Build artifact — regenerated on demand, not maintained by hand.
#
#     INTERFACE
#         Ring:    gate (quality tooling)
#         Input:   fleet scripts (default: fleet/*.sh + fleet/system-prompt/*.sh)
#         Output:  stdout markdown table
#         JSON:    non
#
#     EXIT CODES
#         0    Matrix generated
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLEET_DIR="$REPO_ROOT/fleet"

# Collect all fleet scripts (kernel + support)
mapfile -t SCRIPTS < <(
    find "$FLEET_DIR" -maxdepth 1 -name "*.sh" -type f
    find "$FLEET_DIR/system-prompt" -name "*.sh" -type f 2>/dev/null
    find "$FLEET_DIR/provisioning" -name "*.sh" -type f 2>/dev/null
    find "$FLEET_DIR/toolbox" -name "*.sh" -type f 2>/dev/null
)

# Build base names array
BASES=()
for s in "${SCRIPTS[@]}"; do
    BASES+=("$(basename "$s")")
done

# Sort
mapfile -t BASES < <(printf '%s\n' "${BASES[@]}" | sort)

# Build dependency matrix
declare -A DEPS

for s in "${SCRIPTS[@]}"; do
    src=$(basename "$s")
    # Find all references to other fleet scripts
    for target in "${BASES[@]}"; do
        [[ "$target" == "$src" ]] && continue
        if grep -q "$target" "$s" 2>/dev/null; then
            DEPS["$src→$target"]=1
        fi
    done
done

# --- Output: markdown N² matrix ---
echo "# N-Squared Matrix — Fleet Script Dependencies"
echo ""
echo "**Date** : $(date '+%Y-%m-%d')"
echo "**Dernière révision** : $(date '+%Y-%m-%d')"
echo "**Statut** : artefact généré — ne pas éditer"
echo "**Référencé par** : v6-rings-and-interfaces.md"
echo ""
echo "Generated: $(date '+%Y-%m-%d %H:%M')"
echo "Scripts: ${#BASES[@]}"
echo ""

# Filter to kernel only for readability
KERNEL=(
    "fleet-env.sh"
    "fleet-build-yaml.sh"
    "build-sp.sh"
    "fleet-send.sh"
    "fleet-inbox-read.sh"
    "wake-instance.sh"
    "fleet-state.sh"
    "fleet-done.sh"
    "fleet-action-done.sh"
    "fleet-inject.sh"
    "fleet-dispatch.sh"
    "fleet-plan.sh"
    "fleet-scrub.sh"
    "fleet-launch.sh"
    "light_on.sh"
    "light_off.sh"
)

# Short names for column headers
declare -A SHORT
SHORT["fleet-env.sh"]="env"
SHORT["fleet-build-yaml.sh"]="bld"
SHORT["build-sp.sh"]="sp"
SHORT["fleet-send.sh"]="snd"
SHORT["fleet-inbox-read.sh"]="inb"
SHORT["wake-instance.sh"]="wak"
SHORT["fleet-state.sh"]="sta"
SHORT["fleet-done.sh"]="don"
SHORT["fleet-action-done.sh"]="adn"
SHORT["fleet-inject.sh"]="inj"
SHORT["fleet-dispatch.sh"]="dis"
SHORT["fleet-plan.sh"]="pln"
SHORT["fleet-scrub.sh"]="scr"
SHORT["fleet-launch.sh"]="lnc"
SHORT["light_on.sh"]="on"
SHORT["light_off.sh"]="off"

echo "## Kernel Matrix (16 scripts)"
echo ""

# Header row
printf "| %-20s |" "uses →"
for col in "${KERNEL[@]}"; do
    printf " %3s |" "${SHORT[$col]}"
done
echo ""

# Separator
printf "|%-22s|" "---"
for _ in "${KERNEL[@]}"; do
    printf "%-5s|" "---"
done
echo ""

# Data rows
for row in "${KERNEL[@]}"; do
    printf "| %-20s |" "${SHORT[$row]}"
    for col in "${KERNEL[@]}"; do
        if [[ "$row" == "$col" ]]; then
            printf "  ·  |"
        elif [[ -n "${DEPS["$row→$col"]:-}" ]]; then
            printf "  ✓  |"
        else
            printf "     |"
        fi
    done
    echo ""
done

echo ""
echo "## Dependency Summary"
echo ""

for row in "${KERNEL[@]}"; do
    deps=""
    for col in "${KERNEL[@]}"; do
        [[ "$row" == "$col" ]] && continue
        [[ -n "${DEPS["$row→$col"]:-}" ]] && deps="$deps ${SHORT[$col]}"
    done
    if [[ -n "$deps" ]]; then
        printf "**%s** →%s\n" "${SHORT[$row]}" "$deps"
    fi
done

echo ""
echo "## Ring boundaries"
echo ""
echo "| Ring | Scripts | Depends on |"
echo "|---|---|---|"
echo "| 0 (kernel) | env, bld, sp | (self-contained) |"

# Cross-ring dependencies
r1_deps=""
r2_deps=""
r3_deps=""
r4_deps=""
for s in fleet-send.sh fleet-inbox-read.sh wake-instance.sh; do
    for col in "${KERNEL[@]}"; do
        [[ -n "${DEPS["$s→$col"]:-}" ]] && r1_deps="$r1_deps ${SHORT[$col]}"
    done
done
for s in fleet-state.sh fleet-done.sh fleet-action-done.sh fleet-inject.sh; do
    for col in "${KERNEL[@]}"; do
        [[ -n "${DEPS["$s→$col"]:-}" ]] && r2_deps="$r2_deps ${SHORT[$col]}"
    done
done
for s in fleet-dispatch.sh fleet-plan.sh fleet-scrub.sh; do
    for col in "${KERNEL[@]}"; do
        [[ -n "${DEPS["$s→$col"]:-}" ]] && r3_deps="$r3_deps ${SHORT[$col]}"
    done
done
for s in fleet-launch.sh light_on.sh light_off.sh; do
    for col in "${KERNEL[@]}"; do
        [[ -n "${DEPS["$s→$col"]:-}" ]] && r4_deps="$r4_deps ${SHORT[$col]}"
    done
done

echo "| 1 (IPC) | snd, inb, wak |$(echo "$r1_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ') |"
echo "| 2 (STATE) | sta, don, adn, inj |$(echo "$r2_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ') |"
echo "| 3 (WORKFLOW) | dis, pln, scr |$(echo "$r3_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ') |"
echo "| 4 (SHELL) | lnc, on, off |$(echo "$r4_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ') |"
