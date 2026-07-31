#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/render.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — rendu du JSONL des sondes (terminal ou markdown)
#
# Reads the probes' JSONL on stdin and renders it. The JSONL stays the source of truth: this file
# only presents it, so a rendering bug can never invent or hide a verdict — worst case it displays
# badly something the raw stream still holds.
#
# TWO AUDIENCES, TWO CUTS, and the difference is deliberate:
#   terminal  a glance. `cannot_conclude` shown only where a reader might OVER-read — that is, on
#             everything that is not operational. `--full` forces them all.
#   markdown  a record. ALWAYS full, because the limits are the part that ages worst: a report
#             archived without them reads, six months later, as a clean bill of health.
#
# REPEATABLE means byte-comparable: the order is the input order (probes are numbered, so it is
# deterministic), and the only volatile field is the header timestamp — one line, easy to diff past.
# Two runs of a healthy fleet differ by that line alone.

set -uo pipefail

MODE="term" FULL=0 OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --md)   MODE="md" ;;
    --full) FULL=1 ;;
    --out)  shift; OUT="${1:-}"; MODE="md" ;;
    -h|--help)
      echo "usage: render.sh [--md] [--full] [--out FICHIER.md]  < sondes.jsonl" >&2; exit 0 ;;
    *) echo "render: option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "render: jq absent — le JSONL brut est votre rapport." >&2; cat; exit 2; }

IN="$(cat)"
[[ -n "$IN" ]] || { echo "render: aucune sonde en entree (les sondes n'ont rien emis — c'est EN SOI le premier constat)" >&2; exit 2; }

# Lines that are not valid JSON are kept and shown: they are the degraded TSV fallback (jq missing
# at emit time) or a crash trace. Dropping them would hide exactly the runs worth reading.
JSON="$(printf '%s\n' "$IN" | jq -c . 2>/dev/null)"
JUNK="$(printf '%s\n' "$IN" | jq -R 'fromjson? // .' 2>/dev/null | jq -r 'select(type=="string")' 2>/dev/null)"

count() { printf '%s\n' "$JSON" | jq -r "[.[]?] | length" 2>/dev/null; }
n_of()  { printf '%s\n' "$JSON" | grep -c "\"verdict\":\"$1\"" || true; }

N_OK=$(n_of operational); N_INACT=$(n_of inactive); N_DEG=$(n_of degraded)
N_UNR=$(n_of unreachable); N_UNK=$(n_of unknown)
N_TOT=$(printf '%s\n' "$JSON" | grep -c '"probe"' || true)

# Global verdict, and it follows the exit-code doctrine rather than a friendlier arithmetic: a run
# that could not measure outranks a run that measured a problem, because its silence looks healthy.
if   [[ "$N_UNR" -gt 0 ]]; then GLOBAL="AVEUGLE"; GRC=2
elif [[ "$N_DEG" -gt 0 ]]; then GLOBAL="DEGRADE"; GRC=1
else                            GLOBAL="CONFORME"; GRC=0; fi

CTX="$(printf '%s\n' "$JSON" | jq -r 'select(.probe=="instruments.context") | .evidence' 2>/dev/null | head -1)"
BUILD="$(printf '%s\n' "$JSON" | jq -r 'select(.probe=="fleet.build" and .verdict=="operational") | .evidence' 2>/dev/null | head -1)"
# Not measured is not a build. Quoting the probe's evidence regardless of verdict printed
# "build : health rouge — sonde non lancee" in the header, which reads as a build string.
[[ -z "$BUILD" ]] && BUILD="inconnu (non mesure)"
TS="$(printf '%s\n' "$JSON" | jq -r '.ts' 2>/dev/null | sort | tail -1)"

badge() {
  case "$1" in
    operational) echo "OK   " ;; inactive) echo "OFF  " ;; degraded) echo "DRIFT" ;;
    unreachable) echo "AVEUG" ;; unknown) echo "?    " ;; *) echo "?????" ;;
  esac
}

