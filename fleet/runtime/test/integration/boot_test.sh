#!/bin/bash
#
# SOURCE: test/integration/boot_test.sh
# AUTHOR: LORDZURP
# STARDATE: 2026.130
# STATUS: OPERATIONAL — tests intégration boot lcars-fleet.service (chantier 16)
#
# Exécute des vérifs harness sans nécessiter un systemd actif :
#   1. Lint syntaxique unit file (systemd-analyze verify si dispo)
#   2. Hardening score (systemd-analyze security si dispo)
#   3. Script readiness exit codes
#   4. EnvironmentFile template validation (vars présentes)
#   5. Mix release config présent (rel/runtime.exs)
#
# Tests d'intégration *deployment* (systemctl start réel) hors scope —
# nécessitent un host avec systemd actif + user lcars + release builded.
# Voir README chantier 16 pour procédure deploy manuelle.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT="${ROOT}/etc/lcars-fleet.service"
ENV_TPL="${ROOT}/etc/lcars-fleet.env.template"
READINESS="${ROOT}/bin/lcars-readiness"
RUNTIME_EXS="${ROOT}/config/runtime.exs"

PASS=0
FAIL=0

step() { echo "==> $*"; }

ok() { echo "  ok: $*"; PASS=$((PASS + 1)); }

ko() { echo "  KO: $*" >&2; FAIL=$((FAIL + 1)); }

# ============================================================
# 1. Unit file présent + hardening clés
# ============================================================
step "1. Unit file présent + hardening canon"

[ -f "$UNIT" ] && ok "unit file exists" || ko "unit file missing: $UNIT"

for directive in \
    "Type=notify" \
    "ProtectHome=yes" \
    "ProtectSystem=strict" \
    "NoNewPrivileges=yes" \
    "PrivateTmp=yes" \
    "RestrictNamespaces=user mount" \
    "ReadWritePaths=" \
    "SystemCallFilter=" \
    "RestrictAddressFamilies=" \
    "LockPersonality=yes" \
    "Restart=on-failure" \
    "ExecStartPost=/usr/local/bin/lcars-readiness 60"; do
    if grep -qF "$directive" "$UNIT"; then
        ok "directive present: $directive"
    else
        ko "directive missing: $directive"
    fi
done

# Hardening verify systemd-analyze (si binaire dispo)
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify "$UNIT" 2>&1 | grep -qE "Failed|error"; then
        ko "systemd-analyze verify reported errors"
    else
        ok "systemd-analyze verify clean"
    fi
fi

# ============================================================
# 2. Readiness script exit codes + executable
# ============================================================
step "2. Readiness script"

[ -x "$READINESS" ] && ok "readiness script executable" || ko "readiness script not +x: $READINESS"

# Bash syntax check
if bash -n "$READINESS"; then
    ok "readiness bash syntax ok"
else
    ko "readiness bash syntax fail"
fi

# Test timeout=2 contre URL injoignable → exit 1 attendu
if LCARS_HEALTH_URL="http://localhost:1/never" "$READINESS" 2 >/dev/null 2>&1; then
    ko "readiness should fail on unreachable URL"
else
    ok "readiness exit=1 on unreachable URL (expected)"
fi

# ============================================================
# 3. EnvironmentFile template — vars requises présentes
# ============================================================
step "3. EnvironmentFile template"

[ -f "$ENV_TPL" ] && ok "env template exists" || ko "env template missing: $ENV_TPL"

# F164 : LCARS_CONFIG_PATH / LCARS_CREDENTIALS_ROOT / GITEA_URL / GITEA_TOKEN RETIRÉS (vars mortes,
# aucun module ne les lit — creds=claudeDir ADR-F, forge=FORGE_*). On ne valide que les vars LUES.
for var in \
    "RELEASE_NODE" \
    "RELEASE_COOKIE" \
    "LCARS_LOG_LEVEL" \
    "LCARS_CAPPROFILES_ROOT" \
    "LCARS_PIPELINES_ROOT" \
    "LCARS_STARFLEET_AUDIT_LOG" \
    "LCARS_COORD_POLICIES_PATH" \
    "FLEET_WEBHOOK_SECRET_PATH" \
    "FLEET_API_PORT" \
    "FLEET_API_SECRET_PATH" \
    "LCARS_CONFIG_REPO"; do
    if grep -qE "^${var}=" "$ENV_TPL"; then
        ok "env var template: $var"
    else
        ko "env var missing in template: $var"
    fi
done

# ============================================================
# 4. Mix release runtime config
# ============================================================
step "4. Mix release config rel/runtime.exs"

[ -f "$RUNTIME_EXS" ] && ok "runtime.exs exists" || ko "runtime.exs missing: $RUNTIME_EXS"

if grep -q "import Config" "$RUNTIME_EXS"; then
    ok "runtime.exs uses Config"
else
    ko "runtime.exs missing 'import Config'"
fi

# F180 : le wire-up `:fleet_pipeline, :coord_backend` a été RETIRÉ en R06
# (gates consolidées gatekeeper). Ce grep cherchait un canon mort → KO forever.
# Le wire-up courant `:fleet_starfleet, :coord_backend` est vérifié juste après.

if grep -q "config :fleet_starfleet, :coord_backend, Fleet.Coord" "$RUNTIME_EXS"; then
    ok "runtime.exs wire-up coord_backend ch13 → Fleet.Coord"
else
    ko "runtime.exs missing coord_backend ch13 wire-up"
fi

# ============================================================
# 5. Mix release config dans mix.exs
# ============================================================
step "5. Mix release config mix.exs"

if grep -q "fleet_umbrella:" "${ROOT}/mix.exs"; then
    ok "mix.exs releases fleet_umbrella"
else
    ko "mix.exs missing fleet_umbrella release"
fi

if grep -q "include_executables_for: \[:unix\]" "${ROOT}/mix.exs"; then
    ok "mix.exs Mix release Unix executables"
else
    ko "mix.exs missing include_executables_for unix"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="

if [ "$FAIL" -eq 0 ]; then
    echo "all checks PASS"
    exit 0
else
    echo "FAIL — $FAIL checks failed" >&2
    exit 1
fi
