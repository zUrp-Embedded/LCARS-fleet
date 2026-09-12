#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/accept.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de deploy/accept — la mesure des runners (fait contre non-mesure) et le démarrage de la fleet sous l'humain
#
# Le décor reproduit l'arbre (accept dérive le nom de l'humain de ../runtime/services/forge-gestures.sh
# et les labels des workflows du modèle de projet sous ../runtime) et possède le PATH en entier : sur un poste provisionné,
# /usr/local/bin/fleet existe, et l'hériter mesurerait la machine. runuser ne change pas d'identité,
# il exécute ce qu'on lui demande.

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  SRC="$BATS_TEST_DIRNAME/../accept"; [ -f "$SRC" ]
  SANDBOX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$SANDBOX/deploy" "$SANDBOX/runtime/services"
  MOD="$SANDBOX/deploy/accept"
  sed "/^printf '\\\\n  %sACCEPTATION/,\$d" "$SRC" > "$MOD"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${LCARS_BUILTIN_HUMAN:-lcars}"' > "$SANDBOX/runtime/services/forge-gestures.sh"
  chmod 0755 "$SANDBOX/runtime/services/forge-gestures.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  HOME_DIR="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME_DIR"
  printf '%s\n' '#!/usr/bin/env bash' \
    "[[ \"\$1\" == passwd ]] && printf '%s:x:1001:1001::%s:/bin/bash\\n' \"\$2\" '$HOME_DIR'" \
    'exit 0' > "$BINDIR/getent"
  printf '%s\n' '#!/usr/bin/env bash' 'shift 2; [[ "$1" == "--" ]] && shift; exec "$@"' > "$BINDIR/runuser"
  chmod 0755 "$BINDIR"/*
  printf 'export PATH="%s:/usr/bin:/bin"\n' "$BINDIR" > "$HOME_DIR/.bash_profile"
}

# la doublure de fleet écrit encore après « BEAM vivant » : c'est la fenêtre où un grep -q sous pipefail tuait le producteur
fleet_stub() { # fleet_stub <vivant|mort|start-casse>
  local etat="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "ETAT='$etat'"
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status)'
    printf '%s\n' '    printf "fleet: build deadbeef (source=release)\n"'
    printf '%s\n' '    [[ -f "$MARQUEUR" || "$ETAT" == vivant ]] && printf "fleet: BEAM vivant. Logs : tmux -S …\n"'
    printf '%s\n' '    sleep 0.3'
    printf '%s\n' '    printf "fleet: visibilite debug : off\n"'
    printf '%s\n' '    printf "(aucun pod vivant)\n"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  start) [[ "$ETAT" == start-casse ]] && exit 1; : > "$MARQUEUR"; [[ -z "${LCARS_START_WITHOUT_CLAUDE:-}" ]] || : > "$MARQUEUR.sans-claude" ;;'
    printf '%s\n' '  stop)  rm -f "$MARQUEUR" ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$BINDIR/fleet"
  chmod 0755 "$BINDIR/fleet"
  export MARQUEUR="$BATS_TEST_TMPDIR/beam.vivant"
  rm -f "$MARQUEUR"
}

joue() { run env PATH="$BINDIR:$PATH" HOME="$HOME_DIR" \
  bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; check_fleet_start; printf 'COMPTEURS F=%s S=%s H=%s\n' \"\$FAILED\" \"\$SKIPPED\" \"\$HELD\""; }

curl_stub() { # curl_stub — lit CURL_CODE, CURL_CORPS, CURL_RC de l'environnement
  printf '%s\n' '#!/usr/bin/env bash' \
    'cat >/dev/null 2>&1 || true' \
    'printf "%s" "${CURL_CORPS:-}"' \
    'for a in "$@"; do case "$a" in *%{http_code}*) printf "\n%s" "${CURL_CODE:-000}";; esac; done' \
    'exit "${CURL_RC:-0}"' > "$BINDIR/curl"
  chmod 0755 "$BINDIR/curl"
}

modele_de_projet() { # le modèle de projet livré, tel que la release le porte : un workflow qui demande « shell »
  local wf="$SANDBOX/runtime/rel/lcars_fleet/lib/lcars_fleet-0.0.0/priv/catalogue/project_template/main/.gitea/workflows"
  mkdir -p "$wf"
  printf 'jobs:\n  test:\n    runs-on: shell\n' > "$wf/ci.yml"
}

joue_ci() { # joue_ci <code http> <corps> [rc de curl] — --forge-url par la porte du script, une variable serait écrasée
  curl_stub
  local priv="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$priv"
  printf 'jeton-de-decor\n' > "$priv/forge-master.token"
  [[ -n "${SANS_MODELE:-}" ]] || modele_de_projet
  run env PATH="$BINDIR:/usr/bin:/bin" \
    LCARS_PRIVATE_DIR="$priv" \
    CURL_CODE="$1" CURL_CORPS="$2" CURL_RC="${3:-0}" \
    bash -c "set -euo pipefail; source '$MOD' --forge-url http://forge.decor >/dev/null 2>&1; check_ci; printf 'COMPTEURS F=%s S=%s H=%s\n' \"\$FAILED\" \"\$SKIPPED\" \"\$HELD\""
}

@test "check_ci : une forge injoignable est sautée, jamais comptée comme zéro runner" {
  joue_ci 000 "" 7
  [[ "$output" == *"COMPTEURS F=0 S=1 H=0"* ]]
  refute_out "aucun runner" <<<"$output"
}

@test "check_ci : un jeton hors portée site-admin est sauté, et le refus nomme le code HTTP" {
  joue_ci 403 '{"message":"token does not have at least one of required scope(s)"}'
  [[ "$output" == *"COMPTEURS F=0 S=1 H=0"* ]]
  [[ "$output" == *"(HTTP 403)"* ]]
}

@test "check_ci : une réponse qui n'est pas du JSON est sautée" {
  joue_ci 404 '<html><body>404 Not Found</body></html>'
  [[ "$output" == *"COMPTEURS F=0 S=1 H=0"* ]]
}

@test "check_ci : un 200 sans total_count est sauté — forme inattendue" {
  joue_ci 200 '{"ok":true}'
  [[ "$output" == *"COMPTEURS F=0 S=1 H=0"* ]]
  [[ "$output" == *"sans « total_count »"* ]]
}

@test "check_ci : zéro runner mesuré reste un échec" {
  joue_ci 200 '{"total_count":0,"runners":[]}'
  [[ "$output" == *"COMPTEURS F=1 S=0 H=0"* ]]
  [[ "$output" == *"NON   CI : aucun runner enregistré"* ]]
}

@test "check_ci : des runners qui servent le label demandé par le modèle de projet tiennent la capacité" {
  joue_ci 200 '{"total_count":1,"runners":[{"name":"r1","labels":[{"name":"shell"}]}]}'
  [[ "$output" == *"COMPTEURS F=0 S=0 H=1"* ]]
  [[ "$output" == *"OUI   CI : 1 runner(s) servant les labels que les workflows d'un projet demandent (shell)"* ]]
}

@test "check_ci : un runner qui ne sert pas le label demandé est un échec qui le nomme" {
  joue_ci 200 '{"total_count":1,"runners":[{"name":"r1","labels":[{"name":"autre"}]}]}'
  [[ "$output" == *"COMPTEURS F=1 S=0 H=0"* ]]
  [[ "$output" == *"aucun ne sert : shell"* ]]
}

@test "check_ci : sans modèle de projet sous ../runtime, le contrôle des labels est un échec nommé, jamais un vert vide" {
  SANS_MODELE=1 joue_ci 200 '{"total_count":1,"runners":[{"name":"r1","labels":[{"name":"shell"}]}]}'
  [[ "$output" == *"COMPTEURS F=1 S=0 H=0"* ]]
  [[ "$output" == *"aucun « runs-on » lu dans les workflows du modèle de projet"* ]]
}

@test "fleet déjà vivante : le sondage la voit, rien n'est démarré, et « elle démarre » n'est pas établi" {
  fleet_stub vivant
  joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"---   fleet : déjà démarrée"*"n'est pas établi"* ]]
  [[ "$output" == *"COMPTEURS F=0 S=1 H=0"* ]]
}

@test "instrument : la doublure de fleet écrit encore après « BEAM vivant » — un grep -q sous pipefail tuerait le producteur" {
  fleet_stub vivant
  run env PATH="$BINDIR:$PATH" python3 -c \
    'import signal, os, sys; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash -uo pipefail -c \
    'fleet status 2>/dev/null | grep -q "BEAM vivant"; echo "rc=$? PIPESTATUS=${PIPESTATUS[*]}"'
  [[ "$output" == *"PIPESTATUS=141 0"* ]]
}

@test "fleet absente : elle est démarrée, vue vivante, puis arrêtée" {
  fleet_stub mort
  joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"OUI   fleet : démarre et vivante sous « lcars » (arrêtée après mesure)"* ]]
  [ ! -e "$MARQUEUR" ]
}

@test "sur un banc, la fleet démarre sans credentials claude et reste debout" {
  fleet_stub mort
  LCARS_BENCH=1 joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"OUI"*"laissée debout"* ]]
  [ -e "$MARQUEUR" ]
  [ -e "$MARQUEUR.sans-claude" ]
}

@test "start en échec : refus qui renvoie vers la plainte du lanceur" {
  fleet_stub start-casse
  joue
  [[ "$output" == *"NON   fleet : « fleet start » a échoué sous « lcars »"* ]]
  [[ "$output" == *"COMPTEURS F=1 S=0 H=0"* ]]
}

@test "fleet absent du PATH de l'humain : refus qui nomme le compte" {
  fleet_stub vivant
  rm -f "$BINDIR/fleet"
  joue
  [[ "$output" == *"NON   fleet : « fleet » n'est pas dans le PATH de « lcars »"* ]]
}

@test "le login vient du geste de forge, jamais d'un littéral" {
  fleet_stub vivant
  LCARS_BUILTIN_HUMAN=bob joue
  [[ "$output" == *"« bob »"* ]]
  [[ "$output" != *"« lcars »"* ]]
}

@test "geste de forge muet : sauté en le disant, aucun nom inventé" {
  fleet_stub vivant
  rm -f "$SANDBOX/runtime/services/forge-gestures.sh"
  joue
  [[ "$output" == *"---   fleet : le nom de l'humain de fleet est indéterminable"* ]]
  [[ "$output" != *"« lcars »"* ]]
}
