#!/bin/bash
# SOURCE: test_oauth.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-02 — OAuth wizard WSL2/host
# Teste empiriquement le flow `claude auth login` depuis WSL2 :
#   - interop Windows activé/désactivé ?
#   - le browser host s'ouvre-t-il automatiquement ?
#   - .credentials.json créé à la fin ?
#   - copie umask 077 vers /home/private correcte ?
#   - re-run = skip wizard ?

set -u
TESTDIR=$(mktemp -d /tmp/poc02-XXXXXX)
REPORT="$TESTDIR/report.txt"
SUMMARY=""
log() { echo "[$1] $2" | tee -a "$REPORT"; }
pass() { SUMMARY+=$'\n'"PASS  $1"; log PASS "$1"; }
fail() { SUMMARY+=$'\n'"FAIL  $1: $2"; log FAIL "$1: $2"; }
warn() { SUMMARY+=$'\n'"WARN  $1: $2"; log WARN "$1: $2"; }
info() { log INFO "$1"; }

info "claude version: $(claude --version)"
info "workdir: $TESTDIR"
info "WSL kernel: $(uname -r)"

# ---------- T1: etat interop WSL2 ----------
INTEROP_ENABLED="unknown"
if [ -f /etc/wsl.conf ]; then
  ENABLED_LINE=$(grep -E '^\s*enabled\s*=' /etc/wsl.conf | head -1 | tr -d ' ' | cut -d= -f2 || echo "unknown")
  # [interop] section
  if awk '/^\[interop\]/{found=1; next} /^\[/{found=0} found && /enabled/{print; exit}' /etc/wsl.conf | grep -qi 'false'; then
    INTEROP_ENABLED="false"
  elif awk '/^\[interop\]/{found=1; next} /^\[/{found=0} found && /enabled/{print; exit}' /etc/wsl.conf | grep -qi 'true'; then
    INTEROP_ENABLED="true"
  fi
fi
info "wsl.conf [interop] enabled: $INTEROP_ENABLED"

