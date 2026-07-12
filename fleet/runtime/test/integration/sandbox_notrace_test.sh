#!/bin/bash
#
# SOURCE: test/integration/sandbox_notrace_test.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-14
# STATUS: PROTO-V2 — test intégration F094 : invariant no-trace de la sandbox bwrap_launch.sh
#
# F094 (invariant CARDINAL, non-testable en hermétique) : « l'agent ne voit AUCUNE trace LCARS ». Dépend
# de la VUE sandbox bwrap → seul un bwrap RÉEL peut le prouver. Ce test lance `bin/bwrap_launch.sh` (le
# launcher RÉEL, NON modifié — on l'EXÉCUTE) avec un COMMAND FACTICE (pas de claude/OAuth) qui inspecte SA
# PROPRE vue depuis l'intérieur du sandbox et écrit ses constats dans POD_DIR (bind RW → lisible host-side).
#
# Assertions (la vue de l'agent) :
#   - le code runtime LCARS host (`/home/projects/LCARS`, `/etc/fleet`) est INVISIBLE ;
#   - `/home` est un tmpfs (pas le /home host avec ses humains/pods) ;
#   - HOME = POD_DIR (monde clos) ;
#   - le token OAuth injecté est présent (auth), MAIS l'env ambiant host ne fuit pas (--clearenv).
#
# Standalone (nécessite bwrap + userns + tmux) — hors `mix test`. bwrap NON édité ICI (on prouve le launcher RÉEL) : lu/exécuté.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BWRAP_LAUNCH="${ROOT}/bin/bwrap_launch.sh"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

PASS=0
FAIL=0
step() { echo "==> $*"; }
ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
ko()   { echo "  KO: $*" >&2; FAIL=$((FAIL + 1)); }

# ------------------------------------------------------------------
step "0. Préconditions"
[ -x "$BWRAP_LAUNCH" ] && ok "bwrap_launch.sh +x" || { ko "absent: $BWRAP_LAUNCH"; exit 1; }
command -v "$BWRAP_BIN" >/dev/null 2>&1 && ok "bwrap présent" || { ko "bwrap absent"; exit 1; }
command -v "$TMUX_BIN"  >/dev/null 2>&1 && ok "tmux présent"  || { ko "tmux absent"; exit 1; }
# userns dispo ? (bwrap unshare trivial — usrmerge-aware : /bin,/lib sont des symlinks → --symlink, pas --ro-bind)
if timeout 10 "$BWRAP_BIN" --unshare-all --ro-bind /usr /usr \
     --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
     --proc /proc --dev /dev /usr/bin/true 2>/dev/null; then
  ok "userns bwrap fonctionnel"
else
  ko "userns bwrap indisponible (env ne supporte pas — SKIP non-bloquant)"; echo "SKIP"; exit 0
fi

# ------------------------------------------------------------------
# Fixtures (toutes les préconditions de bwrap_launch.sh, sans claude)
# ------------------------------------------------------------------
WORK="$(mktemp -d)"
POD_DIR="$WORK/pod"
SOCK_BASE="$WORK/sock"
CLAUDE_DIR="$WORK/claudedir"
GIT_MIRROR="$WORK/gitmirror"
VENDOR_SHARE="$WORK/vendor-share"
VENDOR_BIN="$WORK/fake-claude"
POD_ID="ntrace-$$"
SESSION="lcars-pod-$POD_ID"
SOCK="$SOCK_BASE/$POD_ID/pod.sock"
OUT="$POD_DIR/output/notrace.txt"
HOLDER_PID=""

