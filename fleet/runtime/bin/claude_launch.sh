#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-05-09
# STATUS: R1.1 — launcher vendor-spécifique claude INTERACTIF (Ring 1, frontière vendor N1, pool subscription)
#
# Launcher vendor-spécifique pour `claude -p` LCARS v2 (Ring 1 pod
# primitive, frontière vendor niveau 1, préfixe `claude_*`).
#
# Invoqué via `exec` final par `bin/bwrap_launch.sh` (chantier 4).
# Containment pré-set par bwrap (mounts RO + tmpfs /home + bind claudeDir
# RW en ~/.claude). Auth = claudeDir natif Anthropic (.credentials.json,
# refresh cross-process via lockfile natif) — PAS d'env OAuth injecté (adr-f).
#
# Frontière vendor N1 stricte : ce script connaît `claude -p` flags
# uniquement, jamais `bwrap`. Si 2e vendor → `bin/openai_launch.sh`
# co-localisé, mêmes args, flags vendor différents.
#
# Usage : claude_launch.sh <role> <pod_id> <pod_dir>
#
# R0.8-brick4 : budget_sec/budget_usd retirés (pas d'API = pas de budget).
# Le timeout de réponse au tool MCP submit_result est géré côté Pod GenServer
# Elixir (Process.send_after :result_deadline). Le script bash n'a plus de
# timeout shell `timeout BUDGET_SEC` — claude tourne tant que le Port est ouvert.
#
# Exit codes :
#   0   : succès (propagé via exec)
#   1   : setup error (cap-profile/SP/brief missing, jq missing, claude binary missing)
#   *   : claude crash propagé

set -euo pipefail

# =============================================================
# Config (overridable via env pour testabilité)
# =============================================================

CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo /usr/local/bin/claude)}"
JQ_BIN="${LCARS_JQ_BIN:-/usr/bin/jq}"

# =============================================================
# Args validation
# =============================================================