PS_IN_PATH=$(command -v powershell.exe 2>/dev/null || echo "")
WSL_IN_PATH=$(command -v wsl.exe 2>/dev/null || echo "")
INIT_BINFMT=$(ls /init 2>/dev/null || echo "")
INTEROP_SOCK=$(ls /run/WSL/*_interop 2>/dev/null | head -1 || echo "")

info "powershell.exe in PATH: ${PS_IN_PATH:-(non)}"
info "wsl.exe in PATH: ${WSL_IN_PATH:-(non)}"
info "/init binfmt: ${INIT_BINFMT:-(absent)}"
info "interop socket: ${INTEROP_SOCK:-(absent)}"

if [ -n "$INTEROP_SOCK" ] && [ -n "$INIT_BINFMT" ]; then
  info "T1: socket interop present — xdg-open peut tenter de lancer le browser host via /init"
  pass "T1.interop-surface (socket+binfmt dispo)"
else
  fail "T1.interop-surface" "ni socket ni binfmt detectes"
fi

# ---------- T2: `claude auth login` fresh home — flow observe ----------
T2_HOME="$TESTDIR/t2-home"
mkdir -p "$T2_HOME/.claude"

info "T2 : lancement claude auth login en PTY simule, timeout 7s"
LOG="$TESTDIR/t2-auth.log"
# script -q -c ne propage pas SIGTERM de timeout au child claude. On fork,
# laisse claude imprimer l URL, puis kill le child explicitement via pkill -P.
HOME="$T2_HOME" script -q -c "claude auth login" "$LOG" < /dev/null >/dev/null 2>&1 &
SPID=$!
sleep 7
pkill -TERM -P $SPID 2>/dev/null || true
sleep 1
kill $SPID 2>/dev/null || true
wait $SPID 2>/dev/null || true

# Nettoyage ANSI + CR
CLEAN="$TESTDIR/t2-auth.clean.log"
sed 's/\x1b\[[0-9;]*[mGKHJ]//g; s/\r//g' "$LOG" > "$CLEAN"

if grep -q "Opening browser" "$CLEAN"; then
  pass "T2.browser-attempt (message \"Opening browser to sign in\" emis)"
else
  fail "T2.browser-attempt" "pas de trace d ouverture browser dans les 8s"
  head -20 "$CLEAN" | sed 's/^/    /' >> "$REPORT"
fi

URL=$(grep -oE 'https?://claude\.com/cai/oauth/[^ )]+' "$CLEAN" | head -1)
if [ -n "$URL" ]; then
  pass "T2.fallback-url (URL OAuth imprimee comme fallback)"
  info "T2 URL: $(echo "$URL" | head -c 80)..."
else
  fail "T2.fallback-url" "pas d URL OAuth dans sortie"
fi

# ---------- T3: browser host auto-open via xdg-open / wslview ----------
# Le wizard fait probablement xdg-open URL en interne. Verifier que xdg-open
# (ou equivalent) reussit a delegation Windows via /init.
if command -v xdg-open >/dev/null; then
  info "xdg-open present"
elif command -v wslview >/dev/null; then
  info "wslview present"
elif command -v sensible-browser >/dev/null; then
  info "sensible-browser present"
else
  warn "T3.browser-launcher" "aucun launcher (xdg-open/wslview/sensible-browser)"
fi

# Test mecanique : peut-on lancer un browser via /init + powershell ?
# Sans appendWindowsPath, il faut chemin absolu. Probe : /init est binfmt,
# il peut executer un .exe si on a le chemin. Mais sans automount Windows,
# on n a pas de chemin executable Windows.
if [ "$INTEROP_ENABLED" = "false" ]; then
  warn "T3.interop-disabled" "[interop] enabled=false dans /etc/wsl.conf — auto-open browser probablement ko"
  info "-> flow attendu en pratique : user copie l URL manuellement depuis le terminal"
fi

# ---------- T4: permissions credentials starfleet reelle ----------
if [ -f /home/starfleet/.claude/.credentials.json ]; then
  PERMS=$(stat -c '%a' /home/starfleet/.claude/.credentials.json)
  OWNER=$(stat -c '%U:%G' /home/starfleet/.claude/.credentials.json)
  info "T4 /home/starfleet/.claude/.credentials.json : $PERMS $OWNER"
  if [ "$PERMS" = "600" ]; then
    pass "T4.creds-perms (600)"
  else
    fail "T4.creds-perms" "attendu 600, trouve $PERMS"
  fi
else
  warn "T4.creds-missing" "pas de credentials starfleet sur ce systeme"
fi

# ---------- T5: umask 077 + cp produit 600 ----------
SRC="$TESTDIR/t5-src.json"
DST="$TESTDIR/t5-dst.json"
echo '{"token":"fake"}' > "$SRC"
chmod 644 "$SRC"
(umask 077; cp "$SRC" "$DST")
PERMS=$(stat -c '%a' "$DST")
if [ "$PERMS" = "600" ]; then
  pass "T5.umask-077-cp (resultat 600)"
else
  fail "T5.umask-077-cp" "attendu 600, trouve $PERMS"
fi

# ---------- T6: /home/private accessible ? ----------
if [ -d /home/private ] && [ -r /home/private ]; then
  pass "T6.home-private (lisible)"
elif [ -d /home/private ]; then
  warn "T6.home-private-protected" "/home/private existe mais 700/root — copie requiert sudo"
  info "   perms: $(stat -c '%a %U:%G' /home/private 2>/dev/null || echo '?')"
else
  fail "T6.home-private-absent" "/home/private n existe pas"
fi

# ---------- T7: re-run skip (creds deja presentes) ----------
# Copier credentials starfleet dans home de test, verifier que `auth status`
# signale loggedIn=true et qu un deuxieme `auth login` skippe (en theorie).
T7_HOME="$TESTDIR/t7-home"
mkdir -p "$T7_HOME/.claude"
cp /home/starfleet/.claude/.credentials.json "$T7_HOME/.claude/.credentials.json" 2>/dev/null || true
chmod 600 "$T7_HOME/.claude/.credentials.json" 2>/dev/null || true

STATUS=$(HOME="$T7_HOME" claude auth status 2>&1 | head -50 || true)
if echo "$STATUS" | grep -q '"loggedIn"\s*:\s*true' || echo "$STATUS" | grep -qi 'logged in'; then
  pass "T7.rerun-detect (auth status=loggedIn sur creds deja presentes)"
else
  warn "T7.rerun-detect" "auth status ne detecte pas creds (peut-etre format different)"
  echo "$STATUS" | head -10 | sed 's/^/    /' >> "$REPORT"
fi

# ---------- T8: re-run claude -p marche avec creds recopiees ----------
OUT=$(cd "$T7_HOME" && HOME="$T7_HOME" claude -p "say ok" --output-format json \
  --model haiku --setting-sources "" --no-session-persistence 2>&1 || true)
if echo "$OUT" | grep -qE '"is_error":\s*false'; then
  pass "T8.creds-portable (creds recopiees = auth OK)"
else
  fail "T8.creds-portable" "claude -p echoue avec creds recopiees"
  echo "$OUT" | head -c 300 >> "$REPORT"
fi

# ---------- bilan ----------
echo
echo "===== BILAN POC-02 =====" | tee -a "$REPORT"
echo "$SUMMARY" | tee -a "$REPORT"
echo
echo "Rapport: $REPORT"
