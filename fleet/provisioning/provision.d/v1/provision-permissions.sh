#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-permissions.sh
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
#     | MODULE: PROVISION-PERMS   | SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3           | STARDATE: 2026.099              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Enforce filesystem permissions per v7 hardening matrix.  |
#     |  Idempotent. All chmod/chown/setfacl in one place.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision-permissions.sh — enforcement des permissions filesystem.
#     Centralise TOUTE la logique chmod/chown/setfacl. Idempotent.
#     Sourced by provision-system.sh. Requires sudo.
#
#     [EN]
#     provision-permissions.sh — enforce filesystem permissions per hardening matrix.
#     Centralized, idempotent. Sourced by provision-system.sh.
#
# --- END HEADER ---

echo ""
echo "=== Permissions (v7 hardening) ==="

HOMES_ROOT="${HOMES_ROOT:-/home}"
LCARS_ROOT="${LCARS_ROOT:-/local/LCARS}"
FLEET_GROUP="${FLEET_GROUP:-fleet}"

# --- Shared zones ownership ---

# /home/private/ — lordzurp only, starfleet gets rx ACL for secrets access
_target="$HOMES_ROOT/private"
if [ -d "$_target" ]; then
    chown "$FLEET_USER:$FLEET_USER" "$_target"
    chmod 700 "$_target"
    command -v setfacl >/dev/null 2>&1 && setfacl -m "u:starfleet:rx" "$_target" 2>/dev/null
    pass "perms:private → 700 $FLEET_USER:$FLEET_USER (+rx starfleet)"
fi

# /home/fleet-state/run/ — subdir for sentinels and temp files
_target="$HOMES_ROOT/fleet-state"
if [ -d "$_target" ]; then
    mkdir -p "$_target/run"
    chown "$FLEET_USER:$FLEET_GROUP" "$_target/run"
    chmod 2770 "$_target/run"
fi

# /local/ — fleet only, no others access (codex isolation)
if [ -d "$(dirname "$LCARS_ROOT")" ]; then
    chown root:$FLEET_GROUP "$(dirname "$LCARS_ROOT")"
    chmod 750 "$(dirname "$LCARS_ROOT")"
fi
# /local/LCARS/ — runtime, fleet read-only (triangle strict)
if [ -d "$LCARS_ROOT" ]; then
    chown -R starfleet:$FLEET_GROUP "$LCARS_ROOT"
    chmod 2750 "$LCARS_ROOT"
fi
pass "perms:runtime → 750 /local, 2750 LCARS (no others)"

# --- Project source ACLs ---

# LCARS dev repo — starfleet sole writer
_target="$HOMES_ROOT/projects/LCARS"
if [ -d "$_target" ] && command -v setfacl >/dev/null 2>&1; then
    chmod 2755 "$_target"
    setfacl -R -m u:starfleet:rwX "$_target" 2>/dev/null
    setfacl -R -d -m u:starfleet:rwX "$_target" 2>/dev/null
    # Fleet group read-only (default)
    setfacl -R -m g:$FLEET_GROUP:rX "$_target" 2>/dev/null
    setfacl -R -d -m g:$FLEET_GROUP:rX "$_target" 2>/dev/null
    pass "perms:LCARS sources → starfleet:rwX, fleet:rX (ACL)"
fi

