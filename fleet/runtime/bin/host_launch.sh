#!/usr/bin/env bash
# SOURCE: bin/host_launch.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: PROTO-V2 — launcher N0 host (containment: none) : tmux PTY persistant + socket-dir par-pod + holder, SANS bwrap
#
# Frère host (N0, Ring 1 pod primitive, vendor-agnostic) de `bin/bwrap_launch.sh`. Sélectionné par le
# spawner pour les rôles `containment: none` (architect, starfleet) : ces pods tournent SUR
# L'HÔTE, comme l'humain, SANS sandbox bwrap (l'arch interactif paire avec l'humain et voit l'env réel ;
# c'est le SENS de containment:none host_native). LAUNCH-Q : avant ce launcher, le spawner bwrappait TOUT
# (containment jamais lu) → l'arch booté au démarrage était isolé à tort.
#
# Ce launcher RÉPLIQUE le mécanisme PROUVÉ de bwrap_launch — un `tmux new-session -d` sur une socket-DIR
# par-pod + un HOLDER qui garde ce process vivant (handle de vie = Port spawner) — MOINS le sandbox bwrap
# (pas de `--unshare`, pas de `--tmpfs /home`, pas de bind RO/RW, pas de `--clearenv`). Il NE remplace PAS
# l'ancien `TmuxBackend` (`claude --remote-control` hors bwrap, control-path CASSÉ, supprimé R20/F103) : le
# mécanisme tmux-holder est celui de bwrap_launch, pas le remote-control nu.
#
# Frontière N0/N1 (cf. bwrap_launch IX.2/IX.3) : tmux = N0 (tient n'importe quel REPL). host_launch ne
# connaît PAS les flags `claude` — le command (`claude_launch.sh …`, opaque) est dans `${COMMAND[@]}`.
# JAMAIS éditer bwrap_launch.sh (sanctuaire) : un nouveau besoin de containment = un nouveau launcher
# co-localisé, même argv-shape.
#
# Env identité/session (posés par le spawner, hérités du Port — PAS de --setenv, pas de namespace à
# repeupler ; le pod tourne dans l'env réel du daemon, qui tourne `User=<humain>`) :
#   LCARS_POD_SESSION_ID          UUID pré-alloué — requis (:? strict, consommé par claude_launch)
#   LCARS_POD_SESSION_NAME_PREFIX préfixe nom RC requis (<human>_<role>)
#   HOME                          home RÉEL de l'humain (posé par pod.ex pour containment:none) → claude lit
#                                 le ~/.claude humain natif (auth :bind réalisée nativement, refresh OAuth,
#                                 pas de falaise 8h — l'arch est un pod forever).
#   LCARS_VENDOR_BIN              binaire claude per-user résolu par le spawner (autorité, pas `command -v`).
#
# Usage : host_launch.sh <role> <pod_id> <pod_dir> <command...>
#   <command...> = `claude_launch.sh <role> <pod_id> <pod_dir> <sp>` (opaque, argv préservé).
#
# Teardown (DIFFÉRENCE clé vs bwrap) : pas de namespace → tuer le holder ne CASCADE PAS sur le serveur
# tmux (orphelin claude). Donc le holder TRAP SIGTERM/EXIT → `tmux kill-server` sur la socket par-pod
# (teardown self-contained ; `Pod.terminate_pod_port` SIGTERM reste générique). Filet : `reap_orphan_pod`
# (pkill -f pod_id + kill-server) couvre sur le relaunch suivant si le trap rate (crash dur BEAM).
#
# Exit codes :
#   0   : holder terminé proprement (SIGTERM teardown)
#   1   : setup error (args/env vides, cwd inaccessible, sock parent absent, pod_dir absent)
#   2   : tmux missing/not-x

set -euo pipefail

# =============================================================
# Config (overridable via env)
# =============================================================

TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

# Socket-dir par-pod — MÊME convention que bwrap_launch.sh (parent provisionné systemd-tmpfiles.d).
# MÊME chemin côté Elixir (Fleet.Spawner.PodTmux.sock_path = <base>/<pod_id>/pod.sock).
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

# Identité/session (lues de l'env, posées par le spawner ; :? strict — claude_launch les exige aussi).
: "${LCARS_POD_SESSION_ID:?UUID de session requis (pré-alloué par le spawner)}"
: "${LCARS_POD_SESSION_NAME_PREFIX:?préfixe nom RC requis (<human>_<role>)}"

# cwd = racine de branche (monde-invoqué). Défaut $POD_DIR ; le spawner/bootstrap pose le repo cloné.
WORKDIR="${LCARS_POD_CWD:-$POD_DIR}"

