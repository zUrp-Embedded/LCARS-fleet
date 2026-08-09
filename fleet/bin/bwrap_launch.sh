#!/usr/bin/env bash
# SOURCE: bin/bwrap_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — N0 containment + persistent tmux PTY + per-pod socket dir + bwrap-PID1 holder + die-with-parent
#
# Projects the POD SANCTUARY (N0 pod primitive, vendor-agnostic).
# The sandbox is INVERTED: bwrap does not CAGE the agent to protect the world from it — it protects the
# AGENT from the world. The sanctuary is the closed world it PROJECTS for the agent ("what do we
# provide", empty-unless-provisioned by default): the agent has EXACTLY what it needs and can break
# nothing, so "the walls carry the security, not the SP" (I-CBC: what is not projected does not exist →
# no rule to put in the agent's head). THIS FILE is NOT the sanctuary: it is the CODE that projects it —
# edited and tested (bats) like everything else. NO CODE IS SACRED. A different containment means one
# more co-located launcher (one launcher per mode), not that this file is untouchable.
#
# ADR-G model: the command (`claude_launch.sh`, opaque) runs in a **persistent tmux PTY** INSIDE bwrap,
# through a **per-pod socket DIR**. `tmux new-session -d` detaches the session; a **HOLDER**
# (`exec sleep infinity` after creation) keeps bwrap-PID1 alive → the namespace and the tmux server
# survive. The holder is REQUIRED: without it bwrap exits the moment `new-session -d` returns and KILLS
# the namespace, hence the pod. So bwrap does NOT return: this process IS the pod (the spawner's Port
# handle). Boot validation is ASYNC, spawner-side (`tmux list-sessions`); teardown = close Port /
# SIGTERM. `--die-with-parent` is orphan-safe.
#
# N0/N1 frontier (IX.2/IX.3): tmux is N0 (it holds any REPL). bwrap_launch does NOT know the `claude`
# flags — that is `claude_launch.sh`, an opaque command in ${COMMAND[@]}.
#
# Usage: bwrap_launch.sh <role> <pod_id> <pod_dir> <command...>
# Identity/session env (set by the spawner before Port.open; propagated through --setenv):
#   LCARS_POD_SESSION_ID          pre-allocated UUID — required (strict :?, consumed by claude_launch)
#   LCARS_POD_RESUME              0|1 (first creation / recovery) — defaults to 0
#   LCARS_POD_SESSION_NAME_PREFIX readable pod label, passed through verbatim — required (strict :?)
#   CLAUDE_DIR                    the human account's claudeDir — required (bound RW, cf. LCARS_AUTH_MODE)
#   LCARS_AUTH_MODE               bind ONLY:
#                                   - bind: RW bind of CLAUDE_DIR/.credentials.json ALONE →
#                                           pod_dir/.claude/.credentials.json (native Anthropic refresh
#                                           in place + mtime sync, no ~8h cliff). NOT the human's whole
#                                           .claude — that leaks their hooks and jams the boot;
#                                           .claude/ stays pod-owned.
#   LCARS_POD_CWD                 the pod's cwd = the branch/repo root (invoked-world, matching native
#                                 Claude Code /init) — defaults to $POD_DIR (the bootstrap/spawner sets
#                                 it to $POD_DIR/<repo> for a project pod).
#
# Git identity (Z4 forge-identity B'): GIT_AUTHOR_*/GIT_COMMITTER_* are the brief's HUMAN, FORWARDED
# from the env (set by the spawner `pod.ex` through `Fleet.Credentials.ForgeIdentity`, which DERIVES
# them from the host OS: the human's `git config` → GECOS → login; no catalogue). They are NOT derived
# from $ROLE any more: the role no longer signs the identity, it goes in a `Co-authored-by: LCARS-<role>`
# trailer added by the pod. Plus GIT_CONFIG_GLOBAL=/dev/null pod-side → git reads the forwarded
# GIT_AUTHOR_* and not its own global, so the env is the SOLE, deterministic identity source. This is the
# COOPERATIVE DEFAULT (a well-behaved git-native pod commits under the right identity with no SP rule,
# screwdriver-style). It is NOT a security guarantee — a shell can override the env. The F-01 guarantee
# lives WORLD-side: the `Fleet.Pipeline.DeliverableGate` rejects at push any commit outside the
# authorized identity (= the human).
#
# Exit codes: 0 success (the pod is launched detached) | 1 setup error | 2 bwrap/vendor missing
#
# Three corrections over the containment-bwrap draft:
#   + --clearenv            (CLOSED env: everything through explicit --setenv, or the spawner's ambient leaks)
#   + DISABLE_AUTO_MEMORY   (stateless pod: no hidden auto-memory that drifts and dies at nuke time)
#   + LCARS_POD_CWD         (cwd = branch root, not $POD_DIR — matching native Claude Code)

