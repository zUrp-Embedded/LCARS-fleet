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
#     | MODULE: DEPLOY-MAC      | SUBSYSTEM: PROV / MAC           |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploys fleet scripts to a macOS agent home.             |
#     |  Copies fleet/, .claude/ to target user home.             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     deploy-fleet.sh — Interactive fleet deployment for macOS
#
#     Creates Claude multi-agent sessions with role-specific packages and env files.
#     Equivalent of deploy-fleet.sh for Linux / Deploy-Fleet.ps1 for WSL2.
#
#     Usage: bash deploy-fleet.sh [--dry-run]
#       --dry-run  Force simulation mode (no packages installed, no sessions created)
#
#     Without --dry-run: asks interactively. Default answer = simulate.
#
#     [EN]
#     deploy-fleet.sh — Deploys fleet scripts to a macOS agent home.
#     Copies fleet/, .claude/ to target user home.
#

set -euo pipefail

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

command -v brew   &>/dev/null || error "Homebrew non installé — https://brew.sh"
[[ -f "$HOME/.claude/shared-dir" ]] \
    || error "shared-dir absent — lancer d'abord : bash provisioning/mac/setup-mac.sh"
command -v tmux   &>/dev/null || error "tmux non installé — brew install tmux"
command -v claude &>/dev/null || error "Claude Code non installé — relancer setup-mac.sh"
[[ -f "$NEW_AGENT" ]]         || error "new-agent.sh introuvable : $NEW_AGENT"
[[ -x "$NEW_AGENT" ]]         || chmod +x "$NEW_AGENT"

info "Prérequis OK"

# ─── 3. Sélection des rôles ───────────────────────────────────────────────────
section "Sélection des rôles"

ROLES_ORDER=(dev qualifier starfleet engineer)

declare -A ROLE_DESC=(
    [dev]="développement, commits git"
    [qualifier]="tests (pytest, ctest)"
    [starfleet]="coordination fleet"
    [engineer]="toolkit LCARS, config Claude"
)

declare -A ROLE_DEFAULTS=(
    [dev]="Y"
    [qualifier]="Y"
    [starfleet]="Y"
    [engineer]="Y"
)

warn "Rôle non supporté sur macOS (cross-toolchain Linux requis) :"
warn "  builder — cross-compilation ARM64 → utiliser Linux ou WSL2"
echo ""

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
    [dev]="cmake ninja python3 bear"
    [qualifier]="cmake ninja python3"
    [starfleet]=""
    [engineer]=""
)

NEED_GH=0
[[ "${ROLE_ENABLED[starfleet]:-0}" -eq 1 || "${ROLE_ENABLED[engineer]:-0}" -eq 1 ]] && NEED_GH=1

# Deduplicate packages across selected roles
declare -A PKG_SEEN=()
BREW_PACKAGES=()
for role in "${SELECTED_ROLES[@]}"; do
    for pkg in ${ROLE_PACKAGES[$role]:-}; do
        if [[ -z "${PKG_SEEN[$pkg]+_}" ]]; then
            PKG_SEEN[$pkg]=1
            BREW_PACKAGES+=("$pkg")
        fi
    done
done

# ─── 6. Simulation ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    section "Commandes simulées"

    if [[ ${#BREW_PACKAGES[@]} -gt 0 ]]; then
        echo "  brew install ${BREW_PACKAGES[*]}"
    else
        echo "  # aucun package brew requis"
    fi

    if [[ "$NEED_GH" -eq 1 ]]; then
        echo "  brew install gh"
    fi

    echo ""
    for role in "${SELECTED_ROLES[@]}"; do
        WORKSPACE="\$HOME/claude-agents/$role"
        echo "  bash new-agent.sh $role --instance-type $role --no-attach"
        case "$role" in
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

if [[ ${#BREW_PACKAGES[@]} -gt 0 ]]; then
    info "brew install: ${BREW_PACKAGES[*]}"
    brew install "${BREW_PACKAGES[@]}"
else
    info "Aucun package brew à installer"
fi

if [[ "$NEED_GH" -eq 1 ]]; then
    if command -v gh &>/dev/null; then
        info "gh CLI déjà installé — skip"
    else
        info "Installation de gh CLI..."
        brew install gh
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
