#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-fleet.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: DEPLOY-LINUX    | SUBSYSTEM: PROV / LINUX         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploys fleet scripts to a Linux agent home.             |
#     |  Copies fleet/, .claude/ to target user home.             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     deploy-fleet.sh — Interactive fleet deployment for native Linux
#
#     Creates Claude multi-agent sessions with role-specific packages and env files.
#     Equivalent of Deploy-Fleet.ps1 for WSL2.
#
#     Usage: bash deploy-fleet.sh [--dry-run]
#       --dry-run  Force simulation mode (no packages installed, no sessions created)
#
#     Without --dry-run: asks interactively. Default answer = simulate.
#
#     [EN]
#     deploy-fleet.sh — Deploys fleet scripts to a Linux agent home.
#     Copies fleet/, .claude/ to target user home.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[fleet]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[fleet]${NC}  $*"; }
error()   { echo -e "${RED}[fleet]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV_DIR="$(dirname "$SCRIPT_DIR")"
NEW_AGENT="$PROV_DIR/new-agent.sh"

# ─── Args ─────────────────────────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

# ─── 1. Simulation ? ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    read -r -p "Simuler le déploiement ? [Y/n] " sim_ans
    sim_ans="${sim_ans:-Y}"
    [[ "$sim_ans" =~ ^[Yy]$ ]] && DRY_RUN=1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "MODE SIMULATION — aucune commande réelle exécutée"
fi

# ─── 2. Prérequis ─────────────────────────────────────────────────────────────
section "Vérification des prérequis"

[[ -f "$HOME/.claude/shared-dir" ]] \
    || error "shared-dir absent — lancer d'abord : bash provisioning/linux/setup-linux.sh"
command -v tmux   &>/dev/null || error "tmux non installé"
command -v claude &>/dev/null || error "Claude Code non installé — relancer setup-linux.sh"
[[ -f "$NEW_AGENT" ]]         || error "new-agent.sh introuvable : $NEW_AGENT"
[[ -x "$NEW_AGENT" ]]         || chmod +x "$NEW_AGENT"

info "Prérequis OK"

# ─── 3. Sélection des rôles ───────────────────────────────────────────────────
section "Sélection des rôles"

ROLES_ORDER=(dev builder qualifier starfleet engineer)

declare -A ROLE_DESC=(
    [dev]="développement, commits git"
    [builder]="build ARM64/x86-64 (--arch flag)"
    [qualifier]="tests (pytest, ctest)"
    [starfleet]="coordination fleet"
    [engineer]="toolkit LCARS, config Claude"
)

declare -A ROLE_DEFAULTS=(
    [dev]="Y"
    [builder]="Y"
    [qualifier]="Y"
    [starfleet]="Y"
    [engineer]="Y"
)

declare -A ROLE_ENABLED=()

for role in "${ROLES_ORDER[@]}"; do
    default="${ROLE_DEFAULTS[$role]}"
    desc="${ROLE_DESC[$role]}"
    read -r -p "  $role — $desc [${default}] " ans
    ans="${ans:-$default}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        ROLE_ENABLED[$role]=1
    else
        ROLE_ENABLED[$role]=0
    fi
done

# ─── 4. Résumé ────────────────────────────────────────────────────────────────
section "Résumé"

SELECTED_ROLES=()
for role in "${ROLES_ORDER[@]}"; do
    if [[ "${ROLE_ENABLED[$role]}" -eq 1 ]]; then
        echo -e "  ${GREEN}✓${NC} $role"
        SELECTED_ROLES+=("$role")
    else
        echo -e "  ${RED}✗${NC} $role (skipped)"
    fi
done

[[ ${#SELECTED_ROLES[@]} -eq 0 ]] && error "Aucun rôle sélectionné — rien à déployer"

# ─── 5. Packages par rôle ─────────────────────────────────────────────────────
declare -A ROLE_PACKAGES=(
    [dev]="build-essential cmake ninja-build gdb clang clang-format python3 python3-venv python3-pip bear"
    [builder]="gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu build-essential cmake ninja-build gdb python3 file"
    [qualifier]="build-essential cmake ninja-build python3 python3-venv python3-pip"
    [starfleet]=""
    [engineer]=""
)

NEED_GH=0
[[ "${ROLE_ENABLED[starfleet]:-0}" -eq 1 || "${ROLE_ENABLED[engineer]:-0}" -eq 1 ]] && NEED_GH=1

NEED_BUILDER_UTILS=0
NEED_ARM_UTILS=0
[[ "${ROLE_ENABLED[builder]:-0}" -eq 1 ]] && NEED_BUILDER_UTILS=1
[[ "${ROLE_ENABLED[builder]:-0}" -eq 1 ]] && NEED_ARM_UTILS=1

# Deduplicate packages across selected roles
declare -A PKG_SEEN=()
APT_PACKAGES=()
for role in "${SELECTED_ROLES[@]}"; do
    for pkg in ${ROLE_PACKAGES[$role]:-}; do
        if [[ -z "${PKG_SEEN[$pkg]+_}" ]]; then
            PKG_SEEN[$pkg]=1
            APT_PACKAGES+=("$pkg")
        fi
    done
done

# ─── 6. Simulation ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    section "Commandes simulées"

    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        echo "  apt-get install -y ${APT_PACKAGES[*]}"
    else
        echo "  # aucun package apt requis"
    fi

    if [[ "$NEED_GH" -eq 1 ]]; then
        echo "  # gh CLI install (https://cli.github.com/packages)"
    fi
    if [[ "$NEED_BUILDER_UTILS" -eq 1 ]]; then
        echo "  # → ~/.local/bin/: rpi-img-mount.sh fleet-blocker.sh fleet-build-done.sh"
    fi
    if [[ "$NEED_ARM_UTILS" -eq 1 ]]; then
        echo "  # → ~/.local/bin/: build-cycle.sh (ARM)"
    fi

    echo ""
    for role in "${SELECTED_ROLES[@]}"; do
        WORKSPACE="\$HOME/claude-agents/$role"
        echo "  bash new-agent.sh $role --instance-type $role --no-attach"
        case "$role" in
            builder)
                echo "  # → $WORKSPACE/.env.cross  (SYSROOT, toolchain prefix, CFLAGS_CPU — ARM64)"
                echo "  # → $WORKSPACE/.env.x86    (-march=x86-64-v3 — x86-64)"
                echo "  # → $WORKSPACE/.rpi-target"
                ;;
            dev)
                echo "  # → $WORKSPACE/venv/  (python3 -m venv)"
                ;;
            qualifier)
                echo "  # → $WORKSPACE/venv/  (python3 -m venv + pytest pytest-timeout)"
                ;;
        esac
    done

    echo ""
    info "Simulation terminée. Répondre 'n' à la première question pour déployer réellement."
    exit 0
fi

# ─── 7. Installation packages ─────────────────────────────────────────────────
section "Installation des packages"

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    info "apt-get install: ${APT_PACKAGES[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${APT_PACKAGES[@]}"
else
    info "Aucun package apt à installer"
fi

if [[ "$NEED_GH" -eq 1 ]]; then
    if command -v gh &>/dev/null; then
        info "gh CLI déjà installé — skip"
    else
        info "Installation de gh CLI..."
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y gh
    fi
fi

# ─── 7b. Utils builder/ARM → ~/.local/bin/ ────────────────────────────────────
# install.sh installs these only when ~/.wsl-instance-type is set (WSL).
# On Linux native, deploy-fleet.sh handles them directly.
FLEET_DIR="${HOME}/.lcars/fleet"
if [[ "$NEED_BUILDER_UTILS" -eq 1 ]]; then
    if [[ -d "$FLEET_DIR" ]]; then
        mkdir -p "$HOME/.local/bin"
        for util in rpi-img-mount.sh fleet-blocker.sh fleet-build-done.sh; do
            src="$FLEET_DIR/$util"
            [[ -f "$src" ]] || { warn "$util absent de $FLEET_DIR — skip"; continue; }
            cp "$src" "$HOME/.local/bin/$util"
            chmod +x "$HOME/.local/bin/$util"
        done
        info "Builder utils → ~/.local/bin/"
    else
        warn "${HOME}/.lcars/fleet/ absent — builder utils non installés. Relancer setup-linux.sh."
    fi
fi
if [[ "$NEED_ARM_UTILS" -eq 1 && -d "$FLEET_DIR" ]]; then
    src="$FLEET_DIR/build-cycle.sh"
    if [[ -f "$src" ]]; then
        cp "$src" "$HOME/.local/bin/build-cycle.sh"
        chmod +x "$HOME/.local/bin/build-cycle.sh"
        info "ARM utils → ~/.local/bin/ (build-cycle.sh)"
    else
        warn "build-cycle.sh absent de $FLEET_DIR — skip"
    fi
fi

# ─── 8. Création des sessions ─────────────────────────────────────────────────
section "Création des sessions"


for role in "${SELECTED_ROLES[@]}"; do
    WORKSPACE="$HOME/claude-agents/$role"
    info "Agent: $role"
    bash "$NEW_AGENT" "$role" --instance-type "$role" --no-attach

    # Post-creation: role-specific env files
    case "$role" in
        builder)
            cat > "$WORKSPACE/.env.cross" <<'ENVEOF'
