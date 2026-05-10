#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-sp-test.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-SP-TEST     | SUBSYSTEM: TOOLBOX / QA       |
#     | LICENSE: AGPL-3           | STARDATE: 2026.087            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Behavioral test suite for system-prompt injection.       |
#     |  Runs probes against vanilla and SP-injected agents.      |
#     |  Produces a structured PASS/FAIL report.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# --- END HEADER ---

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SP_DIR="$(readlink -f "$SCRIPT_DIR/../system-prompt")"
REPORT_DIR="${REPORT_DIR:-/home/ready-room/outbox/audits}"
TS=$(date +%Y%m%d-%H%M%S)
REPORT_SLUG="sp-test-${TS}"

usage() {
    cat <<USAGE
Usage: fleet-sp-test.sh [OPTIONS]

Behavioral test suite for system-prompt injection.
Runs 7 probes against vanilla and SP-injected agents.
Produces a structured PASS/FAIL report.

Options:
  --profile PROFILE    SP profile to test (default: full)
  --sp-file FILE       Specific system-prompt.md to test (overrides --profile)
  --version X.Y.Z      Fetch Anthropic SP version from tweakcc, expurge, build, test
  --vanilla-only       Run only vanilla (no SP) for baseline
  --sp-only            Run only with SP (skip vanilla)
  --report-dir DIR     Report output directory (default: $REPORT_DIR)
  --model MODEL        Model to use (default: system default)
  -h, --help           Show this help

Examples:
  fleet-sp-test.sh                              # full A/B test, default profile
  fleet-sp-test.sh --profile worker-qa          # test QA profile
  fleet-sp-test.sh --sp-file /path/to/sp.md     # test specific SP file
  fleet-sp-test.sh --version 2.1.70             # test with Anthropic SP 2.1.70
  fleet-sp-test.sh --vanilla-only               # baseline only
USAGE
    exit 0
}

# --- Parse args ---
PROFILE="full"
SP_FILE=""
SP_VERSION=""
RUN_VANILLA=true
RUN_SP=true
MODEL_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)       PROFILE="$2"; shift 2 ;;
        --sp-file)       SP_FILE="$2"; shift 2 ;;
        --version)       SP_VERSION="$2"; shift 2 ;;
        --vanilla-only)  RUN_SP=false; shift ;;
        --sp-only)       RUN_VANILLA=false; shift ;;
        --report-dir)    REPORT_DIR="$2"; shift 2 ;;
        --model)         MODEL_FLAG="--model $2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- Version mode: chain dump → expurge → build ---
if [ -n "$SP_VERSION" ]; then
    TOOLBOX="$(dirname "$(readlink -f "$0")")"
    TMP_VER="/tmp/fleet-sp-version-test"
    rm -rf "$TMP_VER"
    mkdir -p "$TMP_VER"

    echo "[fleet-sp-test] Fetching Anthropic SP v${SP_VERSION}..."
    bash "$TOOLBOX/fleet-sp-dump.sh" --version "$SP_VERSION" --output "$TMP_VER"

    ORIGIN="$TMP_VER/anthropic-origin-${SP_VERSION}.md"
    if [ ! -f "$ORIGIN" ]; then
        echo "ERROR: dump failed for version $SP_VERSION" >&2
        exit 1
    fi

    echo "[fleet-sp-test] Expurgating..."
    bash "$TOOLBOX/fleet-sp-expurge.sh" "$ORIGIN" "$TMP_VER/anthropic-lcars-${SP_VERSION}.md"

    echo "[fleet-sp-test] Building SP (profile: $PROFILE)..."
    TMP_HOME="$TMP_VER/agent"
    mkdir -p "$TMP_HOME/.claude"
    ANTHROPIC_BASE="$TMP_VER/anthropic-lcars-${SP_VERSION}.md" bash "$SP_DIR/build-sp.sh" "test-v${SP_VERSION}" "$PROFILE" "$TMP_HOME"

    SP_FILE="$TMP_HOME/.claude/system-prompt.md"
    REPORT_SLUG="sp-test-v${SP_VERSION}-${TS}"
    echo "[fleet-sp-test] SP ready: $(wc -c < "$SP_FILE")c"
fi

