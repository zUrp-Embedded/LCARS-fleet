#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-steward.sh
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
#     | MODULE: POST-STEWARD    | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.068              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for the steward instance.           |
#     |  Sets instance-name, model, cron 30min watchdog.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-steward.sh — Module post-install pour l'instance steward.
#
#     Le steward est le daemon permanent de la fleet : provisioning mode
#     au premier lancement (skill /fleet-init), puis mode normal (monitoring,
#     briefings, IPC). Lancé via fleet-launch.sh en bas-gauche du monitor.
#
#     [EN]
#     post-install-steward.sh — Post-install config for the steward instance.
#     Permanent fleet daemon: /fleet-init on first run, then normal monitoring mode.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-steward]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-steward]${NC}  $*"; }

# ─── Instance name ────────────────────────────────────────────────────────────
mkdir -p "$HOME/.claude"
echo "steward" > "$HOME/.claude/instance-name"
info "Instance name set to steward"

# ─── Model ────────────────────────────────────────────────────────────────────
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
changed = False
MODEL = "claude-sonnet-4-6"
if s.get("model") != MODEL:
    s["model"] = MODEL
    changed = True
    print(f"[post-install-steward] model set to {MODEL}")
# Bootstrap: force /fleet-init on first launch
# fleet-init step 8 removes this after onboarding completes
PROVISION_MARKER = os.path.expanduser("~/.lcars/.provision-done")
if not os.path.exists(PROVISION_MARKER) and "systemPrompt" not in s:
    s["systemPrompt"] = (
        "Tu es le steward de la fleet LCARS. "
        "C'est ton PREMIER LANCEMENT. "
        "Lance IMMÉDIATEMENT le skill /fleet-init pour guider l'utilisateur "
        "dans l'onboarding interactif. Ne fais rien d'autre avant."
    )
    changed = True
    print("[post-install-steward] systemPrompt bootstrap set (fleet-init)")
if changed:
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
PYEOF
else
    warn "settings.local.json not found — model not configured (post-install.sh should have created it)"
fi

# ─── Cron 30min watchdog ──────────────────────────────────────────────────────
# Checks every 30 min whether the steward tmux pane is alive.
# If the pane is dead (session closed or crashed), does nothing — fleet-launch.sh
# is responsible for restart on next ~/start. Cron is a health probe, not a respawn.
CRON_JOB="*/30 * * * * bash ~/.local/bin/steward-watchdog.sh >> /tmp/steward-watchdog.log 2>&1"
if command -v crontab &>/dev/null; then
    if crontab -l 2>/dev/null | grep -qF "steward-watchdog"; then
        info "Cron steward-watchdog already configured — skipping"
    else
        ( crontab -l 2>/dev/null || true; echo "$CRON_JOB" ) | crontab - 2>/dev/null \
            && info "Cron steward-watchdog installed (every 30 min)" \
            || warn "Cron not available — steward-watchdog skipped"
    fi
else
    warn "crontab not found — steward-watchdog skipped"
fi

# ─── Per-agent git identity ───────────────────────────────────────────────────
git config --global user.name "LCARS-steward"

# ─── Summary ──────────────────────────────────────────────────────────────────
info "Steward instance ready."
info "  Launch via fleet-launch.sh (bottom-left pane of monitor window)"
info "  First launch: /fleet-init provisioning mode"
info "  Subsequent: normal mode (morning briefing + IPC monitoring)"
info "  Cron 30min: steward-watchdog.sh"
