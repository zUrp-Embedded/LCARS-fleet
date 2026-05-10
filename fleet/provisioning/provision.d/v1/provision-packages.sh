#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-packages.sh
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
#     | MODULE: PROVISION-PACKAGES| SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Install apt packages + yq binary.                        |
#     |  Sourced by provision-system.sh. IDIC-compliant (x86_64/aarch64).|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-packages.sh — apt packages + yq binary
#     Sourced by provision-system.sh — uses globals: CHECK, _SYSTEM_YAML
#
#     --- Packages ---
#
#     [EN]
#     provision-packages.sh — Install apt packages + yq binary.
#     Sourced by provision-system.sh. IDIC-compliant (x86_64/aarch64).
#
#
# --- END HEADER ---

PACKAGES=(tmux btop jq git curl expect python3-venv python3-rich gh acl)

echo ""
echo "=== Packages ==="
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        pass "package:$pkg"
    else
        MISSING+=("$pkg")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    if [[ $CHECK -eq 1 ]]; then
        for pkg in "${MISSING[@]}"; do fail "package:$pkg — missing"; done
    else
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y -qq "${MISSING[@]}" > /dev/null 2>&1
        for pkg in "${MISSING[@]}"; do
            if dpkg -s "$pkg" &>/dev/null; then
                pass "package:$pkg — installed"
            else
                fail "package:$pkg — install failed"
            fi
        done
    fi
fi

# --- yq (static binary) ---
echo ""
echo "=== yq ==="
YQ_VERSION="$(grep 'yq_version:' "$_SYSTEM_YAML" 2>/dev/null | awk '{print $2}' | tr -d '"')"
: "${YQ_VERSION:=v4.52.4}"
if command -v yq &>/dev/null && yq --version 2>/dev/null | grep -q "$YQ_VERSION"; then
    pass "yq:$(command -v yq) ($YQ_VERSION)"
elif [[ $CHECK -eq 1 ]]; then
    fail "yq:/usr/local/bin/yq — missing or wrong version"
else
    case "$(uname -m)" in
        x86_64)  YQ_ARCH="amd64" ;;
        aarch64) YQ_ARCH="arm64" ;;
        *)       fail "yq:unsupported arch $(uname -m)"; YQ_ARCH="" ;;
    esac
    if [ -n "$YQ_ARCH" ]; then
        curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
            -o /usr/local/bin/yq && chmod 755 /usr/local/bin/yq
        if command -v yq &>/dev/null; then
            pass "yq:/usr/local/bin/yq — installed ($YQ_VERSION)"
        else
            fail "yq:/usr/local/bin/yq — install failed"
        fi
    fi
fi
