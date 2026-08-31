#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/accept.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-29
# STATUS: bats tests for deploy/accept — la TROISIEME capacite, celle qui n'etait mesuree par personne
#
# CE QUE CES TEMOINS FERMENT, ET POURQUOI ILS ARRIVENT SI TARD.
#
# `check_fleet_start` portait DEUX instruments casses, et les deux etaient INJOIGNABLES : la fonction
# sortait sur « aucun humain de fleet nomme » des que le drapeau `--fleet-human` n'etait pas passe,
# c'est-a-dire dans le cas NOMINAL. Le retrait du drapeau (2026-08-28) a rendu le chemin joignable,
# et les deux defauts sont tombes le meme jour :
#
#   1. `runuser … env … command -v fleet_v2` — `command` est un BUILTIN de shell. Il n'existe aucun
#      `/usr/bin/command`, donc `env` rend 127 SUR TOUTE MACHINE. L'assertion accusait le PATH d'un
#      compte parfaitement equipe.
#   2. `fleet_v2 status 2>/dev/null | grep -q 'BEAM vivant'` sous le `set -o pipefail` de ce fichier.
#      `grep -q` sort au PREMIER match et ferme le tuyau ; le producteur, qui a encore des lignes a
#      ecrire, meurt sur SIGPIPE (141). `pipefail` prend ce 141 et le `if` est FAUX alors que grep a
#      TROUVE. Les deux sondages rendaient donc faux en permanence, quel que soit l'etat.
#
# ⚠ ET LE GATE NE VOYAIT NI L'UN NI L'AUTRE. Mesure du 2026-08-29 : les deux correctifs REVERTES,
# `bats deploy/tests/` rend ZERO rouge. 1420 temoins verts, aucun ne regardait ce fichier. Les deux
# defauts n'ont ete trouves qu'au banc, a la main, une fois — et rien ne l'aurait rejoue.
#
# ⚠ CES TEMOINS MESURENT LE COMPORTEMENT, PAS L'ORTHOGRAPHE. Epingler « le fichier contient
# `bash -lc` » garderait une FORME et laisserait passer toute autre facon de se tromper. On joue donc
# `check_fleet_start` pour de vrai contre des doublures, et le producteur de la doublure CONTINUE
# D'ECRIRE apres le match — c'est cette seule propriete qui fait rougir la forme en tuyau.

load refute

