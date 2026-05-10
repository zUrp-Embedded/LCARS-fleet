#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-fleet.sh
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
#     | MODULE: INSTALL         | SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Real installer — called by bootstrap /install.sh.        |
#     |  Runtime is already in place when this runs.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Installateur réel de la fleet. Appelé par /install.sh après le bootstrap.
#     Le runtime est déjà en place. Chaîne : provision-system → provision-users → deploy.
#
#     [EN]
#     NAME
#         provision-fleet.sh — fleet installer called by bootstrap /install.sh
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   /local/LCARS (runtime), fleet_user identity
#         Output:  fully provisioned fleet (system + users + deploy)
#
#     EXIT CODES
#         0    Fleet provisioned
#         1    Not root or provisioning failure
#
# --- END HEADER ---

set -euo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'
W=$'\033[1;37m'; D=$'\033[2m'; G=$'\033[1;32m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'
NC=$'\033[0m'
info()  { echo -e "${GREEN}[install]${NC}  $*"; }
error() { echo -e "${RED}[install]${NC} $*" >&2; exit 1; }

[ "$EUID" -ne 0 ] && error "Must run as root"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

LCARS_RUNTIME="/local/LCARS"
LCARS_PROJECT="/home/projects/LCARS"
PROVISION="fleet/provisioning"

[ -d "$LCARS_RUNTIME/fleet" ] || error "Runtime not found at $LCARS_RUNTIME — run install.sh from repo root"

PROVISION_D="$LCARS_RUNTIME/$PROVISION/provision.d"
FLEET_YAML="$LCARS_RUNTIME/fleet/fleet.yaml"

# ─── P1.1 — Seed project working copy ────────────────────────────────────
info "=== Project seed ==="
bash "$PROVISION_D/provision-project-seed.sh" "$REAL_USER"

# ─── P1.2 — Offline sentinel ─────────────────────────────────────────────
if ! git -C "$LCARS_RUNTIME" remote get-url origin &>/dev/null; then
    mkdir -p /home/private
    touch "/home/private/.offline-bootstrap"
    chown "$REAL_USER:$REAL_USER" "/home/private/.offline-bootstrap"
    info "offline mode detected — sentinel written"
fi

# ─── P1.3 — Symlink ~/.lcars → runtime ───────────────────────────────────
if [ "$(readlink -f "$REAL_HOME/.lcars" 2>/dev/null)" != "$(readlink -f "$LCARS_RUNTIME")" ]; then
    ln -sfn "$LCARS_RUNTIME" "$REAL_HOME/.lcars"
    chown -h "$REAL_USER:$REAL_USER" "$REAL_HOME/.lcars"
    info "~/.lcars → $LCARS_RUNTIME"
fi

# ─── P1.4 — System provisioning (packages, groups, dirs, wsl, git, claude) ──
info "=== System provisioning ==="
bash "$LCARS_RUNTIME/$PROVISION/provision-system.sh" "$REAL_USER"

# ─── P1.5 — Identity patch (fleet_user + windows_user → fleet.yaml) ──────
info "=== Identity ==="
bash "$PROVISION_D/provision-identity.sh" "$REAL_USER" "$FLEET_YAML"

# ─── P1.6 — Post-reboot trigger (.bashrc) ────────────────────────────────
info "=== Bashrc trigger ==="
bash "$PROVISION_D/provision-bashrc-trigger.sh" "$REAL_HOME"

# ─── P1 gate — .install_ok sentinel ──────────────────────────────────────
mkdir -p /home/private
touch /home/private/.install_ok
info ".install_ok written — P1 complete"

# ─── Retour au home user (évite que claude soit lancé depuis /tmp/lcars) ─
cd "$REAL_HOME"

# ─── Done banner ─────────────────────────────────────────────────────────
cat <<EOF

${AMBER}    ______________________________________________________
   /          ${BA}LCARS FLEET - FEDERATION DATABASE${N}           ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | STATUS: ${G}INSTALLATION COMPLETE${AMBER}
  |   ________   |
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\   ${W}"To boldly go where no code has gone before..."${AMBER}     /
    \\_____________________________________________________/${N}

${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}        LCARS-FLEET — INSTALLATION COMPLETE              ${CYAN}│
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │${N}  ${G}▶  Next steps :${N}                                        ${CYAN}│
  │                                                         │
  │${N}  ${W}  1.${N}  Run ${W}claude${N} — Anthropic wizard, say hello, /exit  ${CYAN}│
  │${N}     ${D}A "Bypass Permissions" warning will appear.${N}         ${CYAN}│
  │${N}     ${D}This is expected: fleet agents need full autonomy.${N}  ${CYAN}│
  │${N}     ${D}They are sandboxed by VM isolation, not prompts.${N}    ${CYAN}│
  │${N}     ${D}See README → Security model (Octagon).${N}              ${CYAN}│
  │${N}  ${W}  2.${N}  ${D}wsl --shutdown${N}  (PowerShell — C: lockdown)        ${CYAN}│
  │${N}  ${W}  3.${N}  Reopen WSL — fleet deploys automatically          ${CYAN}│
  │${N}       ${W}fleet-arch${N}   — talk to Architect                   ${CYAN}│
  │${N}       ${W}fleet-sf${N}     — talk to StarFleet                   ${CYAN}│
  │${N}       ${W}~/start${N}      — full fleet dashboard                ${CYAN}│
  │${N}       ${W}claude${N}       — vanilla Claude (no fleet)           ${CYAN}│
  ├──────────────────────────────────────────────────────────┤
  │${N}  ${G}▶  Étapes suivantes :${N}                                  ${CYAN}│
  │                                                         │
  │${N}  ${W}  1.${N}  Lancez ${W}claude${N} — wizard Anthropic, bonjour, /exit ${CYAN}│
  │${N}     ${D}Un warning ${RED}"Bypass Permissions"${D} va apparaître.${N}      ${CYAN}│
  │${N}     ${D}C'est normal : les agents ont besoin d'autonomie.${N}   ${CYAN}│
  │${N}     ${D}Ils sont confinés par la VM, pas par des prompts.${N}   ${CYAN}│
  │${N}     ${D}Voir README → Modèle de sécurité (Octogone).${N}        ${CYAN}│
  │${N}  ${W}  2.${N}  ${D}wsl --shutdown${N}  (PowerShell — verrouillage C:)   ${CYAN}│
  │${N}  ${W}  3.${N}  Rouvrez WSL — la fleet se déploie automatiquement${CYAN}│
  │                                                         │
  └─────────────────────────────────────────────────────────┘${N}

EOF
read -r _ < /dev/tty 2>/dev/null || true
