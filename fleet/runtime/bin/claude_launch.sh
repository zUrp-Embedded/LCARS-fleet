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

# =============================================================
# Debug trace #585 — append POD_DIR/claude_launch.dbg (bind RW
# bwrap → survit côté host post-mortem). Identifie exit point
# silent (:init_timeout sans NDJSON output, sf diag #585).
# Removable post-B10 PASS si overhead vraiment cher.
# =============================================================
dbg() { echo "[$(date -u +%H:%M:%S.%3N)] $*" >> "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true; }
dbg "start ROLE=$ROLE POD_ID=$POD_ID POD_DIR=$POD_DIR BUDGET_SEC=$BUDGET_SEC BUDGET_USD=$BUDGET_USD PWD=$(pwd) HOME=${HOME:-} USER=$(id -un 2>/dev/null||echo ?)"
dbg "env CLAUDE_CODE_OAUTH_REFRESH_TOKEN_set=$([ -n "${CLAUDE_CODE_OAUTH_REFRESH_TOKEN:-}" ] && echo y || echo n) SCOPES_set=$([ -n "${CLAUDE_CODE_OAUTH_SCOPES:-}" ] && echo y || echo n)"

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" || -z "$BUDGET_SEC" || -z "$BUDGET_USD" ]]; then
  dbg "EXIT: args vides"
  echo "ERR: tous les args doivent être non-vides" >&2
  exit 1
fi
dbg "step args-non-empty OK"

if ! [[ "$BUDGET_SEC" =~ ^[1-9][0-9]*$ ]]; then
  dbg "EXIT: budget_sec invalide ($BUDGET_SEC)"
  echo "ERR: budget_sec doit être un entier strictement positif (reçu : $BUDGET_SEC)" >&2
  exit 1
fi
dbg "step budget_sec OK"

# =============================================================
# Setup checks
# =============================================================

if [[ ! -x "$CLAUDE_BIN" ]]; then
  dbg "EXIT: CLAUDE_BIN absent/non-x : $CLAUDE_BIN ls=$(ls -la "$CLAUDE_BIN" 2>&1)"
  echo "ERR: claude binary missing or not executable: $CLAUDE_BIN" >&2
  exit 1
fi
dbg "step CLAUDE_BIN OK ($CLAUDE_BIN)"

if [[ ! -x "$JQ_BIN" ]]; then
  dbg "EXIT: JQ_BIN absent/non-x : $JQ_BIN"
  echo "ERR: jq binary missing or not executable: $JQ_BIN (parsing cap-profile JSON)" >&2
  exit 1
fi
dbg "step JQ_BIN OK ($JQ_BIN)"

CAP_PROFILE_JSON="$POD_DIR/.cap-profile.json"
SP_PATH="$POD_DIR/.claude/system-prompt.md"
BRIEF_PATH="$POD_DIR/context/brief.md"

if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  dbg "EXIT: cap-profile absent : $CAP_PROFILE_JSON ls_pod=$(ls -la "$POD_DIR" 2>&1)"
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi
dbg "step CAP_PROFILE OK"

if [[ ! -f "$SP_PATH" ]]; then
  dbg "EXIT: SP absent : $SP_PATH ls_claude=$(ls -la "$POD_DIR/.claude" 2>&1)"
  echo "ERR: SP $SP_PATH missing (Fleet.SPBuilder.compose/3 chantier 2)" >&2
  exit 1
fi
dbg "step SP OK"

if [[ ! -f "$BRIEF_PATH" ]]; then
  dbg "EXIT: brief absent : $BRIEF_PATH ls_context=$(ls -la "$POD_DIR/context" 2>&1)"
  echo "ERR: brief $BRIEF_PATH missing (caller responsibility N2bis)" >&2
  exit 1
fi
dbg "step BRIEF OK"

# =============================================================
# Extract listes tools depuis cap-profile JSON resolved
# (string-keyed cohérent fleet_capprofile L100)
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq allowedTools fail rc=$? out=$ALLOWED_TOOLS"; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq disallowedTools fail rc=$? out=$DISALLOWED_TOOLS"; exit 1; }
dbg "step jq tools OK allowed='$ALLOWED_TOOLS' disallowed='$DISALLOWED_TOOLS'"

# =============================================================
# NDJSON log path (consommé par fleet_pod_runtime.stream_parser
# chantier 7 et fleet_claude_bridge chantier 8)
# =============================================================

NDJSON_LOG="${LCARS_NDJSON_LOG:-$POD_DIR/output/.claude-stream.ndjson}"
mkdir -p "$(dirname "$NDJSON_LOG")"
dbg "step ndjson_log mkdir OK ($NDJSON_LOG)"

# =============================================================
# claude -p invocation : timeout bash + --max-budget-usd
# Frontière vendor N1 : flags claude -p uniquement, jamais bwrap.
# =============================================================

dbg "step pre-exec claude -p (timeout=${BUDGET_SEC}s ndjson=$NDJSON_LOG)"
# D9 #590 — `tee` au lieu de `>$NDJSON_LOG` : stdout passe AU PORT
# Erlang (port_backend lit depuis Port.open, parse init event) ET au
# fichier persistant (artefact debug). `>$NDJSON_LOG` seul interceptait
# tout stdout → Port voyait rien → :exited_before_init malgré exit 0.
# `exec` retiré (incompatible avec pipeline, exec ne replace que la
# 1ère commande visible). `set -o pipefail` (L28) propage exit code
# de claude au shell parent.
# D7 #586 — brief streamé sur stdin (claude -p exige user prompt).
timeout "${BUDGET_SEC}s" "$CLAUDE_BIN" -p \
  --output-format stream-json \
  --verbose \
  --system-prompt-file "$SP_PATH" \
  --append-system-prompt-file "$BRIEF_PATH" \
  --allowedTools "$ALLOWED_TOOLS" \
  --disallowedTools "$DISALLOWED_TOOLS" \
  --max-budget-usd "$BUDGET_USD" \
  <"$BRIEF_PATH" 2>&1 | tee "$NDJSON_LOG"