if [[ $# -ne 3 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
POD_DIR="$3"

# =============================================================
# Debug trace #585 — append POD_DIR/claude_launch.dbg (bind RW
# bwrap → survit côté host post-mortem). Identifie exit point
# silent (:init_timeout sans NDJSON output, sf diag #585).
# Removable post-B10 PASS si overhead vraiment cher.
# =============================================================
dbg() { echo "[$(date -u +%H:%M:%S.%3N)] $*" >> "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true; }
# Mi9 : repart d'un dbg vierge à chaque lancement (pas de croissance non bornée si POD_DIR réutilisé).
: > "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true
dbg "start ROLE=$ROLE POD_ID=$POD_ID POD_DIR=$POD_DIR PWD=$(pwd) HOME=${HOME:-} USER=$(id -un 2>/dev/null||echo ?)"
dbg "auth claudeDir bind: $([ -f "$HOME/.claude/.credentials.json" ] && echo 'creds present' || echo 'MISSING')"

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  dbg "EXIT: args vides"
  echo "ERR: tous les args doivent être non-vides" >&2
  exit 1
fi
dbg "step args-non-empty OK"

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
# Sortie pod : dossier livrable ($POD_DIR/output/). En interactif, le livrable est un
# FICHIER écrit par l'agent (lu par l'EXTRACT Elixir R1.2), pas un flux NDJSON stdout.
# =============================================================

OUTPUT_DIR="$POD_DIR/output"
mkdir -p "$OUTPUT_DIR"
dbg "step output_dir mkdir OK ($OUTPUT_DIR)"

# =============================================================
# Onboarding/trust skip (interactif) : sinon claude bloque sur le dialogue 1er lancement.
# .claude.json minimal à la racine du HOME pod ($POD_DIR). Clé projects = cwd pod (= $POD_DIR).
# =============================================================

VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "projects": { "$POD_DIR": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF
dbg "step claude.json provisionné (VER=${VER:-?})"

# =============================================================
# R-CORE.comm — canal MCP fleet↔pod (programmatique, STRUCTURÉ ; le drive propre, jamais de
# scraping terminal). Si le spawner/médiateur a provisionné une config MCP conventionnelle dans
# le pod ($POD_DIR/.mcp-fleet.json — NOMMÉE ainsi, PAS `.mcp.json`, pour éviter l'auto-discovery
# et son dialog de trust), on l'injecte avec --strict-mcp-config (n'utilise QUE cette config,
# ignore toute autre).
#
# DEUX gates de démarrage distincts (NE PAS confondre — vérifié reverse CC 2.1.88 + binaire 2.1.150) :
#   1. PERMISSION : mcp__* déclarés dans le cap-profile allowedTools → auto-approuvés (pas de prompt).
#   2. VISIBILITÉ : SANS `"alwaysLoad":true` au niveau serveur dans .mcp-fleet.json, tout tool MCP est
#      DÉFÉRÉ derrière ToolSearch (isDeferredTool : isMcp → defer) → absent du prompt turn-1. Pour un pod
#      one-shot, le médiateur (pod.ex / driver de gate) DOIT poser alwaysLoad côté config serveur.
# Ce launcher reste content-agnostique : il transmet la config telle quelle, c'est l'émetteur du
# .mcp-fleet.json qui porte alwaysLoad. Keystone prouvé : claude (pod) → tool MCP fleet → résultat structuré.
# =============================================================
MCP_CONFIG="$POD_DIR/.mcp-fleet.json"
MCP_FLAGS=()
if [[ -f "$MCP_CONFIG" ]]; then
  MCP_FLAGS=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  dbg "step MCP config détectée ($MCP_CONFIG) → --strict-mcp-config"
else
  # IRON LAW : MCP est le canal de comm UNIQUE. Un pod réel SANS .mcp-fleet.json = bug de config
  # amont (l'émetteur, pod.ex, doit toujours le provisionner) — pas un "mode sans MCP". Le launcher
  # reste content-agnostique (ne fail-fast pas ; il ne connaît pas l'intention), mais c'est anormal.
  dbg "WARN: pas de MCP config ($MCP_CONFIG absent) — ANORMAL pour un pod réel (provisioning amont manquant)"
fi

# =============================================================
# R1.1 — invocation INTERACTIVE (pool subscription, PAS -p/SDK billing post-15/06).
# Mécanisme prouvé briques 1a/1b/2 : mandat (brief) = prompt initial, sous PTY (claude interactif
# exige un TTY → script(1)), l'agent écrit son livrable en fichier dans output/. Frontière vendor N1 :
# flags claude uniquement, jamais bwrap. claude résolu via PATH (provisionné par bwrap_launch R0.1).
# --max-budget-usd retiré (print-only) ; timeout = budget temps. exit code non-fiable (REPL tué au
# timeout) → l'EXTRACT Elixir s'appuie sur le livrable fichier + tue le pod après extraction, pas sur le code.
# =============================================================

MANDAT="$(cat "$BRIEF_PATH")"
PERM_MODE="${LCARS_PERMISSION_MODE:-acceptEdits}"
LAUNCH_INNER="$POD_DIR/.claude-launch-inner.sh"
# Shebang bash OBLIGATOIRE : `printf %q` produit du quoting ANSI-C bash ($'...\n...') pour le mandat
# multi-ligne. dash (#!/bin/sh) ne comprend pas $'...' → syntax error. bash %q ↔ interpréteur bash.
{ printf '#!/usr/bin/env bash\nexec'; printf ' %q' "$CLAUDE_BIN" "$MANDAT" \
    --permission-mode "$PERM_MODE" \
    --system-prompt-file "$SP_PATH" \
    --allowedTools "$ALLOWED_TOOLS" \
    --disallowedTools "$DISALLOWED_TOOLS" \
    ${MCP_FLAGS[@]+"${MCP_FLAGS[@]}"}; printf '\n'; } > "$LAUNCH_INNER"
chmod +x "$LAUNCH_INNER"

# Typescript du PTY (post-mortem : voir le tour claude, diag silent-exit #585). Dans le pod
# (bind RW → survit côté host). Override LCARS_TYPESCRIPT pour rediriger.
TYPESCRIPT="${LCARS_TYPESCRIPT:-$POD_DIR/.claude-typescript.log}"

# stdin FORCÉ /dev/null (défensif). claude interactif (sous PTY script), une fois le tour-prompt-initial
# exécuté, sort proprement sur EOF stdin. Backgrounded-bash donne /dev/null implicitement (gate-r1.1),
# mais Port.open (Erlang) donne un pipe ouvert SANS EOF → claude traînerait jusqu'au timeout au lieu de
# sortir net après écriture. On force /dev/null → launcher INDÉPENDANT du stdin de l'appelant.
dbg "step pre-exec claude interactif (perm=$PERM_MODE bin=$CLAUDE_BIN ts=$TYPESCRIPT)"
set +e
# R0.8-brick4 : timeout shell retiré (pas de budget durée). claude tourne tant
# que le Port stdin reste ouvert ; le timeout de RÉPONSE est côté Pod GenServer
# (:result_deadline) qui ferme le Port via transition_failed.
script -q -c "$LAUNCH_INNER" "$TYPESCRIPT" < /dev/null
RC=$?
set -e
dbg "post-script rc=$RC output_ls=$(ls -la "$OUTPUT_DIR" 2>&1)"
exit "$RC"
