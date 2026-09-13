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
#   LCARS_AUTH_MODE               bind ONLY: RW bind of CLAUDE_DIR/.credentials.json ALONE →
#                                 pod_dir/.claude/.credentials.json (native Anthropic refresh in
#                                 place + mtime sync, no ~8h cliff). .claude/ stays pod-owned.
#
# Git identity (Z4): GIT_AUTHOR_*/GIT_COMMITTER_* are FORWARDED from the env, and
# GIT_CONFIG_GLOBAL=/dev/null pod-side makes git read them instead of its own global. It is NOT a
# security guarantee — a shell can override the env.
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

# Per-pod socket dir (P1 #1 — bind the DIR, not the file that does not exist yet).
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

# SANDBOX_HOME is what the agent sees as its home (and the root of EVERY pod bind: .claude, creds,
# vendor, plugins). The REAL pod_dir ($POD_DIR, still the SRC of the binds) hides behind /home/.pod.
SANDBOX_HOME="${LCARS_POD_HOME:-$POD_DIR}"

WORKDIR="${LCARS_POD_CWD:-$SANDBOX_HOME}"

# Clean-world: remaps the INTRA-POD cwd only. The REAL pod_dir stays /home/<human>/pods/... (bound to
# itself further down, INTACT).
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

# Per-pod MCP socket (the AF_UNIX channel between the pod's bridge and central). We bind ONLY this
# per-pod dir ($MCP_SOCK_DIR), NEVER the base: binding the base would expose sibling pods' sockets
# inside THIS sandbox — a breach of the multi-human tenant frontier. UNLIKE tmux: the socket file
# (and its dir) is created OUTSIDE the sandbox by the BEAM BEFORE this launch (central provisions
# the per-pod socket) → bwrap MOUNTS a PRE-EXISTING dir, it does not create it (no `install -d`).
MCP_SOCK_BASE="${LCARS_FLEET_MCP_SOCK_BASE:-/run/lcars/mcp}"
MCP_SOCK_DIR="$MCP_SOCK_BASE/$POD_ID"
MCP_SOCK="$MCP_SOCK_DIR/sock"

# Per-pod EGRESS socket — the pod's only way out. ⚠ `socat` IS LOAD-BEARING HERE: it is what turns
# `localhost:$EGRESS_PORT` inside the sandbox into that socket. Absent, the pod is simply sealed —
# the vendor becomes unreachable and the pod cannot work at all. That is why the assertion below is
# fatal rather than degraded: a silent fallback to `--share-net` would turn a missing package into
# an open pod.
EGRESS_SOCK_BASE="${LCARS_FLEET_EGRESS_SOCK_BASE:-/run/lcars/egress}"
EGRESS_SOCK_DIR="$EGRESS_SOCK_BASE/$POD_ID"
EGRESS_PORT="${LCARS_POD_EGRESS_PORT:-8118}"
SOCAT_BIN="${LCARS_SOCAT_BIN:-/usr/bin/socat}"
POD_VENDOR_BIN="$SANDBOX_HOME/.local/bin/$VENDOR_NAME"

if [[ "${LCARS_BWRAP_NO_CLEANUP:-0}" != "1" ]]; then
  trap 'rm -rf "$POD_SOCK_DIR" 2>/dev/null || true' EXIT ERR
fi

[[ -x "$BWRAP_BIN" ]] || { echo "ERR: bwrap missing/not-x: $BWRAP_BIN" >&2; exit 2; }
[[ -x "$TMUX_BIN"  ]] || { echo "ERR: tmux missing/not-x: $TMUX_BIN (N0 PTY host)" >&2; exit 2; }
if [[ -z "$VENDOR_BIN" || ! -x "$VENDOR_BIN" || ! -d "$VENDOR_SHARE" ]]; then
  echo "ERR: vendor '$VENDOR_NAME' not found (bin=$VENDOR_BIN share=$VENDOR_SHARE) — set LCARS_VENDOR_BIN" >&2; exit 2
fi
[[ -d "$CLAUDE_DIR"  ]] || { echo "ERR: claudeDir $CLAUDE_DIR missing (human registration — adr-f)" >&2; exit 1; }
[[ -z "$GIT_MIRROR" || -d "$GIT_MIRROR" ]] || { echo "ERR: git mirror $GIT_MIRROR set but missing (LCARS_GIT_MIRROR)" >&2; exit 1; }
MIRROR_BIND_ARGS=()
[[ -n "$GIT_MIRROR" && -d "$GIT_MIRROR" ]] && MIRROR_BIND_ARGS=(--ro-bind "$GIT_MIRROR" "$GIT_MIRROR")
[[ -d "$POD_DIR"     ]] || { echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2; exit 1; }

