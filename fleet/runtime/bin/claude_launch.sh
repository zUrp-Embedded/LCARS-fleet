#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — INTERACTIVE claude vendor launcher, PTY-puppet (Ring 1, N1 frontier, subscription)
#
# Vendor-specific launcher for the interactive `claude` REPL of LCARS v2 under ADR-G
# (Ring 1 pod primitive, level-1 vendor frontier, `claude_*` prefix).
# RC-at-startup goes through the `--remote-control` flag, PROVEN under a PTY. The one-shot
# `script(1)`-PTY model (brief = CLI prompt) is FORBIDDEN by ADR-G IV.1/IV.2.
#
# Invoked as the COMMAND by an N0 launcher — `bin/bwrap_launch.sh` (containment: bwrap) OR
# `bin/host_launch.sh` (containment: none, host without sandbox — LAUNCH-Q). The PTY is tmux's,
# provided by the N0 launcher: this launcher does NOT hold the PTY (no more `script -q`/inner-script)
# and does NOT carry the brief (that arrives over MCP get_work_item). Containment + tmux + per-pod
# socket = N0. Auth = Anthropic's native claudeDir (RW bind under bwrap; HOME = the human's real home
# on the host), zero OAuth env in :bind mode.
#
# Strict N1 vendor frontier (IX.3): `claude` flags only, never `bwrap`/`tmux`/`unshare`.
# A second vendor means a co-located `bin/openai_launch.sh`.
#
# Usage : claude_launch.sh <role> <pod_id> <pod_dir>
#   The SP is NOT in the argv: it is read from $POD_DIR/.lcars/system-prompt.md (written by the spawner
#   in do_project) via --system-prompt-file. Reason: an SP in the argv leaked into /proc/<pid>/cmdline and
#   brushed ARG_MAX. Measured on 2.1.177: --system-prompt-file is replace + TRUSTED (unlike inline, which
#   goes through the anti-injection filter). `.lcars/` is readable in-sandbox (pod_dir bind). The
#   "never a file" onboarding rule targeted `.claude/system-prompt.md`, masked by the creds bind — it does
#   NOT apply to `.lcars/`.
# Identity env (supplied by the spawner; not subject to masking, so env is fine here, unlike the SP):
#   LCARS_POD_SESSION_ID          PRE-ALLOCATED session UUID (uuidgen, state.json at spawn) — required
#   LCARS_POD_RESUME              0 = first creation (--session-id); 1 = recovery (--resume)
#   LCARS_POD_SESSION_NAME_PREFIX Desktop-readable RC name prefix (<human>_<role>) — required
#
# Exit codes:
#   0   : success (propagated through exec)
#   1   : setup error (cap-profile/jq/claude binary missing, empty args/SP, missing session env)
#   *   : propagated claude crash

set -euo pipefail

# =============================================================
# Config (overridable via env, for testability)
# =============================================================

# Vendor binary: LCARS_CLAUDE_BIN is set by bwrap (--setenv = POD_VENDOR_BIN = the OWNING HUMAN's
# per-user claude, relocated into the pod; Anthropic's native auto-update). Fallback = the pod's PATH
# ($POD_DIR/.local/bin first, under bwrap) ⇒ NEVER the system /usr/local apt build (stale, breaks
# auto-update). Fail-fast when missing — no silent fallback: a pod on a stale binary is a recoverable
# breakage left unrecovered.
CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
: "${CLAUDE_BIN:?claude binary not found (LCARS_CLAUDE_BIN set by bwrap, or the per-user ~/.local PATH)}"
JQ_BIN="${LCARS_JQ_BIN:-/usr/bin/jq}"

# =============================================================
# POSITIONAL args: <role> <pod_id> <pod_dir>
# =============================================================