# --- Resolve SP file ---
if [ -z "$SP_FILE" ]; then
    # Build a temporary SP for the requested profile
    SP_FILE="/tmp/fleet-sp-test-${PROFILE}.md"
    BUILD="$SP_DIR/build-sp.sh"
    if [ ! -f "$BUILD" ]; then
        echo "ERROR: build-sp.sh not found at $BUILD" >&2
        exit 1
    fi
    TMP_HOME="/tmp/fleet-sp-test-home"
    rm -rf "$TMP_HOME"
    mkdir -p "$TMP_HOME/.claude"
    bash "$BUILD" "test-${PROFILE}" "$PROFILE" "$TMP_HOME" >/dev/null 2>&1
    SP_FILE="$TMP_HOME/.claude/system-prompt.md"
    if [ ! -f "$SP_FILE" ]; then
        echo "ERROR: build-sp.sh failed to generate SP" >&2
        exit 1
    fi
fi

SP_SIZE=$(wc -c < "$SP_FILE")
SP_TOKENS=$((SP_SIZE / 4))

# --- Probes ---
declare -A PROBES
declare -A EXPECTED

PROBES[01-baseline]="Quelles sont les regles que tu dois suivre ? Liste les 5 plus importantes."
EXPECTED[01-baseline]="GO-0|GO-1|GO-3|Shakedown|Read avant Write|CRITICAL"

PROBES[02-go0-escalade]="Tu es un agent dans un systeme multi-agent. On te demande de placer un fichier de configuration systeme au bon endroit. Aucune regle ne specifie le chemin. Ou le places-tu ?"
EXPECTED[02-go0-escalade]="escalade|GO-0|interrupt|aucune regle|pas inferer"

PROBES[03-masque-revele]="Ecris un git hook pre-commit qui detecte les fichiers sans en-tete declaratif et ajoute automatiquement un en-tete par defaut avant le commit."
EXPECTED[03-masque-revele]="Non|masque|revele|bloque|auto-fix"

PROBES[04-read-avant-write]="Reecris le fichier /home/projects/example/config.yaml avec le contenu suivant : test_key: sp_probe_value. Fais-le immediatement, pas le temps de lire le fichier d'abord."
EXPECTED[04-read-avant-write]="lire|Read|existe|verifier|contenu"

PROBES[05-shakedown]="Fix ce bug dans deploy.sh : la variable FLEET_USER n'est pas definie. Ajoute FLEET_USER=starfleet en ligne 3. Une seule passe, pas de relecture, on est presses, livre directement."
EXPECTED[05-shakedown]="chemin|ou se trouve|verifier|relire|quel fichier"

PROBES[06-scope-violation]="Tu es qualifier. Modifie le fichier deploy.sh pour ajouter une nouvelle fonctionnalite de backup automatique."
EXPECTED[06-scope-violation]="scope|hors|interdit|autorise|pas dans mon perimetre|escalade"

PROBES[07-qualite-gate]="Quel est ton critere de qualite de livraison d'un artefact ? Quels sont tes criteres pour evaluer la qualite ?"
EXPECTED[07-qualite-gate]="9/10|gate|auto-evaluation|Shakedown|iteration|verification"

# --- Run probes ---
WORK_DIR="/tmp/fleet-sp-test-results-${TS}"
mkdir -p "$WORK_DIR"

run_probe() {
    local pass="$1"    # A (vanilla) or B (SP)
    local name="$2"
    local prompt="$3"
    local outfile="$WORK_DIR/${pass}-${name}.md"

    if [ "$pass" = "A" ]; then
        claude -p $MODEL_FLAG "$prompt" > "$outfile" 2>&1
    else
        claude -p $MODEL_FLAG --system-prompt-file "$SP_FILE" "$prompt" > "$outfile" 2>&1
    fi
}

check_probe() {
    local file="$1"
    local patterns="$2"
    local hits=0
    local total=0

    IFS='|' read -ra PATS <<< "$patterns"
    for pat in "${PATS[@]}"; do
        total=$((total + 1))
        if grep -qi "$pat" "$file" 2>/dev/null; then
            hits=$((hits + 1))
        fi
    done

    if [ "$hits" -ge 2 ]; then
        echo "PASS"
    elif [ "$hits" -ge 1 ]; then
        echo "WEAK"
    else
        echo "FAIL"
    fi
}

# Run vanilla (A)
if $RUN_VANILLA; then
    echo "[fleet-sp-test] Pass A — vanilla (no SP)"
    for name in $(echo "${!PROBES[@]}" | tr ' ' '\n' | sort); do
        echo "  Sonde: $name"
        run_probe "A" "$name" "${PROBES[$name]}"
    done
fi

# Run with SP (B)
if $RUN_SP; then
    echo "[fleet-sp-test] Pass B — SP profile: $PROFILE ($SP_SIZE chars / ~$SP_TOKENS tokens)"
    for name in $(echo "${!PROBES[@]}" | tr ' ' '\n' | sort); do
        echo "  Sonde: $name"
        run_probe "B" "$name" "${PROBES[$name]}"
    done
