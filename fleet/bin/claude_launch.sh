#!/usr/bin/env bash
# SOURCE: bin/claude_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — INTERACTIVE claude vendor launcher, PTY-puppet (N1 vendor frontier, subscription)
#
# Vendor-specific launcher for the interactive `claude` REPL of LCARS v2 under ADR-G
# (pod primitive, N1 vendor frontier, `claude_*` prefix).
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
#   LCARS_POD_SESSION_NAME_PREFIX Desktop-readable pod label (<project>#<ticket>_<role>, or
#                                 <project>_<role> when not ticket-bound) — required, verbatim
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
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?pod label required (Fleet.Layout.pod_label)}"

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
# The override is VALIDATED, not trusted: the FORBIDDEN rule above must hold mechanically for any
# LCARS_SETTING_SOURCES value too, or the env var is a one-word bypass of the containment frontier.
# 'user' in the override → refuse LOUD (fail-closed: a launch with human settings bled into the pod
# is worse than no launch; the operator sees exactly which knob to fix).
SETTING_SOURCES="${LCARS_SETTING_SOURCES:-project,local}"
SETTING_SOURCES="${SETTING_SOURCES// /}"
case ",${SETTING_SOURCES}," in
  *,user,*)
    echo "claude_launch: REFUSED — LCARS_SETTING_SOURCES contains 'user' (${SETTING_SOURCES})." >&2
    echo "claude_launch: 'user' would bleed the human's settings into the pod (forbidden, fleet_spawner v2 §G)." >&2
    exit 1
    ;;
esac

# =============================================================
# NO LAUNCH TRACE IN THE POD — deliberate, and it is not a gap to fill.
#
# This script runs INSIDE bwrap (cf. bwrap_launch.sh, ADR-G): everything it can write, the confined
# agent can read. A boot trace therefore handed the agent the recipe of its own box — permission
# mode and flags, model, effort, setting-sources, the vendor surface that was cut, whether its
# credentials are present. Redacting it field by field was tried (the tool lists became counts) and
# it is the wrong shape: the file stays a channel that must be curated forever, and one forgotten
# field re-opens the whole thing silently.
#
# There is no "write it host-side instead" either: no path outside the sandbox is reachable from in
# here without a bind, and a bind is exactly what the agent reads.
#
# Diagnosing a launch failure means touching this source and rebuilding anyway — it was never a flag
# to flip — so a permanent always-on trace bought a standing exposure against a debugging convenience
# that does not survive its own use case. Failures speak on **stderr**, which the operator collects
# outside and the agent does not read back.
#
# If you are here to re-add a trace: the answer is stderr, or a rebuild with a temporary local patch.
# Not a file under $POD_DIR.
# =============================================================

if [[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]]; then
  echo "ERR: role, pod_id and pod_dir must be non-empty" >&2
  exit 1
fi
if [[ ! -s "$SP_FILE" ]]; then
  echo "ERR: SP file $SP_FILE missing or empty (written by Fleet.Spawner do_project)" >&2
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
if [[ ! -f "$CAP_PROFILE_JSON" ]]; then
  echo "ERR: cap-profile $CAP_PROFILE_JSON missing (Fleet.Spawner ALLOCATE chantier 6)" >&2
  exit 1
fi

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
# empty VER lets the fallback play and we say so on stderr instead of dying.
VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -z "$VER" ]]; then
  echo "WARN: claude --version in an unexpected format — falling back to lastOnboardingVersion 2.1.150" >&2
fi
POD_CWD="${LCARS_POD_CWD:-$POD_DIR}"

