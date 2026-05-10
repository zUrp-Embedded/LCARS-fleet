#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-starfleet.sh
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
#     | MODULE: POST-STARFLEET  | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for the starfleet instance.         |
#     |  StarFleet notes, coordination scripts, IPC paths.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-starfleet.sh — Module post-install pour instances de type 'starfleet'
#
#     Instance à vue globale : accès à l'archi WSL complète et aux deux instances.
#
#     Montages disponibles après boot :
#       /home/commons    → #3_Commons  (handoff, artifacts, bare repos)
#       /home/wsl-root   → WSL/        (Instanciator.ps1, wsl-setup.sh, #2_Home/*)
#       /home/private    → #4_Private  (fichiers locaux non versionnés)
#
#     [EN]
#     post-install-starfleet.sh — Post-install config for the starfleet instance.
#     StarFleet notes, coordination scripts, IPC paths.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-starfleet]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-starfleet]${NC}  $*"; }

# ─── GitHub CLI (gh) ──────────────────────────────────────────────────────────
if command -v gh &>/dev/null; then
    warn "gh already installed — skipping"
else
    info "Installing GitHub CLI (gh)"
    sudo apt-get update -qq
    sudo apt-get install -y gh
    info "gh installed: $(gh --version | head -1)"
fi

# ─── gh auth — token depuis #4_Private ───────────────────────────────────────
# Créer C:\Users\<vous>\WSL\#4_Private\gh-token avec un PAT GitHub (scope: repo)
GH_TOKEN_FILE="/home/private/gh-token"
if [ -f "$GH_TOKEN_FILE" ]; then
    info "Authenticating gh from $GH_TOKEN_FILE"
    gh auth login --with-token < "$GH_TOKEN_FILE"
    info "gh auth OK — $(gh auth status 2>&1 | grep 'Logged in' || echo 'check gh auth status')"
else
    warn "gh-token not found at $GH_TOKEN_FILE"
    warn "Create #4_Private/gh-token with a GitHub PAT (scope: repo)"
    warn "Then run: gh auth login --with-token < /home/private/gh-token"
fi

# ─── WSL interop binfmt (Windows EXE via wsl.exe) ────────────────────────────
# Avec systemd activé et automount=false, WSL enregistre le handler WSLInterop
# via un drop-in qui remplace ExecStart de systemd-binfmt. Pour reprendre le
# contrôle et éviter que le handler disparaisse après reprise sans reboot,
# on désactive protectBinfmt et on gère la registration via binfmt.d.
#
# Flag P obligatoire : sans lui, /init ne passe pas correctement les arguments
# à wsl.exe (les args de ligne de commande sont interprétés comme commande shell).
sudo mkdir -p /mnt/c
if ! grep -q "^C:" /etc/fstab; then
    echo 'C:	/mnt/c	drvfs	uid=1000,gid=1000,metadata,umask=22,fmask=11	0	0' | sudo tee -a /etc/fstab > /dev/null
fi
if ! grep -q "protectBinfmt" /etc/wsl.conf 2>/dev/null; then
    echo 'protectBinfmt=false' | sudo tee -a /etc/wsl.conf > /dev/null
fi
echo ':WSLInterop:M::MZ::/init:P' | sudo tee /etc/binfmt.d/WSLInterop.conf > /dev/null
if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    echo ':WSLInterop:M::MZ::/init:P' | sudo tee /proc/sys/fs/binfmt_misc/register > /dev/null
fi
info "WSL interop binfmt registered (flag P) — wsl.exe opérationnel"

# ─── Claude Code model config ─────────────────────────────────────────────────
# Applies to starfleet + engineer (post-install-engineer.sh calls this script)
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
MODEL = "claude-sonnet-4-6"
if s.get("model") == MODEL:
    print(f"[post-install] model already set to {MODEL} — skip")
else:
    s["model"] = MODEL
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print(f"[post-install] model set to {MODEL}")
PYEOF
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
info "StarFleet instance ready."
info "  /home/commons   — shared state between instances"
info "  /home/wsl-root  — full WSL architecture view"

# Per-agent git identity — overrides global user.name from git-identity.conf
git config --global user.name "LCARS-starfleet"