set -euo pipefail

# =============================================================
# Config (overridable via env)
# =============================================================

CLAUDE_DIR="${CLAUDE_DIR:?CLAUDE_DIR required (claudeDir of the human account, resolved by Fleet.Spawner — adr-f)}"
# DORMANT — WIRED BUT NEVER ACTIVATED. Pod side of a clone accelerator (local git mirror → `--reference`
# clone = local objects, incremental fetch, less network). The clone-side hook
# (`project["reference_repo_path"]`, fleet_project_bootstrap/phase.ex) is READ but never SET, so no
# workspace has `alternates` and this bind resolves NOTHING today. Kept deliberately (the value is real:
# the same project is re-cloned at every spawn), not purged.
# DR-023: the mirror is INERT by default. `LCARS_GIT_MIRROR` unset → empty → NO guard, NO bind.
# A disabled feature must not be a precondition of the normal path — the old default pointed at the
# systemd fossil `/var/lib/lcars/git-mirror`, so a fresh home install carried no mirror and the first
# spawn died on a missing relic. TO REACTIVATE: set `LCARS_GIT_MIRROR=<dir>` (home-native, e.g.
# `~/.lcars/git-mirror`), provision the mirror, and set `reference_repo_path` clone-side.
GIT_MIRROR="${LCARS_GIT_MIRROR:-}"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

# Vendor runtime (R0.1) — the human's per-user binary, relocated to its native place INSIDE the pod
# ($POD_DIR/.local/bin/<vendor>), otherwise `--tmpfs /home` masks it. LCARS_VENDOR_BIN (spawner) wins.
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
VENDOR_BIN="${LCARS_VENDOR_BIN:-$(readlink -f "$(command -v "$VENDOR_NAME" 2>/dev/null)" 2>/dev/null || true)}"
VENDOR_SHARE="${LCARS_VENDOR_SHARE:-$([ -n "$VENDOR_BIN" ] && dirname "$(dirname "$VENDOR_BIN")" || true)}"

# Per-pod socket dir (P1 #1 — bind the DIR, not the file that does not exist yet). The parent normally
# comes from `bin/fleet_v2`, which exports `LCARS_TMUX_SOCK_BASE` under `~/.lcars/run/tmux-sock` and
# creates the dir at start. The base is overridable for tests (no /run perms there).
# (The literal `/run/lcars/tmux-sock` default below is a direct-invocation fallback only.)
SOCK_PARENT="${LCARS_TMUX_SOCK_BASE:-/run/lcars/tmux-sock}"

# =============================================================
# Args
# =============================================================