# Session tmux (nom INTERNE, distinct du préfixe nom RC claude) — MÊMES conventions que bwrap_launch.
POD_SOCK_DIR="$SOCK_PARENT/$POD_ID"
TMUX_SESSION_NAME="lcars-pod-$POD_ID"
# Filename CONSTANT (pas ${TMUX_SESSION_NAME}.sock) : le dir $POD_ID/ donne déjà l'unicité ; le double
# pod_id dépassait sun_path 108o pour un pod_id UUID. (= Fleet.Spawner.PodTmux.sock_path.)
TMUX_SOCK="$POD_SOCK_DIR/pod.sock"

# Binaire vendor : N0 pass-through de l'autorité spawner (LCARS_VENDOR_BIN), exposé sous le nom que le
# launcher vendor attend — MÊME relais que bwrap_launch.sh:283 (--setenv LCARS_CLAUDE_BIN). Sans lui,
# claude_launch retombe sur `command -v claude` (binaire système périmé, outil Monitor absent — piège #4).
if [[ -n "${LCARS_VENDOR_BIN:-}" ]]; then
  export LCARS_CLAUDE_BIN="${LCARS_CLAUDE_BIN:-$LCARS_VENDOR_BIN}"
fi

# =============================================================
# Setup checks
# =============================================================
[[ -x "$TMUX_BIN" ]] || { echo "ERR: tmux missing/not-x: $TMUX_BIN (N0 PTY host)" >&2; exit 2; }
[[ -d "$POD_DIR"  ]] || { echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2; exit 1; }
[[ -d "$WORKDIR"  ]] || { echo "ERR: workdir $WORKDIR inaccessible" >&2; exit 1; }
# Parent socket provisionné à l'install (systemd-tmpfiles.d) — fail-fast au boundary, comme bwrap_launch.
[[ -d "$SOCK_PARENT" ]] || { echo "ERR: sock parent $SOCK_PARENT absent (provisioning systemd-tmpfiles.d / LCARS_TMUX_SOCK_BASE)" >&2; exit 1; }
install -d -m 0700 "$POD_SOCK_DIR"

# =============================================================
# Teardown self-contained (pas de cascade namespace sur l'hôte)
# =============================================================
cleanup() {
  "$TMUX_BIN" -S "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$POD_SOCK_DIR" 2>/dev/null || true
}
# SIGTERM (Port close côté spawner) / SIGINT → exit → le trap EXIT fait le cleanup (une seule fois).
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

# =============================================================
# Launch : tmux new-session détaché (COMMAND opaque) + HOLDER trappable.
#   `cd $WORKDIR` AVANT new-session ⇒ la session démarre dans la branche code (= bwrap `--chdir`).
#   Serveur tmux FRAIS par-pod (socket par-pod) ⇒ il capture l'env hérité du Port → COMMAND voit
#   HOME/CLAUDE_DIR/GIT_*/LCARS_* tels que posés par le spawner (pas de --setenv : pas de namespace).
#   PAS d'`exec` : le shell reste vivant comme HOLDER (handle Port) ET trappable (sinon kill-server raté).
# =============================================================
cd "$WORKDIR"
# Le pod doit connaître son dossier de pod (watch.sh/turn.flag du réveil-par-flag Monitor, etc.). En
# bwrap c'est `--setenv LCARS_POD_CWD` ; ici (host_launch, pas de namespace) on EXPORTE pour que le
# new-session — qui hérite de cet env — le transmette à COMMAND (le pod voyait sinon `$LCARS_POD_CWD` vide).
export LCARS_POD_CWD="$WORKDIR"
"$TMUX_BIN" -S "$TMUX_SOCK" new-session -d -s "$TMUX_SESSION_NAME" "${COMMAND[@]}"

# Holder : ce process EST le pod vivant (Port spawner). SIGTERM → trap → cleanup → namespace-libre, le
# serveur tmux par-pod est tué explicitement. Validation ASYNC côté spawner via `tmux -S sock list-sessions`.
#
# argv0 identifiable `lcars-hold:<role>:<pod_id>` (hygiène ressources) : host_launch n'a NI namespace NI
# `--die-with-parent` (vs bwrap) → sur crash dur BEAM, le trap est bypassé, le holder meurt et le sleep
# ORPHELINE. Sans pod_id dans l'argv, le filet `pkill -f <pod_id>` ne le matche pas → accumulation
# invisible. Avec argv0 porteur du pod_id : orphelin VISIBLE (`ps | grep lcars-hold:`) et REAPABLE.
# Subshell `( exec -a … )` et pas `exec` direct : le shell holder reste vivant + trappable (sinon le
# teardown `kill-server` du trap raterait — cf. l.118).
( exec -a "lcars-hold:${ROLE}:${POD_ID}" sleep infinity ) &
wait $!