if [[ $# -ne 3 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir>" >&2
  exit 1
fi

ROLE="$1"
POD_ID="$2"
# #monde-propre Stage B: under bwrap the REAL pod_dir ($3) is relocated behind LCARS_POD_HOME
# (/home/.pod); claude_launch runs INSIDE the sandbox, so its paths (.claude.json, .lcars, system-prompt)
# must point at the INTRA-POD home. Host pods (host_launch): LCARS_POD_HOME is absent → the real $3.
# Gated, zero effect when unset.
POD_DIR="${LCARS_POD_HOME:-$3}"
# SP OUT OF THE ARGV (/proc/cmdline leak + brushes ARG_MAX): the source is the file the spawner writes in
# do_project (pod.ex). `.lcars/` is readable in-sandbox (cf. --settings, pod_dir bind). claude reads it via
# --system-prompt-file (verified on claude 2.1.177: -file is replace + trusted).
SP_FILE="$POD_DIR/.lcars/system-prompt.md"

# =============================================================
# Session: UUID PRE-ALLOCATED by the spawner (uuidgen, persisted in state.json at spawn).
# Identity supplied by the orchestrator (VII.1) ⇒ env is fine here, unlike an SP travelling in the argv.
# =============================================================

SESSION_ID="${LCARS_POD_SESSION_ID:?session UUID required (pre-allocated by the spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"                          # 0 = first creation; 1 = recovery
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?RC name prefix required (<human>_<role>)}"

# Permission (#kill-yolo): the world is shaped (bwrap RO/RW + cap-profile allow/deny), so
# --dangerously-skip-permissions is NOT used any more — it NEUTRALISED our own lists (a leftover from the
# "agents in the wild" era, before bwrap containment). The mode comes from the CAP-PROFILE
# (`.spec.invocation.permission_mode`, default `default` → lists ENFORCED) over an IN-SANDBOX channel (the
# JSON sits in POD_DIR and is readable), NOT over the env: bwrap --clearenv would strip
# LCARS_PERMISSION_MODE, so the mode travels in the JSON. Host override = LCARS_PERMISSION_MODE
# (host_launch propagates the env). Derivation is DEFERRED until CAP_PROFILE_JSON below.
PERM_ENV_OVERRIDE="${LCARS_PERMISSION_MODE:-}"
# --settings is ADDITIVE ⇒ --setting-sources MUST exclude 'user', otherwise the human's settings bleed
# into the pod. Default project,local — 'user' is FORBIDDEN (fleet_spawner v2 §G).
SETTING_SOURCES="${LCARS_SETTING_SOURCES:-project,local}"

# =============================================================
# Debug trace #585 — appends to POD_DIR/claude_launch.dbg (bwrap RW bind → survives host-side for a
# post-mortem). Pinpoints a silent exit point (sf #585 diagnosis).
# =============================================================
dbg() { echo "[$(date -u +%H:%M:%S.%3N)] $*" >> "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true; }
: > "${POD_DIR:-/tmp}/claude_launch.dbg" 2>/dev/null || true
dbg "start ROLE=$ROLE POD_ID=$POD_ID POD_DIR=$POD_DIR session=$SESSION_ID resume=$POD_RESUME prefix=$SESSION_NAME_PREFIX PWD=$(pwd) HOME=${HOME:-} USER=$(id -un 2>/dev/null||echo ?)"
dbg "auth claudeDir bind: $([ -f "$HOME/.claude/.credentials.json" ] && echo 'creds present' || echo 'MISSING')"

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  dbg "EXIT: empty role/pod_id/pod_dir args"
  echo "ERR: role, pod_id and pod_dir must be non-empty" >&2
  exit 1
fi
if [[ ! -s "$SP_FILE" ]]; then
  dbg "EXIT: SP file missing/empty: $SP_FILE"
  echo "ERR: SP file $SP_FILE missing or empty (written by Fleet.Spawner do_project)" >&2
  exit 1
fi
dbg "step SP_FILE OK ($SP_FILE, $(wc -c < "$SP_FILE" 2>/dev/null) o)"
dbg "step args-non-empty OK"

# =============================================================
# Setup checks
# =============================================================

if [[ ! -x "$CLAUDE_BIN" ]]; then
  dbg "EXIT: CLAUDE_BIN missing/not-x: $CLAUDE_BIN ls=$(ls -la "$CLAUDE_BIN" 2>&1)"
  echo "ERR: claude binary missing or not executable: $CLAUDE_BIN" >&2
  exit 1
fi
dbg "step CLAUDE_BIN OK ($CLAUDE_BIN)"

if [[ ! -x "$JQ_BIN" ]]; then
  dbg "EXIT: JQ_BIN missing/not-x: $JQ_BIN"
  echo "ERR: jq binary missing or not executable: $JQ_BIN (parsing cap-profile JSON)" >&2
  exit 1
fi
dbg "step JQ_BIN OK ($JQ_BIN)"

CAP_PROFILE_JSON="$POD_DIR/.cap-profile.json"
if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  dbg "EXIT: cap-profile missing: $CAP_PROFILE_JSON ls_pod=$(ls -la "$POD_DIR" 2>&1)"
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi
dbg "step CAP_PROFILE OK"

# =============================================================
# Onboarding/trust skip (interactive): without it claude blocks on the first-run dialog. A minimal
# .claude.json at the root of the pod HOME ($POD_DIR, outside .claude/). The `projects` key is the agent's
# REAL cwd (`LCARS_POD_CWD` = the workspace when a project is cloned, else $POD_DIR) — otherwise /init
# would run in a non-onboarded dir (P2 mundo invocado: the agent pops into an already-onboarded project).
# (.claude/ is pod-owned: bwrap binds ONLY .credentials.json there — P1/C9.)
# (The bypass acceptance is NOT here any more: `bypassPermissionsModeAccepted` of the global config moved
#  to settings.json/`skipDangerousModePermissionPrompt` — cf. the "bypass dialog" block below.)
# =============================================================

# `|| true` is MANDATORY: under `set -euo pipefail`, a `--version` in an unexpected format (grep with no
# match, rc=1) killed the launcher HERE with an opaque exit 1, BEFORE the ${VER:-2.1.150} fallback below
# could ever be reached → EVERY pod dead on a mere vendor format change. Non-fatal by construction: an
# empty VER lets the fallback play and we trace it (dbg + stderr) instead of dying.
VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -z "$VER" ]]; then
  dbg "WARN: vendor version undetectable ('$CLAUDE_BIN --version' with no x.y.z match) — falling back to lastOnboardingVersion 2.1.150"
  echo "WARN: claude --version in an unexpected format — falling back to lastOnboardingVersion 2.1.150" >&2