if [[ $# -lt 4 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir> <command...>" >&2
  exit 1
fi
ROLE="$1"; POD_ID="$2"; POD_DIR="$3"; shift 3
COMMAND=("$@")
[[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]] && { echo "ERR: role, pod_id, pod_dir must be non-empty" >&2; exit 1; }

# Identity/session (read from the env, set by the spawner; strict :? — claude_launch requires them too).
SESSION_ID="${LCARS_POD_SESSION_ID:?session UUID required (pre-allocated by the spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?pod label required (Fleet.Layout.pod_label)}"

# Clean-world stage B: the intra-pod $HOME is relocated. SANDBOX_HOME is what the agent sees as its home
# (and the root of EVERY pod bind: .claude, creds, vendor, plugins). Gated: LCARS_POD_HOME absent →
# SANDBOX_HOME=$POD_DIR = IDENTITY = current behaviour (tests, host pods). Set (=/home/.pod) → the REAL
# pod_dir ($POD_DIR, still the SRC of the binds) hides behind /home/.pod: the agent sees neither human nor
# pod_id, and `ls /home` shows only the mounts (the .pod is hidden).
SANDBOX_HOME="${LCARS_POD_HOME:-$POD_DIR}"

# cwd = branch root (invoked-world). Defaults to SANDBOX_HOME (the home); worker/orchestrator set
# LCARS_POD_CWD (/home/<project> or /home/projects.ops).
WORKDIR="${LCARS_POD_CWD:-$SANDBOX_HOME}"

# Clean-world: remaps the INTRA-POD cwd only. If the spawner set LCARS_POD_CWD_SRC (the REAL workspace
# under the pod_dir), we bind it onto WORKDIR (= LCARS_POD_CWD, e.g. /home/<project>) → the agent sees a
# clean path (no human, no pod_id) while the REAL pod_dir stays /home/<human>/pods/... (bound to itself
# further down, INTACT). Absent → no-op (the cwd is covered by the identity POD_DIR bind).
CWD_BIND_ARGS=()
[[ -n "${LCARS_POD_CWD_SRC:-}" && "$LCARS_POD_CWD_SRC" != "$WORKDIR" ]] &&
  CWD_BIND_ARGS=(--bind "$LCARS_POD_CWD_SRC" "$WORKDIR")

# Auth mode — bind ONLY. The rejected token_arg mode injected the OAuth access_token as
#   `--setenv CLAUDE_CODE_OAUTH_TOKEN <token>` → LEAKED into the argv (ps), AND no refresh
#   (expiresAt:null) → a long pod (an engineer past 8h) lost its auth mid-work. bind (ADR-F): RW bind of
#   .credentials.json, native OAuth refresh (proactive + reactive on 401 + lockfile), full scope, no cliff.
AUTH_MODE="${LCARS_AUTH_MODE:-bind}"
case "$AUTH_MODE" in
  bind) ;;
  *) echo "ERR: LCARS_AUTH_MODE='$AUTH_MODE' invalid (expected: bind)" >&2; exit 1 ;;
esac

# tmux session (INTERNAL name, distinct from claude's RC name prefix — P3 #13).
POD_SOCK_DIR="$SOCK_PARENT/$POD_ID"
TMUX_SESSION_NAME="lcars-pod-$POD_ID"
# CONSTANT filename (not ${TMUX_SESSION_NAME}.sock): the $POD_ID/ dir already
# carries the uniqueness. Doubling the pod_id (dir + filename) blew past the
# 108-byte sun_path for a UUID pod_id (pipeline path) → "File name too long".
# SAME path on the Elixir side (Fleet.Spawner.PodTmux.sock_path).
TMUX_SOCK="$POD_SOCK_DIR/pod.sock"

# Per-pod MCP socket (the AF_UNIX channel between the pod's bridge and central). SAME shape as the tmux
# socket dir above: a per-pod dir + a short filename ("sock") keep the path under the sun_path limit (108
# bytes) even for a long pod_id. We bind ONLY this per-pod dir ($MCP_SOCK_DIR), NEVER the base: binding
# the base would expose sibling pods' sockets inside THIS sandbox — a breach of the multi-human tenant
# frontier. UNLIKE tmux: the socket file (and its dir) is created OUTSIDE the sandbox by the BEAM BEFORE
# this launch (central provisions the per-pod socket) → bwrap MOUNTS a PRE-EXISTING dir, it does not
# create it (no `install -d`). The default base matches central's default (`/run/lcars/mcp`); a human
# running their fleet under their home overrides it through LCARS_FLEET_MCP_SOCK_BASE (set by the
# fleet_v2 launcher, read on the Elixir side too) — ONE source.
MCP_SOCK_BASE="${LCARS_FLEET_MCP_SOCK_BASE:-/run/lcars/mcp}"
MCP_SOCK_DIR="$MCP_SOCK_BASE/$POD_ID"
MCP_SOCK="$MCP_SOCK_DIR/sock"
POD_VENDOR_BIN="$SANDBOX_HOME/.local/bin/$VENDOR_NAME"

