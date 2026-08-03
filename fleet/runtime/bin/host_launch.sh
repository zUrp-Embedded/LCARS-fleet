#!/usr/bin/env bash
# SOURCE: bin/host_launch.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: PROTO-V2 — N0 host launcher (containment: none): persistent tmux PTY + per-pod socket-dir + holder, NO bwrap
#
# Host sibling (N0 pod primitive, vendor-agnostic) of `bin/bwrap_launch.sh`. The spawner selects it for
# `containment: none` roles: those pods run ON THE HOST, like the human, with NO bwrap sandbox — outside
# the sandbox is the strongest power in the fleet. LAUNCH-Q: before this launcher the spawner bwrapped
# EVERYTHING (containment was never read), so a role meant to pair with the human was isolated by
# mistake.
#
# NO CANON CAP-PROFILE SELECTS IT TODAY. All 7 are `containment: bwrap` since the 2026-07-19 reorg
# (starfleet became an ordinary bwrap orchestrator); `Fleet.CapProfile` and `Fleet.Spawner.Pod` say the
# same. So this launcher is a supported, tested mode (test/integration/host_launch_test.sh) with zero
# current users — not dead, and not in use. `/api/admin/spawn` refuses host-native by construction
# (`SpawnAdmission` -> `{:host_native_forbidden, name}`), so turning it on is a deliberate act, never a
# default. Read the role names in any older prose here as history, not as configuration.
#
# This launcher REPLICATES bwrap_launch's PROVEN mechanism — a `tmux new-session -d` on a per-pod
# socket-DIR plus a HOLDER keeping this process alive (the life handle IS the spawner's Port) — MINUS the
# bwrap sandbox (no `--unshare`, no `--tmpfs /home`, no RO/RW bind, no `--clearenv`). It does NOT bring
# back the old `TmuxBackend` (`claude --remote-control` outside bwrap, BROKEN control-path, removed
# R20/F103): the mechanism here is bwrap_launch's tmux-holder, not bare remote-control.
#
# N0/N1 frontier (cf. bwrap_launch IX.2/IX.3): tmux is N0 — it holds any REPL. host_launch does NOT know
# the `claude` flags; the command (`claude_launch.sh …`, opaque) lives in `${COMMAND[@]}`. A new
# containment need means a new co-located launcher (one launcher per mode, same argv-shape): a clean
# extension pattern, NOT because bwrap_launch would be untouchable. No code is sacred.
#
# Identity/session env (set by the spawner, INHERITED through the Port — no --setenv, no namespace to
# repopulate; the pod runs in the daemon's real env, and the daemon runs as `User=<human>`):
#   LCARS_POD_SESSION_ID          pre-allocated UUID — required (:? strict, consumed by claude_launch)
#   LCARS_POD_SESSION_NAME_PREFIX required readable pod label, passed through verbatim
#   HOME                          the human's REAL home (set by pod.ex for containment:none) → claude reads
#                                 the native ~/.claude (auth :bind happens natively, OAuth refresh, no 8h
#                                 cliff — the arch is a forever pod).
#   LCARS_VENDOR_BIN              per-user claude binary resolved by the spawner (the authority, not `command -v`).
#
# Usage : host_launch.sh <role> <pod_id> <pod_dir> <command...>
#   <command...> = `claude_launch.sh <role> <pod_id> <pod_dir>` (opaque, argv preserved). The SP is read
#   from $POD_DIR/.lcars/system-prompt.md — it is NOT in the argv.
#
# Teardown (the KEY difference vs bwrap): no namespace, so killing the holder does NOT CASCADE onto the
# tmux server — claude would be orphaned. The holder therefore TRAPS SIGTERM/EXIT and runs `tmux
# kill-server` on the per-pod socket (self-contained teardown; `Pod.terminate_pod_port` stays a generic
# SIGTERM). Safety net: `reap_orphan_pod` (pkill -f pod_id + kill-server) catches it on the next relaunch
# if the trap is missed (hard BEAM crash).
#
# Exit codes:
#   0   : holder exited cleanly (SIGTERM teardown)
#   1   : setup error (empty args/env, unreachable cwd, missing sock parent, missing pod_dir)
#   2   : tmux missing/not-x

set -euo pipefail

# =============================================================
# Config (overridable via env)
# =============================================================

TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

# Per-pod socket-dir — the SAME convention as bwrap_launch.sh. The parent is normally provided by
# `bin/fleet_v2`, which exports `LCARS_TMUX_SOCK_BASE` under `~/.lcars/run/tmux-sock` (the fleet is
# launched by a human) and creates the dir at start. SAME path on the Elixir side (PodTmux.sock_path =
# <base>/<pod_id>/pod.sock). The literal `/run/lcars/tmux-sock` default below is a legacy direct-invocation
# fallback only.
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

# Identity/session (read from the env, set by the spawner; :? strict — claude_launch requires them too).
: "${LCARS_POD_SESSION_ID:?session UUID required (pre-allocated by the spawner)}"
: "${LCARS_POD_SESSION_NAME_PREFIX:?pod label required (Fleet.Layout.pod_label)}"

# cwd = the branch root (the invoked world). Defaults to $POD_DIR; the spawner/bootstrap lays down the clone.
WORKDIR="${LCARS_POD_CWD:-$POD_DIR}"

