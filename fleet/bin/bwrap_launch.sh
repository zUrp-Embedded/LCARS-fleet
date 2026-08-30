#!/usr/bin/env bash
# SOURCE: bin/bwrap_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — N0 containment + persistent tmux PTY + per-pod socket dir + bwrap-PID1 holder + die-with-parent
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

set -euo pipefail


CLAUDE_DIR="${CLAUDE_DIR:?CLAUDE_DIR required (claudeDir of the human account, resolved by Fleet.Spawner — adr-f)}"
# DR-023: the mirror is INERT by default. `LCARS_GIT_MIRROR` unset → empty → NO guard, NO bind.
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

AUTH_MODE="${LCARS_AUTH_MODE:-bind}"
case "$AUTH_MODE" in
  bind) ;;
  *) echo "ERR: LCARS_AUTH_MODE='$AUTH_MODE' invalid (expected: bind)" >&2; exit 1 ;;
esac

# tmux session (INTERNAL name, distinct from claude's RC name prefix — P3 #13).
POD_SOCK_DIR="$SOCK_PARENT/$POD_ID"
TMUX_SESSION_NAME="lcars-pod-$POD_ID"
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

# Per-pod EGRESS socket — the pod's only way out. Same shape and same reasons as the MCP socket
# above (per-pod dir, short filename, provisioned OUTSIDE by the BEAM before this launch, and the
# BASE is never bound: a sibling's egress socket is a sibling's allowlist).
#
# WHY THE NETWORK LEAVES THROUGH THE FILESYSTEM. Without this the sandbox keeps `--share-net`, so a
# pod shares the host's stack: `curl` reaches anything, and denying `WebFetch` only moves the gesture
# from a traced tool to an untraced one. Filtering by host inside a netns wants CAP_NET_ADMIN, which
# a fleet running under the human's UID does not have. So the namespace is dropped entirely and the
# traffic goes out over a unix socket, where the proxy on the other end decides host by host.
#
# ⚠ `socat` IS LOAD-BEARING HERE: it is what turns `localhost:$EGRESS_PORT` inside the sandbox into
# that socket. Absent, the pod is simply sealed — the vendor becomes unreachable and the pod cannot
# work at all. That is why the assertion below is fatal rather than degraded: a silent fallback to
# `--share-net` would turn a missing package into an open pod.
EGRESS_SOCK_BASE="${LCARS_FLEET_EGRESS_SOCK_BASE:-/run/lcars/egress}"
EGRESS_SOCK_DIR="$EGRESS_SOCK_BASE/$POD_ID"
EGRESS_SOCK="$EGRESS_SOCK_DIR/sock"
EGRESS_PORT="${LCARS_POD_EGRESS_PORT:-8118}"
SOCAT_BIN="${LCARS_SOCAT_BIN:-/usr/bin/socat}"
POD_VENDOR_BIN="$SANDBOX_HOME/.local/bin/$VENDOR_NAME"

# Cleanup trap (P2 #7) — useful PRE-exec only: `exec` replaces the shell, so the EXIT trap fires ONLY if
# we leave before `exec` (a failed assertion/setup). On success the pod is launched detached and
# survives. state.json lives OUTSIDE $POD_DIR -> never affected. Caller opt-out (spawner lifecycle).
#
# ⚠ LE SCRIPT DECLARE LUI-MEME LA PROPRIETE, QUATRE LIGNES PLUS BAS :
# `ERR: pod_dir $POD_DIR missing (caller responsibility)`. Le proprietaire a un teardown a lui
# (`Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/3`), avec une garde d'echappement de chemin, et
# il ne l'exerce que sur un pod TERMINAL. « On n'a pas pu demarrer » n'est pas « ce pod est fini » :
# le pod_dir est justement ce que la tentative suivante REUTILISE.
if [[ "${LCARS_BWRAP_NO_CLEANUP:-0}" != "1" ]]; then
  trap 'rm -rf "$POD_SOCK_DIR" 2>/dev/null || true' EXIT ERR
fi

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