[[ -d "$SOCK_PARENT" ]] || { echo "ERR: sock parent $SOCK_PARENT missing (set by bin/fleet at start; override LCARS_TMUX_SOCK_BASE)" >&2; exit 1; }
install -d -m 0700 "$POD_SOCK_DIR"
install -d -m 0755 "$POD_DIR/.local/bin"

touch "$POD_DIR/fleet.feed" 2>/dev/null || true
FEED_BIND_ARGS=()
if [[ -f "$POD_DIR/fleet.feed" ]]; then
  FEED_BIND_ARGS=(--ro-bind "$POD_DIR/fleet.feed" "$SANDBOX_HOME/fleet.feed")
  if [[ -n "${LCARS_POD_CWD_SRC:-}" && "$LCARS_POD_CWD_SRC" == "$POD_DIR" && "$WORKDIR" != "$SANDBOX_HOME" ]]; then
    FEED_BIND_ARGS+=(--ro-bind "$POD_DIR/fleet.feed" "$WORKDIR/fleet.feed")
  fi
fi

ISSUES_BIND_ARGS=()
if [[ -d "$POD_DIR/issues" ]]; then
  ISSUES_BIND_ARGS=(--ro-bind "$POD_DIR/issues" "$SANDBOX_HOME/issues")
  # Meme double-chemin que le feed pour l'arch (cwd RE-MONTE le pod_dir) : sinon l'autre vue reste RW.
  if [[ -n "${LCARS_POD_CWD_SRC:-}" && "$LCARS_POD_CWD_SRC" == "$POD_DIR" && "$WORKDIR" != "$SANDBOX_HOME" ]]; then
    ISSUES_BIND_ARGS+=(--ro-bind "$POD_DIR/issues" "$WORKDIR/issues")
  fi
fi

[[ -d "$MCP_SOCK_DIR" ]] || { echo "ERR: dir socket MCP $MCP_SOCK_DIR missing (central must provision it before the launch)" >&2; exit 1; }

PLUGIN_BINDS=()
set -f
for plugin in ${LCARS_SKILLS_PLUGINS:-}; do
  # Strict NAME allowlist (S5): the name is interpolated into bind paths (belt — the cap-profile
  # source is trusted-operator).
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