# =============================================================
# Cleanup trap (P2 #7) — useful PRE-exec only: `exec` replaces the shell, so the EXIT trap fires ONLY if
# we leave before `exec` (a failed assertion/setup). On success the pod is launched detached and
# survives. state.json lives OUTSIDE $POD_DIR → never affected. Caller opt-out (spawner lifecycle).
# =============================================================
if [[ "${LCARS_BWRAP_NO_CLEANUP:-0}" != "1" ]]; then
  trap 'rm -rf "$POD_DIR" "$POD_SOCK_DIR" 2>/dev/null || true' EXIT ERR
fi

# =============================================================
# Setup checks
# =============================================================
[[ -x "$BWRAP_BIN" ]] || { echo "ERR: bwrap missing/not-x: $BWRAP_BIN" >&2; exit 2; }
[[ -x "$TMUX_BIN"  ]] || { echo "ERR: tmux missing/not-x: $TMUX_BIN (N0 PTY host)" >&2; exit 2; }
if [[ -z "$VENDOR_BIN" || ! -x "$VENDOR_BIN" || ! -d "$VENDOR_SHARE" ]]; then
  echo "ERR: vendor '$VENDOR_NAME' not found (bin=$VENDOR_BIN share=$VENDOR_SHARE) — set LCARS_VENDOR_BIN" >&2; exit 2
fi
[[ -d "$CLAUDE_DIR"  ]] || { echo "ERR: claudeDir $CLAUDE_DIR missing (human registration — adr-f)" >&2; exit 1; }
# DORMANT (cf. GIT_MIRROR above) — DR-023: inert by default. Unset (empty) → no guard at all (a
# disabled feature is not a precondition). SET (LCARS_GIT_MIRROR=<dir>) but missing → fatal: a mirror
# asked for EXPLICITLY and not found is a real error, not something to swallow.
[[ -z "$GIT_MIRROR" || -d "$GIT_MIRROR" ]] || { echo "ERR: git mirror $GIT_MIRROR set but missing (LCARS_GIT_MIRROR)" >&2; exit 1; }
# Bind the mirror ONLY if enabled AND present (dormant → no bind projected into the sandbox).
MIRROR_BIND_ARGS=()
[[ -n "$GIT_MIRROR" && -d "$GIT_MIRROR" ]] && MIRROR_BIND_ARGS=(--ro-bind "$GIT_MIRROR" "$GIT_MIRROR")
[[ -d "$POD_DIR"     ]] || { echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2; exit 1; }

# Per-pod socket dir, host-side, BEFORE the launch (tmux will create the socket in it; we bind the dir).
# In prod the spawner creates it; idempotent here. The parent must exist (set by bin/fleet_v2 at start) —
# fail fast at the boundary.
[[ -d "$SOCK_PARENT" ]] || { echo "ERR: sock parent $SOCK_PARENT missing (set by bin/fleet_v2 at start; override LCARS_TMUX_SOCK_BASE)" >&2; exit 1; }
install -d -m 0700 "$POD_SOCK_DIR"
install -d -m 0755 "$POD_DIR/.local/bin"

# The per-pod MCP socket dir MUST pre-exist: central creates the socket file BEFORE this launch (unlike
# the tmux socket dir above, which tmux fills INSIDE the sandbox). We MOUNT it, we do not create it — its
# absence means the provisioning contract was broken, and a clear failure at the boundary beats binding a
# ghost path and having bwrap fail further along with an opaque message.
[[ -d "$MCP_SOCK_DIR" ]] || { echo "ERR: dir socket MCP $MCP_SOCK_DIR missing (central must provision it before the launch)" >&2; exit 1; }

