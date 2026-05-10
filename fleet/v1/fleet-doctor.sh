#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-doctor.sh
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
#     | MODULE: FLEET-DOCTOR    | SUBSYSTEM: FLEET / DIAG         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Automated fleet environment diagnostic.                  |
#     |  Checks instances, mounts, handoffs, claude, fleet-hub.   |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#     NOTE: This script depends on GNU coreutils (stat, date, find flags, etc.).
#           It is not portable to BSD/macOS without adaptation.
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#
#     [EN]
#     fleet-doctor.sh — Automated fleet environment diagnostic.
#     Checks instances, mounts, handoffs, claude, fleet-hub.
#
#
# --- END HEADER ---



# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -uo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/fleet-env.sh"

SECTION="${2:-all}"
[[ "${1:-}" == "--section" ]] && SECTION="${2:-all}"

FAIL_COUNT=0
WARN_COUNT=0
OK_COUNT=0
TOTAL=0

_pass() { echo "[OK]   $*"; OK_COUNT=$((OK_COUNT + 1)); TOTAL=$((TOTAL + 1)); }
_fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL=$((TOTAL + 1)); }
_warn() { echo "[WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); TOTAL=$((TOTAL + 1)); }
run_section() { [[ "$SECTION" == "all" || "$SECTION" == "$1" ]]; }

# Build effective roles — skip non-provisioned (user missing)
EFFECTIVE_ROLES=()
while IFS= read -r _r; do
    _lu=$(fleet_role_field "$_r" "linux_user" 2>/dev/null)
    [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$_r"
    if id "$_lu" > /dev/null 2>&1; then
        EFFECTIVE_ROLES+=("$_r")
    fi
done < <(fleet_roles)

# Resolve boundary-os role from blueprint (pattern #9 fix: no hardcoded "starfleet")
BOUNDARY_OS=$(yq '.instances[] | select(.scope == "boundary-os") | .role' "$FLEET_YAML" 2>/dev/null | head -1)
[[ -z "$BOUNDARY_OS" || "$BOUNDARY_OS" == "null" ]] && BOUNDARY_OS="starfleet"

echo ""
echo "=== LCARS Fleet Doctor ==="


# ─── Section 0 — Prerequisites ────────────────────────────────────────────────
if run_section 0; then
echo ""
echo "=== 0 — Prerequisites ==="
# 0.1 yq
command -v yq >/dev/null 2>&1 \
    && _pass "yq: $(yq --version 2>/dev/null | head -1)" \
    || _fail "yq: missing (required)"
# 0.2 jq
command -v jq >/dev/null 2>&1 && _pass "jq" || _fail "jq: missing (required)"
# 0.3 python3
command -v python3 >/dev/null 2>&1 && _pass "python3" || _warn "python3: missing"
# 0.4 claude CLI
command -v claude >/dev/null 2>&1 \
    && _pass "claude: $(claude --version 2>/dev/null | head -1)" \
    || _fail "claude: CLI missing (required)"
# 0.5 CC version vs SP Anthropic origin
_CC_VER=$(claude --version 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+')
_SP_VER=$(basename "$LCARS_ROOT/fleet/system-prompt/anthropic-origin-"*.md 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
if [ -n "$_CC_VER" ] && [ -n "$_SP_VER" ]; then
    [[ "$_CC_VER" == "$_SP_VER" ]] \
        && _pass "cc-vs-sp: CC $_CC_VER = SP $_SP_VER" \
        || _warn "cc-vs-sp: CC $_CC_VER ≠ SP origin $_SP_VER"
fi
# 0.6 fleet.yaml readable
if [ -f "$FLEET_YAML" ] && yq '.' "$FLEET_YAML" >/dev/null 2>&1; then
    _pass "fleet.yaml: readable ($FLEET_YAML)"
else
    _fail "fleet.yaml: not readable ($FLEET_YAML)"
fi
fi


# ─── Section 1 — Users & Groups ───────────────────────────────────────────────
if run_section 1; then
echo ""
echo "=== 1 — Users & Groups ==="
getent group fleet > /dev/null 2>&1 && _pass "group:fleet" || _fail "group:fleet missing"
# 1.1 User exists (WARN for non-provisioned roles, not FAIL)
while IFS= read -r role; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    if id "$lu" > /dev/null 2>&1; then
        _pass "user:$lu"
    else
        _warn "user:$lu not provisioned"
    fi
done < <(fleet_roles)
# 1.2-1.4 Detailed checks on provisioned roles only
for role in "${EFFECTIVE_ROLES[@]}"; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    # 1.2 In fleet group
    id -nG "$lu" 2>/dev/null | tr ' ' '\n' | grep -qx "fleet" \
        && _pass "fleet-member:$lu" \
        || _warn "fleet-member:$lu not in fleet group"
    # 1.3 Home exists + mode 750
    AGENT_HOME="$HOMES_ROOT/$lu"
    if [ -d "$AGENT_HOME" ]; then
        _M=$(stat -c '%a' "$AGENT_HOME" 2>/dev/null)
        [[ "$_M" == "750" ]] && _pass "home-mode:$lu (750)" || _warn "home-mode:$lu (mode=$_M, expected 750)"
    else
        _fail "home:$lu missing"
    fi
    # 1.4 Primary group correct
    _PG=$(id -gn "$lu" 2>/dev/null)
    [[ "$_PG" == "$lu" ]] && _pass "primary-group:$lu" || _warn "primary-group:$lu (primary=$_PG, expected $lu)"
done
fi


# ─── Section 2 — Permissions ──────────────────────────────────────────────────
if run_section 2; then
echo ""
echo "=== 2 — Permissions ==="
# 2.1 /home/commons/ mode 2770 owner lordzurp group fleet
if [ -d "/home/commons" ]; then
    _M=$(stat -c '%a' "/home/commons" 2>/dev/null)
    _O=$(stat -c '%U' "/home/commons" 2>/dev/null)
    [[ "$_M" == "2770" && "$_O" == "$FLEET_USER" ]] \
        && _pass "commons: mode 2770 owner $FLEET_USER" \
        || _fail "commons: mode=$_M owner=$_O (expected 2770 $FLEET_USER)"
else
    _fail "commons: /home/commons missing"
fi
# 2.2 /home/private/ mode 700 owner lordzurp
if [ -d "/home/private" ]; then
    _M=$(stat -c '%a' "/home/private" 2>/dev/null)
    _O=$(stat -c '%U' "/home/private" 2>/dev/null)
    [[ "$_M" == "700" && "$_O" == "$FLEET_USER" ]] \
        && _pass "private: mode 700 owner $FLEET_USER" \
        || _warn "private: mode=$_M owner=$_O (expected 700 $FLEET_USER)"
else
    _warn "private: /home/private missing"
fi
# 2.3 /home/tmp/ mode 2770 owner lordzurp group fleet
if [ -d "/home/tmp" ]; then
    _M=$(stat -c '%a' "/home/tmp" 2>/dev/null)
    _O=$(stat -c '%U' "/home/tmp" 2>/dev/null)
    [[ "$_M" == "2770" && "$_O" == "$FLEET_USER" ]] \
        && _pass "tmp: mode 2770 owner $FLEET_USER" \
        || _warn "tmp: mode=$_M owner=$_O (expected 2770 $FLEET_USER)"
else
    _warn "tmp: /home/tmp missing"
fi
# 2.4 /var/spool/fleet/ mode 770 group fleet
if [ -d "$FLEET_SPOOL" ]; then
    _M=$(stat -c '%a' "$FLEET_SPOOL" 2>/dev/null)
    _G=$(stat -c '%G' "$FLEET_SPOOL" 2>/dev/null)
    [[ "$_M" == "770" && "$_G" == "fleet" ]] \
        && _pass "spool: mode 770 group fleet" \
        || _fail "spool: mode=$_M group=$_G (expected 770 fleet)"
else
    _fail "spool: $FLEET_SPOOL missing"
fi
# 2.5 /local/LCARS/ owner starfleet group fleet
if [ -d "$LCARS_ROOT" ]; then
    _O=$(stat -c '%U' "$LCARS_ROOT" 2>/dev/null)
    _G=$(stat -c '%G' "$LCARS_ROOT" 2>/dev/null)
    [[ "$_O" == "$BOUNDARY_OS" && "$_G" == "fleet" ]] \
        && _pass "lcars-root: owner $BOUNDARY_OS group fleet" \
        || _fail "lcars-root: owner=$_O group=$_G (expected $BOUNDARY_OS fleet)"
else
    _fail "lcars-root: $LCARS_ROOT missing"
fi
# Per-role permission checks
for role in "${EFFECTIVE_ROLES[@]}"; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    AGENT_HOME="$HOMES_ROOT/$lu"
    # 2.6 Handoff owned by agent
    HF="$FLEET_HANDOFFS/$lu-handoff.md"
    if [ -f "$HF" ]; then
        _HO=$(stat -c '%U' "$HF" 2>/dev/null)
        [[ "$_HO" == "$lu" || "$_HO" == "root" || "$_HO" == "$BOUNDARY_OS" ]] \
            && _pass "handoff-owner:$lu ($lu-handoff.md)" \
            || _warn "handoff-owner:$lu (owner=$_HO, expected $lu)"
    fi
    # 2.8 ~/.claude/CLAUDE.md owned root mode 664
    CM="$AGENT_HOME/.claude/CLAUDE.md"
    if [ -f "$CM" ]; then
        _CO=$(stat -c '%U' "$CM" 2>/dev/null)
        _CM=$(stat -c '%a' "$CM" 2>/dev/null)
        [[ "$_CO" == "root" && "$_CM" == "664" ]] \
            && _pass "claude-md-perm:$lu (root 664)" \
            || _warn "claude-md-perm:$lu (owner=$_CO mode=$_CM, expected root 664)"
    fi
    # 2.9 ~/.claude/hooks/*.sh mode 775
    HOOKS_DIR="$AGENT_HOME/.claude/hooks"
    if [ -d "$HOOKS_DIR" ]; then
        while IFS= read -r h; do
            _HM=$(stat -c '%a' "$h" 2>/dev/null)
            [[ "$_HM" == "775" ]] \
                && _pass "hook-mode:$lu/$(basename "$h")" \
                || _warn "hook-mode:$lu/$(basename "$h") (mode=$_HM, expected 775)"
        done < <(find "$HOOKS_DIR" -name "*.sh" 2>/dev/null)
    fi
    # 2.10 ~/.claude/.credentials.json mode 600
    CRED="$AGENT_HOME/.claude/.credentials.json"
    if [ -f "$CRED" ]; then
        _CM=$(stat -c '%a' "$CRED" 2>/dev/null)
        [[ "$_CM" == "600" ]] \
            && _pass "credentials-mode:$lu (600)" \
            || _fail "credentials-mode:$lu (mode=$_CM, expected 600)"
    fi
done
# 2.7 fleet-state.log not world-writable
LOG="$FLEET_STATE_DIR/fleet-state.log"
if [ -f "$LOG" ]; then
    find "$LOG" -perm /o+w 2>/dev/null | grep -q . \
        && _warn "state-log: world-writable ($LOG)" \
        || _pass "state-log: not world-writable"
fi
fi


# ─── Section 3 — Symlinks ─────────────────────────────────────────────────────
if run_section 3; then
echo ""
echo "=== 3 — Symlinks ==="
for role in "${EFFECTIVE_ROLES[@]}"; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    AGENT_HOME="$HOMES_ROOT/$lu"
    # 3.1 ~/.lcars → /local/LCARS
    SL="$AGENT_HOME/.lcars"
    if [ -L "$SL" ]; then
        _TGT=$(readlink -f "$SL" 2>/dev/null)
        [[ "$_TGT" == "$LCARS_ROOT" ]] \
            && _pass "lcars-link:$lu" \
            || _warn "lcars-link:$lu wrong target ($_TGT, expected $LCARS_ROOT)"
    elif [ -e "$SL" ]; then
        _warn "lcars-link:$lu not a symlink"
    else
        _warn "lcars-link:$lu missing"
    fi
    # 3.2 ~/directives → /local/LCARS/directives
    SL="$AGENT_HOME/directives"
    EXPECTED="$LCARS_ROOT/directives"
    if [ -L "$SL" ]; then
        _TGT=$(readlink -f "$SL" 2>/dev/null)
        [[ "$_TGT" == "$EXPECTED" ]] \
            && _pass "directives-link:$lu" \
            || _warn "directives-link:$lu wrong target ($_TGT)"
    elif [ -e "$SL" ]; then
        _warn "directives-link:$lu not a symlink"
    else
        _warn "directives-link:$lu missing"
    fi
    # 3.3 role.md — removed in v6.0 (role injected via SP-custom, no symlink needed)
    # 3.4 ~/L2 → knowledge domain (if symlink exists, verify it's not broken)
    SL="$AGENT_HOME/L2"
    if [ -L "$SL" ]; then
        _TGT=$(readlink -f "$SL" 2>/dev/null)
        if [ -n "$_TGT" ] && [ -d "$_TGT" ]; then
            _pass "l2:$lu → $( readlink "$SL")"
        else
            _warn "l2:$lu broken symlink ($(readlink "$SL"))"
        fi
    fi
done
fi


# ─── Section 4 — Deploy State ─────────────────────────────────────────────────
if run_section 4; then
echo ""
echo "=== 4 — Deploy State ==="
# Determine expected deployed scripts (tagged DEPLOY: instance-util)
EXPECTED_SCRIPTS=$(grep -rl "DEPLOY: instance-util" "$LCARS_ROOT/fleet/" 2>/dev/null | xargs -r -I{} basename {} | sort)
for role in "${EFFECTIVE_ROLES[@]}"; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    AGENT_HOME="$HOMES_ROOT/$lu"
    # 4.1 CLAUDE.md exists (deploy.sh customizes per role — no md5 comparison)
    DEP="$AGENT_HOME/.claude/CLAUDE.md"
    [ -f "$DEP" ] \
        && _pass "claude-md:$lu present" \
        || _fail "claude-md:$lu CLAUDE.md missing"
    # 4.2 Hooks deployed in ~/.claude/hooks/
    HOOKS_DIR="$AGENT_HOME/.claude/hooks"
    if [ -d "$HOOKS_DIR" ]; then
        _NH=$(find "$HOOKS_DIR" -name "*.sh" 2>/dev/null | wc -l)
        [[ "$_NH" -gt 0 ]] \
            && _pass "hooks-deployed:$lu ($_NH hooks)" \
            || _warn "hooks-deployed:$lu no hooks found"
    else
        _fail "hooks-deployed:$lu $HOOKS_DIR missing"
    fi
    # 4.3 Scripts fleet dans ~/.local/bin/
    BIN_DIR="$AGENT_HOME/.local/bin"
    if [ -d "$BIN_DIR" ]; then
        _NB=$(ls "$BIN_DIR" 2>/dev/null | wc -l)
        [[ "$_NB" -gt 0 ]] \
            && _pass "bin-scripts:$lu ($_NB scripts)" \
            || _warn "bin-scripts:$lu $BIN_DIR empty"
        # Check critical scripts
        for _s in fleet-send.sh fleet-inbox-read.sh fleet-env.sh fleet-doctor.sh; do
            [ -f "$BIN_DIR/$_s" ] && _pass "bin:$lu/$_s" || _warn "bin:$lu/$_s missing"
        done
    else
        _warn "bin-scripts:$lu $BIN_DIR missing"
    fi
    # 4.4 instance-name present and correct
    INAME_FILE="$AGENT_HOME/.claude/instance-name"
    if [ -f "$INAME_FILE" ]; then
        _INAME=$(cat "$INAME_FILE" 2>/dev/null | tr -d '[:space:]')
        [[ "$_INAME" == "$role" || "$_INAME" == "$lu" ]] \
            && _pass "instance-name:$lu ($_INAME)" \
            || _warn "instance-name:$lu ($_INAME, expected $role)"
    else
        _warn "instance-name:$lu missing"
    fi
    # 4.5 settings.local.json contains hooks
    SLJ="$AGENT_HOME/.claude/settings.local.json"
    if [ -f "$SLJ" ]; then
        _NHK=$(jq '.hooks // {} | to_entries | length' "$SLJ" 2>/dev/null)
        [[ "${_NHK:-0}" -gt 0 ]] \
            && _pass "hooks-registered:$lu ($_NHK event type(s))" \
            || _warn "hooks-registered:$lu no hooks in settings.local.json"
    else
        _warn "hooks-registered:$lu settings.local.json missing"
    fi
    # hooks wiring: commands in settings.local.json point to existing files
    if [ -f "$SLJ" ]; then
        grep -Eo '"command"\s*:\s*"[^"]+"' "$SLJ" 2>/dev/null | sed 's/.*"command"\s*:\s*"//; s/"$//' | grep '\.sh' | while IFS= read -r cmd; do
            _sp=$(echo "$cmd" | sed 's/^bash //' | sed 's/^sh //' | awk '{print $1}')
            _sp="${_sp/\$HOME/$AGENT_HOME}"
            [ -z "$_sp" ] && continue
            [ -f "$_sp" ] \
                && _pass "hook-wired:$lu/$(basename "$_sp")" \
                || _fail "hook-wired:$lu/$(basename "$_sp") missing ($_sp)"
        done
    fi
done
# Supplementary: LCARS source scripts syntax + shebangs
while IFS= read -r s; do
    bash -n "$s" 2>/dev/null \
        && _pass "syntax:$(basename "$s")" \
        || _fail "syntax:$(basename "$s")"
done < <(find "$LCARS_ROOT/fleet" -name "*.sh" -not -path "*/_archived/*" 2>/dev/null)
while IFS= read -r s; do
    bash -n "$s" 2>/dev/null \
        && _pass "syntax:hooks/$(basename "$s")" \
        || _fail "syntax:hooks/$(basename "$s")"
done < <(find "$LCARS_ROOT/.claude/hooks" -name "*.sh" 2>/dev/null)
# Shebangs
while IFS= read -r s; do
    _sb=$(head -1 "$s")
    case "$_sb" in
        "#!/bin/bash"|"#!/usr/bin/env bash"|"#!/bin/sh"|"#!/usr/bin/env sh")
            _pass "shebang:$(basename "$s")" ;;
        *)
            _fail "shebang:$(basename "$s") — $_sb" ;;
    esac
done < <(find "$LCARS_ROOT/fleet" "$LCARS_ROOT/.claude/hooks" -name "*.sh" -not -path "*/_archived/*" 2>/dev/null)
# GO-7 headers on source scripts
while IFS= read -r s; do
    head -25 "$s" 2>/dev/null | grep -qEi "SOURCE:|AUTHOR:|STARDATE:" \
        && _pass "go7:$(basename "$s")" \
        || _warn "go7:$(basename "$s") missing header"
done < <(find "$LCARS_ROOT/fleet" -name "*.sh" -not -path "*/_archived/*" -not -path "*/git-hooks/*" 2>/dev/null)
# GO-7 on SP user sources (formerly directives/)
for _d in protocole.md protocole-user.md profile.md; do
    _f="$LCARS_ROOT/fleet/system-prompt/sources/user/$_d"
    [ -f "$_f" ] || continue
    _h=$(head -15 "$_f")
    if echo "$_h" | grep -qF "**Date**" || echo "$_h" | grep -qE "^\s+date:"; then
        _pass "go7:$_d"
    else
        _warn "go7:$_d missing date header"
    fi
done
# Skills SKILL.md
while IFS= read -r sd; do
    _sn=$(basename "$sd")
    [ -f "$sd/SKILL.md" ] && _pass "skill:$_sn" || _fail "skill:$_sn no SKILL.md"
done < <(find "$LCARS_ROOT/.claude/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi


# ─── Section 5 — Git ──────────────────────────────────────────────────────────
if run_section 5; then
echo ""
echo "=== 5 — Git ==="
LCARS_DEV="/home/projects/LCARS"
# 5.1 Clone dev exists
[ -d "$LCARS_DEV/.git" ] && _pass "git:dev clone ($LCARS_DEV)" || _fail "git:dev clone missing"
# 5.2 Clone runtime exists
[ -d "$LCARS_ROOT/.git" ] && _pass "git:runtime clone ($LCARS_ROOT)" || _fail "git:runtime clone missing"
# 5.3 Remote origin configured (×2)
if [ -d "$LCARS_DEV/.git" ]; then
    _REM=$(git -C "$LCARS_DEV" remote get-url origin 2>/dev/null)
    [ -n "$_REM" ] && _pass "git:dev remote origin ($_REM)" || _warn "git:dev no remote origin"
fi
if [ -d "$LCARS_ROOT/.git" ]; then
    _REM=$(git -C "$LCARS_ROOT" remote get-url origin 2>/dev/null)
    [ -n "$_REM" ] && _pass "git:runtime remote origin ($_REM)" || _warn "git:runtime no remote origin"
fi
# 5.4 No uncommitted changes on runtime
if [ -d "$LCARS_ROOT/.git" ]; then
    _DIRTY=$(git -C "$LCARS_ROOT" status --porcelain 2>/dev/null)
    [ -z "$_DIRTY" ] && _pass "git:runtime clean" || _warn "git:runtime has uncommitted changes"
fi
# 5.5 Runtime on main
if [ -d "$LCARS_ROOT/.git" ]; then
    _BR=$(git -C "$LCARS_ROOT" branch --show-current 2>/dev/null)
    [[ "$_BR" == "main" ]] && _pass "git:runtime on main" || _warn "git:runtime on '$_BR' (expected main)"
fi
# Supplementary: dev branch
if [ -d "$LCARS_DEV/.git" ]; then
    _BR=$(git -C "$LCARS_DEV" branch --show-current 2>/dev/null)
    [[ "$_BR" == "main" ]] && _pass "git:dev on main" || _fail "git:dev on '$_BR'"
    _REM=$(git -C "$LCARS_DEV" remote get-url origin 2>/dev/null)
    echo "$_REM" | grep -q "git@github.com" && _pass "git:SSH remote" || _warn "git:HTTPS remote (not SSH)"
fi
# LCARS repo pre-commit hook (fleet-managed repos only)
[ -f "$LCARS_DEV/.git/hooks/pre-commit" ] \
    && _pass "hooks:LCARS pre-commit" \
    || _warn "hooks:LCARS no pre-commit hook"
fi


# ─── Section 6 — IPC ──────────────────────────────────────────────────────────
if run_section 6; then
echo ""
echo "=== 6 — IPC ==="
# 6.1 Spool inbox exists + one dir per role
[ -d "$FLEET_SPOOL_INBOX" ] && _pass "spool:inbox dir exists" || _fail "spool:inbox missing"
for role in "${EFFECTIVE_ROLES[@]}"; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    [ -d "$FLEET_SPOOL_INBOX/$lu" ] \
        && _pass "spool:inbox/$lu" \
        || _fail "spool:inbox/$lu missing"
    # 6.2 .consumed/ per role
    [ -d "$FLEET_SPOOL_INBOX/$lu/.consumed" ] \
        && _pass "spool:.consumed/$lu" \
        || _warn "spool:.consumed/$lu missing"
done
# 6.3 Spool outbox
[ -d "$FLEET_SPOOL_OUTBOX" ] && _pass "spool:outbox" || _warn "spool:outbox missing"
# 6.4-6.7 Handoff files (stateful roles only)
while IFS= read -r role; do
    lu=$(fleet_role_field "$role" "linux_user" 2>/dev/null)
    [[ "$lu" == "null" || -z "$lu" ]] && lu="$role"
    HF="$FLEET_HANDOFFS/$lu-handoff.md"
    # 6.4 Handoff file exists
    if [ ! -f "$HF" ]; then
        _fail "handoff:$lu missing"
        continue
    fi
    _pass "handoff:$lu exists"
    # 6.5 Contains ## STATE
    grep -q "## STATE" "$HF" 2>/dev/null \
        && _pass "handoff-state:$lu has ## STATE" \
        || _warn "handoff-state:$lu missing ## STATE"
    # 6.6 STATE fields: action/status/date
    for _field in action status date; do
        grep -qi "^$_field:" "$HF" 2>/dev/null \
            && _pass "handoff-field:$lu/$_field" \
            || _warn "handoff-field:$lu/$_field missing"
    done
    # 6.7 Handoff UTF-8 (inline iconv — no side effects)
    if iconv -f utf-8 -t utf-8 < "$HF" > /dev/null 2>&1; then
        _pass "utf8:$lu handoff"
    else
        _warn "utf8:$lu handoff encoding issue"
    fi
done < <(fleet_roles_stateful | while IFS= read -r _sr; do
    for _er in "${EFFECTIVE_ROLES[@]}"; do
        [[ "$_sr" == "$_er" ]] && echo "$_sr" && break
    done
done)
# 6.8 Ready-room mounted and accessible
[ -d "$FLEET_READY_ROOM" ] && _pass "ready-room: accessible" || _warn "ready-room: $FLEET_READY_ROOM missing"
# 6.9 Ready-room inbox/outbox
for _sub in inbox outbox; do
    [ -d "$FLEET_READY_ROOM/$_sub" ] \
        && _pass "ready-room:$_sub" \
        || _warn "ready-room:$_sub missing"
done
# 6.10 fleet-send.sh in PATH
command -v fleet-send.sh >/dev/null 2>&1 \
    && _pass "ipc:fleet-send.sh in PATH" \
    || _warn "ipc:fleet-send.sh not in PATH"
# Supplementary: IPC sentinel wiring
_f="$LCARS_ROOT/fleet/fleet-wake-notify.sh"
[ -f "$_f" ] && grep -q "\[FLEET-INBOX\]" "$_f" \
    && _pass "sentinel:fleet-wake-notify.sh" \
    || _fail "sentinel:fleet-wake-notify.sh missing or no sentinel"
_f="$LCARS_ROOT/fleet/fleet-inbox-watch-daemon.sh"
[ -f "$_f" ] && grep -q "fleet-wake-notify\|WAKE_NOTIFY" "$_f" \
    && _pass "sentinel:daemon→wake-notify" \
    || _fail "sentinel:daemon→wake-notify broken"
_OP="$LCARS_ROOT/.claude/hooks/on-prompt.sh"
[ -f "$_OP" ] && grep -q "FLEET-INBOX" "$_OP" \
    && _pass "sentinel:on-prompt.sh" \
    || _warn "sentinel:on-prompt.sh missing sentinel handling"
# Supplementary: stale legacy IPC refs in active SP user sources
_STALE_EXCLUDE="_archived\|\.git"
for _d in protocole.md protocole-user.md; do
    _f="$LCARS_ROOT/fleet/system-prompt/sources/user/$_d"
    [ -f "$_f" ] || continue
    grep -q "/home/commons" "$_f" 2>/dev/null \
        && _fail "stale:$_d refs /home/commons/" \
        || _pass "stale:$_d no /home/commons/"
    grep -qE "to-engineer\.md|to-qualifier\.md|to-starfleet\.md" "$_f" 2>/dev/null \
        && _fail "stale:$_d refs legacy IPC files" \
        || _pass "stale:$_d no legacy IPC"
done
fi


# ─── Section 7 — WSL Hardening ────────────────────────────────────────────────
if run_section 7; then
echo ""
echo "=== 7 — WSL Hardening ==="
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    # 7.1 wsl.conf: interop disabled
    grep -q "enabled=false" /etc/wsl.conf 2>/dev/null \
        && _pass "wsl:interop disabled" \
        || _fail "wsl.conf: missing [interop] enabled=false"
    # 7.2 wsl.conf: appendWindowsPath=false
    grep -q "appendWindowsPath=false" /etc/wsl.conf 2>/dev/null \
        && _pass "wsl:appendWindowsPath=false" \
        || _warn "wsl.conf: missing appendWindowsPath=false"
    # 7.3 Mount C:\ non-writable (only test if actually mounted)
    if mountpoint -q /mnt/c 2>/dev/null; then
        if touch /mnt/c/.fleet-doctor-probe 2>/dev/null; then
            rm -f /mnt/c/.fleet-doctor-probe 2>/dev/null
            _fail "wsl:C:\\ is writable from WSL"
        else
            _pass "wsl:C:\\ not writable"
        fi
    else
        _pass "wsl:C:\\ not mounted (no risk)"
    fi
    # 7.4 provisioning sentinels
    [ -f "/home/private/.install_ok" ] \
        && _pass "install-ok: P1 sentinel present" \
        || _warn "install-ok: /home/private/.install_ok missing (provision-fleet.sh not run)"
    [ -f "/home/private/.fleet_ready" ] \
        && _pass "fleet-ready: P2 sentinel present" \
        || _warn "fleet-ready: /home/private/.fleet_ready missing (post-reboot.sh not run)"
    [ -f "/home/fleet-state/.deploy_ok" ] \
        && _pass "deploy-ok: onboarding sentinel present" \
        || _fail "deploy-ok: /home/fleet-state/.deploy_ok missing (onboarding not complete)"
else
    _warn "WSL: not running on WSL — section 7 skipped"
fi
fi


# ─── Section 8 — Services & Runtime ───────────────────────────────────────────
if run_section 8; then
echo ""
echo "=== 8 — Services & Runtime ==="
# 8.1 tmux socket
if [ -S "$FLEET_TMUX_SOCK" ]; then
    _pass "tmux:socket exists ($FLEET_TMUX_SOCK)"
else
    _warn "tmux:socket missing ($FLEET_TMUX_SOCK)"
fi
# 8.2 fleet-fetch.timer — removed (fleet-fetch.sh retired)
# 8.3 /dev/shm/fleet/ — removed (legacy fleet-monitor.sh, replaced by fleet-monitor.py)
fi


# ─── 9. Permissions (v7 hardening) ────────────────────────────────────────────

# 9.1 Shared zone ownership
_check_owner() {
    local path="$1" expected_owner="$2" expected_mode="$3"
    if [ -d "$path" ]; then
        local actual
        actual="$(stat -c '%U %a' "$path" 2>/dev/null)"
        if [[ "$actual" == "$expected_owner $expected_mode" ]]; then
            _pass "perms:$(basename "$path") → $expected_owner:$expected_mode"
        else
            _warn "perms:$(basename "$path") expected $expected_owner:$expected_mode, got $actual"
        fi
    fi
}
_check_owner "/home/private" "lordzurp" "700"
_check_owner "/home/commons" "lordzurp" "2770"
_check_owner "/home/fleet-state" "lordzurp" "2770"
_check_owner "/local/LCARS" "starfleet" "2755"

# 9.2 ACL on LCARS sources (starfleet write)
if command -v getfacl >/dev/null 2>&1 && [ -d "/home/projects/LCARS" ]; then
    getfacl -p "/home/projects/LCARS" 2>/dev/null | grep -q "user:starfleet:rwx" \
        && _pass "perms:LCARS ACL starfleet:rwX" \
        || _warn "perms:LCARS ACL starfleet:rwX missing"
fi

# 9.3 setfacl available
command -v setfacl >/dev/null 2>&1 \
    && _pass "perms:acl package installed" \
    || _fail "perms:acl package missing — run: apt install acl"


# ─── 10. Health checks (absorbed from fleet-maintenance.sh) ───────────────────

# 10.1 Stale handoffs (>24h without update, not offline/done)
_NOW_TS=$(date +%s)
for _hf in "$FLEET_HANDOFFS"/*-handoff.md; do
    [ -f "$_hf" ] || continue
    _role=$(basename "$_hf" -handoff.md)
    _hdate=$(grep -m1 '^date:' "$_hf" 2>/dev/null | awk '{print $2, $3}')
    _hstatus=$(grep -m1 '^status:' "$_hf" 2>/dev/null | awk '{print $2}')
    [ -z "$_hdate" ] && continue
    [[ "$_hstatus" == "offline" || "$_hstatus" == "done" || "$_hstatus" == "—" ]] && continue
    _hts=$(date -d "$_hdate" +%s 2>/dev/null || echo 0)
    [ "$_hts" -eq 0 ] && continue
    _age_h=$(( (_NOW_TS - _hts) / 3600 ))
    if [ "$_age_h" -gt 24 ]; then
        _warn "stale:$_role — last update ${_age_h}h ago (status=$_hstatus)"
    else
        _pass "handoff:$_role — fresh (${_age_h}h)"
    fi
done

# 10.2 Fleet tmux session health
if [ -S "$FLEET_TMUX_SOCK" ]; then
    tmux has-session -t fleet 2>/dev/null \
        && _pass "tmux:fleet session active" \
        || _warn "tmux:fleet session missing"
fi


# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  fleet-doctor: $TOTAL checks — $OK_COUNT OK, $WARN_COUNT WARN, $FAIL_COUNT FAIL"
echo "═══════════════════════════════════════════════════════════════"

[[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