# LCARS_SKILLS_PATHS: one `name:abs_path` per line. The first `:` separates — the name is a fleet
# slug (no `:` in its alphabet), the path keeps any `:` it has.
SKILL_BINDS=()
while IFS= read -r skill_line; do
  [[ -z "$skill_line" ]] && continue
  skill_name="${skill_line%%:*}"
  skill_path="${skill_line#*:}"
  case "$skill_name" in
    *..* | */* | .* | "") echo "ERR: invalid skill name '$skill_name' (path-traversal)" >&2; exit 1 ;;
  esac
  [[ -d "$skill_path" ]] || { echo "ERR: skill '$skill_name' has no dir at '$skill_path' (filtered upstream — projection/launch skew)" >&2; exit 1; }
  SKILL_BINDS+=(--ro-bind "$skill_path" "$SANDBOX_HOME/.claude/skills/$skill_name")
done <<< "${LCARS_SKILLS_PATHS:-}"

AUTH_BIND_ARGS=()
HUMAN_CREDS="$CLAUDE_DIR/.credentials.json"
[[ -f "$HUMAN_CREDS" ]] || { echo "ERR: creds $HUMAN_CREDS missing (human registration — adr-f)" >&2; exit 1; }
# The pod-owned `.claude/` must exist host-side to host the creds mountpoint (POD_DIR is itself
# bind-mounted RW → this mkdir is visible in the sandbox).
mkdir -p "$POD_DIR/.claude"
AUTH_BIND_ARGS=(--bind "$HUMAN_CREDS" "$SANDBOX_HOME/.claude/.credentials.json")

# Cutting telemetry also cuts the Statsig/GrowthBook flag fetch → `MONITOR_TOOL` defaults OFF, and the
# agent falls back to the `engage` kick instead of the Monitor. The coupling is on the Anthropic relay
# side; `CLAUDE_INTERNAL_FC_OVERRIDES` is gated on `USER_TYPE=ant`, inert on the public binary.
TELEMETRY_ENV=()
if [[ "${LCARS_POD_DISABLE_TELEMETRY:-0}" == "1" ]]; then
  TELEMETRY_ENV=(--setenv DISABLE_TELEMETRY "1" --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1")
fi

# resolv.conf is often a symlink out of /etc (WSL → /mnt/wsl), so we bind the REAL file straight
# onto /etc/resolv.conf: no symlink to resolve, no /mnt/wsl exposed. Dead DNS = claude hangs on the API.
RESOLV_REAL="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
[[ -n "$RESOLV_REAL" && -e "$RESOLV_REAL" ]] || RESOLV_REAL=/etc/resolv.conf

# Le pod ne source JAMAIS de script : sourcer du shell venu d'un artefact telecharge, dans le
# processus qui construit le bac a sable, rouvrirait ici le trou que le convergeur referme. Le
# convergeur joue l'`env_script` d'un SDK UNE fois et fige son delta a plat ; le pod recoit un
# resultat.
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

# Bound AFTER the `--tmpfs /home` below ⇒ they restore the masked paths (e.g. /home/projects).
CATALOG_BINDS=()
if [[ -n "${LCARS_POD_MOUNTS:-}" ]]; then
  while IFS= read -r _mount; do
    [[ -z "$_mount" ]] && continue
    _mode="${_mount%%:*}"; _rest="${_mount#*:}"
    if [[ "$_rest" == *:* ]]; then _path="${_rest%%:*}"; _dst="${_rest#*:}"; else _path="$_rest"; _dst="$_rest"; fi
    [[ "$_path" == /* ]] || { echo "ERR: catalogue mount path is not absolute: '$_path'" >&2; exit 1; }
    [[ "$_dst"  == /* ]] || { echo "ERR: catalogue mount target is not absolute: '$_dst'" >&2; exit 1; }
    [[ -e "$_path"   ]] || { echo "ERR: catalogue mount path missing host-side: '$_path'" >&2; exit 1; }
    case "$_mode" in
      ro) CATALOG_BINDS+=(--ro-bind "$_path" "$_dst") ;;
      rw)
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

NET_ARGS=(--unshare-all)
if [[ -n "${LCARS_POD_EGRESS_SOCK:-}" ]]; then
  [[ -d "$EGRESS_SOCK_DIR" ]] || { echo "ERR: dir socket egress $EGRESS_SOCK_DIR missing (central must provision it before the launch)" >&2; exit 1; }
  [[ -x "$SOCAT_BIN" ]] || { echo "ERR: socat missing ($SOCAT_BIN) — the pod would be sealed with no way to reach its vendor" >&2; exit 2; }
  EGRESS_BINDS=(--bind "$EGRESS_SOCK_DIR" "$EGRESS_SOCK_DIR" --ro-bind "$SOCAT_BIN" "$SOCAT_BIN")
else
  EGRESS_BINDS=()
fi

# 002, NOT 000 — group-writable, world-untouched. Every tree a pod writes into is group-owned by
# design (the store cache, the face zones, the per-human pod dir); none of them wants world-write.
umask 002

exec env -i "$BWRAP_BIN" \
  "${NET_ARGS[@]}" \
  --hostname "lcars-pod-$POD_ID" \
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
  `# Without it those links dangle → 'awk: command not found' while gawk IS there.` \
  --ro-bind /sys /sys \
  --tmpfs /home \
  --tmpfs /tmp \
  --dev /dev --proc /proc \
  --bind "$POD_DIR" "$SANDBOX_HOME" \
  ${CWD_BIND_ARGS[@]+"${CWD_BIND_ARGS[@]}"} \
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
  `# L'outillage passe EN PREMIER : bwrap garde la DERNIERE occurrence, donc le contrat deplie` \
  `# apres a le dernier mot.` \
  ${TOOLCHAIN_ENV[@]+"${TOOLCHAIN_ENV[@]}"} \
  --setenv HOME "$SANDBOX_HOME" \
  --setenv PATH "$POD_PATH" \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv LANG "${LANG:-C.UTF-8}" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_FLEET_MCP_SOCKET "$MCP_SOCK" \
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
       # THE HOLDER DIES WITH THE AGENT. A holder that outlives its tmux server keeps the
       # namespace, the Port, and therefore the LIVENESS of the pod: the fleet re-briefs that pod at
       # every tick because its Port is still open, and the ticket stays lcars-in-flight forever
       # (measured 2026-08-11: tmux server gone, `lcars attach` saying "no sessions", Port open).
       # Teardown is wired both ways: close the Port -> the sleep dies -> tmux and claude fall; and
       # this return leg. The Port closing lands on the rail that already exists —
       # `Pod.handle_event({:exit_status, _})` -> `pod.failed` / `exited_before_result` -> incident
       # -> reconciliation reclaims the lock -> a real re-dispatch, instead of a brief into a corpse.
       # Poll rather than block: no tmux primitive waits on "this server exited", and 5s of latency
       # on a death is nothing next to a pod that is never declared dead at all.
       while "$tmux_bin" -S "$sock" has-session -t "$name" 2>/dev/null; do sleep 5; done
     ' sh "$SOCAT_BIN" "${LCARS_POD_EGRESS_SOCK:-}" "$EGRESS_PORT" "$TMUX_BIN" "$TMUX_SOCK" "$TMUX_SESSION_NAME" "${COMMAND[@]}"
