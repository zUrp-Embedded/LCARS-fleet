#!/bin/bash
#
# SOURCE: test/integration/host_launch_test.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: PROTO-V2 — test intégration bin/host_launch.sh (LAUNCH-Q, containment: none)
#
# Datum de RÉALITÉ pour host_launch.sh : l'exécute vraiment contre tmux (pas de gate-vert seul). Command
# FACTICE (pas de claude/OAuth/agent réel) → safe en CI/dev. Vérifie le mécanisme tmux-holder-sans-bwrap :
#   1. host_launch crée le sock-dir par-pod (0700) + une session tmux `lcars-pod-<id>`.
#   2. Le COMMAND opaque reçoit l'argv EXACT (<role> <pod_id> <pod_dir> <sp>) — contrat de bout en bout.
#   3. Le holder reste vivant (handle de vie du pod).
#   4. SIGTERM au holder → trap → `tmux kill-server` : session ET sock-dir disparaissent (teardown
#      self-contained, pas de cascade namespace sur l'hôte).
#
# Standalone (nécessite tmux) — pas dans `mix test`. Usage : bash test/integration/host_launch_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="${ROOT}/bin/host_launch.sh"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

PASS=0
FAIL=0
step() { echo "==> $*"; }
ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
ko()   { echo "  KO: $*" >&2; FAIL=$((FAIL + 1)); }

# ------------------------------------------------------------------
# Préconditions
# ------------------------------------------------------------------
step "0. Préconditions"
[ -x "$LAUNCHER" ] && ok "host_launch.sh +x" || { ko "host_launch.sh absent/non-x: $LAUNCHER"; exit 1; }
command -v "$TMUX_BIN" >/dev/null 2>&1 && ok "tmux présent ($TMUX_BIN)" || { ko "tmux absent (test requiert tmux)"; exit 1; }

# ------------------------------------------------------------------
# Fixtures éphémères
# ------------------------------------------------------------------
WORK="$(mktemp -d)"
SOCK_BASE="$WORK/sock"
POD_DIR="$WORK/pod"
MARKER="$WORK/command_ran.txt"
POD_ID="itest-$$"
SESSION="lcars-pod-$POD_ID"
SOCK="$SOCK_BASE/$POD_ID/pod.sock"
HOLDER_PID=""

cleanup() {
  [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null && kill -TERM "$HOLDER_PID" 2>/dev/null
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$SOCK_BASE" "$POD_DIR"

# COMMAND factice : à la place de claude_launch.sh. Écrit un marqueur prouvant qu'il a reçu l'argv EXACT
# (<role> <pod_id> <pod_dir> <sp>), puis reste vivant (sinon tmux ferme la session aussitôt).
FAKE_CMD="$WORK/fake_claude_launch.sh"
cat > "$FAKE_CMD" <<'FAKE'
#!/bin/sh
# argv attendu : $1=role $2=pod_id $3=pod_dir $4=sp
{
  echo "argc=$#"
  echo "role=$1"
  echo "pod_id=$2"
  echo "pod_dir=$3"
  echo "sp=$4"
} > "$ITEST_MARKER"
exec sleep 30
FAKE
chmod +x "$FAKE_CMD"

# ------------------------------------------------------------------
# 1. Launch — host_launch en arrière-plan (c'est un holder, il bloque)
# ------------------------------------------------------------------
step "1. host_launch.sh (containment: none) — launch"

# Argv = celui produit par LauncherPortBackend.build_spawn :
#   host_launch <role> <pod_id> <pod_dir>  <COMMAND = fake_cmd role pod_id pod_dir sp>
ITEST_MARKER="$MARKER" \
LCARS_TMUX_SOCK_BASE="$SOCK_BASE" \
LCARS_TMUX_BIN="$TMUX_BIN" \
LCARS_POD_SESSION_ID="sess-$$" \
LCARS_POD_SESSION_NAME_PREFIX="tester_role" \
  "$LAUNCHER" "role" "$POD_ID" "$POD_DIR" \
              "$FAKE_CMD" "role" "$POD_ID" "$POD_DIR" "SP inline de test" &
HOLDER_PID=$!

# Attendre l'apparition de la session (le serveur tmux frais se crée au new-session).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null && break
  sleep 0.3
done

if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ok "session tmux créée ($SESSION)"
else
  ko "session tmux absente après launch"
fi

[ -d "$SOCK_BASE/$POD_ID" ] && ok "sock-dir par-pod créé" || ko "sock-dir par-pod absent"
# Permissions 0700 (install -d -m 0700).
perms="$(stat -c '%a' "$SOCK_BASE/$POD_ID" 2>/dev/null)"
[ "$perms" = "700" ] && ok "sock-dir 0700" || ko "sock-dir perms=$perms (attendu 700)"

kill -0 "$HOLDER_PID" 2>/dev/null && ok "holder vivant (handle Port)" || ko "holder mort après launch"

# ------------------------------------------------------------------
# 2. Contrat argv — le COMMAND opaque a reçu exactement <role> <pod_id> <pod_dir> <sp>
# ------------------------------------------------------------------
step "2. Contrat argv transmis au COMMAND"

for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER" ] && break; sleep 0.3; done

if [ -f "$MARKER" ]; then
  ok "COMMAND exécuté (marqueur écrit)"
  grep -qx "argc=4" "$MARKER"              && ok "argc=4 (pas de pollution d'argv)" || ko "argc != 4: $(grep argc= "$MARKER")"
  grep -qx "role=role" "$MARKER"           && ok "argv[1]=role"     || ko "role: $(grep '^role=' "$MARKER")"
  grep -qx "pod_id=$POD_ID" "$MARKER"      && ok "argv[2]=pod_id"   || ko "pod_id: $(grep '^pod_id=' "$MARKER")"
  grep -qx "pod_dir=$POD_DIR" "$MARKER"    && ok "argv[3]=pod_dir"  || ko "pod_dir: $(grep '^pod_dir=' "$MARKER")"
  grep -qx "sp=SP inline de test" "$MARKER" && ok "argv[4]=sp (inline, espaces préservés)" || ko "sp: $(grep '^sp=' "$MARKER")"
else
  ko "COMMAND jamais exécuté (marqueur absent) — argv non transmis ?"
fi

# ------------------------------------------------------------------
# 3. Teardown self-contained — SIGTERM holder → trap → tmux kill-server
# ------------------------------------------------------------------
step "3. Teardown SIGTERM (pas de cascade namespace sur l'hôte)"

kill -TERM "$HOLDER_PID" 2>/dev/null

# Le holder doit sortir (sleep infinity interrompu par le trap).
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.3; done
kill -0 "$HOLDER_PID" 2>/dev/null && ko "holder encore vivant après SIGTERM" || ok "holder sorti sur SIGTERM"

# Le trap a dû tuer le serveur tmux (sinon claude orphelin) — la session disparaît.
for _ in 1 2 3 4 5 6 7 8 9 10; do "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null || break; sleep 0.3; done
if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ko "session tmux SURVIT au teardown (orphelin — trap kill-server raté)"
else
  ok "session tmux tuée par le trap (kill-server)"
fi

# Le sock-dir par-pod doit être nettoyé par le cleanup du trap.
[ -d "$SOCK_BASE/$POD_ID" ] && ko "sock-dir par-pod non nettoyé après teardown" || ok "sock-dir par-pod nettoyé"

HOLDER_PID=""  # déjà mort, ne pas re-kill au trap EXIT

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="
if [ "$FAIL" -eq 0 ]; then
  echo "all checks PASS"
  exit 0
else
  echo "FAIL — $FAIL checks failed" >&2
  exit 1
fi
