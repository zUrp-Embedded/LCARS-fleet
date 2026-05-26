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
#   --bind  claudeDir        (claudeDir du compte humain, RW en ~/.claude — refresh natif Anthropic, adr-f)
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
#   1 : setup error (args manquants, claudeDir/mirror/pod_dir invalides)
#   2 : bwrap binary missing ou version incompatible
#   3 : vendor launch fail (propagé via exec)

set -euo pipefail

# =============================================================
# Config (overridable via env pour testabilité)
# =============================================================

# claudeDir du compte de l'humain du pod (share per-humain, adr-f). Résolu par
# Fleet.Spawner depuis la registration (humain → claudeDir), jamais hardcodé (I-CBC).
# Monté RW en ~/.claude ; refresh OAuth délégué au lockfile cross-process natif Anthropic.
CLAUDE_DIR="${CLAUDE_DIR:?CLAUDE_DIR required (claudeDir du compte humain, resolu par Fleet.Spawner — adr-f)}"
GIT_MIRROR="${LCARS_GIT_MIRROR:-/var/lib/lcars/git-mirror}"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"

# Vendor runtime provisioning (R0.1) — générique, défaut claude.
# Le binaire vendor vit sous $HOME/.local (masqué par --tmpfs /home DANS le pod) → on le
# re-provisionne à son emplacement NATIF dans le pod ($POD_DIR/.local/bin/<vendor> +
# $POD_DIR/.local/share/<vendor>). Sinon claude se croit "native install absente" et dégrade
# (ex: --remote-control → REPL ; cf. diag brique 1b). Paramétrable LCARS_VENDOR_* (anti-hardcode,
# 2e vendor = override LCARS_VENDOR_NAME). Pas de factory (anti-abstraction prématurée, 1 vendor).
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
VENDOR_BIN="${LCARS_VENDOR_BIN:-$(readlink -f "$(command -v "$VENDOR_NAME" 2>/dev/null)" 2>/dev/null || true)}"
VENDOR_SHARE="${LCARS_VENDOR_SHARE:-$([ -n "$VENDOR_BIN" ] && dirname "$(dirname "$VENDOR_BIN")" || true)}"

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

if [[ -z "$VENDOR_BIN" || ! -x "$VENDOR_BIN" || ! -d "$VENDOR_SHARE" ]]; then
  echo "ERR: vendor runtime '$VENDOR_NAME' introuvable (bin=$VENDOR_BIN share=$VENDOR_SHARE) — set LCARS_VENDOR_BIN" >&2
  exit 2
fi

if [[ ! -d "$CLAUDE_DIR" ]]; then
  echo "ERR: claudeDir $CLAUDE_DIR missing (registration humain incomplete — adr-f)" >&2
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
# Mi10 : word-splitting espace intentionnel (liste space-separated) MAIS pas de glob-expansion
# des noms de plugins → noglob le temps de la boucle.
set -f
for plugin in ${LCARS_SKILLS_PLUGINS:-}; do
  HOST_PLUGIN_PATH="$HOME/.claude/plugins/$plugin"
  if [[ ! -d "$HOST_PLUGIN_PATH" ]]; then
    echo "ERR: plugin '$plugin' not installed host-side at $HOST_PLUGIN_PATH" >&2
    exit 1
  fi
  PLUGIN_BINDS+=(--ro-bind "$HOST_PLUGIN_PATH" "$POD_DIR/.claude/plugins/$plugin")
done
set +f

# =============================================================
# Bwrap durci PoC-3 T2 stack + exec
# =============================================================

exec "$BWRAP_BIN" \
  --unshare-all --share-net \
  --ro-bind / / \
  --tmpfs /home \
  --tmpfs /tmp \
  --bind "$POD_DIR" "$POD_DIR" \
  --bind "$CLAUDE_DIR" "$POD_DIR/.claude" \
  --ro-bind "$GIT_MIRROR" "$GIT_MIRROR" \
  --ro-bind "$VENDOR_BIN" "$POD_DIR/.local/bin/$VENDOR_NAME" \
  --ro-bind "$VENDOR_SHARE" "$POD_DIR/.local/share/$VENDOR_NAME" \
  ${PLUGIN_BINDS[@]+"${PLUGIN_BINDS[@]}"} \
  --dev /dev --proc /proc \
  --chdir "$POD_DIR" \
  --setenv HOME "$POD_DIR" \
  --setenv PATH "$POD_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_ROLE "$ROLE" \
  --setenv DISABLE_TELEMETRY "1" \
  --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1" \
  --setenv DISABLE_AUTOUPDATER "1" \
  --setenv CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "100" \
  -- "${COMMAND[@]}"