# =============================================================
# LA SURFACE VENDOR — elle n'est pas montee, elle est DANS LE BINAIRE
# =============================================================
# Mesure du 2026-08-12 : `~/.local` ne contient que `bin/claude` (308 Mo), et le prompt de `/init`
# est compile dedans (`grep -c` sur l'executable : 2 occurrences). Aucun bind ne retire une commande
# compilee — le mecanisme qui borne tout le reste ici (« les droits vivent dans le montage ») ne peut
# structurellement pas atteindre ca. Le seul levier est un flag du vendor, et il existe :
#   claude --help  ->  --disable-slash-commands   Disable all skills
#
# CE QUE `/init` FERAIT DANS UN POD PRODUCTEUR, ET POURQUOI CE N'EST PAS THEORIQUE. Son prompt dit
# « analyze this codebase » (le cwd EST le depot : vrai chez un producteur), « if there's already a
# CLAUDE.md, suggest improvements to it » (c'est le fichier d'entree de tous les producteurs) et
# « be sure to prefix the file with `# CLAUDE.md / This file provides guidance…` » — un titre et une
# forme que l'extracteur de la fleet ne reconnait pas. L'etalon vendor et l'etalon LCARS ecrivent
# deux fichiers incompatibles sous le meme nom.
#
# LE PREDICAT EST « CE POD A UN DEPOT SOUS LA MAIN », PAS « IL NE DECLARE AUCUNE SKILL ». Les deux
# coincident aujourd'hui — 9 roles canon sur 10 declarent `skills: []`, et le seul qui en declare une
# (starfleet, `card-revision`) est justement celui qui n'entre dans aucun projet. Ce n'est pas une
# coincidence, c'est le meme axe vu deux fois : une skill equipe un role pour ce qu'il fait, et le
# role qui a besoin d'une skill n'a rien de monte a abimer. Mais coincider n'est pas causer :
# equiper l'engineer d'une skill de catalogue est un geste legitime, et il rouvrirait `/init` sur le
# role qui peut faire le plus de degats — en silence, sans que personne ne fasse le lien.
# On teste donc la propriete elle-meme : un `.git` au cwd = un depot que ce pod peut casser.
SKILL_FLAGS=()
if [[ -d "$POD_CWD/.git" ]]; then
  # LA COMBINAISON QUE LE FLAG NE PEUT PAS SERVIR — il coupe TOUT, catalogue compris. Un pod qui
  # cumule un depot et une skill montee est un cas que ni « couper » ni « laisser » ne sert
  # correctement, et le resoudre en silence reviendrait a sacrifier un des deux cotes sans le dire.
  # L'ensemble est VIDE aujourd'hui : on le nomme avant qu'il n'arrive, comme W-11 refuse un
  # catalogue qui declare un role qu'il ne peut pas equiper.
  # `|| true` OBLIGATOIRE, meme raison que le `--version` plus haut : sous `set -euo pipefail`, un
  # `ls` sur un repertoire absent — le cas NOMINAL, 9 roles sur 10 n'ont aucune skill — rend 2, et
  # `pipefail` propage ce 2 a toute la substitution. Sans lui, le launcher mourait ICI, exit 2 opaque,
  # sur le chemin le plus frequent.
  MOUNTED_SKILLS="$(ls -1 "$POD_DIR/.claude/skills" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "${MOUNTED_SKILLS// /}" ]]; then
    echo "ERR: ce pod a un depot au cwd ($POD_CWD) ET des skills montees ($MOUNTED_SKILLS)." >&2
    echo "     --disable-slash-commands coupe TOUTES les skills, catalogue compris : il ne peut pas" >&2
    echo "     servir ce cas. Retirer les skills de ce role, ou lui retirer son workspace." >&2
    exit 1
  fi
  SKILL_FLAGS=(--disable-slash-commands)
fi
# Claude Desktop visibility — read HERE because it GATES remoteControlAtStartup in the .claude.json below.
# `spec.invocation.remote_control: false` (qualifier/reviewer judges) means a pod INVISIBLE in Desktop.
# There are TWO RC levers to keep consistent, or the judge shows up anyway: (1) the --remote-control flag
# (RC_FLAGS, further down) AND (2) remoteControlAtStartup in .claude.json. If remoteControlAtStartup stays
# hardcoded true, claude ENABLES RC at boot EVEN without the flag → the judge leaks into Desktop. Both are
# therefore driven by the same value, read once here.
#
# THE RUNTIME DECIDES, THIS SCRIPT OBEYS. `LCARS_POD_REMOTE_CONTROL` carries the answer of
# `LaunchSpec.remote_control?/1`, the single authority. Re-deriving it here from the profile — as
# this script did — made TWO derivations of one fact, which agree exactly until something tries to
# change it: the half not reached then yields a pod VISIBLE in Desktop whose slot is never captured
# nor resumed (visible now, a fresh slot every boot — the "12 archs" bug wearing a new hat).
#
# The jq read survives as the STANDALONE fallback: this script is the N1 vendor frontier and is
# invoked by hand (bats, a debug run) with no runtime around it. It can only ever be the narrower
# answer — the declaration is the floor, and any widening lives upstream — so an absent env is a
# missing widening, never a wrongly-opened door.
# jq TRAP: `.x // true` treats `false` AND null as "empty", so `false // true` = true. The old `// true`
# therefore SWALLOWED the judges' remote_control:false — forced RC was THE bug. Defaulting on null ONLY
# preserves an explicit false: null -> true (engineer/arch, absent), false -> false (judges), true -> true.
if [[ -n "${LCARS_POD_REMOTE_CONTROL:-}" ]]; then
  REMOTE_CONTROL="$LCARS_POD_REMOTE_CONTROL"
else
  REMOTE_CONTROL=$("$JQ_BIN" -r '.spec.invocation.remote_control | if . == null then true else . end' "$CAP_PROFILE_JSON" 2>/dev/null)
fi
RC_STARTUP=$([[ "$REMOTE_CONTROL" != "false" ]] && echo true || echo false)

# SOLE writer of .claude.json (N1 vendor frontier; pod.ex at N0 no longer writes it — this `cat >` would
# clobber it). remoteControlAtStartup is conditional (see above); hasUsedRemoteControl/remoteDialogSeen stay
# true: they PRE-ACCEPT the RC dialog (which would otherwise block the interactive boot again) WITHOUT
# forcing RC on. `projects` is the agent's real cwd ($POD_CWD), not $POD_DIR.
#
# THE MARKETPLACE GATE IS HERE, AND NOT WHERE IT WAS DECLARED. Every spawn cloned Anthropic's plugin
# marketplace from GitHub to install zero plugin — 7.2 MB and a network fetch at boot, inside a
# sandbox whose whole point is a projected world. The settings file carries
# `extensions.marketplace.autoInstall: false` and `--settings` DOES pass it; the install happened
# anyway. Measured on a bench 2026-08-09, both directions, CLI 2.1.221:
#   - two pods with the settings key and WITHOUT these two -> .claude = 7.9 MB, plugins/ = 7.2 MB;
#   - one pod with the settings key AND these two          -> .claude = 604 KB, plugins/ ABSENT.
# So the vendor gates this on its own config keys, and the settings key does nothing on this
# version. `--settings` is documented as ADDITIONAL settings, not a tier that overrides.
#
# These are vendor-INTERNAL keys, so they are an anchor to re-measure, not a contract: the day the
# CLI stops reading them the plugins come back and nothing here will say so. The measurement above
# is what a future reader re-runs — `du -sh <pod_dir>/.claude/plugins` on a fresh pod.
cat > "$POD_DIR/.claude.json" <<JSONEOF
{ "hasCompletedOnboarding": true, "lastOnboardingVersion": "${VER:-2.1.150}", "migrationVersion": 13,
  "officialMarketplaceAutoInstalled": true, "officialMarketplaceAutoInstallAttempted": true,
  "remoteControlAtStartup": $RC_STARTUP, "hasUsedRemoteControl": true, "remoteDialogSeen": true,
  "projects": { "$POD_CWD": { "allowedTools": [], "hasTrustDialogAccepted": true, "projectOnboardingSeenCount": 10 } } }
JSONEOF

# =============================================================
# Tools from the resolved cap-profile JSON (string-keyed, consistent with fleet_cap_profile L100).
# =============================================================

ALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.allowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { echo "ERR: jq allowedTools failed on $CAP_PROFILE_JSON: $ALLOWED_TOOLS" >&2; exit 1; }
DISALLOWED_TOOLS=$("$JQ_BIN" -r '.spec.scope.disallowedTools | join(",")' "$CAP_PROFILE_JSON" 2>&1) || { echo "ERR: jq disallowedTools failed on $CAP_PROFILE_JSON: $DISALLOWED_TOOLS" >&2; exit 1; }
# #kill-yolo: the fleet MCP protocol is UNIVERSAL (every pod does get_work_item/submit_result) → appended
# to the allowlist. Under --permission-mode default an unlisted MCP tool PROMPTS ("Do you want to
# proceed?") → headless hang. Role-specific MCP tools (the arch's create_*/get_issue_status) stay in the
# cap-profile.
ALLOWED_TOOLS="${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}mcp__fleet__get_work_item,mcp__fleet__submit_result"

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

# Model + effort from the catalogue (spec.invocation) → claude flags. Absent/null ⇒ the flag is omitted
# (claude keeps its binary default; the 7 canon cap-profiles set them, so the flag is always emitted in
# prod). `--effort` enum {low,medium,high,xhigh,max}; `--model` takes an alias ('opus'/'sonnet') or a full
# name.
MODEL=$("$JQ_BIN" -r '.spec.invocation.model // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
EFFORT=$("$JQ_BIN" -r '.spec.invocation.effort // empty' "$CAP_PROFILE_JSON" 2>/dev/null)
MODEL_FLAGS=();  [[ -n "$MODEL"  ]] && MODEL_FLAGS=(--model "$MODEL")
EFFORT_FLAGS=(); [[ -n "$EFFORT" ]] && EFFORT_FLAGS=(--effort "$EFFORT")

# --remote-control flag: OMITTED when remote_control:false (a judge) → the pod still runs INTERACTIVE
# under the tmux PTY (MCP/wake intact) but stays INVISIBLE in Desktop. REMOTE_CONTROL was read above (it
# also gates remoteControlAtStartup in .claude.json — both RC levers share that one read).
# On-demand debugging: a `/remote-control <slot>` sent via send-key turns a judge's visibility back on.
RC_FLAGS=()
# #chantier pod-seed: the EXACT RC name goes through `--remote-control "<name>"` (the optional positional
# name), NOT `--remote-control-session-name-prefix`, which appends an auto suffix — random names piling up.
# SESSION_NAME_PREFIX carries the WHOLE label, built by one function on the Elixir side
# (Fleet.Layout.pod_label/3) and passed through verbatim: nothing here composes or parses it.
[[ "$REMOTE_CONTROL" != "false" ]] &&
  RC_FLAGS=(--remote-control "$SESSION_NAME_PREFIX")

# =============================================================
# Pod settings: CONSUMED, never composed (BL-6-07). $POD_DIR/.lcars/settings.json is written
# COMPLETE by the projection tier (Fleet.Spawner.Pod.Assets.pod_settings_json/1 — the tier that
# holds the cap-profile and the permission policy): autoMemoryEnabled:false (F-POD-AUTOMEM) for
# every mode, skipDangerousModePermissionPrompt:true ONLY under bypassPermissions (the flag that
# pre-accepts the danger dialog a headless pod would hang on; --settings IS the flagSettings
# source, independent of --setting-sources). This launcher used to jq-merge its OWN keys here —
# a second composer with a second policy over one file, and the two disagreed on the
# skip-dialog: the decision belongs to Elixir, the launcher executes. No file → no --settings
# flag, and the launcher writes NOTHING (a settings-less run is the projection tier's business).
# =============================================================

POD_SETTINGS_FILE="$POD_DIR/.lcars/settings.json"

# --setting-sources is UNCONDITIONAL: it excludes the 'user' tier (the human's ~/.claude/settings.json).
# NOTE (P1/C9): this flag is NOT enough to close the hook leak — that one came through the `project`/`local`
# tiers, which it ALLOWS, and whose root is cwd = POD_DIR = the human's .claude back when it was bound
# whole. The leak is closed at the BIND (.claude pod-owned, bwrap binds only the creds), not by this flag.
# `--settings` (additive/flagSettings) is added only when the pod file exists.
SETTINGS_FLAGS=(--setting-sources "$SETTING_SOURCES")
if [[ -f "$POD_SETTINGS_FILE" ]]; then
  SETTINGS_FLAGS+=(--settings "$POD_SETTINGS_FILE")
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
else
  # IRON LAW: MCP is the ONE communication channel. A real pod WITHOUT .mcp-fleet.json is an upstream
  # config bug — the emitter must always provision it. The launcher stays content-agnostic (it does not
  # fail-fast), but this is abnormal, and it says so where the operator collects it: stderr.
  echo "WARN: no MCP config ($MCP_CONFIG absent) — ABNORMAL for a real pod (upstream provisioning missing)" >&2
fi

# =============================================================
# Session: pre-allocated UUID (--session-id requires a UUID — the binary checks it; NEVER a readable name).
#   first creation : --session-id <UUID>   (PROVEN: creates the session with that UUID).
#   recovery       : --resume <UUID>       (PROVEN: resumes, context preserved on Anthropic's server).
#   The Desktop-visible readable name is a SEPARATE axis: --remote-control-session-name-prefix (auto suffix).
# =============================================================

# A session that holds NO conversation turn is not resumable, and asking anyway is FATAL AND
# SELF-SUSTAINING. Measured 2026-08-11: a pod died at its first start, leaving a 334-byte transcript
# with only `mode` / `permission-mode` / `bridge-session` records; every later start passed --resume
# on it and the binary answered "No conversation found with session ID: <uuid>" and exited at once.
# The fleet then re-briefed a corpse forever, and the FIRST cause was unrecoverable — erased by the
# trap it had set. So the predicate is positive: at least one `user` or `assistant` record. Those two
# types are what a transcript is made of; the preamble records are not, and enumerating the preamble
# instead would re-open the trap the day the vendor adds one.
#
# Not resumable -> the stub is REMOVED and we start fresh. It carries nothing by construction, and
# deleting it is what makes the fallback unconditional: whether --session-id tolerates a pre-existing
# transcript for the same UUID is a vendor behaviour we would be guessing at, and a wrong guess here
# reinstates exactly the loop this fixes.
resumable_session() {
  local id=$1 f
  f=$(find "$POD_DIR/.claude/projects" -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null)
  [[ -n "$f" ]] || return 1
  if grep -qE '"type":"(user|assistant)"' "$f"; then
    return 0
  fi
  # No conversation turn: the stub of a pod that died at start. Removing it makes the session
  # non-resumable, which is the correct verdict — resuming an empty transcript loops the pod.
  rm -f "$f"
  return 1
}

if [[ "$POD_RESUME" == "1" ]] && resumable_session "$SESSION_ID"; then
  SESSION_FLAGS=(--resume "$SESSION_ID")
else
  SESSION_FLAGS=(--session-id "$SESSION_ID")
fi

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

exec "$CLAUDE_BIN" \
    "${RC_FLAGS[@]}" \
    "${SESSION_FLAGS[@]}" \
    --system-prompt-file "$SP_FILE" \
    "${PERM_FLAGS[@]}" \
    --allowedTools "$ALLOWED_TOOLS" \
    --disallowedTools "$DISALLOWED_TOOLS" \
    ${SKILL_FLAGS[@]+"${SKILL_FLAGS[@]}"} \
    "${MODEL_FLAGS[@]+"${MODEL_FLAGS[@]}"}" \
    "${EFFORT_FLAGS[@]+"${EFFORT_FLAGS[@]}"}" \
    ${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"} \
    ${MCP_FLAGS[@]+"${MCP_FLAGS[@]}"}