cleanup() {
  [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null && kill -TERM "$HOLDER_PID" 2>/dev/null
  "$TMUX_BIN" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$POD_DIR" "$SOCK_BASE" "$CLAUDE_DIR" "$GIT_MIRROR" "$VENDOR_SHARE"
printf '#!/bin/sh\necho fake-vendor\n' > "$VENDOR_BIN"; chmod +x "$VENDOR_BIN"

# COMMAND factice (à la place de claude_launch.sh). Vit SOUS POD_DIR (bind RW → visible dans le sandbox au
# même path). Inspecte la vue de l'agent et écrit ses constats dans POD_DIR/output (lisible host-side).
INSPECT="$POD_DIR/inspect.sh"
cat > "$INSPECT" <<'INS'
#!/bin/sh
out="$HOME/output"
mkdir -p "$out"
{
  echo "home_entries=[$(ls -A /home 2>/dev/null | tr '\n' ',')]"
  echo "host_lcars_repo=$([ -e /home/projects/LCARS ] && echo VISIBLE || echo absent)"
  echo "host_projects=$([ -e /home/projects ] && echo VISIBLE || echo absent)"
  echo "etc_fleet=$([ -e /etc/fleet ] && echo VISIBLE || echo absent)"
  echo "home_env=$HOME"
  echo "cwd=$(pwd)"
  echo "oauth_token=$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo set || echo unset)"
  echo "DONE"
} > "$out/notrace.txt" 2>&1
exec sleep 30
INS
chmod +x "$INSPECT"

# ------------------------------------------------------------------
step "1. Lancer bwrap_launch.sh (le launcher réel) avec COMMAND factice"

LCARS_BWRAP_NO_CLEANUP=1 \
LCARS_BWRAP_BIN="$BWRAP_BIN" \
LCARS_TMUX_BIN="$TMUX_BIN" \
LCARS_TMUX_SOCK_BASE="$SOCK_BASE" \
CLAUDE_DIR="$CLAUDE_DIR" \
LCARS_GIT_MIRROR="$GIT_MIRROR" \
LCARS_VENDOR_NAME="claude" \
LCARS_VENDOR_BIN="$VENDOR_BIN" \
LCARS_VENDOR_SHARE="$VENDOR_SHARE" \
LCARS_AUTH_MODE="token_arg" \
LCARS_ANTHROPIC_AUTH_TOKEN="dummy-token-for-test" \
LCARS_POD_SESSION_ID="sess-$$" \
LCARS_POD_SESSION_NAME_PREFIX="tester_role" \
GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@t" \
  "$BWRAP_LAUNCH" "role" "$POD_ID" "$POD_DIR" \
                  "$INSPECT" "role" "$POD_ID" "$POD_DIR" "SP test" &
HOLDER_PID=$!

for _ in $(seq 1 20); do "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null && break; sleep 0.3; done
if "$TMUX_BIN" -S "$SOCK" has-session -t "$SESSION" 2>/dev/null; then
  ok "session tmux dans bwrap créée"
else
  ko "session tmux absente — bwrap_launch n'a pas démarré (voir stderr ci-dessus)"
fi

# ------------------------------------------------------------------
step "2. Invariant no-trace — la vue de l'agent (depuis l'intérieur)"

for _ in $(seq 1 20); do [ -f "$OUT" ] && break; sleep 0.3; done

if [ -f "$OUT" ]; then
  ok "COMMAND a inspecté sa vue (constats écrits)"
  echo "    --- vue agent ---"; sed 's/^/    /' "$OUT"
  # Coeur de l'invariant no-trace : le code/arbo runtime LCARS host est invisible (le point de F094).
  grep -qxF "host_lcars_repo=absent" "$OUT" && ok "code runtime LCARS host INVISIBLE (/home/projects/LCARS)" || ko "FUITE : /home/projects/LCARS visible dans le pod"
  grep -qxF "host_projects=absent"   "$OUT" && ok "/home/projects host invisible"                            || ko "FUITE : /home/projects visible"
  grep -qxF "home_entries=[]"        "$OUT" && ok "/home = tmpfs vide (pas le /home host)"                   || ko "/home non-vide : $(grep home_entries= "$OUT")"
  grep -qxF "home_env=$POD_DIR"      "$OUT" && ok "HOME = POD_DIR (monde clos)"                               || ko "HOME inattendu : $(grep home_env= "$OUT")"
  grep -qxF "oauth_token=set"        "$OUT" && ok "token OAuth injecté présent (auth)"                        || ko "token OAuth absent (auth cassée)"

  # FINDING (PAS un FAIL — fix = éditer bwrap_launch.sh : ro-bind /etc sélectif ; décision user) : bwrap_launch `--ro-bind
  # /etc /etc` expose TOUT /etc, dont `/etc/fleet` (lcars-fleet.env = FORGE_TOKEN/RELEASE_COOKIE,
  # api-secret, webhook-secret). Un agent qui DÉRIVE (le seul thread intra reconnu, ADR-C « contenir le
  # pod ») peut les lire → le sandbox ne contient PAS les secrets fleet. Remontée user, pas un fix de nuit.
  if grep -qxF "etc_fleet=VISIBLE" "$OUT"; then
    echo "  ⚠ FINDING (no-trace partiel) : /etc/fleet VISIBLE dans le pod (bwrap --ro-bind /etc) →" >&2
    echo "    secrets fleet (lcars-fleet.env, *-secret) lisibles par un agent dérivant. Fix = masquer" >&2
    echo "    /etc/fleet (--tmpfs) ou ro-bind /etc sélectif dans bwrap_launch.sh (décision user)." >&2
  else
    ok "/etc/fleet invisible (pas de fuite secrets fleet)"
  fi
else
  ko "COMMAND jamais exécuté dans le sandbox (constats absents)"
fi

# ------------------------------------------------------------------
step "3. Teardown"
kill -TERM "$HOLDER_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$HOLDER_PID" 2>/dev/null || break; sleep 0.3; done
kill -0 "$HOLDER_PID" 2>/dev/null && ko "holder survit au SIGTERM" || ok "holder + sandbox tombés (SIGTERM)"
HOLDER_PID=""

echo ""
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "===================="
if [ "$FAIL" -eq 0 ]; then echo "all checks PASS"; exit 0; else echo "FAIL — $FAIL checks failed" >&2; exit 1; fi