# `touch`, JAMAIS `: >` : le pod_dir survit au respawn (l'arch est `forever`), donc une troncature
# ici effacerait le journal a chaque relance — l'inverse exact de ce qu'on protege.
touch "$POD_DIR/fleet.feed" 2>/dev/null || true
FEED_BIND_ARGS=()
if [[ -f "$POD_DIR/fleet.feed" ]]; then
  FEED_BIND_ARGS=(--ro-bind "$POD_DIR/fleet.feed" "$SANDBOX_HOME/fleet.feed")
  # Le pod dont le cwd RE-MONTE le pod_dir (l'arch : /home/.pod et /home/<projet> sont la meme
  # source) voit le feed sous DEUX chemins. Un seul monte RO laisserait l'autre ecrivable, ce qui
  # revient a n'en monter aucun.
  if [[ -n "${LCARS_POD_CWD_SRC:-}" && "$LCARS_POD_CWD_SRC" == "$POD_DIR" && "$WORKDIR" != "$SANDBOX_HOME" ]]; then
    FEED_BIND_ARGS+=(--ro-bind "$POD_DIR/fleet.feed" "$WORKDIR/fleet.feed")
  fi
fi

# `issues/` porte l'ORDRE du pod — `mandate.md` (le mandat, adresse par contenu) et le contexte
# lisible `issues/<id>.md`. Le pod le LIT, il ne l'ecrit jamais : on le monte RO par-dessus le bind
# RW du pod_dir (meme geste que fleet.feed), pour que le mandat soit exactement ce qui a ete authore,
# immuable — le SP promet "lecture seule", l'implementation le tient. Le dossier est cree par le
# scaffold avant le lancement ; le garde `-d` couvre le pod qui n'en aurait pas.
ISSUES_BIND_ARGS=()
if [[ -d "$POD_DIR/issues" ]]; then
  ISSUES_BIND_ARGS=(--ro-bind "$POD_DIR/issues" "$SANDBOX_HOME/issues")
  # Meme double-chemin que le feed pour l'arch (cwd RE-MONTE le pod_dir) : sinon l'autre vue reste RW.
  if [[ -n "${LCARS_POD_CWD_SRC:-}" && "$LCARS_POD_CWD_SRC" == "$POD_DIR" && "$WORKDIR" != "$SANDBOX_HOME" ]]; then
    ISSUES_BIND_ARGS+=(--ro-bind "$POD_DIR/issues" "$WORKDIR/issues")
  fi
fi

# The per-pod MCP socket dir MUST pre-exist: central creates the socket file BEFORE this launch (unlike
# the tmux socket dir above, which tmux fills INSIDE the sandbox). We MOUNT it, we do not create it — its
# absence means the provisioning contract was broken, and a clear failure at the boundary beats binding a
# ghost path and having bwrap fail further along with an opaque message.
[[ -d "$MCP_SOCK_DIR" ]] || { echo "ERR: dir socket MCP $MCP_SOCK_DIR missing (central must provision it before the launch)" >&2; exit 1; }

# Native Claude Code plugins (RO bind host→pod, allowlisted by LCARS_SKILLS_PLUGINS).
# (arch→worker cascade vector: a bare worker has no plugin by default = empty list.)
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
  HOST_PLUGIN_PATH="$CLAUDE_DIR/plugins/$plugin"
  [[ -d "$HOST_PLUGIN_PATH" ]] || { echo "ERR: plugin '$plugin' not installed host-side at $HOST_PLUGIN_PATH" >&2; exit 1; }
  PLUGIN_BINDS+=(--ro-bind "$HOST_PLUGIN_PATH" "$SANDBOX_HOME/.claude/plugins/$plugin")
done
set +f

# Fleet skills (RO bind host->pod, filtered by the cap-profile whitelist — BL-6-22).
# LCARS_SKILLS_PATHS is NEWLINE-delimited, one `name:abs_path` per line (the LCARS_POD_MOUNTS
# pattern — paths may carry spaces, a word-split loop would shatter them). The first `:`
# separates: the name is a fleet slug (no `:` in its alphabet), the path keeps any `:` it has.
# bwrap CREATES the bind target inside the namespace when absent (same invariant the plugin
# loop above relies on; pinned by the bats). Empty/absent var -> zero bind, zero loop.
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

# exec bwrap → HOLDER sh → (detached `tmux new-session -d` + exec sleep infinity) → command.
#   HOLDER: `new-session -d` returns immediately; were it bwrap's foreground process, bwrap would exit
#   and KILL the namespace and the tmux server (hence the pod). The `exec sleep infinity` after creation
#   keeps PID1 alive → bwrap blocking IS the pod's liveness handle (the spawner's Port; close → SIGTERM →
#   the sleep dies → namespace + tmux + claude fall together).
#   sock/name/command are passed as the holder's ARGS ($1/$2/$3/$@) ⇒ argv preserved, zero shell
#   re-parsing.
#   --clearenv: CLOSED env — nothing from the spawner's ambient leaks; everything is explicit --setenv.
#   The discipline lives in the WALLS (binds = what exists) and the ENV (what is set), not in the SP.
# Bind ONLY CLAUDE_DIR's `.credentials.json` (ADR-F).
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

