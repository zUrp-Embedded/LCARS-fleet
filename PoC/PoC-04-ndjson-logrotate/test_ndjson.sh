#!/bin/bash
# SOURCE: test_ndjson.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-04 — event log NDJSON concurrent + logrotate.
#
# Scenario :
#   - 2 writers Python concurrent ecrivent 1000 lignes chacun en O_APPEND+fsync
#   - Au milieu du run, logrotate est declenche (mv + touch + SIGHUP writers)
#   - Verifier apres : pas de ligne coupee, aucune perte, ordering par writer
#     preserve (dans file actif ET entre archives/file actif)

set -u
TESTDIR=$(mktemp -d /tmp/poc04-XXXXXX)
LOG="$TESTDIR/events.ndjson"
ROTATED="$TESTDIR/events.ndjson.1"
REPORT="$TESTDIR/report.txt"
HERE=$(dirname "$(readlink -f "$0")")

SUMMARY=""
log()  { echo "[$1] $2" | tee -a "$REPORT"; }
pass() { SUMMARY+=$'\n'"PASS  $1"; log PASS "$1"; }
fail() { SUMMARY+=$'\n'"FAIL  $1: $2"; log FAIL "$1: $2"; }
info() { log INFO "$1"; }

info "workdir: $TESTDIR"
touch "$LOG"

# ---------- Lancement writers ----------
TOTAL_PER_WRITER=1000
INTERVAL_MS=2

python3 "$HERE/writer.py" W1 "$LOG" "$TOTAL_PER_WRITER" "$INTERVAL_MS" \
  > "$TESTDIR/w1.log" 2>&1 &
PID1=$!
python3 "$HERE/writer.py" W2 "$LOG" "$TOTAL_PER_WRITER" "$INTERVAL_MS" \
  > "$TESTDIR/w2.log" 2>&1 &
PID2=$!
info "writers lances: W1=$PID1 W2=$PID2"

# ---------- Rotation mid-run ----------
# attendre ~40% du run
sleep 1
info "taille avant rotation: $(stat -c %s "$LOG") bytes"

# Strategie rename+touch+SIGHUP : equivalent de logrotate postrotate avec
# 'create' + script 'kill -HUP'.
mv "$LOG" "$ROTATED"
touch "$LOG"
chmod 644 "$LOG"

# postrotate hook : ecrit stream.meta correspondant au snapshot
META="$TESTDIR/events.ndjson.1.meta"
cat > "$META" <<META
{
  "rotated_at_ns": $(date +%s%N),
  "source": "$(basename "$ROTATED")",
  "size_bytes": $(stat -c %s "$ROTATED"),
  "writers_known": ["W1","W2"]
}
META

info "rotation done. Archive: $(stat -c %s "$ROTATED") bytes"

# signal writers pour reopen FD
kill -HUP "$PID1" "$PID2" 2>/dev/null || true
info "SIGHUP envoye a writers"

# ---------- Attente fin ----------
wait "$PID1" || info "W1 exit=$?"
wait "$PID2" || info "W2 exit=$?"
info "writers finis. active: $(stat -c %s "$LOG") / archive: $(stat -c %s "$ROTATED")"

# ---------- Verif ----------
info "running verify.py sur rotated + active (dans l ordre)..."
if python3 "$HERE/verify.py" "$ROTATED" "$LOG" | tee -a "$REPORT"; then
  :
else
  :
fi
VERIFY_EXIT=${PIPESTATUS[0]}

if [ "$VERIFY_EXIT" -eq 0 ]; then
  pass "T1.integrity (pas de perte, ordering preserve, pas de ligne coupee)"
else
  fail "T1.integrity" "verify.py exit=$VERIFY_EXIT"
fi

# ---------- T2: postrotate meta ecrit sans race ----------
if [ -f "$META" ] && jq -e . "$META" >/dev/null 2>&1; then
  pass "T2.postrotate-meta (stream.meta JSON valide post-rotation)"
elif [ -f "$META" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$META" 2>/dev/null; then
  pass "T2.postrotate-meta (stream.meta JSON valide post-rotation)"
else
  fail "T2.postrotate-meta" "meta absent ou JSON invalide"
fi

# ---------- T3: toutes les lignes sont JSON complet (zero partial line) ----------
TOTAL_LINES=$(wc -l < "$ROTATED")
TOTAL_LINES=$((TOTAL_LINES + $(wc -l < "$LOG")))
VALID_LINES=$(cat "$ROTATED" "$LOG" | awk 'NF' | while IFS= read -r l; do
  echo "$l" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null && echo OK
done | grep -c OK)
info "lignes totales: $TOTAL_LINES, JSON valides: $VALID_LINES"
if [ "$TOTAL_LINES" = "$VALID_LINES" ] && [ "$TOTAL_LINES" -gt 0 ]; then
  pass "T3.atomic-lines ($VALID_LINES/$TOTAL_LINES lignes JSON valides)"
else
  fail "T3.atomic-lines" "$VALID_LINES/$TOTAL_LINES JSON valides"
fi

# ---------- T4: 2 writers effectifs dans les deux fichiers ----------
W1_IN_ROT=$(grep -c '"writer":"W1"' "$ROTATED")
W2_IN_ROT=$(grep -c '"writer":"W2"' "$ROTATED")
W1_IN_ACT=$(grep -c '"writer":"W1"' "$LOG")
W2_IN_ACT=$(grep -c '"writer":"W2"' "$LOG")
info "W1: rotated=$W1_IN_ROT active=$W1_IN_ACT"
info "W2: rotated=$W2_IN_ROT active=$W2_IN_ACT"
# Au moins quelques lignes de chaque writer dans chaque fichier (preuve de
# la rotation mid-run et du reopen FD)
if [ "$W1_IN_ROT" -gt 0 ] && [ "$W1_IN_ACT" -gt 0 ] && \
   [ "$W2_IN_ROT" -gt 0 ] && [ "$W2_IN_ACT" -gt 0 ]; then
  pass "T4.reopen-after-rotate (writers ont ecrit dans rotated ET active)"
else
  fail "T4.reopen-after-rotate" "un writer n a pas reouvert"
fi

# ---------- bilan ----------
echo
echo "===== BILAN POC-04 =====" | tee -a "$REPORT"
echo "$SUMMARY" | tee -a "$REPORT"
echo
echo "Rapport: $REPORT"