# =============================================================
# Native Claude Code plugins (RO bind host→pod, allowlisted by LCARS_SKILLS_PLUGINS).
# (arch→worker cascade vector: a bare worker has no plugin by default = empty list.)
# =============================================================
PLUGIN_BINDS=()
set -f
for plugin in ${LCARS_SKILLS_PLUGINS:-}; do
  # Strict NAME allowlist (S5): the name is interpolated into bind paths. Without the guard, a forged
  # name (`..`, `/`, leading dot) is a path traversal out of ~/.claude/plugins. Rejected before any path
  # is built. (The cap-profile source is meant to be trusted-operator; this is the belt.)
  case "$plugin" in
    *..* | */* | .*) echo "ERR: invalid plugin name '$plugin' (path-traversal)" >&2; exit 1 ;;
  esac
  [[ "$plugin" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERR: invalid plugin name '$plugin' (allowlist [A-Za-z0-9._-])" >&2; exit 1; }
  # F152: resolve from CLAUDE_DIR (the human's REAL ~/.claude), NOT $HOME — the spawner opens the Port
  # with HOME=POD_DIR (the pod's env), so host-side `$HOME` is the fresh pod_dir with no plugins in it.
  # `$HOME/.claude/plugins` therefore always failed → exit 1 → the EXIT trap's `rm -rf "$POD_DIR"`
  # destroyed the provisioned pod, for EVERY cap-profile with a plugin-qualified skill. CLAUDE_DIR
  # (required at the top) points at the human claudeDir, so their plugins are under CLAUDE_DIR/plugins.
  HOST_PLUGIN_PATH="$CLAUDE_DIR/plugins/$plugin"
  [[ -d "$HOST_PLUGIN_PATH" ]] || { echo "ERR: plugin '$plugin' not installed host-side at $HOST_PLUGIN_PATH" >&2; exit 1; }
  PLUGIN_BINDS+=(--ro-bind "$HOST_PLUGIN_PATH" "$SANDBOX_HOME/.claude/plugins/$plugin")
done
set +f

# =============================================================
# Fleet skills (RO bind host->pod, filtered by the cap-profile whitelist — BL-6-22).
# LCARS_SKILLS_PATHS is NEWLINE-delimited, one `name:abs_path` per line (the LCARS_POD_MOUNTS
# pattern — paths may carry spaces, a word-split loop would shatter them). The first `:`
# separates: the name is a fleet slug (no `:` in its alphabet), the path keeps any `:` it has.
# bwrap CREATES the bind target inside the namespace when absent (same invariant the plugin
# loop above relies on; pinned by the bats). Empty/absent var -> zero bind, zero loop.
# =============================================================
SKILL_BINDS=()
while IFS= read -r skill_line; do
  [[ -z "$skill_line" ]] && continue
  skill_name="${skill_line%%:*}"
  skill_path="${skill_line#*:}"
  # Same belt as the plugin names (S5): the name lands in a bind path — refuse traversal shapes
  # before any path is built. The Elixir side already slugs it; this is the launcher's own wall.
  case "$skill_name" in
    *..* | */* | .* | "") echo "ERR: invalid skill name '$skill_name' (path-traversal)" >&2; exit 1 ;;
  esac
  [[ -d "$skill_path" ]] || { echo "ERR: skill '$skill_name' has no dir at '$skill_path' (filtered upstream — projection/launch skew)" >&2; exit 1; }
  SKILL_BINDS+=(--ro-bind "$skill_path" "$SANDBOX_HOME/.claude/skills/$skill_name")
done <<< "${LCARS_SKILLS_PATHS:-}"