# A pod has NO business in /etc wholesale: `--ro-bind /etc /etc` exposed 166 entries, useless AND
# dangerous (the /etc/fleet SECRETS — api-secret/webhook-secret/FORGE_PUSH_TOKEN —, /etc/shadow,
# /etc/sudoers…), which undid the forge delegation: a pod could read the token and talk to Gitea
# directly. The pod needs ONLY DNS (resolv/nsswitch/hosts/host.conf/gai), TLS (ssl/ca-certificates), uid
# resolution (passwd/group), tz/net. Everything else is OUTSIDE the projected world (cf. the carved binds
# below). resolv.conf is often a symlink out of /etc (WSL → /mnt/wsl), so we bind the REAL file straight
# onto /etc/resolv.conf: no symlink to resolve, no /mnt/wsl exposed. Dead DNS = claude hangs on the API.
RESOLV_REAL="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
[[ -n "$RESOLV_REAL" && -e "$RESOLV_REAL" ]] || RESOLV_REAL=/etc/resolv.conf

# CATALOGUE mounts (cap-profile-driven, LCARS_POD_MOUNTS = "mode:path" lines). The projected world is
# DECLARED by the cap-profile (sanctuary philosophy: "what do we provide"), no longer hardcoded here.
# Bound AFTER the `--tmpfs /home` below ⇒ they restore the masked paths (e.g. /home/projects). Belt:
# absolute + existing path; RW forbidden on the system roots (already mounted RO by the base sandbox).
# The cap-profile source is trusted-operator — the belt is anti-footgun, not anti-adversary.
# ENVIRONNEMENT D'OUTILLAGE (LCARS_POD_TOOLCHAIN_ENV = lignes `KEY=VALUE`, composees et VALIDEES
# cote Elixir par `LaunchSpec.toolchain_env/0` — ici on DEPLIE, on ne valide pas).
#
# Le pod ne source JAMAIS de script : sourcer du shell venu d'un artefact telecharge, dans le
# processus qui construit le bac a sable, rouvrirait ici le trou que le convergeur referme. Le
# convergeur joue l'`env_script` d'un SDK UNE fois et fige son delta a plat ; le pod recoit un
# resultat.
#
# `LCARS_PATH_PREPEND` EST LE SEUL CAS PARTICULIER, et il ne se regle pas par « le dernier gagne » :
# le PATH final est compose ICI, en PREFIXANT celui d'aujourd'hui, jamais en le remplacant. Un
# `--setenv PATH` venu du tableau ecraserait `$SANDBOX_HOME/.local/bin` et couperait le pod de ses
# propres outils.
#
# Vide (pas de magasin, pas d'env.d) => tableau vide, ZERO `--setenv` de plus, ligne de commande
# identique a aujourd'hui.
TOOLCHAIN_ENV=()
POD_PATH="$SANDBOX_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
if [[ -n "${LCARS_POD_TOOLCHAIN_ENV:-}" ]]; then
  while IFS= read -r _pair; do
    [[ -z "$_pair" ]] && continue
    _k="${_pair%%=*}"; _v="${_pair#*=}"
    if [[ "$_k" == "LCARS_PATH_PREPEND" ]]; then
      [[ -n "$_v" ]] && POD_PATH="$_v:$POD_PATH"
    else
      TOOLCHAIN_ENV+=(--setenv "$_k" "$_v")
    fi
  done <<< "$LCARS_POD_TOOLCHAIN_ENV"
fi

