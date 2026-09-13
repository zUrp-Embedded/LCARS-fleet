#!/usr/bin/env bash
# SOURCE: deploy/gate.sh
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: la porte de l'installeur — plancher shellcheck, en-têtes déclaratifs, puis le corpus bats, entier ou par couche
#
# USAGE  deploy/gate.sh [unit | integration | structure]
#        deploy/gate.sh --list-corpora     le corpus que cette porte joue, lu par mix lcars.contracts.check
#
#   unit          les fonctions d'une lib, sourcées et jouées avec des doublures
#   integration   un script ou un module joué entier sous un décor
#   structure     ce que les sources doivent porter, lu sans les jouer (murs, manifestes, composes)
#
#   Chaque témoin déclare sa couche en tête (« # bats file_tags=<couche> ») ; un témoin sans couche
#   est refusé, sinon une entrée par couche jouerait moins qu'elle n'annonce.
#   EXIT  0 tout vert · 1 refus de la porte · sinon le code de bats
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE/tests"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
COUCHES="unit integration structure"

# --list-corpora imprime la variable que la découverte utilise : le registre des corpus du runtime
# demande à chaque porte ce qu'elle joue au lieu de le croire
if [[ "${1:-}" == "--list-corpora" ]]; then
  [[ -d "$TESTS_DIR" ]] && printf '%s\n' "${TESTS_DIR#"$REPO_ROOT/"}"
  exit 0
fi
COUCHE="${1:-}"
if [[ -n "$COUCHE" && " $COUCHES " != *" $COUCHE "* ]]; then
  echo "ÉCHEC: couche inconnue « $COUCHE » — unit, integration ou structure." >&2
  exit 1
fi
if [[ $# -gt 1 ]]; then
  echo "ÉCHEC: un seul argument, la couche — reçu : $*" >&2
  exit 1
fi

echo "=== gate de l'installeur : $HERE${COUCHE:+ — couche $COUCHE} ==="

# un corpus vide est un échec, jamais un saut : zéro test joué se lirait comme zéro test rouge
mapfile -t BATS_FILES < <(find "$TESTS_DIR" -type f -name '*.bats' 2>/dev/null | sort)
if [[ "${#BATS_FILES[@]}" -eq 0 ]]; then
  echo "ÉCHEC: aucun .bats sous $TESTS_DIR — la porte de l'installeur ne mesure rien." >&2
  exit 1
fi

# la couche se lit en deuxième ligne, sous le shebang — pas dans un décor écrit en heredoc plus bas
couche_de() { sed -n '2s/^# bats file_tags=\([a-z]*\)$/\1/p' "$1"; }
SANS_SHEBANG=()
SANS_COUCHE=()
JOUES=()
for f in "${BATS_FILES[@]}"; do
  IFS= read -r first < "$f" || true
  [[ "$first" == "#!"*bats* ]] || { SANS_SHEBANG+=("${f#"$HERE/"}"); continue; }
  t="$(couche_de "$f")"
  case "$t" in
    unit|integration|structure) [[ -n "$COUCHE" && "$t" != "$COUCHE" ]] || JOUES+=("$f") ;;
    *) SANS_COUCHE+=("${f#"$HERE/"}") ;;
  esac
done
# un .bats sans shebang bats sortirait du plancher shellcheck en silence : il est refusé
if [[ "${#SANS_SHEBANG[@]}" -gt 0 ]]; then
  echo "ÉCHEC: ${#SANS_SHEBANG[@]} fichier(s) de tests sans shebang bats en première ligne :" >&2
  printf '   %s\n' "${SANS_SHEBANG[@]}" >&2
  exit 1
fi
if [[ "${#SANS_COUCHE[@]}" -gt 0 ]]; then
  echo "ÉCHEC: ${#SANS_COUCHE[@]} fichier(s) de tests sans couche déclarée (« # bats file_tags=unit|integration|structure » en deuxième ligne) :" >&2
  printf '   %s\n' "${SANS_COUCHE[@]}" >&2
  exit 1
fi
if [[ "${#JOUES[@]}" -eq 0 ]]; then
  echo "ÉCHEC: aucun fichier de tests dans la couche « $COUCHE » — cette entrée ne mesure rien." >&2
  exit 1
fi
# `grep -c` rend 1 sans occurrence, et sous pipefail ce 1 tuerait le script avant la garde « bats absent »
BATS_TEST_COUNT="$( { grep -hcE '^@test' "${JOUES[@]}" 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')"

if ! command -v bats >/dev/null 2>&1; then
  echo "ÉCHEC: bats absent — ${#JOUES[@]} fichier(s), $BATS_TEST_COUNT cas non joués." >&2
  echo "       Installer : apt install bats (cette porte est la suite de l'installeur)." >&2
  exit 1
fi

