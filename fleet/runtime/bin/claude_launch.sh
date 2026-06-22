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
# Invoqué comme COMMAND par un launcher N0 — `bin/bwrap_launch.sh` (containment: bwrap)
# OU `bin/host_launch.sh` (containment: none, host sans sandbox — LAUNCH-Q). Le PTY est
# celui de tmux (fourni par le launcher N0) — ce launcher NE tient PLUS le PTY (plus de
# `script -q`/inner-script) et NE porte PLUS le mandat (il arrive par MCP get_task).
# Containment + tmux + socket-par-pod = N0. Auth = claudeDir natif Anthropic (bind RW sous
# bwrap ; HOME = home humain réel sous host), zéro env OAuth en mode :bind.
#
# Frontière vendor N1 stricte (IX.3) : flags `claude` uniquement, jamais `bwrap`/
# `tmux`/`unshare`. Si 2e vendor → `bin/openai_launch.sh` co-localisé.
#
# Usage : claude_launch.sh <role> <pod_id> <pod_dir>
#   SP HORS argv (2026-06-14) : lu depuis $POD_DIR/.lcars/system-prompt.md (écrit par le spawner en
#   do_project) via --system-prompt-file. Motif : le SP en argv fuitait /proc/<pid>/cmdline + frôlait
#   ARG_MAX. Empirique 2.1.177 : --system-prompt-file = replace + TRUSTED (≠ inline, qui passe au filtre
#   anti-injection). `.lcars/` lisible in-sandbox (bind pod_dir). (L'onboarding-DN « jamais fichier »
#   visait `.claude/system-prompt.md` masqué par le bind creds — ne s'applique PAS à `.lcars/`.)
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
# Args POSITIONNELS : <role> <pod_id> <pod_dir>
# =============================================================

