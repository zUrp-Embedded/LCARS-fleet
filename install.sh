#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: install.sh
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
#     | MODULE: BOOTSTRAP       | SUBSYSTEM: INSTALL              |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Entry point — bootstrap only.                            |
#     |  Ensures runtime exists, then delegates to the real       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: install.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v6.0
#
#     [EN]
#     install.sh — Entry point — bootstrap only.
#     Ensures runtime exists, then delegates to the real
#
#
# --- END HEADER ---


set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────────────────────
AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'

# ─── Parse options ──────────────────────────────────────────────────────────
REPO_URL="https://github.com/lordzurp/LCARS-fleet.git"
BRANCH="main"
CHECK_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  CHECK_MODE=1; shift ;;
        --repo)   REPO_URL="${2:?--repo requires a URL}"; shift 2 ;;
        --branch) BRANCH="${2:?--branch requires a name}"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check         Dry-run — verify prerequisites only"
            echo "  --repo URL      GitHub repo (default: lordzurp/LCARS-fleet)"
            echo "  --branch NAME   Branch (default: main)"
            echo "  --help          Show this help"
            echo ""
            echo "Install: wget -O /tmp/install.sh https://raw.githubusercontent.com/<repo>/main/install.sh"
            echo "         sudo bash /tmp/install.sh"
            exit 0
            ;;
        *)
            echo "Unknown option: $1 — use --help" >&2
            exit 1
            ;;
    esac
done

# ─── Preflight checks ──────────────────────────────────────────────────────
preflight_ok=1

check_cmd() {
    if command -v "$1" &>/dev/null; then
        echo "  ${G}[ok]${N} $1"
    else
        echo "  ${R}[MISSING]${N} $1 — $2"
        preflight_ok=0
    fi
}

echo ""
echo "  ${W}Preflight checks${N}"
check_cmd git "apt install git"
check_cmd bash "should be present on any system"

# sudo check — only if not already root
if [[ "$EUID" -ne 0 ]]; then
    check_cmd sudo "required for system setup"
fi

if [[ "$preflight_ok" -eq 0 ]]; then
    echo ""
    echo "  ${R}Prerequisites missing — install them first.${N}"
    exit 1
fi

if [[ "$CHECK_MODE" -eq 1 ]]; then
    echo ""
    echo "  ${G}All prerequisites OK.${N}"
    exit 0
fi

# ─── Stdin detection — refuse curl|bash ─────────────────────────────────────
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
    echo ""
    echo "  ${R}ERROR: install.sh must be run from a file, not piped from stdin.${N}"
    echo "  Download first:"
    echo "    wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh"
    echo "    sudo bash /tmp/install.sh"
    exit 1
fi

# ─── Banner + sudo escalation ──────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    cat <<EOF

${AMBER}    ______________________________________________________
   /          ${BA}LCARS FLEET - FEDERATION DATABASE${N}           ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | SYSTEM: LCARS-FLEET v6.0
  |   ________   | STATUS: INSTALLER
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\   ${W}"To boldly go where no code has gone before..."${AMBER}  /
    \\_____________________________________________________/${N}


${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}        LCARS-FLEET — AI AGENT FLEET INSTALLER           ${CYAN}│
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │${N}  ${W}Requires sudo${N} — creates Linux users, configures        ${CYAN}│
  │${N}  system (mounts, sudoers, /etc/wsl.conf).               ${CYAN}│
  │                                                         │
  │${N}  ${W}C: access${N} — WSL mounts C: drive R+W by default.        ${CYAN}│
  │${N}  This script ${W}CLOSES${N} that access via /etc/wsl.conf.      ${CYAN}│
  │${N}  Only /home/ready-room stays open.                      ${CYAN}│
  │                                                         │
  │${N}  ${W}Containment${N} — everything runs ${W}inside${N} WSL.              ${CYAN}│
  │${N}  No access to your ${W}home${N} or ${W}system${N}.                      ${CYAN}│
  │${N}  Worst case = destroy and reprovisioning in minutes.    ${CYAN}│
  ├─────────────────────────────────────────────────────────┤
  │${N}  ${W}Requiert sudo${N} — crée des utilisateurs Linux,           ${CYAN}│
  │${N}  configure le système (montages, sudoers, wsl.conf).    ${CYAN}│
  │                                                         │
  │${N}  ${W}Accès C:${N} — WSL monte C: en R+W par défaut.             ${CYAN}│
  │${N}  Ce script ${W}FERME${N} cet accès via /etc/wsl.conf.           ${CYAN}│
  │${N}  Seul /home/ready-room reste ouvert.                    ${CYAN}│
  │                                                         │
  │${N}  ${W}Confinement${N} — tout tourne ${W}dans${N} WSL.                    ${CYAN}│
  │${N}  Aucun accès à votre ${W}home${N} ni au ${W}système${N}.                ${CYAN}│
  │${N}  Pire cas = détruire et reprovisionner en 10min.        ${CYAN}│
  └─────────────────────────────────────────────────────────┘${N}

  ${G}    ▶  Enter to continue${N}      /  ${R}Ctrl+C to cancel${N}
  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}

EOF
    read -r _ < /dev/tty 2>/dev/null || echo "  [install] No TTY — continuing automatically."

    echo ""
    echo "  ${W}[sudo]${N} Root privileges required — you may be prompted for your password."
    echo ""
    exec sudo bash "$(readlink -f "$0")" "$@"
fi
# past this point: running as root

# ─── Ensure runtime exists ──────────────────────────────────────────────────
LCARS_RUNTIME="/local/LCARS"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Case 1: run from a local repo (tar extract or existing clone)
if [[ -f "$SCRIPT_DIR/fleet/provisioning/provision-fleet.sh" ]]; then
    if [[ "$(readlink -f "$SCRIPT_DIR")" != "$(readlink -f "$LCARS_RUNTIME")" ]]; then
        echo "[install] Seeding runtime from local source → $LCARS_RUNTIME"
        mkdir -p "$LCARS_RUNTIME"
        cp -a "$SCRIPT_DIR"/. "$LCARS_RUNTIME/"
        echo "[install] After bootstrap, runtime is managed by fleet-update.sh (GitHub triangle)"
    fi
    exec bash "$LCARS_RUNTIME/fleet/provisioning/provision-fleet.sh" "$@"
fi

# Case 2: standalone script (downloaded separately)
if [[ -d "$LCARS_RUNTIME/.git" ]]; then
    echo "[install] Runtime exists — force-syncing to branch: $BRANCH"
    git -C "$LCARS_RUNTIME" fetch origin
    git -C "$LCARS_RUNTIME" checkout "$BRANCH" 2>/dev/null || true
    git -C "$LCARS_RUNTIME" reset --hard "origin/$BRANCH"
else
    echo "[install] Cloning $REPO_URL (branch: $BRANCH) → $LCARS_RUNTIME"
    mkdir -p "$LCARS_RUNTIME"
    git clone --branch "$BRANCH" "$REPO_URL" "$LCARS_RUNTIME"
fi
exec bash "$LCARS_RUNTIME/fleet/provisioning/provision-fleet.sh" "$@"
