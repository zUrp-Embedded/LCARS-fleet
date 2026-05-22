#!/usr/bin/env bash
# SOURCE: bin/bwrap_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: chantier #4 run #3.1 — launcher générique containment LCARS v2 (Ring 1)
#
# Launcher générique containment LCARS v2 (Ring 1 pod primitive).
# Vendor-agnostic : invoque le command tier (`claude_launch.sh` ou
# autre) via `exec` final.
#
# Stack bwrap durci PoC-3 T2 :
#   --ro-bind / /            (root entier RO, surface attaque réduite)
#   --tmpfs /home            (isolation home cross-role)
#   --bind  $POD_DIR         (pod home RW unique)
#   --ro-bind credentials    (coffre role-spécifique, fleet_credentials chantier 3)
#   --ro-bind git-mirror     (Q5 ADR-B, bootstrap repo via --reference)
#   --unshare-all --share-net (isolation namespace + accès réseau API)
#
# ENV defaults LCARS v2 hardcoded (4 vars, doctrine close 2026-05-09).
# Random pod_id via bwrap user namespace (Q4 ADR-B, collision-free
# statistique kernel-side).
#
# Usage : bwrap_launch.sh <role> <pod_id> <pod_dir> <command...>
#
# Exit codes :
#   0 : succès (propagé via exec)
#   1 : setup error (args manquants, coffre/mirror/pod_dir invalides)
#   2 : bwrap binary missing ou version incompatible
#   3 : vendor launch fail (propagé via exec)

set -euo pipefail

# =============================================================
# Config (overridable via env pour testabilité)
# =============================================================

CREDS_ROOT="${LCARS_CREDS_ROOT:-/var/lib/lcars/credentials}"
GIT_MIRROR="${LCARS_GIT_MIRROR:-/var/lib/lcars/git-mirror}"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"

# =============================================================
# Args validation
# =============================================================

if [[ $# -lt 4 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir> <command...>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
POD_DIR="$3"
shift 3
COMMAND=("$@")

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  echo "ERR: role, pod_id, pod_dir must be non-empty" >&2
  exit 1
fi

# =============================================================
# F-CRIT-3 v1.5 fix : trap cleanup pod_dir on EXIT/ERR (idempotent)
#
# Posé ICI, AVANT les setup checks, pour que toute exit anticipée
# (coffre/mirror/pod_dir/bwrap missing) déclenche aussi le cleanup.
# Skippable via LCARS_BWRAP_NO_CLEANUP=1 (tests + caller fleet_spawner
# qui gère son propre lifecycle).
# =============================================================

if [[ "${LCARS_BWRAP_NO_CLEANUP:-0}" != "1" ]]; then
  trap 'rm -rf "$POD_DIR" 2>/dev/null || true' EXIT ERR
fi

# =============================================================
# Setup checks
# =============================================================

if [[ ! -x "$BWRAP_BIN" ]]; then
  echo "ERR: bwrap binary missing or not executable: $BWRAP_BIN" >&2
  exit 2
fi

CREDS_PATH="$CREDS_ROOT/$ROLE"
if [[ ! -d "$CREDS_PATH" ]]; then
  echo "ERR: coffre $CREDS_PATH missing (re-bootstrap via bin/setup-credentials.sh)" >&2
  exit 1
fi

if [[ ! -d "$GIT_MIRROR" ]]; then
  echo "ERR: git mirror $GIT_MIRROR missing (provisioning starfleet G21 _install/reinstall.sh)" >&2
  exit 1
fi

if [[ ! -d "$POD_DIR" ]]; then
  echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2
  exit 1
fi

# =============================================================
# Exposition plugins Claude Code natifs
# DN ring1/pod-bootstrap-superpowers — mount-bind RO host→pod.
# LCARS_SKILLS_PLUGINS = plugins whitelistés (space-separated),
# produit par fleet_spbuilder.filter_skills/2 côté caller. Défaut
# vide = aucun plugin (rétro-compatible). Adaptation anti-M1 vs
# pseudo-patch DN : pod HOME réel = $POD_DIR (--setenv HOME +
# --tmpfs /home), PAS /home/$ROLE. Fail-fast si absent host-side.
# =============================================================

PLUGIN_BINDS=()
for plugin in ${LCARS_SKILLS_PLUGINS:-}; do
  HOST_PLUGIN_PATH="$HOME/.claude/plugins/$plugin"
  if [[ ! -d "$HOST_PLUGIN_PATH" ]]; then
    echo "ERR: plugin '$plugin' not installed host-side at $HOST_PLUGIN_PATH" >&2
    exit 1
  fi
  PLUGIN_BINDS+=(--ro-bind "$HOST_PLUGIN_PATH" "$POD_DIR/.claude/plugins/$plugin")
done

# =============================================================
# Bwrap durci PoC-3 T2 stack + exec
# =============================================================

exec "$BWRAP_BIN" \
  --unshare-all --share-net \
  --ro-bind / / \
  --tmpfs /home \
  --tmpfs /tmp \
  --bind "$POD_DIR" "$POD_DIR" \
  --ro-bind "$CREDS_PATH" "$CREDS_PATH" \
  --ro-bind "$GIT_MIRROR" "$GIT_MIRROR" \
  ${PLUGIN_BINDS[@]+"${PLUGIN_BINDS[@]}"} \
  --dev /dev --proc /proc \
  --chdir "$POD_DIR" \
  --setenv HOME "$POD_DIR" \
  --setenv PATH "/usr/local/bin:/usr/bin:/bin" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_ROLE "$ROLE" \
  --setenv DISABLE_TELEMETRY "1" \
  --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1" \
  --setenv DISABLE_AUTOUPDATER "1" \
  --setenv CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "100" \
  --setenv CLAUDE_CODE_OAUTH_REFRESH_TOKEN "${CLAUDE_CODE_OAUTH_REFRESH_TOKEN:-}" \
  --setenv CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  --setenv CLAUDE_CODE_OAUTH_SCOPES "${CLAUDE_CODE_OAUTH_SCOPES:-}" \
  -- "${COMMAND[@]}"