# Cross-compilation ARM64 — Raspberry Pi Zero 2
# SYSROOT must exist before any build — provision manually before use.
# See: https://github.com/nicowillis/rpi-sysroot or use a pre-built sysroot.

SYSROOT=/opt/rpi-sysroot
CROSS_TRIPLE=aarch64-linux-gnu
CC=${CROSS_TRIPLE}-gcc
CXX=${CROSS_TRIPLE}-g++
AR=${CROSS_TRIPLE}-ar
CFLAGS_CPU="-mcpu=cortex-a53 -mtune=cortex-a53"
CMAKE_TOOLCHAIN_FILE=cmake/toolchain-aarch64.cmake
ENVEOF
            cat > "$WORKSPACE/.env.x86" <<'ENVEOF'
# Native x86-64 build — N100 / Alder Lake
CFLAGS_CPU="-march=x86-64-v3 -mtune=alderlake"
CXXFLAGS_CPU="-march=x86-64-v3 -mtune=alderlake"
ENVEOF
            echo "rpi-zero2" > "$WORKSPACE/.rpi-target"
            info "  → .env.cross, .env.x86, .rpi-target"
            ;;
        dev)
            if [[ ! -d "$WORKSPACE/venv" ]]; then
                python3 -m venv "$WORKSPACE/venv"
                info "  → venv/"
            else
                info "  → venv/ already exists"
            fi
            ;;
        qualifier)
            if [[ ! -d "$WORKSPACE/venv" ]]; then
                python3 -m venv "$WORKSPACE/venv"
                "$WORKSPACE/venv/bin/pip" install --quiet pytest pytest-timeout
                info "  → venv/ + pytest, pytest-timeout"
            else
                info "  → venv/ already exists"
            fi
            ;;
    esac
done

# ─── 9. Bilan ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Fleet déployée"
echo ""
for role in "${SELECTED_ROLES[@]}"; do
    echo -e "  ${GREEN}✓${NC} $role  →  tmux attach -t claude-$role"
done
echo ""
echo "  Lister les sessions  : tmux ls"
echo "  Attacher une session : tmux attach -t claude-<role>"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