# tmux session (an INTERNAL name, distinct from claude's RC name prefix) — SAME conventions as bwrap_launch.
POD_SOCK_DIR="$SOCK_PARENT/$POD_ID"
TMUX_SESSION_NAME="lcars-pod-$POD_ID"
# CONSTANT filename (not ${TMUX_SESSION_NAME}.sock): the $POD_ID/ dir already carries the uniqueness, and
# doubling the pod_id overflowed sun_path's 108 bytes for a UUID pod_id. (= Fleet.Spawner.PodTmux.sock_path.)
TMUX_SOCK="$POD_SOCK_DIR/pod.sock"

# Vendor binary: N0 pass-through of the spawner's authority (LCARS_VENDOR_BIN), exposed under the name the
# vendor launcher expects — the SAME relay as bwrap_launch.sh (--setenv LCARS_CLAUDE_BIN). Without it
# claude_launch falls back to `command -v claude`: a stale system binary with no Monitor tool (trap #4).
if [[ -n "${LCARS_VENDOR_BIN:-}" ]]; then
  export LCARS_CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$LCARS_VENDOR_BIN}"
fi

# =============================================================
# Setup checks
# =============================================================
[[ -x "$TMUX_BIN" ]] || { echo "ERR: tmux missing/not-x: $TMUX_BIN (N0 PTY host)" >&2; exit 2; }
[[ -d "$POD_DIR"  ]] || { echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2; exit 1; }
[[ -d "$WORKDIR"  ]] || { echo "ERR: workdir $WORKDIR inaccessible" >&2; exit 1; }
# The parent socket dir is normally laid down by fleet_v2 (LCARS_TMUX_SOCK_BASE → ~/.lcars/run/tmux-sock,
# mkdir at start) — fail-fast at the boundary, like bwrap_launch.
[[ -d "$SOCK_PARENT" ]] || { echo "ERR: sock parent $SOCK_PARENT missing (fleet started via fleet_v2? LCARS_TMUX_SOCK_BASE correct?)" >&2; exit 1; }
install -d -m 0700 "$POD_SOCK_DIR"

# =============================================================
# Self-contained teardown (no namespace cascade on the host)
# =============================================================
cleanup() {
  "$TMUX_BIN" -S "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$POD_SOCK_DIR" 2>/dev/null || true
}
# SIGTERM (spawner-side Port close) / SIGINT → exit → the EXIT trap runs the cleanup (exactly once).
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

# =============================================================
# Launch: detached tmux new-session (opaque COMMAND) + a trappable HOLDER.
#   `cd $WORKDIR` BEFORE new-session ⇒ the session starts in the code branch (bwrap's `--chdir`).
#   A FRESH per-pod tmux server (per-pod socket) ⇒ it captures the env inherited from the Port, so COMMAND
#   sees HOME/CLAUDE_DIR/GIT_*/LCARS_* as the spawner set them (no --setenv: there is no namespace).
#   NO `exec`: the shell stays alive as the HOLDER (Port handle) AND trappable — otherwise kill-server is missed.
# =============================================================
cd "$WORKDIR"
# The pod must know its own pod directory (watch.sh/turn.flag of the Monitor flag-wake, etc.). Under bwrap
# that is `--setenv LCARS_POD_CWD`; here (host_launch, no namespace) we EXPORT it so that new-session —
# which inherits this env — passes it to COMMAND. Without it the pod saw an empty `$LCARS_POD_CWD`.
export LCARS_POD_CWD="$WORKDIR"
# F-E1 — the pod's ROOT (where watch.sh/turn.flag of the flag-wake live), distinct from the CODE workspace
# (LCARS_POD_CWD = the branch when a repo is cloned). Under bwrap, $HOME = $POD_DIR gives it; on the host
# (HOME = the real home ≠ pod_dir) the pod has no other door, so we EXPOSE LCARS_POD_DIR. The SP arms the
# Monitor on `${LCARS_POD_DIR:-$HOME}/watch.sh` (works for bwrap and host alike).
export LCARS_POD_DIR="$POD_DIR"
"$TMUX_BIN" -S "$TMUX_SOCK" new-session -d -s "$TMUX_SESSION_NAME" "${COMMAND[@]}"

# Holder: this process IS the live pod (the spawner's Port). SIGTERM → trap → cleanup → no namespace to
# free, the per-pod tmux server is killed explicitly. Spawner-side validation is ASYNC, via
# `tmux -S sock list-sessions`.
#
# Identifiable argv0 `lcars-hold:<role>:<pod_id>` (resource hygiene): host_launch has NEITHER a namespace
# NOR `--die-with-parent` (unlike bwrap), so on a hard BEAM crash the trap is bypassed, the holder dies and
# the sleep is ORPHANED. Without the pod_id in the argv, the `pkill -f <pod_id>` net does not match it and
# orphans pile up invisibly. With the pod_id carried in argv0 an orphan is VISIBLE
# (`ps | grep lcars-hold:`) and REAPABLE. A subshell `( exec -a … )` rather than a direct `exec`: the
# holder shell stays alive AND trappable — otherwise the trap's `kill-server` teardown would be missed.
( exec -a "lcars-hold:${ROLE}:${POD_ID}" sleep infinity ) &
wait $!
