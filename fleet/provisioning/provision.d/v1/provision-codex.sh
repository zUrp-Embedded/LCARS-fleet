#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-codex.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v7.0
#     |  |  v7.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: PROVISION-CODEX   | SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3           | STARDATE: 2026.092              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Provision Codex external agent: user, CLI, home, IPC.    |
#     |  Self-contained. Sourced by provision-system.sh.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-codex.sh — provisioning Codex (agent externe)
#     Sourced by provision-system.sh — uses globals: CHECK, FLEET_USER,
#       FLEET_GROUP, HOMES_ROOT, check_or_do, pass, fail, warn
#
#     [EN]
#     provision-codex.sh — Provision Codex external agent.
#     Creates user, installs CLI, sets up home structure, IPC bridge,
#     and filesystem permissions with OS-level constraints.
#
# --- END HEADER ---

echo ""
echo "=== Codex (external agent) ==="

# --- Opt-in prompt (skip in --check mode) ---
if [[ $CHECK -eq 0 ]]; then
    echo -n "Install Codex external agent? [Y/n] (5s timeout) "
    read -t 5 -r _codex_answer || _codex_answer=""
    _codex_answer="${_codex_answer:-y}"
    if [[ "${_codex_answer,,}" == "n" ]]; then
        warn "codex:skipped by user"
        return 0
    fi
fi

# --- Group: external ---
check_or_do "group:external" \
    "getent group external >/dev/null 2>&1" \
    "groupadd external"

# --- System owner: lordzurp reads everything (fleet + external) ---
check_or_do "lordzurp:group:external" \
    "id -nG lordzurp 2>/dev/null | grep -qw external" \
    "usermod -aG external lordzurp"

# --- User: codex (primary group external, no fleet membership) ---
check_or_do "user:codex" \
    "id codex >/dev/null 2>&1" \
    "useradd -m -s /bin/bash -g external codex"

# Ensure correct groups if user already exists
if id codex >/dev/null 2>&1; then
    _codex_primary="$(id -gn codex 2>/dev/null)"
    if [[ "$_codex_primary" != "external" ]]; then
        usermod -g external codex
        pass "user:codex — primary group → external"
    fi
    # codex must NOT be in fleet group — external isolation
    if id -nG codex 2>/dev/null | grep -qw "$FLEET_GROUP"; then
        gpasswd -d codex "$FLEET_GROUP" 2>/dev/null
        pass "user:codex — removed from $FLEET_GROUP (external isolation)"
    fi
fi

# --- Codex CLI (npm) ---
echo ""
echo "=== Codex CLI ==="
check_or_do "codex-cli:/usr/local/bin/codex" \
    "command -v codex >/dev/null 2>&1" \
    "npm install -g @openai/codex 2>&1 | tail -1"

# --- Home structure ---
echo ""
echo "=== Codex home ==="
_codex_home="$HOMES_ROOT/codex"

for _dir in "$_codex_home/.codex" "$_codex_home/livrables" "$_codex_home/audits"; do
    check_or_do "dir:$_dir" "[ -d $_dir ]" "sudo -u codex mkdir -p $_dir"
done

# .hushlogin
check_or_do "hushlogin:codex" \
    "[ -f $_codex_home/.hushlogin ]" \
    "touch $_codex_home/.hushlogin && chown codex:external $_codex_home/.hushlogin"

# .gitconfig
if [[ $CHECK -eq 0 ]]; then
    cat > "$_codex_home/.gitconfig" <<'GITCFG'
[safe]
	directory = /home/projects/LCARS
	directory = /home/projects/LCARS/.git
GITCFG
    chown codex:external "$_codex_home/.gitconfig"
    pass "codex:.gitconfig"
fi

# --- Deploy config from repo (immutable: starfleet-owned) ---
echo ""
echo "=== Codex config ==="
_config_src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../external-agents/codex"
if [ -d "$_config_src" ]; then
    for _f in AGENTS.md config.toml; do
        if [ -f "$_config_src/$_f" ]; then
            cp "$_config_src/$_f" "$_codex_home/.codex/$_f"
            chown "$FLEET_USER:$FLEET_GROUP" "$_codex_home/.codex/$_f"
            chmod 644 "$_codex_home/.codex/$_f"
            pass "codex:config:$_f → immutable ($FLEET_USER-owned)"
        fi
    done
fi

# --- Home permissions ---
echo ""
echo "=== Codex permissions ==="
if [[ $CHECK -eq 0 ]]; then
    chown codex:external "$_codex_home"
    chmod 750 "$_codex_home"
    # .codex dir: codex owns for runtime files (logs, sqlite, sessions)
    chown codex:external "$_codex_home/.codex"
    chmod 750 "$_codex_home/.codex"
    # livrables + audits: codex owns, fleet reads via ACL
    for _dir in "$_codex_home/livrables" "$_codex_home/audits"; do
        chown codex:external "$_dir"
        chmod 750 "$_dir"
    done
    # ACL: fleet traverse home
    setfacl -m g:$FLEET_GROUP:--x "$_codex_home"
    # ACL: fleet read livrables + audits (recursive + default)
    for _dir in "$_codex_home/livrables" "$_codex_home/audits"; do
        setfacl -R -m g:$FLEET_GROUP:rX "$_dir"
        setfacl -R -d -m g:$FLEET_GROUP:rX "$_dir"
    done
    pass "perms:codex home → 750 codex:external, fleet ACL on outputs"
fi

# --- IPC bridge: /home/commons/codex/ ---
echo ""
echo "=== Codex IPC bridge ==="
_bridge="$HOMES_ROOT/commons/codex"
check_or_do "dir:$_bridge" "[ -d $_bridge ]" "mkdir -p $_bridge"

if [[ $CHECK -eq 0 ]]; then
    # Bridge owned by fleet_user, group fleet, setgid
    chown "$FLEET_USER:$FLEET_GROUP" "$_bridge"
    chmod 2770 "$_bridge"
    # Codex writes via user ACL (dir + all existing files)
    setfacl -m u:codex:rwx "$_bridge"
    setfacl -R -m u:codex:rw "$_bridge" 2>/dev/null || true
    setfacl -d -m u:codex:rw- "$_bridge"
    # Codex needs to traverse /home/commons/ (which is 2770 fleet)
    setfacl -m u:codex:--x "$HOMES_ROOT/commons"
    pass "perms:codex IPC bridge → $FLEET_USER:$FLEET_GROUP 2770, codex ACL"
fi

# --- ACL: /home/projects/ readable by external group ---
echo ""
echo "=== Codex project access ==="
if [[ $CHECK -eq 0 ]] && [ -d "$HOMES_ROOT/projects" ]; then
    setfacl -R -m g:external:rX "$HOMES_ROOT/projects"
    setfacl -R -d -m g:external:rX "$HOMES_ROOT/projects"
    pass "perms:/home/projects/ → g:external:rX (ACL)"
fi

# --- ACL deny: block codex from system dirs ---
echo ""
echo "=== Codex system isolation ==="
if [[ $CHECK -eq 0 ]]; then
    # System dirs: full deny (codex has no business outside /home)
    # /etc left open — shell bootstrap needs it, and we're in a VM anyway
    for _sysdir in /var /run /boot /srv /opt /usr/local/bin; do
        setfacl -m u:codex:--- "$_sysdir" 2>/dev/null || true
    done
    pass "perms:codex system isolation → ACL deny on /var /run /boot /srv /opt"
fi
