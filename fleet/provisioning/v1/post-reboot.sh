#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-reboot.sh
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
#     | MODULE: POST-REBOOT     | SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  One-shot post-reboot fleet bootstrap.                    |
#     |  Copies credentials from wizard, provisions agents,       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Bootstrap one-shot post-reboot. Copie les credentials depuis le wizard,
#     provisionne les agents, lance deploy. Exécuté une seule fois après le premier reboot.
#
#     [EN]
#     NAME
#         post-reboot.sh — one-shot post-reboot fleet bootstrap
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   wizard credentials, fleet runtime
#         Output:  provisioned fleet, credentials propagated, deploy complete
#
#     EXIT CODES
#         0    Bootstrap completed
#         1    Not root or missing prerequisites
#
# --- END HEADER ---

set -euo pipefail

PRIVATE="/home/private"
INSTALL_OK="$PRIVATE/.install_ok"
FLEET_READY="$PRIVATE/.fleet_ready"
DEPLOY_OK="$FLEET_STATE_DIR/.deploy_ok"
LOG="$PRIVATE/post-reboot.log"

# ── Gate check ──────────────────────────────────────────────────────────
[ -f "$INSTALL_OK" ] || exit 0      # install not done yet
[ -f "$FLEET_READY" ] && exit 0     # already bootstrapped