fi
POD_CWD="${LCARS_POD_CWD:-$POD_DIR}"
# Claude Desktop visibility — read HERE because it GATES remoteControlAtStartup in the .claude.json below.
# `spec.invocation.remote_control: false` (qualifier/reviewer judges) means a pod INVISIBLE in Desktop.
# There are TWO RC levers to keep consistent, or the judge shows up anyway: (1) the --remote-control flag
# (RC_FLAGS, further down) AND (2) remoteControlAtStartup in .claude.json. If remoteControlAtStartup stays
# hardcoded true, claude ENABLES RC at boot EVEN without the flag → the judge leaks into Desktop. Both are
# therefore driven by the same flag, from a single shared jq read.
# jq TRAP: `.x // true` treats `false` AND null as "empty", so `false // true` = true. The old `// true`
# therefore SWALLOWED the judges' remote_control:false — forced RC was THE bug. Defaulting on null ONLY
# preserves an explicit false: null -> true (engineer/arch, absent), false -> false (judges), true -> true.
REMOTE_CONTROL=$("$JQ_BIN" -r '.spec.invocation.remote_control | if . == null then true else . end' "$CAP_PROFILE_JSON" 2>/dev/null)
RC_STARTUP=$([[ "$REMOTE_CONTROL" != "false" ]] && echo true || echo false)

