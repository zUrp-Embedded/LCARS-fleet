#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: wsl-setup.sh
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
#     | MODULE: WSL-SETUP       | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Initial WSL2 environment setup for fleet.                |
#     |  Configures networking, mounts, shared paths.             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     wsl-setup.sh — Configuration minimale post-import d'une instance WSL
#
#     Usage: sudo bash wsl-setup.sh --hostname <n> --wsl-root <wsl-path> [OPTIONS]
#
#     Ce script est lancé par Instanciator.ps1 juste après wsl --import.
#     Il fait le strict minimum nécessaire AVANT le premier boot systemd :
#       - packages de base + purge snap
#       - packages spécifiques au type d'instance (build/dev/base)
#
#     [EN]
#     wsl-setup.sh — Initial WSL2 environment setup for fleet.
#     Configures networking, mounts, shared paths.
#

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
WSL_HOSTNAME=""
USERNAME="architect"
INSTANCE_TYPE="base"
WSL_ROOT_PATH=""

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo bash $0 --hostname <n> --wsl-root <wsl-path> [OPTIONS]

Required:
  --hostname <n>            Hostname pour cette instance WSL
  --wsl-root <wsl-path>     Chemin WSL de la racine WSL (ex: /mnt/c/Users/$ARCHITECT_USER/WSL)

Options:
  --user <username>         User Linux à créer (default: architect)
  --instance-type <type>    Type d'instance : base | dev | builder | starfleet | engineer | qualifier (default: base)
  -h, --help                Affiche cette aide
EOF
    exit 0
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)      WSL_HOSTNAME="${2:?'--hostname requires a value'}"; shift 2 ;;
        --user)          USERNAME="${2:?'--user requires a value'}"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="${2:?'--instance-type requires a value'}"; shift 2 ;;
        --wsl-root)      WSL_ROOT_PATH="${2:?'--wsl-root requires a value'}"; shift 2 ;;
        -h|--help)       usage ;;
        *) error "Unknown argument: $1" ;;
    esac
done

[[ -z "$WSL_HOSTNAME"  ]] && error "--hostname is required"
[[ -z "$WSL_ROOT_PATH" ]] && error "--wsl-root is required"
[[ $EUID -ne 0 ]]         && error "Must be run as root (sudo)"

case "$INSTANCE_TYPE" in
    base|dev|builder|starfleet|engineer|qualifier) ;;
    *) error "Unknown instance type '$INSTANCE_TYPE' — expected: base, dev, builder, starfleet, engineer, qualifier" ;;
esac

# ─── Chemins dérivés de WSL_ROOT_PATH ─────────────────────────────────────────
# WSL_ROOT_PATH  = /mnt/c/Users/$ARCHITECT_USER/WSL  (chemin WSL, passé par Instanciator.ps1)
# WIN_ROOT       = C:\Users\$ARCHITECT_USER\WSL       (chemin Windows pour fstab drvfs)
WIN_ROOT=$(echo "$WSL_ROOT_PATH" | sed 's|^/mnt/c|C:|; s|/|\\|g')

WIN_HOME="${WIN_ROOT}\\#2_Home\\${WSL_HOSTNAME}"
WIN_HOME_MNT="${WSL_ROOT_PATH}/#2_Home/${WSL_HOSTNAME}"

WIN_COMMONS="${WIN_ROOT}\\#3_Commons"
WIN_PRIVATE="${WIN_ROOT}\\#4_Private"

# NOTE: LCARS-fleet source est sur ext4 (/home/${LCARS_REPO:-$ARCHITECT_USER/LCARS-fleet}), pas sur drvfs.
# ~/.lcars sera cloné depuis GitHub par post-install.sh au premier boot.

# ─── 1. System update ─────────────────────────────────────────────────────────
info "Updating package lists"
apt-get update -qq

info "Upgrading installed packages"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ─── 2. Purge snap ────────────────────────────────────────────────────────────
# Snap bloque l'init de la session systemd --user sous WSL (socket résiduel).
info "Removing snap"
if systemctl is-system-running &>/dev/null; then
    systemctl mask snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
fi
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq snapd 2>/dev/null || true
rm -rf /snap /var/snap /var/lib/snapd /usr/lib/systemd/user/snapd.session-agent.socket

# ─── 3. Base packages ─────────────────────────────────────────────────────────
info "Installing base packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    sudo \
    tzdata \
    locales \
    unzip \
    rsync \
    git \
    htop \
    btop \
    vim \
    nano \
    dbus \
    dbus-user-session

# ─── 4. Locale ────────────────────────────────────────────────────────────────
info "Setting locale to en_US.UTF-8"
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null
update-locale LANG=en_US.UTF-8