# la liste vient d'un find, pas de git : la porte se joue aussi sur un kit détaré sans .git ; les
# entrées sans extension se reconnaissent à leur shebang, et chaque .bats a le sien (vérifié ci-dessus)
mapfile -t SHELL_FILES < <(
  { find "$HERE" -type f 2>/dev/null; [[ ! -f "$HERE/../install.sh" ]] || readlink -f "$HERE/../install.sh"; } | sort | while IFS= read -r f; do
    IFS= read -r first < "$f" || true
    case "$f" in
      *.bats|*.sh|*.bash) printf '%s\n' "$f"; continue ;;
    esac
    [[ "$first" =~ ^#!.*(bash|[^a-z]sh)([[:space:]]|$) ]] && printf '%s\n' "$f"
  done
)
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ÉCHEC: shellcheck absent — ${#SHELL_FILES[@]} fichier(s) shell de l'installeur non audités." >&2
  echo "       Installer : apt install shellcheck." >&2
  exit 1
fi
set +e
SC_FLOOR="$(shellcheck -x --source-path=SCRIPTDIR -S warning -f gcc "${SHELL_FILES[@]}" 2>&1)"
SC_FLOOR_RC=$?
set -e
if [[ "$SC_FLOOR_RC" -ne 0 ]]; then
  printf '%s\n' "$SC_FLOOR" >&2
  echo "ÉCHEC: shellcheck plancher — $(printf '%s\n' "$SC_FLOOR" | grep -c ':') signalement(s) de sévérité >= warning sur $(printf '%s\n' "$SC_FLOOR" | cut -d: -f1 | sort -u | grep -c .) fichier(s)." >&2
  exit 1
fi
echo "--- shellcheck plancher (-S warning, ${#SHELL_FILES[@]} fichier(s) shell de l'installeur) : OK ---"

# les deux prédicats GO-7 sont une copie de ceux de runtime/git-hooks/pre-commit : cette porte ne
# source rien hors de deploy/, c'est ce qu'elle garantit ; installer_gate.bats tient l'accord des copies
go7_exempt() { # un `.go7-exempt` dans le dossier ou un de ses parents, jusqu'à la racine de la porte
  local d; d="$(dirname "$1")"
  while :; do
    [[ -f "$d/.go7-exempt" ]] && return 0
    [[ "$d" == "$HERE" || "$d" == "/" || "$d" == "." ]] && return 1
    d="$(dirname "$d")"
  done
}
go7_md_header() {
  local h; h="$(head -15 "$1" 2>/dev/null)"
  grep -qF '**Date**' <<<"$h" && return 0
  grep -qE '^\s+date:' <<<"$h" && return 0
  grep -qE '<!--\s*Date\s*:' <<<"$h" && return 0
  return 1
}
go7_source_header() {
  [[ -n "$(head -20 "$1" 2>/dev/null | grep -Ei 'SOURCE:|AUTHOR:|STARDATE:')" ]]
}
GO7_BAD=()
GO7_N=0
while IFS= read -r f; do
  go7_exempt "$f" && continue
  GO7_N=$((GO7_N + 1))
  case "${f##*.}" in
    md) go7_md_header "$f" || GO7_BAD+=("${f#"$HERE/"}") ;;
    sh|py) go7_source_header "$f" || GO7_BAD+=("${f#"$HERE/"}") ;;
  esac
done < <({ find "$HERE" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' \) 2>/dev/null; [[ ! -f "$HERE/../install.sh" ]] || readlink -f "$HERE/../install.sh"; } | sort)
if [[ ${#GO7_BAD[@]} -gt 0 ]]; then
  echo "ÉCHEC: GO-7 — ${#GO7_BAD[@]} fichier(s) sans en-tête déclaratif sous $HERE :" >&2
  printf '   %s\n' "${GO7_BAD[@]}" >&2
  echo "   (.md : une ligne **Date** ; .sh/.py : SOURCE:, AUTHOR: ou STARDATE: dans les 20 premières lignes)" >&2
  exit 1
fi
echo "--- GO-7 : en-têtes déclaratifs ($GO7_N fichier(s) .md/.sh/.py de l'installeur) : OK ---"

# copie assumée du bloc de runtime/test/shell_gate.sh : sans elle, l'environnement du lanceur
# (FORGE_BASE_URL exporté par provision --env, un LCARS_SEAT_UID_FILE posé à la main, PROV_FLEET_GROUP
# qui voyage par services.env) retunerait la mesure ; installer_gate.bats tient l'accord des copies
BATS_ENV=()
while read -r v; do [[ -n "$v" ]] && BATS_ENV+=(-u "$v"); done < <(
  compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' | sort
)
if [[ "${#BATS_ENV[@]}" -gt 0 ]]; then
  echo "--- ${#BATS_ENV[@]} variable(s) du lanceur neutralisée(s) : ${BATS_ENV[*]//-u/}"
fi

echo "--- bats${COUCHE:+ (couche $COUCHE)} : ${#JOUES[@]} fichier(s), $BATS_TEST_COUNT cas ---"
# un cas sauté n'est pas un cas joué : le verdict les compte, sinon un poste qui en saute soixante rend le même vert
SORTIE="$(mktemp "${TMPDIR:-/tmp}/gate-bats.XXXXXX")"
set +e
env "${BATS_ENV[@]}" bats "${JOUES[@]}" | tee "$SORTIE"
RC="${PIPESTATUS[0]}"
set -e
SAUTES="$(grep -c '# skip' "$SORTIE" || true)"
rm -f "$SORTIE"

if [[ "$RC" -ne 0 ]]; then
  echo "=== gate de l'installeur : ÉCHEC (bats exit=$RC) ===" >&2
  exit "$RC"
fi
echo "=== gate de l'installeur : OK ($BATS_TEST_COUNT cas${COUCHE:+, couche $COUCHE}, $SAUTES sauté(s)) ==="