# =============================================================
# exec bwrap → HOLDER sh → (detached `tmux new-session -d` + exec sleep infinity) → command.
#   HOLDER: `new-session -d` returns immediately; were it bwrap's foreground process, bwrap would exit
#   and KILL the namespace and the tmux server (hence the pod). The `exec sleep infinity` after creation
#   keeps PID1 alive → bwrap blocking IS the pod's liveness handle (the spawner's Port; close → SIGTERM →
#   the sleep dies → namespace + tmux + claude fall together).
#   sock/name/command are passed as the holder's ARGS ($1/$2/$3/$@) ⇒ argv preserved, zero shell
#   re-parsing.
#   --clearenv: CLOSED env — nothing from the spawner's ambient leaks; everything is explicit --setenv.
#   The discipline lives in the WALLS (binds = what exists) and the ENV (what is set), not in the SP.
# =============================================================
# Bind ONLY CLAUDE_DIR's `.credentials.json` (ADR-F).
#
# P1/C9 — the human's whole .claude is NOT bound. Reason: cwd=HOME=POD_DIR, so the `project`/`local`
# settings tiers (rooted at cwd, enabled by --setting-sources project,local) resolved inside the bound
# human .claude → the human's settings.json was loaded as *project* settings → their hooks
# (session-startup.sh…) ran → crashed → retried 10× → JAM at boot. The flag could not help (it is what
# authorizes project/local). Fix: only `.credentials.json` is bound (native OAuth refresh writes IN
# PLACE, which survives a single-file bind and rewrites the human's file); `.claude/` stays pod-owned
# (created by do_project) → no human settings.json → no hook.
# ###################### /!\ NEVER DELETE /!\ ###################### ADR-F
# THIS BIND IS NOT A SECURITY HOLE. IT IS THE PLATE. Read it before proposing to close it.
# The Anthropic credential BUYS THE TOKENS the model eats — it is a meter, it signs nothing.
# What signs is the ROLE token (`/home/private/<role>.gitea_token`): per role, on every forge act.
# Two rails, two jobs. Do NOT conflate them into "the pod authenticates as the human", and do NOT
# turn this into a per-pod identity: a single credential RW-bound and refreshed IN PLACE is the
# pattern Anthropic recommends for multi-agent refresh, and it is the only shape without the ~8h
# cliff (the mechanism is at the top of this file, LCARS_AUTH_MODE).
# ################################################################## ADR-F
AUTH_BIND_ARGS=()
HUMAN_CREDS="$CLAUDE_DIR/.credentials.json"
[[ -f "$HUMAN_CREDS" ]] || { echo "ERR: creds $HUMAN_CREDS missing (human registration — adr-f)" >&2; exit 1; }
# The pod-owned `.claude/` must exist host-side to host the creds mountpoint (POD_DIR is itself
# bind-mounted RW → this mkdir is visible in the sandbox). do_project already creates it; defensive here.
mkdir -p "$POD_DIR/.claude"
AUTH_BIND_ARGS=(--bind "$HUMAN_CREDS" "$SANDBOX_HOME/.claude/.credentials.json")

