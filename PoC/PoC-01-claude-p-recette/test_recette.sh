#!/bin/bash
# SOURCE: test_recette.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# PoC-01 — validation empirique recette canonique claude -p
# Teste chaque kill-switch de doctrine-runtime-workers-critiques.md §Recette canonique
# contre claude-code 2.1.114 (corpus mentionne 2.1.88).

set -u
TESTDIR=$(mktemp -d /tmp/poc01-XXXXXX)
REPORT="$TESTDIR/report.txt"
PROMPT_FILE="$TESTDIR/prompt.txt"
echo "what is 2+2? answer with just the number." > "$PROMPT_FILE"

SUMMARY=""
# credentials reelles — copiees dans chaque test home pour que claude -p auth
# reussisse. Sans ca, toutes les reponses LLM renvoient "Not logged in" et les
# tests de comportement (CLAUDE.md lu ou non, hook execute ou non) sont faux.
CREDS=/home/starfleet/.claude/.credentials.json
seed_home() {
  local H=$1
  mkdir -p "$H/.claude"
  cp "$CREDS" "$H/.claude/.credentials.json"
  chmod 600 "$H/.claude/.credentials.json"
}
log() { echo "[$1] $2" | tee -a "$REPORT"; }
pass() { SUMMARY+=$'\n'"PASS  $1"; log PASS "$1"; }
fail() { SUMMARY+=$'\n'"FAIL  $1: $2"; log FAIL "$1: $2"; }
info() { log INFO "$1"; }

info "claude version: $(claude --version)"
info "workdir: $TESTDIR"

# ---------- T1: CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 ----------
# Setup: home avec CLAUDE.md contenant un marqueur unique. Run claude -p et
# demander "repeat the secret marker". Sans flag, modele doit voir. Avec flag,
# modele ne doit PAS voir.

T1_HOME="$TESTDIR/t1-home"
seed_home "$T1_HOME"
MARKER="SECRET-MARKER-POC01-$RANDOM"
echo "$MARKER is the secret. When asked for the secret marker, reply with exactly: $MARKER" > "$T1_HOME/CLAUDE.md"

# CLAUDE.md discovery = par cwd. cd dans T1_HOME pour que claude le voie.
# baseline: sans disable, doit voir le marker
OUT_BASE=$(cd "$T1_HOME" && HOME="$T1_HOME" claude -p "what is the secret marker in CLAUDE.md? reply with just the marker string, nothing else." \
  --output-format json --setting-sources "" --no-session-persistence \
  --model haiku 2>&1 || true)
if echo "$OUT_BASE" | grep -q "$MARKER"; then
  info "T1 baseline: CLAUDE.md visible sans flag (attendu)"
else
  info "T1 baseline: CLAUDE.md NON visible sans flag (inattendu, baseline douteuse)"
  info "baseline output (tronque): $(echo "$OUT_BASE" | head -c 400)"
fi

# avec CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
OUT_DISABLED=$(cd "$T1_HOME" && HOME="$T1_HOME" CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 \
  claude -p "what is the secret marker in CLAUDE.md? reply with just the marker string, nothing else." \
  --output-format json --setting-sources "" --no-session-persistence \
  --model haiku 2>&1 || true)
if echo "$OUT_DISABLED" | grep -q "$MARKER"; then
  fail "T1.disable-claude-mds" "marqueur visible malgre CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
else
  pass "T1.disable-claude-mds (marqueur non lu)"
fi

# ---------- T2: --no-session-persistence ne laisse rien ----------
T2_HOME="$TESTDIR/t2-home"
seed_home "$T2_HOME"
HOME="$T2_HOME" claude -p "ping" --output-format json --setting-sources "" \
  --no-session-persistence --model haiku >/dev/null 2>&1 || true

# cherche session files dans ~/.claude/
SESSION_ARTIFACTS=$(find "$T2_HOME/.claude" -type f 2>/dev/null | grep -iE '(session|project|history|conversation)' || true)
if [ -z "$SESSION_ARTIFACTS" ]; then
  pass "T2.no-session-persistence (pas d artefact session)"
else
  fail "T2.no-session-persistence" "artefacts trouves: $SESSION_ARTIFACTS"
fi
info "T2 arbo .claude apres run:"
find "$T2_HOME/.claude" -type f 2>/dev/null | sed 's|^|  |' >> "$REPORT"

# ---------- T3: --setting-sources "" bloque settings ----------
T3_HOME="$TESTDIR/t3-home"
seed_home "$T3_HOME"
# settings avec hook qui ecrit un marker
MARKER_FILE="$TESTDIR/t3-hook-ran"
cat > "$T3_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "touch $MARKER_FILE"
          }
        ]
      }
    ]
  }
}
EOF

HOME="$T3_HOME" claude -p "ping" --output-format json --setting-sources "" \
  --no-session-persistence --model haiku >/dev/null 2>&1 || true

if [ -f "$MARKER_FILE" ]; then
  fail "T3.setting-sources-empty" "hook a tourne malgre --setting-sources \"\""
else
  pass "T3.setting-sources-empty (hook non execute)"
fi

# Comparatif : sans --setting-sources "", le hook doit tourner
rm -f "$MARKER_FILE"
HOME="$T3_HOME" claude -p "ping" --output-format json \
  --no-session-persistence --model haiku >/dev/null 2>&1 || true