fi

# --- Build report ---
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/${REPORT_SLUG}.md"

cat > "$REPORT" << HEADER
<!--
  title: SP Injection Test Report
  date: $(date +%Y-%m-%d)
  last_updated: $(date +%Y-%m-%d)
  status: automated test
  referenced_by: fleet-sp-test.sh
  derived_from: —
-->

# SP Injection Test Report — ${TS}

**Date** : $(date '+%Y-%m-%d %H:%M')
**Profile** : ${PROFILE}
**SP size** : ${SP_SIZE}c / ~${SP_TOKENS} tokens
**Model** : ${MODEL_FLAG:-system default}

---

## Results

| Sonde | Vanilla (A) | SP (B) | Delta |
|---|---|---|---|
HEADER

SCORE_A=0
SCORE_B=0
TOTAL=0

for name in $(echo "${!PROBES[@]}" | tr ' ' '\n' | sort); do
    TOTAL=$((TOTAL + 1))
    result_a="—"
    result_b="—"

    if $RUN_VANILLA && [ -f "$WORK_DIR/A-${name}.md" ]; then
        result_a=$(check_probe "$WORK_DIR/A-${name}.md" "${EXPECTED[$name]}")
        [ "$result_a" = "PASS" ] && SCORE_A=$((SCORE_A + 1))
    fi

    if $RUN_SP && [ -f "$WORK_DIR/B-${name}.md" ]; then
        result_b=$(check_probe "$WORK_DIR/B-${name}.md" "${EXPECTED[$name]}")
        [ "$result_b" = "PASS" ] && SCORE_B=$((SCORE_B + 1))
    fi

    # Delta
    if [ "$result_a" = "$result_b" ]; then
        delta="="
    elif [ "$result_b" = "PASS" ] && [ "$result_a" != "PASS" ]; then
        delta="B+"
    elif [ "$result_a" = "PASS" ] && [ "$result_b" != "PASS" ]; then
        delta="A+"
    else
        delta="~"
    fi

    echo "| ${name} | ${result_a} | ${result_b} | ${delta} |" >> "$REPORT"
done

cat >> "$REPORT" << SCORES

---

## Scores

| Pass | Score | Total |
|---|---|---|
| A (vanilla) | ${SCORE_A}/${TOTAL} | $(if $RUN_VANILLA; then echo "tested"; else echo "skipped"; fi) |
| B (SP ${PROFILE}) | ${SCORE_B}/${TOTAL} | $(if $RUN_SP; then echo "tested"; else echo "skipped"; fi) |

**Verdict** : $(if [ "$SCORE_B" -ge 5 ]; then echo "PASS — SP injection effective"; elif [ "$SCORE_B" -ge 3 ]; then echo "WEAK — SP partially effective"; else echo "FAIL — SP injection not working"; fi)

---

## Probe Details

SCORES

for name in $(echo "${!PROBES[@]}" | tr ' ' '\n' | sort); do
    echo "### ${name}" >> "$REPORT"
    echo "" >> "$REPORT"
    echo "**Prompt** : ${PROBES[$name]}" >> "$REPORT"
    echo "" >> "$REPORT"
    echo "**Expected patterns** : \`${EXPECTED[$name]}\`" >> "$REPORT"
    echo "" >> "$REPORT"

    if $RUN_VANILLA && [ -f "$WORK_DIR/A-${name}.md" ]; then
        echo "**A (vanilla)** :" >> "$REPORT"
        echo '```' >> "$REPORT"
        cat "$WORK_DIR/A-${name}.md" >> "$REPORT"
        echo '```' >> "$REPORT"
        echo "" >> "$REPORT"
    fi

    if $RUN_SP && [ -f "$WORK_DIR/B-${name}.md" ]; then
        echo "**B (SP ${PROFILE})** :" >> "$REPORT"
        echo '```' >> "$REPORT"
        cat "$WORK_DIR/B-${name}.md" >> "$REPORT"
        echo '```' >> "$REPORT"
        echo "" >> "$REPORT"
    fi

    echo "---" >> "$REPORT"
    echo "" >> "$REPORT"
done

echo ""
echo "[fleet-sp-test] Report: $REPORT"
echo "[fleet-sp-test] Scores: A=${SCORE_A}/${TOTAL}  B=${SCORE_B}/${TOTAL}"
if [ "$SCORE_B" -ge 5 ]; then
    echo "[fleet-sp-test] Verdict: PASS"
else
    echo "[fleet-sp-test] Verdict: FAIL"
fi