# Other project repos — dev sole writer
for _proj_dir in "$HOMES_ROOT"/projects/*/; do
    _proj_name="$(basename "$_proj_dir")"
    [[ "$_proj_name" == "LCARS" ]] && continue
    [[ -d "$_proj_dir/.git" ]] || continue
    if command -v setfacl >/dev/null 2>&1; then
        chmod 2755 "$_proj_dir"
        setfacl -R -m u:dev:rwX "$_proj_dir" 2>/dev/null
        setfacl -R -d -m u:dev:rwX "$_proj_dir" 2>/dev/null
        setfacl -R -m g:$FLEET_GROUP:rX "$_proj_dir" 2>/dev/null
        setfacl -R -d -m g:$FLEET_GROUP:rX "$_proj_dir" 2>/dev/null
        pass "perms:$_proj_name sources → dev:rwX, fleet:rX (ACL)"
    fi
done

# --- Shared dirs ownership enforcement ---
for _shared_dir in "$HOMES_ROOT/commons" "$HOMES_ROOT/handoffs" \
                   "$HOMES_ROOT/fleet-state" "$HOMES_ROOT/tmp" \
                   "$HOMES_ROOT/projects"; do
    if [ -d "$_shared_dir" ]; then
        chown "$FLEET_USER:$FLEET_GROUP" "$_shared_dir"
        chmod 2770 "$_shared_dir"
    fi
done
chown "$FLEET_USER:$FLEET_USER" "$HOMES_ROOT/private" 2>/dev/null
chmod 700 "$HOMES_ROOT/private" 2>/dev/null
pass "perms:shared dirs → $FLEET_USER:$FLEET_GROUP 2770"

# --- Codex IPC bridge (/home/commons/codex/) ---
_codex_bridge="$HOMES_ROOT/commons/codex"
if [ -d "$_codex_bridge" ]; then
    chown codex:external "$_codex_bridge"
    chmod 2770 "$_codex_bridge"
    setfacl -R -m u:codex:rwx "$_codex_bridge" 2>/dev/null
    setfacl -R -d -m u:codex:rwx "$_codex_bridge" 2>/dev/null
    setfacl -R -m g:$FLEET_GROUP:rwx "$_codex_bridge" 2>/dev/null
    setfacl -R -d -m g:$FLEET_GROUP:rwx "$_codex_bridge" 2>/dev/null
    pass "perms:codex bridge → codex:rwx, fleet:rwx (ACL)"
fi

# --- Worktree projects.work/ ACLs (Phase 3) ---

for _proj_dir in "$HOMES_ROOT"/projects.work/*/; do
    _proj_name="$(basename "$_proj_dir")"
    _wdir="$_proj_dir/work"
    [ -d "$_wdir" ] || continue

    chown -R starfleet:$FLEET_GROUP "$_wdir"
    chmod 2750 "$_wdir"

    # plans/ — architect + starfleet
    [ -d "$_wdir/plans" ] && {
        setfacl -R -m u:architect:rwX,u:starfleet:rwX "$_wdir/plans/" 2>/dev/null
        setfacl -R -d -m u:architect:rwX,u:starfleet:rwX "$_wdir/plans/" 2>/dev/null
    }
    # doing/ — engineer + dev + starfleet
    [ -d "$_wdir/doing" ] && {
        setfacl -R -m u:engineer:rwX,u:dev:rwX,u:starfleet:rwX "$_wdir/doing/" 2>/dev/null
        setfacl -R -d -m u:engineer:rwX,u:dev:rwX,u:starfleet:rwX "$_wdir/doing/" 2>/dev/null
    }
    # done/ — starfleet + qualifier + reviewer
    [ -d "$_wdir/done" ] && {
        setfacl -R -m u:starfleet:rwX,u:qualifier:rwX,u:reviewer:rwX "$_wdir/done/" 2>/dev/null
        setfacl -R -d -m u:starfleet:rwX,u:qualifier:rwX,u:reviewer:rwX "$_wdir/done/" 2>/dev/null
    }
    # audits/ — consultant + qualifier + reviewer + starfleet
    [ -d "$_wdir/audits" ] && {
        setfacl -R -m u:consultant:rwX,u:qualifier:rwX,u:reviewer:rwX,u:starfleet:rwX "$_wdir/audits/" 2>/dev/null
        setfacl -R -d -m u:consultant:rwX,u:qualifier:rwX,u:reviewer:rwX,u:starfleet:rwX "$_wdir/audits/" 2>/dev/null
    }
    # handoffs/ — dir: all agents can list+create. files: owner+starfleet write, others read-only.
    [ -d "$_wdir/handoffs" ] && {
        chmod 2770 "$_wdir/handoffs"
        # Dir ACL: all agents rwx (need x to list, w to create their own handoff)
        while IFS= read -r _role; do
            setfacl -m "u:${_role}:rwx" "$_wdir/handoffs/" 2>/dev/null
        done < <(fleet_roles)
        # Default ACL: clear all user defaults, set group read-only
        # New files inherit: owner rw, group r, others nothing
        # Per-file ACLs are set by provision (above) or by the handoff skill
        setfacl -b -d "$_wdir/handoffs/" 2>/dev/null
        setfacl -d -m "u::rw-,g::r--,g:$FLEET_GROUP:r--,o::---" "$_wdir/handoffs/" 2>/dev/null
        # Per-file ACL: owner rw + starfleet rw, all others read-only
        while IFS= read -r _role; do
            _hf="$_wdir/handoffs/${_role}-handoff.md"
            [ -f "$_hf" ] || continue
            chown "${_role}:$FLEET_GROUP" "$_hf"
            chmod 640 "$_hf"
            # Reset ACLs: owner rw, starfleet rw (supervision), group read
            setfacl -b "$_hf" 2>/dev/null
            setfacl -m "u:${_role}:rw-,u:starfleet:rw-,g:$FLEET_GROUP:r--" "$_hf" 2>/dev/null
        done < <(fleet_roles)
        # Lock files: same pattern
        find "$_wdir/handoffs/" -name "*.lock" -exec bash -c '
            _lf="$1"; _grp="$2"
            chmod 640 "$_lf"
            setfacl -b "$_lf" 2>/dev/null
            setfacl -m "u:starfleet:rw-,g:${_grp}:r--" "$_lf" 2>/dev/null
        ' _ {} "$FLEET_GROUP" \;
    }
    # scratchpad + backlog — fleet group rw
    for _f in scratchpad.md backlog.md; do
        [ -f "$_wdir/$_f" ] && { chmod 660 "$_wdir/$_f"; chgrp $FLEET_GROUP "$_wdir/$_f"; }
    done
    # work/ plan files — writable by agents in fleet-plan.sh matrice (architect, engineer, dev, starfleet, consultant)
    # index.md + plan dirs (TODO, doing, done) need write access for fleet-plan.sh operations
    _PLAN_AGENTS="architect engineer dev starfleet consultant"
    for _f in index.md backlog.md; do
        [ -f "$_wdir/$_f" ] || continue
        for _pa in $_PLAN_AGENTS; do
            setfacl -m "u:${_pa}:rw-" "$_wdir/$_f" 2>/dev/null
        done
    done
    for _d in TODO doing done; do
        [ -d "$_wdir/$_d" ] || continue
        for _pa in $_PLAN_AGENTS; do
            setfacl -m "u:${_pa}:rwx" "$_wdir/$_d/" 2>/dev/null
            setfacl -d -m "u:${_pa}:rw-" "$_wdir/$_d/" 2>/dev/null
        done
    done

    pass "perms:projects.work/${_proj_name}/ → ACLs enforced"
done

# --- Per-agent home check ---

while IFS= read -r _role; do
    _home="$HOMES_ROOT/$_role"
    [ -d "$_home" ] || continue

    # Home: 750 agent:fleet
    _cur="$(stat -c '%U:%G %a' "$_home" 2>/dev/null)"
    if [ "$_cur" != "$_role:$FLEET_GROUP 750" ]; then
        chown "$_role:$FLEET_GROUP" "$_home"
        chmod 750 "$_home"
    fi
done < <(fleet_roles)
pass "perms:agent homes → 750 agent:fleet"

echo ""
echo "  Permissions enforced."