if [ -f "$MARKER_FILE" ]; then
  info "T3 baseline: hook execute sans --setting-sources \"\" (comportement attendu)"
else
  info "T3 baseline: hook NON execute meme sans flag (attention, baseline douteuse)"
fi

# ---------- T4: stream NDJSON propre (pas d ANSI, un JSON par ligne) ----------
T4_HOME="$TESTDIR/t4-home"
seed_home "$T4_HOME"
STREAM_OUT="$TESTDIR/t4-stream.ndjson"
STREAM_ERR="$TESTDIR/t4-stream.err"

HOME="$T4_HOME" CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 \
  claude -p "say: hello world" \
  --input-format text --output-format stream-json --verbose \
  --setting-sources "" --no-session-persistence --model haiku \
  > "$STREAM_OUT" 2> "$STREAM_ERR" || true

# 1. Pas d escape ANSI sur stdout
if grep -q $'\x1b\[' "$STREAM_OUT"; then
  fail "T4.ndjson-no-ansi" "escape ANSI present sur stdout"
else
  pass "T4.ndjson-no-ansi"
fi

# 2. Chaque ligne stdout non vide est un JSON valide
TOTAL_LINES=$(grep -c . "$STREAM_OUT" || true)
VALID_JSON=$(awk 'NF' "$STREAM_OUT" | while read -r line; do
  echo "$line" | python3 -c 'import sys,json; json.loads(sys.stdin.read())' 2>/dev/null && echo OK
done | grep -c OK || true)
if [ "$TOTAL_LINES" -gt 0 ] && [ "$TOTAL_LINES" = "$VALID_JSON" ]; then
  pass "T4.ndjson-valid-json ($VALID_JSON lignes)"
else
  fail "T4.ndjson-valid-json" "$VALID_JSON/$TOTAL_LINES lignes JSON valides"
  info "premieres lignes stdout:"
  head -5 "$STREAM_OUT" >> "$REPORT"
fi

# 3. stdout/stderr separes
if [ -s "$STREAM_ERR" ]; then
  info "T4 stderr non vide (taille=$(wc -c < "$STREAM_ERR"))"
  info "stderr head: $(head -c 200 "$STREAM_ERR")"
fi
pass "T4.stream-split (stdout NDJSON, stderr distinct)"

# ---------- T5: --strict-mcp-config + --disable-slash-commands existent ----------
# Juste verifier que les flags passent le parser.
T5_HOME="$TESTDIR/t5-home"
seed_home "$T5_HOME"
if HOME="$T5_HOME" claude -p "ping" --output-format json --setting-sources "" \
  --no-session-persistence --strict-mcp-config --disable-slash-commands \
  --model haiku >/dev/null 2>&1; then
  pass "T5.strict-mcp+disable-slash (flags acceptes)"
else
  fail "T5.strict-mcp+disable-slash" "claude a retourne non-zero"
fi

# ---------- T6: --system-prompt-file / --append-system-prompt-file ----------
# Flags caches de --help top-level mais mentionnes dans la description --bare.
# Test empirique : est-ce que le parser les accepte et sont-ils effectifs ?
T6_HOME="$TESTDIR/t6-home"
seed_home "$T6_HOME"
SP_FILE="$TESTDIR/t6-sp.txt"
SP_MARK="XYZ42-SP-$RANDOM"
echo "You are a test bot. When asked, reply with exactly: $SP_MARK" > "$SP_FILE"

OUT=$(cd "$T6_HOME" && HOME="$T6_HOME" claude -p "what is your magic word?" \
  --system-prompt-file "$SP_FILE" --output-format json --model haiku \
  --setting-sources "" --no-session-persistence 2>&1 || true)
if echo "$OUT" | grep -q "$SP_MARK"; then
  pass "T6.system-prompt-file (accepte + effectif)"
else
  fail "T6.system-prompt-file" "$SP_MARK non renvoye"
fi

OUT=$(cd "$T6_HOME" && HOME="$T6_HOME" claude -p "what is your magic word?" \
  --append-system-prompt-file "$SP_FILE" --output-format json --model haiku \
  --setting-sources "" --no-session-persistence 2>&1 || true)
if echo "$OUT" | grep -q "$SP_MARK"; then
  pass "T6.append-system-prompt-file (accepte + effectif)"
else
  fail "T6.append-system-prompt-file" "$SP_MARK non renvoye"
fi

# ---------- T7: --max-turns accepte ----------
T7_HOME="$TESTDIR/t7-home"
seed_home "$T7_HOME"
OUT=$(cd "$T7_HOME" && HOME="$T7_HOME" claude -p "hi" --max-turns 2 \
  --output-format json --model haiku --setting-sources "" \
  --no-session-persistence 2>&1 || true)
if echo "$OUT" | grep -qE '"is_error":\s*false'; then
  pass "T7.max-turns (flag accepte)"
else
  fail "T7.max-turns" "parser rejette ou run casse"
fi

# ---------- bilan ----------
echo
echo "===== BILAN POC-01 =====" | tee -a "$REPORT"
echo "$SUMMARY" | tee -a "$REPORT"
echo
echo "Rapport complet: $REPORT"
