#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-claude-bin.sh
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
#     | MODULE: PROVISION-CLAUDE| SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Install Claude Code CLI binary to /usr/local/bin/.       |
#     |  Sourced by provision-system.sh. Downloads via install.sh.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-claude-bin.sh — Claude Code binary install
#     Sourced by provision-system.sh — uses globals: CHECK, _SYSTEM_YAML
#
#     [EN]
#     provision-claude-bin.sh — Install Claude Code CLI binary to /usr/local/bin/.
#     Sourced by provision-system.sh. Downloads via install.sh.
#
#
# --- END HEADER ---

echo ""
echo "=== Claude Code ==="
if [ -x /usr/local/bin/claude ] && ! [ -L /usr/local/bin/claude ]; then
    pass "claude:/usr/local/bin/claude"
elif [[ $CHECK -eq 1 ]]; then
    fail "claude:/usr/local/bin/claude — not installed"
else
    rm -f /usr/local/bin/claude 2>/dev/null || true
    INSTALL_TMP="$(mktemp -d /tmp/claude-install-XXXXXX)"
    CLAUDE_INSTALL_URL="$(grep 'claude_install_url:' "$_SYSTEM_YAML" 2>/dev/null | awk '{print $2}' | tr -d '"')"
    : "${CLAUDE_INSTALL_URL:=https://claude.ai/install.sh}"
    curl -fsSL "$CLAUDE_INSTALL_URL" -o "$INSTALL_TMP/install.sh"
    HOME="$INSTALL_TMP" bash "$INSTALL_TMP/install.sh" stable
    CLAUDE_BIN=""
    for candidate in "$INSTALL_TMP/.local/bin/claude" "$INSTALL_TMP/.claude/local/claude"; do
        [ -x "$candidate" ] && CLAUDE_BIN="$candidate" && break
    done
    if [ -n "$CLAUDE_BIN" ]; then
        cp "$(readlink -f "$CLAUDE_BIN")" /usr/local/bin/claude
        chmod 755 /usr/local/bin/claude
        rm -rf "$INSTALL_TMP"
        pass "claude:/usr/local/bin/claude — installed"
    else
        rm -rf "$INSTALL_TMP"
        fail "claude:/usr/local/bin/claude — install failed"
    fi
fi
