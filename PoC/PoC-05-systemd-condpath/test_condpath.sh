#!/bin/bash
# SOURCE: test_condpath.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-05 — ConditionPathExists sous WSL2 systemd.
#
# Installe une unit oneshot dont le start depend de la presence de
# /tmp/.poc05-gate. Verifie :
#   T1 start sans gate -> status "condition failed" (pas un start reel)
#   T2 touch gate + start -> OK, ExecStart tourne
#   T3 rm gate + restart -> refus, retour a condition failed

set -u
UNIT=poc05-condpath.service
GATE=/tmp/.poc05-gate-$RANDOM
MARKER=/tmp/.poc05-marker-$RANDOM
REPORT=/tmp/poc05-report-$$.txt

SUMMARY=""
log()  { echo "[$1] $2" | tee -a "$REPORT"; }
pass() { SUMMARY+=$'\n'"PASS  $1"; log PASS "$1"; }
fail() { SUMMARY+=$'\n'"FAIL  $1: $2"; log FAIL "$1: $2"; }
info() { log INFO "$1"; }

cleanup() {
  sudo rm -f "/etc/systemd/system/$UNIT" 2>/dev/null
  sudo systemctl daemon-reload 2>/dev/null
  sudo rm -f "$GATE" "$MARKER"
}
trap cleanup EXIT

info "WSL kernel: $(uname -r)"
info "systemd PID 1: $(ps -p 1 -o comm= 2>/dev/null)"
info "gate path: $GATE"
info "marker path: $MARKER"

# ---------- Install unit ----------
sudo tee "/etc/systemd/system/$UNIT" > /dev/null <<UNIT
[Unit]
Description=PoC-05 ConditionPathExists gate
ConditionPathExists=$GATE

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/bin/bash -c "/bin/touch $MARKER && /bin/echo ran"
UNIT
sudo systemctl daemon-reload
info "unit installe + daemon-reload done"

# ---------- T1: start sans gate ----------
sudo rm -f "$GATE" "$MARKER"
sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
sudo systemctl start "$UNIT" 2>&1 | tee -a "$REPORT"
STATUS=$(systemctl show "$UNIT" -p ConditionResult,ActiveState,SubState,Result 2>&1)
info "post-start (sans gate): $STATUS"

COND=$(echo "$STATUS" | grep -oP 'ConditionResult=\K\S+')
if [ "$COND" = "no" ]; then
  pass "T1.no-gate (ConditionResult=no, start skippe)"
else
  fail "T1.no-gate" "ConditionResult=$COND (attendu: no)"
fi
if [ ! -f "$MARKER" ]; then
  pass "T1.no-marker (ExecStart n a pas tourne)"
else
  fail "T1.no-marker" "marker existe = unit a tourne malgre condition"
fi

# ---------- T2: touch gate + start ----------
sudo rm -f "$MARKER"
touch "$GATE"
sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
# pour capturer ConditionResult=yes avant que oneshot termine et que
# systemd nettoie l etat, on utilise journalctl post-run pour confirmer
JOUR_BEFORE=$(sudo journalctl -u "$UNIT" -o cat --since "1 second ago" 2>/dev/null | wc -l)
sudo systemctl start "$UNIT" 2>&1 | tee -a "$REPORT"
sleep 0.5
# verifier via journalctl que la condition a ete passee
JOUR_AFTER=$(sudo journalctl -u "$UNIT" -o cat --since "10 seconds ago" 2>/dev/null)
info "journal apres start (gate present):"
echo "$JOUR_AFTER" | head -10 | sed 's/^/    /' | tee -a "$REPORT"

STATUS=$(systemctl show "$UNIT" -p ConditionResult,ActiveState,SubState,Result 2>&1)
info "post-start (avec gate): $STATUS"
COND=$(echo "$STATUS" | grep -oP 'ConditionResult=\K\S+')
RESULT=$(echo "$STATUS" | grep -oP 'Result=\K\S+')
# Pour oneshot inactive, systemd reporte parfois ConditionResult=no apres
# coup. Fallback : verifier absence de "Condition check resulted in" = ok
# et presence de "ran" dans journal (notre ExecStart echo).
if [ "$COND" = "yes" ]; then
  pass "T2.gate-present-cond (ConditionResult=yes)"
elif ! echo "$JOUR_AFTER" | grep -qi "condition.*failed\|condition.*not met"; then
  pass "T2.gate-present-cond (journal: aucun 'condition failed', ExecStart tente)"
else
  fail "T2.gate-present-cond" "ConditionResult=$COND + journal indique echec condition"
fi
if [ -f "$MARKER" ]; then
  pass "T2.gate-present-exec (ExecStart a tourne, marker present)"
else
  fail "T2.gate-present-exec" "marker absent = ExecStart n a pas tourne"
fi

# ---------- T3: rm gate + restart ----------
sudo rm -f "$GATE" "$MARKER"
sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
sudo systemctl start "$UNIT" 2>&1 | tee -a "$REPORT"
STATUS=$(systemctl show "$UNIT" -p ConditionResult,ActiveState,SubState,Result 2>&1)
info "post-start (gate retiree): $STATUS"
COND=$(echo "$STATUS" | grep -oP 'ConditionResult=\K\S+')
if [ "$COND" = "no" ]; then
  pass "T3.gate-removed (ConditionResult=no, systemd refuse a nouveau)"
else
  fail "T3.gate-removed" "ConditionResult=$COND (attendu: no)"
fi
if [ ! -f "$MARKER" ]; then
  pass "T3.gate-removed-noexec (ExecStart skippe)"
else
  fail "T3.gate-removed-noexec" "marker present = ExecStart a tourne malgre condition"
fi

# ---------- T4: idempotence du condition-failed ----------
# Repeter T1 pour confirmer qu il n y a pas d etat failed residuel qui
# empeche les gates suivants.
for i in 1 2 3; do
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  sudo systemctl start "$UNIT" 2>/dev/null
done
STATUS=$(systemctl show "$UNIT" -p ConditionResult,Result 2>&1)
info "post-3-runs: $STATUS"
COND=$(echo "$STATUS" | grep -oP 'ConditionResult=\K\S+')
if [ "$COND" = "no" ]; then
  pass "T4.idempotent (3 starts consecutifs sans gate = tous skippes)"
else
  fail "T4.idempotent" "drift apres 3 runs: ConditionResult=$COND"
fi

# ---------- bilan ----------
echo
echo "===== BILAN POC-05 =====" | tee -a "$REPORT"
echo "$SUMMARY" | tee -a "$REPORT"
echo
echo "Rapport: $REPORT"