# ─── 5. Packages spécifiques au type d'instance ───────────────────────────────
case "$INSTANCE_TYPE" in
    dev)
        info "Instance type 'dev' — installing dev packages"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            build-essential \
            cmake \
            ninja-build \
            pkg-config \
            python3 \
            python3-pip \
            python3-venv \
            gdb \
            clang \
            clang-format \
            clang-tidy \
            bear \
            ssh
        ;;
    builder)
        info "Instance type 'builder' — installing cross-compilation toolchain (ARM64)"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            gcc-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu \
            cmake \
            ninja-build \
            pkg-config \
            file \
            ssh
        ;;
    qualifier)
        info "Instance type 'qualifier' — installing test toolchain"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            build-essential \
            cmake \
            ninja-build \
            pkg-config \
            python3 \
            python3-pip \
            python3-venv \
            ssh
        ;;
    base|starfleet|engineer)
        info "Instance type '$INSTANCE_TYPE' — no additional packages"
        ;;
esac

# ─── 6. User creation ─────────────────────────────────────────────────────────
if id "$USERNAME" &>/dev/null; then
    warn "User '$USERNAME' already exists — skipping creation"
else
    info "Creating user '$USERNAME'"
    useradd -m -U -s /bin/bash "$USERNAME"
    usermod -aG sudo "$USERNAME"

    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

    touch "/home/${USERNAME}/.sudo_as_admin_successful"

    if ! grep -q "WSL customisation" "/home/${USERNAME}/.bashrc"; then
        cat >> "/home/${USERNAME}/.bashrc" <<'BASHRC'

# ── WSL customisation ──────────────────────────────────────────────────────
export EDITOR=nano
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:erasedups

alias ll='ls -lah --color=auto'
alias gs='git status'
alias glog='git log --oneline --graph --decorate'

# Fleet session marker — exclut les terminaux VS Code
[[ "${TERM_PROGRAM:-}" != "vscode" ]] && export FLEET_SESSION=1

cd ~
BASHRC
    fi

    chown "${USERNAME}:${USERNAME}" \
        "/home/${USERNAME}/.bashrc" \
        "/home/${USERNAME}/.sudo_as_admin_successful"

    info "User '$USERNAME' created"
fi

# ─── 7. Répertoire build ──────────────────────────────────────────────────────
info "Creating /home/builder (build workspace, VHDX)"
mkdir -p /home/builder
chown "${USERNAME}:${USERNAME}" /home/builder
chmod 755 /home/builder

# ─── 8. Permissions SSH ───────────────────────────────────────────────────────
if [ -d "/home/${USERNAME}/.ssh" ]; then
    chmod 700 "/home/${USERNAME}/.ssh"
    find "/home/${USERNAME}/.ssh" -type f -name "*.pub"                             -exec chmod 644 {} \;
    find "/home/${USERNAME}/.ssh" -type f ! -name "*.pub" ! -name "authorized_keys" -exec chmod 400 {} \;
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh"
fi

# ─── 9. Linger ────────────────────────────────────────────────────────────────
if systemctl is-system-running &>/dev/null; then
    info "Enabling linger for '$USERNAME'"
    loginctl enable-linger "$USERNAME"
    systemctl daemon-reload
else
    warn "systemd not active yet — linger will be effective after restart"
fi

# ─── 10. wsl.conf — écrit EN DERNIER ─────────────────────────────────────────
info "Writing /etc/wsl.conf"
cat > /etc/wsl.conf <<EOF
[network]
hostname=${WSL_HOSTNAME}
generateResolvConf=true

[user]
default=${USERNAME}

[interop]
enabled=true
appendWindowsPath=false

[automount]
enabled=false
mountFsTab=true

[boot]
systemd=true
EOF

echo "$WSL_HOSTNAME" > /etc/hostname
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${WSL_HOSTNAME}/" /etc/hosts
else
    printf "127.0.1.1\t%s\n" "$WSL_HOSTNAME" >> /etc/hosts
fi

# ─── 11. fstab ────────────────────────────────────────────────────────────────
info "Writing /etc/fstab (drvfs mounts)"

# Home persistant
if grep -q "/home/${USERNAME}" /etc/fstab 2>/dev/null; then
    warn "fstab: /home/${USERNAME} already present — skipping"
else
    mkdir -p "/home/${USERNAME}"
    printf '%s\t/home/%s\tdrvfs\tuid=1000,gid=1000,metadata,umask=22,fmask=11,noatime\t0\t0\n' \
        "$WIN_HOME" "$USERNAME" >> /etc/fstab
    info "fstab: home mount added"
fi

# Commons — partagé entre toutes les instances
if grep -q "/home/commons" /etc/fstab 2>/dev/null; then
    warn "fstab: /home/commons already present — skipping"
else
    mkdir -p /home/commons
    printf '%s\t/home/commons\tdrvfs\tuid=1000,gid=1000,metadata,umask=22,fmask=11,noatime\t0\t0\n' \
        "$WIN_COMMONS" >> /etc/fstab
    info "fstab: /home/commons mount added ($WIN_COMMONS)"
fi