# Telemetry ↔ feature flags. The Statsig/GrowthBook flags (including `MONITOR_TOOL`, which exposes the
# Monitor tool = waking the pod by flag) are fetched through the telemetry pipeline.
# `DISABLE_TELEMETRY=1` + `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` CUT that fetch → `MONITOR_TOOL`
# defaults OFF → the agent falls back to the `engage` kick (send-keys) instead of the Monitor. The content
# stays 100% MCP (get_work_item/submit_result) either way. Ruling: we PREFER the Monitor, so telemetry is
# ON by default. Privacy mode is opt-in: `LCARS_POD_DISABLE_TELEMETRY=1` (no Monitor, engage fallback). The
# telemetry→Monitor coupling is on the Anthropic relay side, not our choice; the
# `CLAUDE_INTERNAL_FC_OVERRIDES` override is gated on `USER_TYPE=ant` (internal, inert on the public
# binary) → not usable.
TELEMETRY_ENV=()
if [[ "${LCARS_POD_DISABLE_TELEMETRY:-0}" == "1" ]]; then
  TELEMETRY_ENV=(--setenv DISABLE_TELEMETRY "1" --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1")
fi

# SELECTIVE /etc (sanctuary: project ONLY what the pod needs — bwrap arch audit #5.2).
# A pod has NO business in /etc wholesale: `--ro-bind /etc /etc` exposed 166 entries, useless AND
# dangerous (the /etc/fleet SECRETS — api-secret/webhook-secret/FORGE_PUSH_TOKEN —, /etc/shadow,
# /etc/sudoers…), which undid the forge delegation: a pod could read the token and talk to Gitea
# directly. The pod needs ONLY DNS (resolv/nsswitch/hosts/host.conf/gai), TLS (ssl/ca-certificates), uid
# resolution (passwd/group), tz/net. Everything else is OUTSIDE the projected world (cf. the carved binds
# below). resolv.conf is often a symlink out of /etc (WSL → /mnt/wsl), so we bind the REAL file straight
# onto /etc/resolv.conf: no symlink to resolve, no /mnt/wsl exposed. Dead DNS = claude hangs on the API.
RESOLV_REAL="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
[[ -n "$RESOLV_REAL" && -e "$RESOLV_REAL" ]] || RESOLV_REAL=/etc/resolv.conf

# =============================================================
# CATALOGUE mounts (cap-profile-driven, LCARS_POD_MOUNTS = "mode:path" lines). The projected world is
# DECLARED by the cap-profile (sanctuary philosophy: "what do we provide"), no longer hardcoded here.
# Bound AFTER the `--tmpfs /home` below ⇒ they restore the masked paths (e.g. /home/projects). Belt:
# absolute + existing path; RW forbidden on the system roots (already mounted RO by the base sandbox).
# The cap-profile source is trusted-operator — the belt is anti-footgun, not anti-adversary.
# =============================================================
CATALOG_BINDS=()
if [[ -n "${LCARS_POD_MOUNTS:-}" ]]; then
  while IFS= read -r _mount; do
    [[ -z "$_mount" ]] && continue
    _mode="${_mount%%:*}"; _path="${_mount#*:}"
    [[ "$_path" == /* ]] || { echo "ERR: catalogue mount path is not absolute: '$_path'" >&2; exit 1; }
    [[ -e "$_path"   ]] || { echo "ERR: catalogue mount path missing host-side: '$_path'" >&2; exit 1; }
    case "$_mode" in
      ro) CATALOG_BINDS+=(--ro-bind "$_path" "$_path") ;;
      rw)
        case "$_path" in
          / | /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/* | /boot | /boot/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /root | /root/*)
            echo "ERR: catalogue mount RW forbidden on a system root: '$_path'" >&2; exit 1 ;;
          *) CATALOG_BINDS+=(--bind "$_path" "$_path") ;;
        esac ;;
      *) echo "ERR: catalogue mount mode '$_mode' invalid (expected ro|rw) for '$_path'" >&2; exit 1 ;;
    esac
  done <<< "$LCARS_POD_MOUNTS"
fi

# `env -i` — bwrap becomes PID 1 of the pod's namespace and keeps its OWN environment: --clearenv
# scrubs the CHILD's env, never bwrap's, and the pod reads that env back through /proc/1/environ.
# So the spawner's whole ambient env (RELEASE_COOKIE, SSH keys, central topology) is pod-readable
# unless bwrap itself starts empty. Everything the pod legitimately needs crosses explicitly
# through --setenv below. Locked by `test/bwrap_launch/bwrap_launch.bats` (assembly + a secret
# exported around the spawner must not reach the sandbox).
exec env -i "$BWRAP_BIN" \
  --unshare-all --share-net \
  --hostname "lcars-pod-$POD_ID" \
  `# uts is already unshared (--unshare-all) but the hostname was not rewritten, so the pod believed it` \
  `# was on the human's machine (host name leaking into the agent context + misleading logs). Role-agnostic.` \
  --die-with-parent \
  --clearenv \
  --ro-bind /usr /usr \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --ro-bind "$RESOLV_REAL" /etc/resolv.conf \
  --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
  --ro-bind-try /etc/host.conf /etc/host.conf \
  --ro-bind-try /etc/hosts /etc/hosts \
  --ro-bind-try /etc/gai.conf /etc/gai.conf \
  --ro-bind-try /etc/ssl /etc/ssl \
  --ro-bind-try /etc/ca-certificates /etc/ca-certificates \
  --ro-bind-try /etc/passwd /etc/passwd \
  --ro-bind-try /etc/group /etc/group \
  --ro-bind-try /etc/protocols /etc/protocols \
  --ro-bind-try /etc/services /etc/services \
  --ro-bind-try /etc/localtime /etc/localtime \
  --ro-bind-try /etc/alternatives /etc/alternatives \
  `# /etc/alternatives: Debian's resolver for the /usr/bin symlinks (awk→gawk, cc→gcc, vi, java…).` \
  `# Without it ~46 /usr/bin links dangle → 'awk: command not found' while gawk IS there (it bit the` \
  `# first Makefile/script an engineer touched). Universal (/usr plumbing, zero secrets) → same list as` \
  `# the other /etc entries, no per-role case: the launcher stays role-agnostic, the domain logic lives` \
  `# in the cap-profile.` \
  --ro-bind /sys /sys \
  --tmpfs /home \
  --tmpfs /tmp \
  --dev /dev --proc /proc \
  --bind "$POD_DIR" "$SANDBOX_HOME" \
  ${CWD_BIND_ARGS[@]+"${CWD_BIND_ARGS[@]}"} \
  ${AUTH_BIND_ARGS[@]+"${AUTH_BIND_ARGS[@]}"} \
  ${MIRROR_BIND_ARGS[@]+"${MIRROR_BIND_ARGS[@]}"} \
  --ro-bind "$VENDOR_BIN" "$POD_VENDOR_BIN" \
  --ro-bind "$VENDOR_SHARE" "$SANDBOX_HOME/.local/share/$VENDOR_NAME" \
  --bind "$POD_SOCK_DIR" "$POD_SOCK_DIR" \
  --bind "$MCP_SOCK_DIR" "$MCP_SOCK_DIR" \
  ${PLUGIN_BINDS[@]+"${PLUGIN_BINDS[@]}"} \
  ${SKILL_BINDS[@]+"${SKILL_BINDS[@]}"} \
  ${CATALOG_BINDS[@]+"${CATALOG_BINDS[@]}"} \
  --chdir "$WORKDIR" \
  --setenv HOME "$SANDBOX_HOME" \
  --setenv PATH "$SANDBOX_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv LANG "${LANG:-C.UTF-8}" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_FLEET_MCP_SOCKET "$MCP_SOCK" \
  --setenv LCARS_ROLE "$ROLE" \
  --setenv LCARS_POD_CWD "$WORKDIR" \
  --setenv LCARS_POD_HOME "$SANDBOX_HOME" \
  --setenv GIT_AUTHOR_NAME "${GIT_AUTHOR_NAME:?Z4: GIT_AUTHOR_NAME required (the human, set by pod.ex)}" \
  --setenv GIT_AUTHOR_EMAIL "${GIT_AUTHOR_EMAIL:?Z4: GIT_AUTHOR_EMAIL required (the human)}" \
  --setenv GIT_COMMITTER_NAME "${GIT_COMMITTER_NAME:?Z4: GIT_COMMITTER_NAME required (the human)}" \
  --setenv GIT_COMMITTER_EMAIL "${GIT_COMMITTER_EMAIL:?Z4: GIT_COMMITTER_EMAIL required (the human)}" \
  --setenv GIT_CONFIG_GLOBAL "/dev/null" \
  --setenv LCARS_AUTH_MODE "$AUTH_MODE" \
  --setenv LCARS_POD_SESSION_ID "$SESSION_ID" \
  --setenv LCARS_POD_RESUME "$POD_RESUME" \
  --setenv LCARS_POD_SESSION_NAME_PREFIX "$SESSION_NAME_PREFIX" \
  --setenv LCARS_CLAUDE_BIN "$POD_VENDOR_BIN" \
  --setenv DISABLE_AUTOUPDATER "1" \
  --setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY "1" \
  --setenv CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "100" \
  ${TELEMETRY_ENV[@]+"${TELEMETRY_ENV[@]}"} \
  -- /bin/sh -c '
       tmux_bin=$1; sock=$2; name=$3; shift 3
       "$tmux_bin" -S "$sock" new-session -d -s "$name" "$@"
       exec sleep infinity
     ' sh "$TMUX_BIN" "$TMUX_SOCK" "$TMUX_SESSION_NAME" "${COMMAND[@]}"

# bwrap does NOT return (holder sleep infinity): this process IS the live pod (the spawner's Port handle).
# Validation is ASYNC, spawner-side: `tmux -S "$TMUX_SOCK" list-sessions` → is there a "lcars-pod-$POD_ID"
# session? Teardown, spawner-side: close Port / SIGTERM this process → the sleep dies → namespace + tmux +
# claude fall together; --die-with-parent is orphan-safe if the spawner dies. (The spawner cleans the
# sock dir.)
