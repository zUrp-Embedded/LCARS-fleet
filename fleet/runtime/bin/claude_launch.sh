#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — launcher vendor claude INTERACTIF marionnette-PTY (Ring 1, frontière N1, subscription)
#
# Launcher vendor-spécifique pour `claude` REPL interactif LCARS v2 sous ADR-G
# (Ring 1 pod primitive, frontière vendor niveau 1, préfixe `claude_*`).
# Déroule la DN `beyond_#5/design-notes/spawn/launcher-claude.md` (PROMOTED 9/10,
# validation user 2026-05-30, amendement M.F.5 2026-05-31 : RC-at-startup = flag
# `--remote-control` PROVEN sous PTY). Supersède le modèle `script(1)`-PTY one-shot
# (mandat = prompt CLI) — interdit par ADR-G IV.1/IV.2.
#
# Invoqué via `exec` final par `bin/bwrap_launch.sh` (N0). Le PTY est celui de
# tmux (fourni par bwrap_launch) — ce launcher NE tient PLUS le PTY (plus de
# `script -q`/inner-script) et NE porte PLUS le mandat (il arrive par MCP get_task).
# Containment + tmux + socket-par-pod = N0 (bwrap_launch). Auth = claudeDir natif
# Anthropic bind RW (adr-f), zéro env OAuth.
#
# Frontière vendor N1 stricte (IX.3) : flags `claude` uniquement, jamais `bwrap`/
# `tmux`/`unshare`. Si 2e vendor → `bin/openai_launch.sh` co-localisé.
#
# Usage : claude_launch.sh <role> <pod_id> <pod_dir> <sp>
#   <sp> = SP composé, élément argv discret (onboarding-DN : Port.open(args:[…,sp])
#          → execve → claude ; jamais fichier, jamais env, jamais $(cat)).
# Env identité (fournie par le spawner, non sensible au masquage ⇒ env OK ≠ SP) :
#   LCARS_POD_SESSION_ID          UUID de session PRÉ-ALLOUÉ (uuidgen, state.json au spawn) — requis
#   LCARS_POD_RESUME              0 = 1ʳᵉ création (--session-id) ; 1 = recovery (--resume)
#   LCARS_POD_SESSION_NAME_PREFIX préfixe nom RC lisible Desktop (<human>_<role>) — requis
#
# Exit codes :
#   0   : succès (propagé via exec)
#   1   : setup error (cap-profile/jq/claude binary missing, args/SP vides, session env manquant)
#   *   : claude crash propagé

set -euo pipefail

# =============================================================
# Config (overridable via env pour testabilité)
# =============================================================

# Binaire vendor : LCARS_CLAUDE_BIN posé par bwrap (--setenv = POD_VENDOR_BIN = le claude
# per-user du HUMAIN propriétaire, relocalisé dans le pod ; auto-update natif Anthropic).
# Fallback = PATH du pod ($POD_DIR/.local/bin en tête, bwrap) ⇒ JAMAIS le /usr/local apt
# système (stale, casse l'auto-update). Fail-fast si introuvable — pas de fallback silencieux
# (un pod sur un binaire stale = casse rattrapable non rattrapée).
CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
: "${CLAUDE_BIN:?claude binary introuvable (LCARS_CLAUDE_BIN posé par bwrap, ou PATH per-user ~/.local)}"
JQ_BIN="${LCARS_JQ_BIN:-/usr/bin/jq}"

# =============================================================
# Args POSITIONNELS : <role> <pod_id> <pod_dir> <sp>
# =============================================================

