#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: chantier #5 run #3.1 — launcher vendor-spécifique claude -p (Ring 1, frontière vendor N1)
#
# Launcher vendor-spécifique pour `claude -p` LCARS v2 (Ring 1 pod
# primitive, frontière vendor niveau 1, préfixe `claude_*`).
#
# Invoqué via `exec` final par `bin/bwrap_launch.sh` (chantier 4).
# Containment pré-set par bwrap (mounts RO + tmpfs /home + bind
# credentials_path). ENV vars OAuth (`CLAUDE_CODE_OAUTH_REFRESH_TOKEN`
# + `CLAUDE_CODE_OAUTH_SCOPES`) héritées du parent process via
# `bwrap --setenv` depuis `Fleet.Credentials.resolve_env/2`.
#
# Frontière vendor N1 stricte : ce script connaît `claude -p` flags
# uniquement, jamais `bwrap`. Si 2e vendor → `bin/openai_launch.sh`
# co-localisé, mêmes args, flags vendor différents.
#
# Usage : claude_launch.sh <role> <pod_id> <pod_dir> <budget_sec> <budget_usd>
#
# Exit codes :
#   0   : succès (propagé via exec)
#   1   : setup error (cap-profile/SP/brief missing, jq missing, claude binary missing)
#   124 : timeout bash (BUDGET_SEC dépassé)
#   *   : claude -p crash propagé

set -euo pipefail

# =============================================================
# Config (overridable via env pour testabilité)
# =============================================================

CLAUDE_BIN="${LCARS_CLAUDE_BIN:-/usr/local/bin/claude}"
JQ_BIN="${LCARS_JQ_BIN:-/usr/bin/jq}"

# =============================================================
# Args validation
# =============================================================

if [[ $# -ne 5 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir> <budget_sec> <budget_usd>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
POD_DIR="$3"
BUDGET_SEC="$4"
BUDGET_USD="$5"

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" || -z "$BUDGET_SEC" || -z "$BUDGET_USD" ]]; then
  echo "ERR: tous les args doivent être non-vides" >&2
  exit 1
fi

if ! [[ "$BUDGET_SEC" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERR: budget_sec doit être un entier strictement positif (reçu : $BUDGET_SEC)" >&2
  exit 1
fi

# =============================================================
# Setup checks
# =============================================================

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "ERR: claude binary missing or not executable: $CLAUDE_BIN" >&2
  exit 1
fi

if [[ ! -x "$JQ_BIN" ]]; then
  echo "ERR: jq binary missing or not executable: $JQ_BIN (parsing cap-profile JSON)" >&2
  exit 1
fi

CAP_PROFILE_JSON="$POD_DIR/.cap-profile.json"
SP_PATH="$POD_DIR/.claude/system-prompt.md"
BRIEF_PATH="$POD_DIR/context/brief.md"

if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi

if [[ ! -f "$SP_PATH" ]]; then
  echo "ERR: SP $SP_PATH missing (Fleet.SPBuilder.compose/3 chantier 2)" >&2
  exit 1
fi

if [[ ! -f "$BRIEF_PATH" ]]; then
  echo "ERR: brief $BRIEF_PATH missing (caller responsibility N2bis)" >&2
  exit 1
fi

# =============================================================
# Extract listes tools depuis cap-profile JSON resolved
# (string-keyed cohérent fleet_capprofile L100)
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON")
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON")

# =============================================================
# NDJSON log path (consommé par fleet_pod_runtime.stream_parser
# chantier 7 et fleet_claude_bridge chantier 8)
# =============================================================

NDJSON_LOG="${LCARS_NDJSON_LOG:-$POD_DIR/output/.claude-stream.ndjson}"
mkdir -p "$(dirname "$NDJSON_LOG")"

# =============================================================
# claude -p invocation : timeout bash + --max-budget-usd
# Frontière vendor N1 : flags claude -p uniquement, jamais bwrap.
# =============================================================

exec timeout "${BUDGET_SEC}s" "$CLAUDE_BIN" -p \
  --output-format stream-json \
  --verbose \
  --system-prompt-file "$SP_PATH" \
  --append-system-prompt-file "$BRIEF_PATH" \
  --allowedTools "$ALLOWED_TOOLS" \
  --disallowedTools "$DISALLOWED_TOOLS" \
  --max-budget-usd "$BUDGET_USD" \
  >"$NDJSON_LOG" 2>&1