# ── Colors ─────────────────────────────────────────────────────────────
AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'; D=$'\033[2m'
G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; N=$'\033[0m'

# ── Verify wizard completed ─────────────────────────────────────────────
CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    echo ""
    echo "${Y}[BLOQUÉ]${N} Credentials Anthropic absentes."
    echo ""
    echo "Étape requise : lancez 'claude' dans ce terminal."
    echo "Le wizard Anthropic va vous demander de vous connecter (navigateur ou token)."
    echo "Une fois connecté, dites bonjour pour vérifier que ça marche, puis tapez /exit."
    echo "Ensuite, relancez un terminal — le bootstrap reprendra automatiquement."
    echo ""
    exit 0
fi

# ── Pre-flight checks ──────────────────────────────────────────────────
C_LOCKED="?"
if grep -qi microsoft /proc/version 2>/dev/null; then
    if touch /mnt/c/tmp/.fleet-check-$$ 2>/dev/null; then
        rm -f /mnt/c/tmp/.fleet-check-$$ 2>/dev/null
        C_LOCKED="${R}OPEN${N}"
    else
        C_LOCKED="${G}LOCKED${N}"
    fi
fi

RR_MOUNTED="?"
if mountpoint -q /home/ready-room 2>/dev/null; then
    RR_MOUNTED="${G}YES${N}"
else
    RR_MOUNTED="${Y}NO${N}"
fi

# ── Banner ──────────────────────────────────────────────────────────────
echo ""
echo "${AMBER}       ______________________________________________________"
echo "      /          LCARS FLEET - FEDERATION DATABASE           \\"
echo "     |   ________   __________________________________________\\"
echo "     |  |  2026  |  |${W} POST-REBOOT BOOTSTRAP${AMBER}"
echo "     |  |________|  |${N} System installed, wizard completed.${AMBER}"
echo "     |   ________   |${N}${AMBER}"
echo "     |  | ${G}BOOT${AMBER}  |  |${N} C:\\ drive   : $C_LOCKED${AMBER}"
echo "     |  |________|  |${N} ready-room  : $RR_MOUNTED${AMBER}"
echo "     |              |${N} credentials : ${G}OK${N}${AMBER}"
echo "      \\    ${N}${D}\"To boldly go where no code has gone before...\"${N}${AMBER}     /"
echo "       \\______________________________________________________/${N}"
echo ""
echo "  ${D}Next: provisioning agents + deploying fleet + agent auth.${N}"
echo ""
echo "  ${G}▶  Enter to continue${N}  /  ${R}Ctrl+C to cancel${N}"
echo ""
read -r _ < /dev/tty 2>/dev/null || true

# ── P2.1 — Import credentials to /home/private/ ──────────────────────────
LCARS_ROOT="/local/LCARS"
PROVISION_D="$LCARS_ROOT/fleet/provisioning/provision.d"
GH_HOSTS="$HOME/.config/gh/hosts.yml"
bash "$PROVISION_D/provision-credentials.sh" "$CREDS" "$GH_HOSTS" \
    || { echo "${R}[ERREUR]${N} Import credentials échoué."; exit 1; }

# ── P2.2 — Provision agents ──────────────────────────────────────────────
FLEET_USER="$(whoami)"
echo ""
echo "=== Provisioning agents ==="
sudo bash "$LCARS_ROOT/fleet/provisioning/provision-users.sh" "$FLEET_USER" 2>&1 | tee -a "$LOG" \
    || { echo "${R}[ERREUR]${N} Provisioning échoué. Relancez un terminal pour réessayer."; exit 1; }

# ── Deploy fleet ────────────────────────────────────────────────────────
echo ""
echo "=== Deploy fleet ==="
sudo bash "$LCARS_ROOT/fleet/provisioning/deploy.sh" 2>&1 | tee -a "$LOG" \
    || { echo "${R}[ERREUR]${N} Deploy échoué. Relancez un terminal pour réessayer."; exit 1; }

# fleet-arch + fleet-sf symlinks are created by deploy.sh — no inline wrappers needed

# ── Authenticate starfleet (Anthropic OAuth) ──────────────────────────
# Only starfleet is authenticated here — it's needed for onboarding.
# Other agents are authenticated later via: sudo fleet-auth
echo ""
echo "${AMBER}       ______________________________________________________"
echo "      /          LCARS FLEET - FEDERATION DATABASE           \\"
echo "     |   ________   __________________________________________\\"
echo "     |  | ${Y}AUTH${AMBER}  |  |${W} STARFLEET AUTHENTICATION${AMBER}"
echo "     |  |________|  |${N} StarFleet a besoin d'un token Anthropic${AMBER}"
echo "     |              |${N} pour lancer l'onboarding.${AMBER}"
echo "      \\______________________________________________________/${N}"
echo ""

SF_CRED="/home/starfleet/.claude/.credentials.json"
if [ -f "$SF_CRED" ] && python3 -c "
import json,sys
try:
    d=json.load(open('$SF_CRED'))
    t=d.get('claudeAiOauth',{}).get('accessToken','')
    sys.exit(0 if t else 1)
except: sys.exit(1)
" 2>/dev/null; then
    echo "  ${G}[OK]${N} starfleet — already authenticated"
else
    echo "  ${AMBER}╔═══════════════════════════════════════════════════╗${N}"
    echo "  ${AMBER}║${W}  Agent: starfleet                                ${AMBER}║${N}"
    echo "  ${AMBER}║${N}                                                   ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  Tapez ${W}/login${N} puis ${W}/exit${N} pour continuer.       ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  (Si le wizard demande un lien, copiez-le         ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  dans votre navigateur.)                           ${AMBER}║${N}"
    echo "  ${AMBER}╚═══════════════════════════════════════════════════╝${N}"
    echo ""
    sudo -i -u starfleet claude --dangerously-skip-permissions < /dev/tty || true
    # No post-wizard check — the real test is fleet-sf starting successfully
fi

# ── Write sentinels (LAST — atomic gate) ────────────────────────────────
# .fleet_ready only — prevents post-reboot re-run
# .deploy_ok is NOT written here — reserved for onboard_v2 after security barriers
# This ensures fleet-sf/fleet-arch/~/start block until onboarding is complete
sudo touch "$FLEET_READY"

echo ""
echo "${AMBER}       ______________________________________________________"
echo "      /          LCARS FLEET - FEDERATION DATABASE           \\"
echo "     |   ________   __________________________________________\\"
echo "     |  | ${G}DONE${AMBER}  |  |${W} FLEET DEPLOYED${AMBER}"
echo "     |  |________|  |${N}${AMBER}"
echo "     |   ________   |${N} Lancez ${W}fleet-sf${N} pour l'onboarding${AMBER}"
echo "     |  | ${W}v5.4${AMBER}  |  |${N} (configuration GitHub + isolation).${AMBER}"
echo "     |  |________|  |${N}${AMBER}"
echo "     |              |${N} Après l'onboarding :${AMBER}"
echo "     |              |${N}   ${W}~/start${N}      dashboard tmux complet${AMBER}"
echo "     |              |${N}   ${W}fleet-arch${N}   architect (plein écran)${AMBER}"
echo "     |              |${N}   ${W}fleet-sf${N}     starfleet (plein écran)${AMBER}"
echo "     |              |${N}   ${W}claude${N}       vanilla Claude (hors fleet)${AMBER}"
echo "     |              |${N}${AMBER}"
echo "     |              |${N} ${W}sudo fleet-auth${N} pour authentifier${AMBER}"
echo "     |              |${N} les autres agents (Anthropic OAuth).${AMBER}"
echo "      \\    ${N}${D}\"To boldly go where no code has gone before...\"${N}${AMBER}     /"
echo "       \\______________________________________________________/${N}"
echo ""