# SOLE writer of .claude.json (N1 vendor frontier; pod.ex at N0 no longer writes it — this `cat >` would
# clobber it). remoteControlAtStartup is conditional (see above); hasUsedRemoteControl/remoteDialogSeen stay
# true: they PRE-ACCEPT the RC dialog (which would otherwise block the interactive boot again) WITHOUT
# forcing RC on. `projects` is the agent's real cwd ($POD_CWD), not $POD_DIR.
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "remoteControlAtStartup": $RC_STARTUP, "hasUsedRemoteControl": true, "remoteDialogSeen": true,
  "projects": { "$POD_CWD": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF
dbg "step claude.json provisioned (VER=${VER:-?}, remoteControlAtStartup=$RC_STARTUP)"

# =============================================================
# Tools from the resolved cap-profile JSON (string-keyed, consistent with fleet_cap_profile L100).
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq allowedTools fail rc=$? out=$ALLOWED_TOOLS"; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { dbg "EXIT: jq disallowedTools fail rc=$? out=$DISALLOWED_TOOLS"; exit 1; }
# #kill-yolo: the fleet MCP protocol is UNIVERSAL (every pod does get_work_item/submit_result) → appended
# to the allowlist. Under --permission-mode default an unlisted MCP tool PROMPTS ("Do you want to
# proceed?") → headless hang. Role-specific MCP tools (the arch's create_*/get_issue_status) stay in the
# cap-profile.
ALLOWED_TOOLS="${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}mcp__fleet__get_work_item,mcp__fleet__submit_result"
dbg "step jq tools OK allowed='$ALLOWED_TOOLS' disallowed='$DISALLOWED_TOOLS'"

# Permission mode (#kill-yolo): env override (host), else `cap-profile.spec.invocation.permission_mode`,
# default "default" (→ `--permission-mode default`, lists ENFORCED; no more --dangerously-skip bypassing
# them). N0 (LaunchSpec.permission_mode) already BOUNDS the mode to the CLI enum and REFUSES a
# present-but-out-of-enum value BEFORE any launch (DR-021), so this read carries an already-validated
# value. The `// "default"` therefore only covers ABSENCE (unspecified = enforced, which is legitimate);
# a present-but-invalid value cannot reach here (N0 refused the pod) and `claude`'s own enum would reject
# it as a last resort. No silent normalisation.
PERM_MODE="${PERM_ENV_OVERRIDE:-$("$JQ_BIN" -r '.spec.invocation.permission_mode // "default"' "$CAP_PROFILE_JSON" 2>/dev/null)}"
[[ -z "$PERM_MODE" ]] && PERM_MODE="default"
PERM_FLAGS=(--permission-mode "$PERM_MODE")
dbg "step perm mode=$PERM_MODE (env_override='${PERM_ENV_OVERRIDE}')"

# Model + effort from the catalogue (spec.invocation) → claude flags. Absent/null ⇒ the flag is omitted
# (claude keeps its binary default; the 7 canon cap-profiles set them, so the flag is always emitted in
# prod). `--effort` enum {low,medium,high,xhigh,max}; `--model` takes an alias ('opus'/'sonnet') or a full
# name.
MODEL=$("$JQ_BIN" -r '.spec.invocation.model // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
EFFORT=$("$JQ_BIN" -r '.spec.invocation.effort // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
MODEL_FLAGS=();  [[ -n "$MODEL"  ]] && MODEL_FLAGS=(--model "$MODEL")
EFFORT_FLAGS=(); [[ -n "$EFFORT" ]] && EFFORT_FLAGS=(--effort "$EFFORT")
dbg "step jq invocation model='$MODEL' effort='$EFFORT'"

# --remote-control flag: OMITTED when remote_control:false (a judge) → the pod still runs INTERACTIVE
# under the tmux PTY (MCP/wake intact) but stays INVISIBLE in Desktop. REMOTE_CONTROL was read above (it
# also gates remoteControlAtStartup in .claude.json — both RC levers share that one read).
# On-demand debugging: a `/remote-control <slot>` sent via send-key turns a judge's visibility back on.
RC_FLAGS=()
# #chantier pod-seed: the EXACT RC name goes through `--remote-control "<name>"` (the optional positional
# name), NOT `--remote-control-session-name-prefix`, which appends an auto suffix — random names piling up.
# SESSION_NAME_PREFIX now carries the full `<project>_<role>` name (set by the spawner, pod.ex).
[[ "$REMOTE_CONTROL" != "false" ]] &&
  RC_FLAGS=(--remote-control "$SESSION_NAME_PREFIX")
dbg "step jq remote_control='$REMOTE_CONTROL' (RC=${#RC_FLAGS[@]} flags)"

# =============================================================
# Pod-specific settings (permissions/bypass). $POD_DIR/.lcars/settings.json, passed as flagSettings via
# --settings (ADDITIVE, independent of --setting-sources). The human's hooks no longer leak, and they are
# stopped at the BIND (bwrap binds only .credentials.json, .claude/ is pod-owned → zero human settings.json
# in any user/project/local tier — P1/C9). Optional: no file, no --settings flag.
# =============================================================

POD_SETTINGS_FILE="$POD_DIR/.lcars/settings.json"

# Bypass dialog: under PERM_MODE=bypassPermissions, pre-accept the interactive DIALOG ("1. No / 2. Yes I
# accept") that hangs a headless pod. Mechanism (observed on v2.1.88, verified e2e): interactiveHelpers.tsx
# shows the dialog iff `!hasSkipDangerousModePermissionPrompt()`, which reads
# `skipDangerousModePermissionPrompt` from userSettings|localSettings|flagSettings|policySettings.
# `--settings <file>` IS the **flagSettings** source ⇒ in that list, and INDEPENDENT of --setting-sources.
# So the flag is provisioned in the pod settings (merged if the file exists) and claude_launch stays the
# end-to-end owner of bypass mode: the flag AND the lifting of the dialog. Outside bypass (default, or a
# role restricted by its cap-profile) we do not touch it. The old `bypassPermissionsModeAccepted` of the
# global config is DEPRECATED/migrated — do not write it any more.
# F-POD-AUTOMEM: the pod settings file is written UNCONDITIONALLY. It used to be bypass-only, but every pod
# runs --permission-mode default since kill-yolo, so it was never written. `autoMemoryEnabled:false` turns
# off the pod's claude auto-memory (siloed memory, useless to the fleet, doctrine pollution BUG-3) — for
# EVERY PERM_MODE.
# The guard is keyed on the enum's REAL VALUE (`bypassPermissions`, launch_spec.ex @permission_modes):
# PERM_MODE is NEVER empty (the "default" above guarantees it), so the old `-z "$PERM_MODE"` guard was DEAD
# and a bypassPermissions pod HUNG at boot on the un-pre-accepted dialog. Latent today (no canon cap-profile
# runs in bypass) — a defensive gesture.
mkdir -p "$POD_DIR/.lcars"
POD_SETTINGS_JSON='{"autoMemoryEnabled":false}'
[[ "$PERM_MODE" == "bypassPermissions" ]] && POD_SETTINGS_JSON="$("$JQ_BIN" -nc --argjson b "$POD_SETTINGS_JSON" '$b + {skipDangerousModePermissionPrompt:true}')"
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  _merged="$("$JQ_BIN" --argjson add "$POD_SETTINGS_JSON" '. + $add' "$POD_SETTINGS_FILE")" \
    && printf '%s\n' "$_merged" > "$POD_SETTINGS_FILE" \
    || { dbg "EXIT: pod settings merge failed"; echo "ERR: pod settings merge failed" >&2; exit 1; }
else
  printf '%s\n' "$POD_SETTINGS_JSON" > "$POD_SETTINGS_FILE"
fi
dbg "step pod settings written (autoMemoryEnabled=false → $POD_SETTINGS_FILE)"

# --setting-sources is UNCONDITIONAL: it excludes the 'user' tier (the human's ~/.claude/settings.json).
# NOTE (P1/C9): this flag is NOT enough to close the hook leak — that one came through the `project`/`local`
# tiers, which it ALLOWS, and whose root is cwd = POD_DIR = the human's .claude back when it was bound
# whole. The leak is closed at the BIND (.claude pod-owned, bwrap binds only the creds), not by this flag.
# `--settings` (additive/flagSettings) is added only when the pod file exists.
SETTINGS_FLAGS=(--setting-sources "$SETTING_SOURCES")
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  SETTINGS_FLAGS+=(--settings "$POD_SETTINGS_FILE")
  dbg "step pod settings found ($POD_SETTINGS_FILE) + --setting-sources $SETTING_SOURCES"
else
  dbg "step no pod settings ($POD_SETTINGS_FILE absent); --setting-sources $SETTING_SOURCES alone"
fi

# =============================================================
# R-CORE.comm — the fleet↔pod MCP channel (the clean, structured drive; never terminal scraping).
# .mcp-fleet.json is NAMED that way, NOT `.mcp.json`, to avoid auto-discovery and its trust dialog.
# `alwaysLoad:true` at server level is carried by the emitter (pod.ex/spawner) — without it the MCP tools
# are DEFERRED behind ToolSearch and absent from the turn-1 prompt. The launcher stays content-agnostic: it
# forwards the config as-is via --strict-mcp-config (which uses ONLY that config).
# =============================================================

MCP_CONFIG="$POD_DIR/.mcp-fleet.json"
MCP_FLAGS=()
if [[ -f "$MCP_CONFIG" ]]; then
  MCP_FLAGS=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
  dbg "step MCP config found ($MCP_CONFIG) → --strict-mcp-config"
else
  # IRON LAW: MCP is the ONE communication channel. A real pod WITHOUT .mcp-fleet.json is an upstream
  # config bug — the emitter must always provision it. The launcher stays content-agnostic (it does not
  # fail-fast), but this is abnormal.
  dbg "WARN: no MCP config ($MCP_CONFIG absent) — ABNORMAL for a real pod (upstream provisioning missing)"
fi

# =============================================================
# Session: pre-allocated UUID (--session-id requires a UUID — the binary checks it; NEVER a readable name).
#   first creation : --session-id <UUID>   (PROVEN: creates the session with that UUID).
#   recovery       : --resume <UUID>       (PROVEN: resumes, context preserved on Anthropic's server).
#   The Desktop-visible readable name is a SEPARATE axis: --remote-control-session-name-prefix (auto suffix).
# =============================================================

if [[ "$POD_RESUME" == "1" ]]; then
  SESSION_FLAGS=(--resume "$SESSION_ID")
else
  SESSION_FLAGS=(--session-id "$SESSION_ID")
fi
dbg "step session flags: ${SESSION_FLAGS[*]}"

# =============================================================
# exec INTERACTIVE claude, PTY-puppet (ADR-G). NO -p, NO stream-json, NO budget, NO positional prompt —
# the brief arrives over MCP get_work_item (IV.4). NO script(1)/inner-script: the PTY is tmux's
# (bwrap_launch, N0), so a direct exec keeps the argv clean end to end (lifts F-1b-04). RC-at-startup is the
# --remote-control flag (PROVEN under a PTY; accepted silently though absent from --help; with no TTY the
# binary falls back to --print-like — the tmux PTY is what guarantees interactive RC mode).
# The SP travels via --system-prompt-file (OUT of the argv): read from $SP_FILE (.lcars/system-prompt.md),
# trusted+replace.
# =============================================================

# Tool search stays at the VENDOR DEFAULT (on): disabling it (ENABLE_TOOL_SEARCH=false) was
# weighed 2026-07-18 and REJECTED — it would load every deferred schema into EVERY pod's
# context (judges included, who arm nothing) to save a single ToolSearch call per
# long-lived pod life, and it diverges from the vendor default on a compat knob. The
# arming discipline lives in the SPs (imperative STEP 0), not in a launcher env.

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