# ── Terminal ──────────────────────────────────────────────────────────────────────────────────────
render_term() {
  local C_OK="" C_DEG="" C_UNR="" C_UNK="" C_OFF="" C_H="" C_0=""
  if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_DEG=$'\033[33m'; C_UNR=$'\033[31m'; C_UNK=$'\033[35m'
    C_OFF=$'\033[90m'; C_H=$'\033[1m'; C_0=$'\033[0m'
  fi
  local col
  printf '%s\n' "${C_H}=== ETAT DE LA FLEET — $GLOBAL ===${C_0}"
  printf '    %s\n' "$TS"
  [[ -n "$CTX"   ]] && printf '    %s\n' "$CTX"
  [[ -n "$BUILD" ]] && printf '    build : %s\n' "$BUILD"
  printf '    %s sondes : %s conformes · %s eteintes · %s drift · %s aveugles · %s ambigues\n\n' \
    "$N_TOT" "$N_OK" "$N_INACT" "$N_DEG" "$N_UNR" "$N_UNK"

  local plane last_plane="" probe verdict evidence cannot
  while IFS=$'\t' read -r plane probe verdict evidence cannot; do
    [[ -z "$probe" ]] && continue
    if [[ "$plane" != "$last_plane" ]]; then
      printf '%s\n' "${C_H}[$plane]${C_0}"
      last_plane="$plane"
    fi
    case "$verdict" in
      operational) col="$C_OK" ;; degraded) col="$C_DEG" ;; unreachable) col="$C_UNR" ;;
      unknown) col="$C_UNK" ;; *) col="$C_OFF" ;;
    esac
    printf '  %s%s%s %-34s %s\n' "$col" "$(badge "$verdict")" "$C_0" "$probe" "$evidence"
    if [[ "$FULL" -eq 1 || "$verdict" != "operational" ]]; then
      printf '        %s↳ ne prouve pas : %s%s\n' "$C_OFF" "$cannot" "$C_0"
    fi
  done < <(printf '%s\n' "$JSON" | jq -r '[.plane,.probe,.verdict,.evidence,.cannot_conclude] | @tsv')

  if [[ -n "$JUNK" ]]; then
    printf '\n%s[lignes non-JSON — sortie degradee ou crash, conservees telles quelles]%s\n' "$C_UNR" "$C_0"
    printf '  %s\n' "$JUNK"
  fi
}

# ── Markdown ──────────────────────────────────────────────────────────────────────────────────────
render_md() {
  echo "# Etat de la fleet — $GLOBAL"
  echo
  echo "**Releve** : $TS"
  [[ -n "$CTX"   ]] && echo "**Contexte** : $CTX"
  [[ -n "$BUILD" ]] && echo "**Build servi** : \`$BUILD\`"
  echo
  echo "| conformes | eteintes | drift | aveugles | ambigues | total |"
  echo "|---|---|---|---|---|---|"
  echo "| $N_OK | $N_INACT | $N_DEG | $N_UNR | $N_UNK | $N_TOT |"
  echo
  echo "\`aveugle\` n'est pas \`drift\` : une sonde qui n'a pas pu tourner ne dit RIEN de sa cible."
  echo "Chaque ligne porte ce qu'elle ne prouve pas — c'est la partie qui vieillit le plus mal."
  echo

  local plane last_plane="" probe verdict evidence cannot method vantage
  while IFS=$'\t' read -r plane probe verdict vantage method evidence cannot; do
    [[ -z "$probe" ]] && continue
    if [[ "$plane" != "$last_plane" ]]; then
      echo; echo "## $plane"; echo
      last_plane="$plane"
    fi
    echo "### \`$probe\` — **$verdict**"
    echo
    echo "- **constat** : $evidence"
    echo "- **ne prouve pas** : $cannot"
    echo "- **mesure** : \`$method\` *(depuis : $vantage)*"
    echo
  done < <(printf '%s\n' "$JSON" | jq -r '[.plane,.probe,.verdict,.vantage,.method,.evidence,.cannot_conclude] | @tsv')

  if [[ -n "$JUNK" ]]; then
    echo; echo "## lignes non-JSON"; echo
    echo "Sortie degradee (jq absent a l'emission) ou trace de crash. Conservees telles quelles :"
    echo; echo '```'; printf '%s\n' "$JUNK"; echo '```'
  fi
}

if [[ "$MODE" == "md" ]]; then
  if [[ -n "$OUT" ]]; then
    render_md > "$OUT" || { echo "render: ecriture impossible : $OUT" >&2; exit 2; }
    echo "render: rapport ecrit — $OUT" >&2
  else
    render_md
  fi
else
  render_term
fi
exit "$GRC"