if [[ $# -ne 3 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
# #monde-propre Stage B : en bwrap, le pod_dir RÉEL ($3) est relocalisé derrière LCARS_POD_HOME (/home/.pod) ;
# claude_launch tourne DANS le sandbox → ses paths (.claude.json, .lcars, system-prompt) doivent pointer le
# home INTRA-POD. Host pods (host_launch) : LCARS_POD_HOME absent → $3 réel. Gaté, zéro effet si non posé.
POD_DIR="${LCARS_POD_HOME:-$3}"
# SP HORS ARGV (fuite /proc/cmdline + frôle ARG_MAX) : source = fichier écrit par le spawner en
# do_project (pod.ex). `.lcars/` est lisible in-sandbox (cf. --settings, bind pod_dir). claude le lit
# via --system-prompt-file (vérifié 2026-06-14, claude 2.1.177 : -file = replace + trusted).
SP_FILE="$POD_DIR/.lcars/system-prompt.md"

# =============================================================
# Session : UUID PRÉ-ALLOUÉ par le spawner (uuidgen, persisté state.json au spawn).
# Identité fournie par l'orchestrateur (VII.1) ⇒ env OK (≠ SP qui voyage en argv).
# =============================================================

SESSION_ID="${LCARS_POD_SESSION_ID:?UUID de session requis (pré-alloué par le spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"                          # 0 = 1ʳᵉ création ; 1 = recovery
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?préfixe nom RC requis (<human>_<role>)}"

# Permission (#kill-yolo 2026-06-22) : le monde est shapé (bwrap RO/RW + cap-profile allow/deny) → on
# N'utilise PLUS --dangerously-skip-permissions, qui NEUTRALISAIT nos listes (héritage « agents dans la
# nature », d'avant le sanctuaire bwrap). Le mode vient du CAP-PROFILE (`.spec.invocation.permission_mode`,
# défaut `default` → listes ENFORCED) — canal IN-SANDBOX (la JSON est dans POD_DIR, lisible), PAS l'env
# (bwrap --clearenv stripperait LCARS_PERMISSION_MODE, et bwrap_launch est SANCTUAIRE). Override host =
# LCARS_PERMISSION_MODE (host_launch propage l'env). Dérivation DÉFÉRÉE après CAP_PROFILE_JSON (infra).
PERM_ENV_OVERRIDE="${LCARS_PERMISSION_MODE:-}"
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
if [[ ! -s "$SP_FILE" ]]; then
  dbg "EXIT: SP file absent/vide : $SP_FILE"
  echo "ERR: SP file $SP_FILE absent ou vide (écrit par Fleet.Spawner do_project)" >&2
  exit 1
fi
dbg "step SP_FILE OK ($SP_FILE, $(wc -c < "$SP_FILE" 2>/dev/null) o)"
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
# F115/F157 : ÉCRIVAIN UNIQUE du .claude.json (N1, frontière vendor). Les 3 clés remote-control
# (remoteControlAtStartup/hasUsedRemoteControl/remoteDialogSeen) sont posées ICI — avant, pod.ex (N0)
# les écrivait puis ce `cat >` les clobberait → le dialog RC re-bloquait au boot (ADR-G). La clé
# `projects` = le CWD réel de l'agent ($POD_CWD), pas $POD_DIR.
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "remoteControlAtStartup": true, "hasUsedRemoteControl": true, "remoteDialogSeen": true,
  "projects": { "$POD_CWD": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF
dbg "step claude.json provisionné (VER=${VER:-?}, RC keys posées)"

# F-RC-ORG (2026-06-22) : merge l'oauthAccount (org/compte de l'humain, posé par pod.ex depuis son
# ~/.claude.json) → claude peut « determine your organization » pour l'éligibilité Remote Control (Desktop).
# Absent/échec → skip (best-effort, non bloquant : la fleet tourne sans Desktop).
OAUTH_FILE="$POD_DIR/.lcars/oauth_account.json"
if [[ -f "$OAUTH_FILE" ]]; then
  _cj="$("$JQ_BIN" -s '.[0] * .[1]' "$POD_DIR/.claude.json" "$OAUTH_FILE" 2>/dev/null)" \
    && printf '%s\n' "$_cj" > "$POD_DIR/.claude.json" \
    && dbg "step oauthAccount mergé (.claude.json → RC org éligible)" \
    || dbg "WARN: merge oauthAccount échoué — RC org indispo (non bloquant)"
fi

# =============================================================
# Tools depuis cap-profile JSON resolved (string-keyed, cohérent fleet_cap_profile L100).
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq allowedTools fail rc=$? out=$ALLOWED_TOOLS"; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq disallowedTools fail rc=$? out=$DISALLOWED_TOOLS"; exit 1; }
# #kill-yolo : protocole MCP fleet UNIVERSEL (tout pod fait get_task/submit_result) → append à l'allowlist.
# En --permission-mode default, un tool MCP non listé PROMPTE (« Do you want to proceed? ») → hang headless.
# (Les MCP role-specific — create_*/get_ticket_status de l'arch — restent au cap-profile.)
ALLOWED_TOOLS="${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}mcp__fleet__get_task,mcp__fleet__submit_result"
dbg "step jq tools OK allowed='$ALLOWED_TOOLS' disallowed='$DISALLOWED_TOOLS'"

# Mode permission (#kill-yolo) : override env (host) sinon `cap-profile.spec.invocation.permission_mode`,
# défaut "default" (→ `--permission-mode default`, listes ENFORCED ; fini --dangerously-skip qui bypassait).
PERM_MODE="${PERM_ENV_OVERRIDE:-$("$JQ_BIN" -r '.spec.invocation.permission_mode // "default"' "$CAP_PROFILE_JSON" 2>/dev/null)}"
[[ -z "$PERM_MODE" ]] && PERM_MODE="default"
PERM_FLAGS=(--permission-mode "$PERM_MODE")
dbg "step perm mode=$PERM_MODE (env_override='${PERM_ENV_OVERRIDE}')"

# Model + effort depuis le catalogue (spec.invocation) → flags claude. Absent/null ⇒ flag omis
# (claude garde son défaut binaire ; les 7 cap-profiles canon les posent ⇒ flag toujours émis en prod).
# `--effort` enum {low,medium,high,xhigh,max}, `--model` alias ('opus'/'sonnet') ou nom complet (claude --help 2.1.114).
MODEL=$("$JQ_BIN" -r '.spec.invocation.model // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
EFFORT=$("$JQ_BIN" -r '.spec.invocation.effort // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
MODEL_FLAGS=();  [[ -n "$MODEL"  ]] && MODEL_FLAGS=(--model "$MODEL")
EFFORT_FLAGS=(); [[ -n "$EFFORT" ]] && EFFORT_FLAGS=(--effort "$EFFORT")
dbg "step jq invocation model='$MODEL' effort='$EFFORT'"

# Visibilité Claude Desktop : `invocation.remote_control: false` (juges qualifier/reviewer) → on OMET
# `--remote-control` (+ son nom de session) → le pod tourne INTERACTIF sous le PTY tmux (MCP/wake
# intacts) mais reste INVISIBLE dans Desktop (RC = couche d'attache Desktop seule). Absent/true = visible.
# Debug à la demande : un `/remote-control <slot>` envoyé en send-key rallume la visibilité d'un juge.
REMOTE_CONTROL=$("$JQ_BIN" -r '.spec.invocation.remote_control // true' "$CAP_PROFILE_JSON" 2>/dev/null)
RC_FLAGS=()
# #chantier pod-seed : nom RC EXACT via `--remote-control "<nom>"` (le nom optionnel positionnel),
# PAS `--remote-control-session-name-prefix` (qui colle un suffixe auto = « noms random qui s'empilent »).
# SESSION_NAME_PREFIX porte désormais le nom complet `<projet>_<role>` (posé par le spawner, pod.ex).
[[ "$REMOTE_CONTROL" != "false" ]] &&
  RC_FLAGS=(--remote-control "$SESSION_NAME_PREFIX")
dbg "step jq remote_control='$REMOTE_CONTROL' (RC=${#RC_FLAGS[@]} flags)"

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
# F-POD-AUTOMEM (2026-06-22) : settings pod INCONDITIONNEL (avant : skip-mode seul → or tous les pods sont
# en --permission-mode default depuis kill-yolo → jamais écrit). `autoMemoryEnabled:false` coupe l'auto-memory
# claude du pod (mémoire siloée, inutile à la fleet, pollution doctrine BUG-3) — TOUS PERM_MODE. En skip-mode
# (PERM_MODE vide) on AJOUTE `skipDangerousModePermissionPrompt:true` (pré-accepte le dialogue qui hang headless).
mkdir -p "$POD_DIR/.lcars"
POD_SETTINGS_JSON='{"autoMemoryEnabled":false}'
[[ -z "$PERM_MODE" ]] && POD_SETTINGS_JSON="$("$JQ_BIN" -nc --argjson b "$POD_SETTINGS_JSON" '$b + {skipDangerousModePermissionPrompt:true}')"
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  _merged="$("$JQ_BIN" --argjson add "$POD_SETTINGS_JSON" '. + $add' "$POD_SETTINGS_FILE")" \
    && printf '%s\n' "$_merged" > "$POD_SETTINGS_FILE" \
    || { dbg "EXIT: merge settings pod fail"; echo "ERR: merge settings pod échoué" >&2; exit 1; }
else
  printf '%s\n' "$POD_SETTINGS_JSON" > "$POD_SETTINGS_FILE"
fi
dbg "step settings pod écrit (autoMemoryEnabled=false → $POD_SETTINGS_FILE)"

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
# TTY le binaire bascule en --print-like — le PTY tmux assure le mode interactif RC).
# SP via --system-prompt-file (HORS argv) : lu depuis $SP_FILE (.lcars/system-prompt.md), trusted+replace.
# =============================================================

dbg "step pre-exec claude (RC=${#RC_FLAGS[@]} flags perm=${PERM_FLAGS[*]} bin=$CLAUDE_BIN sp_file=$SP_FILE)"
exec "$CLAUDE_BIN" \
    "${RC_FLAGS[@]}" \
    "${SESSION_FLAGS[@]}" \
    --system-prompt-file "$SP_FILE" \
    "${PERM_FLAGS[@]}" \
    --allowedTools "$ALLOWED_TOOLS" \
    --disallowedTools "$DISALLOWED_TOOLS" \
    "${MODEL_FLAGS[@]+"${MODEL_FLAGS[@]}"}" \
    "${EFFORT_FLAGS[@]+"${EFFORT_FLAGS[@]}"}" \
    ${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"} \
    ${MCP_FLAGS[@]+"${MCP_FLAGS[@]}"}