CATALOG_BINDS=()
if [[ -n "${LCARS_POD_MOUNTS:-}" ]]; then
  while IFS= read -r _mount; do
    [[ -z "$_mount" ]] && continue
    _mode="${_mount%%:*}"; _rest="${_mount#*:}"
    # `mode:src` (the common form) or `mode:src:dst` — the pinned reference face is the only
    # producer of the second form: its content lives in the pod dir so it survives its source, but
    # it is bound at the canonical face path so a pointer written in a brief resolves unchanged.
    # No `dst` => bind in place, exactly as before.
    if [[ "$_rest" == *:* ]]; then _path="${_rest%%:*}"; _dst="${_rest#*:}"; else _path="$_rest"; _dst="$_rest"; fi
    [[ "$_path" == /* ]] || { echo "ERR: catalogue mount path is not absolute: '$_path'" >&2; exit 1; }
    [[ "$_dst"  == /* ]] || { echo "ERR: catalogue mount target is not absolute: '$_dst'" >&2; exit 1; }
    [[ -e "$_path"   ]] || { echo "ERR: catalogue mount path missing host-side: '$_path'" >&2; exit 1; }
    case "$_mode" in
      ro) CATALOG_BINDS+=(--ro-bind "$_path" "$_dst") ;;
      rw)
        # The system-root belt covers the DESTINATION too: a translated mount could otherwise land
        # a writable tree on /etc while its source looks innocent.
        for _p in "$_path" "$_dst"; do
          case "$_p" in
            / | /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/* | /boot | /boot/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /root | /root/*)
              echo "ERR: catalogue mount RW forbidden on a system root: '$_p'" >&2; exit 1 ;;
          esac
        done
        CATALOG_BINDS+=(--bind "$_path" "$_dst") ;;
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
NET_ARGS=(--unshare-all)
if [[ -n "${LCARS_POD_EGRESS_SOCK:-}" ]]; then
  [[ -d "$EGRESS_SOCK_DIR" ]] || { echo "ERR: dir socket egress $EGRESS_SOCK_DIR missing (central must provision it before the launch)" >&2; exit 1; }
  [[ -x "$SOCAT_BIN" ]] || { echo "ERR: socat missing ($SOCAT_BIN) — the pod would be sealed with no way to reach its vendor" >&2; exit 2; }
  EGRESS_BINDS=(--bind "$EGRESS_SOCK_DIR" "$EGRESS_SOCK_DIR" --ro-bind "$SOCAT_BIN" "$SOCAT_BIN")
else
  EGRESS_BINDS=()
fi

# THE POD'S UMASK, and it is what makes the shared cache actually shared. The store's `cache/` is
# bound `rw` and lives on a setgid directory, so what a pod writes there lands in the fleet group —
# but setgid fixes the GROUP, never the MODE. At the default 022 every entry pip, npm or cargo
# leaves is `0644`, and the next human's pod can read it and not replace it. The cache then degrades
# into one copy per human that nobody can refresh: the failure mode `/home/projects` already pays
# setgid to avoid, arriving through the one door setgid does not close.
#
# 002, NOT 000 — group-writable, world-untouched. Every tree a pod writes into is group-owned by
# design (the store cache, the face zones, the per-human pod dir); none of them wants world-write.
#
# IT SURVIVES `env -i`, AND THAT IS THE WHOLE REASON THIS LINE CAN LIVE HERE. The umask is a
# process attribute, not an environment variable — `env -i` empties the environment and leaves it
# untouched. bwrap inherits it, and the tmux server is started INSIDE the sandbox on a per-pod
# socket dir, so it inherits too instead of carrying the umask of some server that was already
# running. Set LAST, immediately before the exec: anything this script created earlier keeps the
# mode it was created with.
umask 002

exec env -i "$BWRAP_BIN" \
  "${NET_ARGS[@]}" \
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
  `# APRES les deux binds du pod_dir, delibere : bwrap applique dans l'ordre, donc ce ro-bind` \
  `# RECOUVRE le fichier deja projete en ecriture. Avant, il serait annule par le bind du dossier.` \
  ${FEED_BIND_ARGS[@]+"${FEED_BIND_ARGS[@]}"} \
  ${ISSUES_BIND_ARGS[@]+"${ISSUES_BIND_ARGS[@]}"} \
  ${AUTH_BIND_ARGS[@]+"${AUTH_BIND_ARGS[@]}"} \
  ${MIRROR_BIND_ARGS[@]+"${MIRROR_BIND_ARGS[@]}"} \
  --ro-bind "$VENDOR_BIN" "$POD_VENDOR_BIN" \
  --ro-bind "$VENDOR_SHARE" "$SANDBOX_HOME/.local/share/$VENDOR_NAME" \
  --bind "$POD_SOCK_DIR" "$POD_SOCK_DIR" \
  --bind "$MCP_SOCK_DIR" "$MCP_SOCK_DIR" \
  "${EGRESS_BINDS[@]}" \
  ${PLUGIN_BINDS[@]+"${PLUGIN_BINDS[@]}"} \
  ${SKILL_BINDS[@]+"${SKILL_BINDS[@]}"} \
  ${CATALOG_BINDS[@]+"${CATALOG_BINDS[@]}"} \
  --chdir "$WORKDIR" \
  `# AVANT les --setenv nommes, et c'est la garde : bwrap garde la DERNIERE occurrence (mesure —` \
  `# --setenv V a --setenv V b rend b). Le tableau d'outillage passe donc EN PREMIER, pour qu'une` \
  `# cle venue d'un env.d ne puisse pas ecraser une variable du contrat (HOME, LCARS_POD_ID, les` \
  `# proxys) : le contrat, deplie apres, a toujours le dernier mot. PATH est deja compose, jamais` \
  `# ecrase (POD_PATH). Un temoin bats epingle cet ordre.` \
  ${TOOLCHAIN_ENV[@]+"${TOOLCHAIN_ENV[@]}"} \
  --setenv HOME "$SANDBOX_HOME" \
  --setenv PATH "$POD_PATH" \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv LANG "${LANG:-C.UTF-8}" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_FLEET_MCP_SOCKET "$MCP_SOCK" \
  `# The vendor CLI honours HTTP(S)_PROXY natively (undici). NO_PROXY is set EMPTY and not merely` \
  `# left out: an inherited one would be a documented bypass of the only wall the pod has.` \
  --setenv HTTP_PROXY "http://127.0.0.1:$EGRESS_PORT" \
  --setenv HTTPS_PROXY "http://127.0.0.1:$EGRESS_PORT" \
  --setenv http_proxy "http://127.0.0.1:$EGRESS_PORT" \
  --setenv https_proxy "http://127.0.0.1:$EGRESS_PORT" \
  --setenv NO_PROXY "" \
  --setenv no_proxy "" \
  --setenv LCARS_POD_EGRESS_SOCK "${LCARS_POD_EGRESS_SOCK:-}" \
  --setenv LCARS_POD_EGRESS_PORT "$EGRESS_PORT" \
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
       socat_bin=$1; egress_sock=$2; egress_port=$3; tmux_bin=$4; sock=$5; name=$6; shift 6
       # THE RELAY, started BEFORE the session and inside the namespace: the pod has no route to
       # anywhere, so `localhost:$egress_port` only exists because socat listens on it and carries
       # the bytes to the unix socket the proxy serves. Backgrounded as a child of the holder, so
       # it dies with the pod exactly like tmux does — nothing to clean up separately.
       # Empty socket = a pod launched with no egress at all (host containment, tests): the vendor
       # is then unreachable, which is the honest consequence of not provisioning one.
       if [ -n "$egress_sock" ]; then
         "$socat_bin" TCP-LISTEN:"$egress_port",bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:"$egress_sock" &
       fi
       "$tmux_bin" -S "$sock" new-session -d -s "$name" "$@"
       # THE HOLDER DIES WITH THE AGENT. It used to hold unconditionally, so a pod whose agent had
       # exited kept its namespace, its Port, and therefore its LIVENESS. Measured 2026-08-11: the
       # tmux server was gone, `lcars attach` said "no sessions", and the fleet re-briefed that pod
       # at every tick because its Port was still open; the ticket stayed lcars-in-flight forever.
       # Teardown was wired one way only (close the Port -> the sleep dies -> tmux and claude fall);
       # this is the return leg. The Port closing lands on the rail that already exists —
       # `Pod.handle_event({:exit_status, _})` -> `pod.failed` / `exited_before_result` -> incident
       # -> reconciliation reclaims the lock -> a real re-dispatch, instead of a brief into a corpse.
       # Poll rather than block: no tmux primitive waits on "this server exited", and 5s of latency
       # on a death is nothing next to a pod that is never declared dead at all.
       while "$tmux_bin" -S "$sock" has-session -t "$name" 2>/dev/null; do sleep 5; done
     ' sh "$SOCAT_BIN" "${LCARS_POD_EGRESS_SOCK:-}" "$EGRESS_PORT" "$TMUX_BIN" "$TMUX_SOCK" "$TMUX_SESSION_NAME" "${COMMAND[@]}"

# bwrap does NOT return (holder sleep infinity): this process IS the live pod (the spawner's Port handle).
# Validation is ASYNC, spawner-side: `tmux -S "$TMUX_SOCK" list-sessions` → is there a "lcars-pod-$POD_ID"
# session? Teardown, spawner-side: close Port / SIGTERM this process → the sleep dies → namespace + tmux +
# claude fall together; --die-with-parent is orphan-safe if the spawner dies. (The spawner cleans the
# sock dir.)