# Private — config personnelle non versionnée (git identity, secrets locaux)
# Uniquement pour les instances qui font des commits ou gèrent des secrets.
# builder et qualifier : pas de commits, pas d'accès aux secrets.
if [[ "$INSTANCE_TYPE" == "starfleet" || "$INSTANCE_TYPE" == "engineer" || "$INSTANCE_TYPE" == "dev" ]]; then
    if grep -q "/home/private" /etc/fstab 2>/dev/null; then
        warn "fstab: /home/private already present — skipping"
    else
        mkdir -p /home/private
        printf '%s\t/home/private\tdrvfs\tuid=1000,gid=1000,metadata,umask=22,fmask=11,noatime\t0\t0\n' \
            "$WIN_PRIVATE" >> /etc/fstab
        info "fstab: /home/private mount added ($WIN_PRIVATE)"
    fi
else
    info "fstab: /home/private skipped (instance type '$INSTANCE_TYPE' has no secret access)"
fi

# WSL root — starfleet + engineer : vue globale de l'archi WSL
if [[ "$INSTANCE_TYPE" == "starfleet" || "$INSTANCE_TYPE" == "engineer" ]]; then
    if grep -q "/home/wsl-root" /etc/fstab 2>/dev/null; then
        warn "fstab: /home/wsl-root already present — skipping"
    else
        mkdir -p /home/wsl-root
        printf '%s\t/home/wsl-root\tdrvfs\tuid=1000,gid=1000,metadata,umask=22,fmask=11,noatime\t0\t0\n' \
            "$WIN_ROOT" >> /etc/fstab
        info "fstab: /home/wsl-root mount added ($WIN_ROOT)"
    fi
fi

# NOTE: pas de mount drvfs pour ~/.lcars — post-install.sh clone depuis GitHub.

# ─── 12. Migration dotfiles vers le home Windows ─────────────────────────────
info "Migrating dotfiles to Windows home"
if [ -d "/home/${USERNAME}" ] && [ -d "$WIN_HOME_MNT" ]; then
    rsync -a --exclude=".ssh" "/home/${USERNAME}/" "$WIN_HOME_MNT/"
    info "Dotfiles migrated to $WIN_HOME_MNT"
else
    warn "Could not migrate dotfiles — $WIN_HOME_MNT not accessible"
fi

# ─── 13. Écriture du type d'instance ─────────────────────────────────────────
# Utilisé par post-install.sh pour charger le bon module.
echo "$INSTANCE_TYPE" > "${WIN_HOME_MNT}/.wsl-instance-type"
info "Instance type written: $INSTANCE_TYPE"

# ─── 14. Autorun premier boot — post-install.sh ───────────────────────────────
# Injecte dans .bashrc un bloc one-shot gardé par fichier flag.
# Plus robuste que sed sur le contenu du bloc lui-même.
BASHRC_TARGET="${WIN_HOME_MNT}/.bashrc"

if ! grep -q "First boot: post-install" "$BASHRC_TARGET" 2>/dev/null; then
    cat >> "$BASHRC_TARGET" <<'AUTORUN'

# ── First boot: post-install ────────────────────────────────────────────────
if [ ! -f "$HOME/.post-install-done" ]; then
    _POST_SCRIPT="$HOME/.lcars/fleet/provisioning/wsl2/post-install.sh"
    if [ -f "$_POST_SCRIPT" ]; then
        echo "[post-install] Running..."
        bash "$_POST_SCRIPT" && touch "$HOME/.post-install-done" && \
            echo "[post-install] Done."
    else
        echo "[post-install] Script not found at $_POST_SCRIPT — run manually"
    fi
    unset _POST_SCRIPT
fi
AUTORUN
    info "Autorun injected in .bashrc (one-shot via flag file)"
fi

# ─── 15. Summary ──────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Setup complete — instance: ${WSL_HOSTNAME}"
echo "  User          : $USERNAME"
echo "  Instance type : $INSTANCE_TYPE"
echo "  Build dir     : /home/builder (VHDX)"
echo "  Home          : /home/$USERNAME -> #2_Home/${WSL_HOSTNAME} (drvfs, fstab)"
echo "  Commons       : /home/commons -> #3_Commons (drvfs, fstab)"
echo "  Private       : /home/private -> #4_Private (drvfs, fstab)"
[[ "$INSTANCE_TYPE" == "starfleet" || "$INSTANCE_TYPE" == "engineer" ]] && \
echo "  WSL root      : /home/wsl-root -> WSL/ (drvfs, fstab)"
echo "  automount     : disabled (effectif après restart)"
echo "  claude-dir    : ~/.lcars (cloné depuis GitHub par post-install.sh au premier boot)"
echo "  post-install  : ~/.bashrc one-shot → ~/.lcars/fleet/provisioning/wsl2/post-install.sh"
echo ""
warn "Restart depuis PowerShell pour appliquer wsl.conf :"
echo "  wsl --terminate ${WSL_HOSTNAME}"
echo "  # Ouvrir un nouvel onglet Windows Terminal"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