if [[ $# -ne 4 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir> <sp>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
POD_DIR="$3"
SP="$4"

# =============================================================
# Session : UUID PRÉ-ALLOUÉ par le spawner (uuidgen, persisté state.json au spawn).
# Identité fournie par l'orchestrateur (VII.1) ⇒ env OK (≠ SP qui voyage en argv).
# =============================================================

SESSION_ID="${LCARS_POD_SESSION_ID:?UUID de session requis (pré-alloué par le spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"                          # 0 = 1ʳᵉ création ; 1 = recovery
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?préfixe nom RC requis (<human>_<role>)}"

# Permission : SANCTUAIRE = liberté totale. Les murs bwrap portent la sécu, PAS le harness — l'agent
# ne se brise pas les dents sur la paranoïa permission de Claude Code (un prompt « autoriser ? » hang
# un pod headless : personne pour répondre). Défaut = --dangerously-skip-permissions (le user le fait
# déjà sur sa session RC ; pod sous UID humain ≠ root → accepté). Le « no-internet recommended » du
# flag est OK ici : threat-model = sandbox jetable root-de-confiance, le containment bwrap est le mur.
# Overridable par cap-profile (LCARS_PERMISSION_MODE) pour un rôle bridé (ex. plan).
PERM_MODE="${LCARS_PERMISSION_MODE:-}"
if [[ -n "$PERM_MODE" ]]; then
  PERM_FLAGS=(--permission-mode "$PERM_MODE")
else
  # --dangerously-skip-permissions POSE le mode bypass. Le BLOCAGE n'est pas le mode mais le DIALOGUE
  # interactif d'acceptation (« 1. No / 2. Yes I accept ») qui hang un pod headless → levé séparément
  # par skipDangerousModePermissionPrompt en settings (bloc « bypass dialog » ci-dessous). PAS besoin de
  # --allow-dangerously-skip-permissions (redondant : il ne fait qu'enclencher le même mode).
  PERM_FLAGS=(--dangerously-skip-permissions)
fi
# --settings est ADDITIF ⇒ --setting-sources DOIT exclure 'user' (sinon le settings de
# l'humain bleed dans le pod). Default project,local — 'user' INTERDIT (fleet_spawner v2 §G).
SETTING_SOURCES="${LCARS_SETTING_SOURCES:-project,local}"

# =============================================================
# Debug trace #585 — append POD_DIR/claude_launch.dbg (bind RW bwrap → survit
# côté host post-mortem). Identifie un exit point silencieux (diag sf #585).
# =============================================================
dbg() { echo "[$(date -u +%H:%M:%S.%3N)] $*" >> "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true; }
: > "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true
dbg "start ROLE=$ROLE POD_ID=$POD_ID POD_DIR=$POD_DIR session=$SESSION_ID resume=$POD_RESUME prefix=$SESSION_NAME_PREFIX PWD=$(pwd) HOME=${HOME:-} USER=$(id -un 2>/dev/null||echo ?)"
dbg "auth claudeDir bind: $([ -f "$HOME/.claude/.credentials.json" ] && echo 'creds present' || echo 'MISSING')"

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  dbg "EXIT: args role/pod_id/pod_dir vides"
  echo "ERR: role, pod_id et pod_dir doivent être non-vides" >&2
  exit 1
fi
if [[ -z "$SP" ]]; then
  dbg "EXIT: SP inline (argv) vide"
  echo "ERR: SP inline (argv 4) doit être non-vide (Fleet.SPBuilder.compose/3)" >&2
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
if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  dbg "EXIT: cap-profile absent : $CAP_PROFILE_JSON ls_pod=$(ls -la "$POD_DIR" 2>&1)"
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi
dbg "step CAP_PROFILE OK"

# =============================================================
# Onboarding/trust skip (interactif) : sinon claude bloque sur le dialogue 1er lancement.
# .claude.json minimal à la racine du HOME pod ($POD_DIR, hors .claude/). Clé projects = le CWD réel
# de l'agent (`LCARS_POD_CWD`, = workspace quand un projet est cloné, sinon $POD_DIR) — sinon /init
# tournerait dans un dir non-onboardé (P2 mundo invocado : l'agent pop dans un projet déjà onboardé).
# (.claude/ est pod-owned : bwrap n'y bind QUE .credentials.json — P1/C9.)
# (NB : l'acceptation bypass N'est PLUS ici — `bypassPermissionsModeAccepted` du global config a
#  MIGRÉ vers settings.json/`skipDangerousModePermissionPrompt` — cf. bloc « bypass dialog » infra.)
# =============================================================

VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
POD_CWD="${LCARS_POD_CWD:-$POD_DIR}"
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "projects": { "$POD_CWD": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF
dbg "step claude.json provisionné (VER=${VER:-?})"

# =============================================================
# Tools depuis cap-profile JSON resolved (string-keyed, cohérent fleet_capprofile L100).
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq allowedTools fail rc=$? out=$ALLOWED_TOOLS"; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq disallowedTools fail rc=$? out=$DISALLOWED_TOOLS"; exit 1; }
dbg "step jq tools OK allowed='$ALLOWED_TOOLS' disallowed='$DISALLOWED_TOOLS'"

# Model + effort depuis le catalogue (spec.invocation) → flags claude. Absent/null ⇒ flag omis
# (claude garde son défaut binaire ; les 7 cap-profiles canon les posent ⇒ flag toujours émis en prod).
# `--effort` enum {low,medium,high,xhigh,max}, `--model` alias ('opus'/'sonnet') ou nom complet (claude --help 2.1.114).
MODEL=$("$JQ_BIN" -r '.spec.invocation.model // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
EFFORT=$("$JQ_BIN" -r '.spec.invocation.effort // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
MODEL_FLAGS=();  [[ -n "$MODEL"  ]] && MODEL_FLAGS=(--model "$MODEL")
EFFORT_FLAGS=(); [[ -n "$EFFORT" ]] && EFFORT_FLAGS=(--effort "$EFFORT")
dbg "step jq invocation model='$MODEL' effort='$EFFORT'"

# =============================================================
# Settings pod-spécifiques (permissions/bypass). $POD_DIR/.lcars/settings.json, passé en flagSettings
# via --settings (ADDITIF, indépendant de --setting-sources). Les hooks humains, eux, ne fuitent plus
# au niveau du BIND (bwrap ne bind que .credentials.json, .claude/ pod-owned → 0 settings.json humain
# dans aucun tier user/project/local — P1/C9). Optionnel : si absent, pas de flag --settings.
# =============================================================

POD_SETTINGS_FILE="$POD_DIR/.lcars/settings.json"

# Bypass dialog : en mode skip-permissions, pré-accepter le DIALOGUE interactif (« 1. No / 2. Yes I
# accept ») qui hang un pod headless. Mécanisme (src leak v2.1.88, vérifié e2e 2026-06-01) :
# interactiveHelpers.tsx montre le dialogue ssi `!hasSkipDangerousModePermissionPrompt()`, qui lit
# `skipDangerousModePermissionPrompt` depuis userSettings|localSettings|flagSettings|policySettings.
# `--settings <file>` = source **flagSettings** ⇒ dans la liste, INDÉPENDANT de --setting-sources.
# On provisionne donc le flag dans le settings pod (merge si présent), claude_launch reste le
# propriétaire bout-en-bout du mode bypass (le flag + la levée du dialogue). Non-skip (rôle bridé
# par cap-profile) : on n'y touche pas. (Ex `bypassPermissionsModeAccepted` du global config :
# DÉPRÉCIÉ/migré — ne plus l'écrire.)
if [[ -z "$PERM_MODE" ]]; then
  mkdir -p "$POD_DIR/.lcars"
  if [[ -f "$POD_SETTINGS_FILE" ]]; then
    _merged="$("$JQ_BIN" '. + {skipDangerousModePermissionPrompt: true}' "$POD_SETTINGS_FILE")" \
      && printf '%s\n' "$_merged" > "$POD_SETTINGS_FILE" \
      || { dbg "EXIT: merge skipDangerousModePermissionPrompt fail"; echo "ERR: merge settings échoué" >&2; exit 1; }
  else
    printf '{ "skipDangerousModePermissionPrompt": true }\n' > "$POD_SETTINGS_FILE"
  fi
  dbg "step bypass dialog pré-accepté (skipDangerousModePermissionPrompt → $POD_SETTINGS_FILE)"
fi

# --setting-sources INCONDITIONNEL : exclut le tier 'user' (settings.json de l'humain en ~/.claude).
# NB (P1/C9) : ce flag NE suffit PAS à fermer la fuite des hooks — celle-ci passait par les tiers
# `project`/`local` (qu'il AUTORISE), dont la racine = cwd = POD_DIR = le .claude humain quand il
# était bindé entier. La fuite est fermée au BIND (.claude pod-owned, bwrap ne bind que les creds),
# pas par ce flag. `--settings` (additif/flagSettings) ajouté seulement si le fichier pod existe.
SETTINGS_FLAGS=(--setting-sources "$SETTING_SOURCES")
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  SETTINGS_FLAGS+=(--settings "$POD_SETTINGS_FILE")
  dbg "step settings pod détecté ($POD_SETTINGS_FILE) + --setting-sources $SETTING_SOURCES"
else
  dbg "step pas de settings pod ($POD_SETTINGS_FILE absent) ; --setting-sources $SETTING_SOURCES seul"
fi

# =============================================================
# R-CORE.comm — canal MCP fleet↔pod (le drive propre, structuré ; jamais de scraping terminal).
# .mcp-fleet.json (NOMMÉE ainsi, PAS `.mcp.json`, pour éviter l'auto-discovery + trust dialog),
# `alwaysLoad:true` au niveau serveur porté par l'émetteur (pod.ex/spawner) — sinon les tools MCP
# sont DÉFÉRÉS derrière ToolSearch (absents du prompt turn-1). Le launcher reste content-agnostique :
# il transmet la config telle quelle via --strict-mcp-config (n'utilise QUE cette config).
# =============================================================

MCP_CONFIG="$POD_DIR/.mcp-fleet.json"
MCP_FLAGS=()
if [[ -f "$MCP_CONFIG" ]]; then
  MCP_FLAGS=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  dbg "step MCP config détectée ($MCP_CONFIG) → --strict-mcp-config"
else
  # IRON LAW : MCP est le canal de comm UNIQUE. Un pod réel SANS .mcp-fleet.json = bug de config
  # amont (l'émetteur doit toujours le provisionner). Le launcher reste content-agnostique (ne
  # fail-fast pas), mais c'est anormal.
  dbg "WARN: pas de MCP config ($MCP_CONFIG absent) — ANORMAL pour un pod réel (provisioning amont manquant)"
fi

# =============================================================
# Session : UUID pré-alloué (--session-id exige un UUID — vérif binaire ; JAMAIS un nom lisible).
#   1ʳᵉ création : --session-id <UUID>   (PROVEN : crée la session avec cet UUID).
#   recovery     : --resume <UUID>       (PROVEN : reprend, contexte préservé serveur Anthropic).
#   Nom lisible visible Desktop = axe SÉPARÉ : --remote-control-session-name-prefix (suffixe auto).
# =============================================================

if [[ "$POD_RESUME" == "1" ]]; then
  SESSION_FLAGS=(--resume "$SESSION_ID")
else
  SESSION_FLAGS=(--session-id "$SESSION_ID")
fi
dbg "step session flags : ${SESSION_FLAGS[*]}"

# =============================================================
# exec claude INTERACTIF marionnette-PTY (ADR-G). PAS -p, PAS stream-json, PAS budget, PAS de
# prompt positionnel (mandat = MCP get_task, IV.4). PAS de script(1)/inner-script : le PTY est
# tmux (bwrap_launch, N0) ⇒ exec direct = argv propre de bout en bout (lève F-1b-04). RC-at-startup
# = flag --remote-control (PROVEN sous PTY 2026-05-31 ; accepté silencieusement hors --help ; sans
# TTY le binaire bascule en --print-like — le PTY tmux assure le mode interactif RC). SP inline argv.
# =============================================================

dbg "step pre-exec claude --remote-control (perm=${PERM_FLAGS[*]} bin=$CLAUDE_BIN)"
exec "$CLAUDE_BIN" \
    --remote-control \
    "${SESSION_FLAGS[@]}" \
    --remote-control-session-name-prefix "$SESSION_NAME_PREFIX" \
    --system-prompt "$SP" \
    "${PERM_FLAGS[@]}" \
    --allowedTools "$ALLOWED_TOOLS" \
    --disallowedTools "$DISALLOWED_TOOLS" \
    "${MODEL_FLAGS[@]+"${MODEL_FLAGS[@]}"}" \
    "${EFFORT_FLAGS[@]+"${EFFORT_FLAGS[@]}"}" \
    ${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"} \
    ${MCP_FLAGS[@]+"${MCP_FLAGS[@]}"}