setup() {
  # Le decor possede l'environnement : ces temoins jugent ce que le script fait d'un environnement
  # DONNE. L'heriter reviendrait a juger la machine qui les joue.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../accept"
  [ -f "$SRC" ]

  # ─── LE BAC A SABLE REPRODUIT L'ARBRE, parce que `accept` DERIVE le nom de l'humain de fleet de
  # sa propre position (`$(dirname "$BASH_SOURCE")/../services/forge-gestures.sh`). Le decor doit
  # donc porter la meme forme d'arbre, sinon on mesure un repli au lieu du chemin nominal.
  SANDBOX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$SANDBOX/deploy" "$SANDBOX/services"

  # Le corps SANS son execution finale : on appelle ses fonctions, on ne le lance pas.
  MOD="$SANDBOX/deploy/accept"
  sed "/^printf '\\\\n  %sACCEPTATION/,\$d" "$SRC" > "$MOD"

  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${LCARS_BUILTIN_HUMAN:-lcars}"' \
    > "$SANDBOX/services/forge-gestures.sh"
  chmod 0755 "$SANDBOX/services/forge-gestures.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  HOME_DIR="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME_DIR"

  # `getent passwd <login>` : le home du decor, jamais celui de la machine.
  printf '%s\n' '#!/usr/bin/env bash' \
    "[[ \"\$1\" == passwd ]] && printf '%s:x:1001:1001::%s:/bin/bash\\n' \"\$2\" '$HOME_DIR'" \
    'exit 0' > "$BINDIR/getent"

  # ⚠ `runuser` NE CHANGE PAS D'IDENTITE ICI, ET C'EST DELIBERE : un temoin ne peut pas devenir un
  # autre compte. Ce qui doit etre epingle est ce que le script DEMANDE, pas le pouvoir de le faire —
  # meme idiome que `stub_impersonation` de `provision_runner.bats`. La doublure retire `-u <login>`
  # et le `--`, puis exec le reste.
  printf '%s\n' '#!/usr/bin/env bash' 'shift 2; [[ "$1" == "--" ]] && shift; exec "$@"' \
    > "$BINDIR/runuser"

  chmod 0755 "$BINDIR"/*

  # `bash -lc` charge un profil : sans cette ligne, le PATH du decor ne survit pas au shell de login
  # et le temoin mesurerait le PATH de la machine.
  # ⚠ ET LE DECOR POSSEDE CE PATH EN ENTIER — `$BINDIR:$PATH` HERITAIT DE LA MACHINE. Sur un poste
  # DEJA provisionne, `/usr/local/bin/fleet_v2` existe (pose par 60-deploy) : le temoin « lanceur
  # ABSENT du PATH » retirait sa doublure et trouvait le VRAI lanceur — aucun refus ne sortait.
  # Banc WSL, 2026-08-30, troisieme run ; vert au premier, ou la release n'etait pas encore posee.
  # `/usr/bin:/bin` suffit aux outils que ce corpus appelle ; le reste appartient au decor.
  printf 'export PATH="%s:/usr/bin:/bin"\n' "$BINDIR" > "$HOME_DIR/.bash_profile"
}

# ─── LA DOUBLURE DE `fleet_v2`, ET SA SEULE PROPRIETE QUI COMPTE ────────────────────────────────
#
# ⚠ ELLE CONTINUE D'ECRIRE APRES LE MATCH. Le vrai `fleet_v2 status` imprime « BEAM vivant » en
# ligne 2 puis calcule encore (visibilite debug, pods) avant d'ecrire les lignes 3 a 5. C'est CETTE
# fenetre qui tue le producteur sous `grep -q`. Une doublure qui rendrait ses cinq lignes d'un coup
# ne reproduirait pas le defaut, et le temoin serait vert sans rien prouver.
fleet_v2_stub() { # fleet_v2_stub <vivant|mort|start-casse>
  local etat="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "ETAT='$etat'"
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status)'
    printf '%s\n' '    printf "fleet_v2: build deadbeef (source=release)\n"'
    printf '%s\n' '    [[ -f "$MARQUEUR" || "$ETAT" == vivant ]] && printf "fleet_v2: BEAM vivant. Logs : tmux -S …\n"'
    # La pause laisse a `grep -q` le temps de trouver sa ligne et de FERMER le tuyau, pour que
    # l'ecriture suivante prenne le SIGPIPE. C'est elle qui fait de cette doublure un producteur
    # qui ECRIT ENCORE apres le match — la seule propriete qui reproduise le defaut.
    printf '%s\n' '    sleep 0.3'
    printf '%s\n' '    printf "fleet_v2: visibilite debug : off\n"'
    printf '%s\n' '    printf "(aucun pod vivant)\n"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  start) [[ "$ETAT" == start-casse ]] && exit 1; : > "$MARQUEUR" ;;'
    printf '%s\n' '  stop)  rm -f "$MARQUEUR" ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$BINDIR/fleet_v2"
  chmod 0755 "$BINDIR/fleet_v2"
  export MARQUEUR="$BATS_TEST_TMPDIR/beam.vivant"
  rm -f "$MARQUEUR"
}

# Joue `check_fleet_start` dans le decor, avec le PATH du bac a sable.
joue() { run env PATH="$BINDIR:$PATH" HOME="$HOME_DIR" \
  bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; check_fleet_start"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -6 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

# ─── LE SONDAGE ────────────────────────────────────────────────────────────────────────────────

@test "fleet DEJA vivante : le sondage la VOIT, et rien n'est demarre" {
  # LE TEMOIN DU DEFAUT SIGPIPE. Sous la forme en tuyau, ce sondage rendait faux ici — donc la
  # branche « deja demarree » ne s'armait JAMAIS, et le script demarrait une fleet qui tournait deja.
  fleet_v2_stub vivant
  joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"deja demarree"* ]]
  [[ "$output" == *"OUI"* ]]
}

@test "TEMOIN DU TEMOIN : la doublure REPRODUIT bien la condition qui tue le producteur" {
  # ⚠ SANS CE PENDANT, LE TEMOIN CI-DESSUS PASSERAIT AUSSI AVEC UNE DOUBLURE QUI REND TOUT D'UN COUP,
  # c'est-a-dire sans avoir rien prouve. On mesure ici que la forme en TUYAU, sous `pipefail`, rend
  # bien FAUX contre cette doublure — 141 (SIGPIPE) cote producteur, 0 cote grep.
  fleet_v2_stub vivant
  # ⚠ CE TEMOIN EPINGLE 141, ET 141 N'EST PAS UNE PROPRIETE DU CODE : c'est la DISPOSITION DE
  # SIGPIPE dans l'environnement qui decide si le producteur meurt (141) ou survit (0). Elle
  # s'HERITE, et POSIX veut qu'un signal deja IGNORE a l'exec le reste — bash ne peut pas revenir
  # dessus, `trap - PIPE` compris (mesure : rc=0 dans les trois formes essayees).
  #
  # OR LE BEAM IGNORE SIGPIPE, et `mix gate` lance ce filet par un port. Le temoin passait donc
  # partout SAUF sous `mix gate`, ou lui seul rougissait sur 1544 — un ecart qu'aucun changement de
  # code n'expliquait, et qui a coute deux faux diagnostics (la charge, puis la duree de pause).
  #
  # ⚠ ET SOUS LE BEAM, LE DEFAUT QUE CE FICHIER MESURE N'EXISTE PAS : SIGPIPE ignore, le producteur
  # survit, le `if` de l'ancienne forme aurait ete VRAI. Le correctif de `deploy/accept` reste juste
  # — il vaut dans les deux environnements — mais son temoin ne peut pas HERITER la condition qu'il
  # pretend mesurer. Il la POSE : `python3` remet SIGPIPE a SIG_DFL puis exec le shell. python3 est
  # deja un prerequis DUR de `shell_gate.sh`, qui refuse de tourner sans lui.
  run env PATH="$BINDIR:$PATH" python3 -c \
    'import signal, os, sys; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash -uo pipefail -c \
    'fleet_v2 status 2>/dev/null | grep -q "BEAM vivant"; echo "rc=$? PIPESTATUS=${PIPESTATUS[*]}"'
  [[ "$output" == *"rc=141"* ]]
  [[ "$output" == *"PIPESTATUS=141 0"* ]]
}

@test "fleet ABSENTE : elle est demarree, vue vivante, puis arretee" {
  fleet_v2_stub mort
  joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"demarre et vivante"* ]]
  [[ "$output" == *"OUI"* ]]
}

@test "start en ECHEC : refus qui renvoie vers la plainte du lanceur" {
  # Le pendant du precedent : sans lui, un sondage qui rendrait TOUJOURS vrai passerait les deux.
  fleet_v2_stub start-casse
  joue
  [ "$status" -ne 0 ] || [[ "$output" == *"NON"* ]]
  [[ "$output" == *"a echoue"* ]]
}

# ─── L'ACCES AU LANCEUR ────────────────────────────────────────────────────────────────────────

@test "fleet_v2 ABSENT du PATH : refus qui NOMME le compte" {
  # LE TEMOIN DU DEFAUT `command`. La forme `env … command -v` rendait 127 partout, donc ce refus
  # sortait sur TOUTE machine — y compris celles ou le lanceur est parfaitement joignable.
  fleet_v2_stub vivant
  rm -f "$BINDIR/fleet_v2"
  joue
  [[ "$output" == *"n'est pas dans le PATH"* ]]
  [[ "$output" == *"lcars"* ]]
}

@test "TEMOIN DU TEMOIN : command est un BUILTIN, pas un binaire — la forme qui a menti ne peut pas reussir" {
  # C'est la mesure qui explique le refus permanent d'avant. Elle tient sur toute machine POSIX :
  # `command` est un builtin, il n'a pas de fichier.
  # Sans `run` : le drapeau `run -127` exigerait `bats_require_minimum_version` en tete de fichier.
  # L'idiome existe ici (`authority_ask.bats`, `lcars_catalogue.bats`) mais il engage tout le fichier
  # sur un plancher de version ; une capture directe du code de sortie coute deux lignes et n'engage
  # rien.
  local rc=0
  env command -v fleet_v2 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 127 ]
}

# ─── LE NOM DE L'HUMAIN ────────────────────────────────────────────────────────────────────────

@test "le login vient de l'AUTORITE, jamais d'un litteral de ce fichier" {
  fleet_v2_stub vivant
  LCARS_BUILTIN_HUMAN=bob joue
  [[ "$output" == *"bob"* ]]
  [[ "$output" != *"« lcars »"* ]]
  # Et le fichier ne grave aucun nom de compte.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/-])lcars([^[:alnum:]_.-]|$)' <<<"$code"
}

@test "autorite MUETTE : on saute en le DISANT, on n'invente pas de nom" {
  # « je ne peux pas mesurer » et « il n'y a personne » appellent deux gestes opposes.
  fleet_v2_stub vivant
  rm -f "$SANDBOX/services/forge-gestures.sh"
  joue
  [[ "$output" == *"indeterminable"* ]] || [[ "$output" == *"indéterminable"* ]]
  [[ "$output" != *"« lcars »"* ]]
}

@test "TEMOIN DU TEMOIN : le decor POSSEDE le PATH — le lanceur d'une machine provisionnee n'y entre pas" {
  # Le pendant du temoin « ABSENT du PATH » : si le decor heritait de `$PATH`, ce temoin-la
  # mesurerait la machine — vert sur un poste ou rien n'est installe, rouge sur un poste installe.
  # La regle vaut pour le fichier entier, pas pour un seul cas.
  local ligne
  ligne="$(grep -F 'export PATH=' "$BATS_TEST_DIRNAME/accept.bats" | grep -v '^ *#' | head -1)"
  [ -n "$ligne" ]
  [[ "$ligne" == *'/usr/bin:/bin'* ]]
  [[ "$ligne" != *':$PATH'* ]]
}
