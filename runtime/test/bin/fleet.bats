#!/usr/bin/env bats
# SOURCE: runtime/test/bin/fleet.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.239
# STATUS: bats tests for bin/fleet env semantics (maintenance override)
#
# The launcher used to clobber LCARS_BOOT_PERMANENT_AT_START with an unconditional
# export: an operator booting in maintenance (=false) got the permanent pods anyway
# (real spend, forge effects). setup_env must PRESERVE the operator's intent; the
# asymmetry with LCARS_PILOT_STEP (already override-preserving) was the tell.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/fleet"
  TMP_BASE="$(mktemp -d)"
  export HOME="$TMP_BASE"
  mkdir -p "$HOME/.lcars"
  # setup_env fail-louds on a missing forge URL (legitimate guard) — satisfied here.
  export FORGE_BASE_URL="http://forge.test"
  # ⚠ LA COUTURE EST LE CHEMIN, PAS LA VALEUR — ET SANS ELLE CES TEMOINS MESURERAIENT LA MACHINE.
  # GUARD B lit `/etc/lcars/seat.uid` et ce FICHIER GAGNE sur la variable : c'est ce qui empeche le
  # garde de lever sa propre garde. Sur une machine provisionnee, le vrai fichier ecraserait le decor
  # de chaque test ci-dessous — verts ici, rouges sur un poste installe, meme arbre. La couture
  # deplace donc le CHEMIN vers le decor.
  #
  # ⚠ ET LE DECOR POSE LE FICHIER, IL NE COMPTE PLUS SUR SON ABSENCE. Ce harnais pointait la couture
  # vers un chemin INEXISTANT, en s'appuyant sur un repli — « sans fichier, on retombe sur la
  # variable ». Ce repli est mort le 2026-08-27, et sa premisse etait fausse : une machine sans siege
  # est une machine ou l'installeur n'a pas tourne en entier, pas un arbre de dev. Le siege est l'uid
  # de l'humain qui installe LCARS — ou, quand une forge est deja fournie, celui derive du nom de son
  # admin. Il n'existe aucun cas legitime ou la fleet demarre sans lui.
  #
  # 99999 : un uid que personne ne porte, donc GUARD B laisse passer par defaut et chaque temoin
  # atteint la porte qu'il vise. Ceux qui mesurent le REFUS ecrivent `$(id -u)` eux-memes.
  export LCARS_SEAT_UID_FILE="$TMP_BASE/seat.uid"
  echo 99999 > "$LCARS_SEAT_UID_FILE"
}

teardown() {
  # Les faux BEAM sont de VRAIS processus : sans ce reaping ils survivent au test (`sleep 300`)
  # et le poste garde une trainee d'orphelins a chaque passage du gate.
  [[ -n "${STUB_HARNESS_PID:-}" ]] && kill -9 -- "-$STUB_HARNESS_PID" 2>/dev/null
  rm -rf "$TMP_BASE"
  return 0
}

@test "maintenance override SURVIVES setup_env (LCARS_BOOT_PERMANENT_AT_START=false)" {
  run bash -c "export LCARS_BOOT_PERMANENT_AT_START=false; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "nominal default stays ON (flag unset -> true)" {
  run bash -c "unset LCARS_BOOT_PERMANENT_AT_START; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=true"* ]]
}

@test "the env file's own false is honoured too (operator intent from fleet.env)" {
  echo 'LCARS_BOOT_PERMANENT_AT_START=false' > "$HOME/.lcars/fleet.env"
  run bash -c "source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "sourcing the launcher never runs the dispatcher (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

# --- cmd_start: the claude credentials preflight ---
# The one input no pod can think without. Without the door-side check, `start` looks green and
# every pod then dies in tmux logs nobody reads. These tests pin the refusal AND its escape: a
# guard whose override is untested is a guard that can silently become unbypassable.
# The launch itself is neutralised (dtmux/fleet_up_notice redefined after sourcing) — what is
# under test is the door, not the BEAM.
# ⚠ The stub must ANSWER `has-session` NEGATIVELY. A blanket `dtmux() { :; }` reports a live
# session, cmd_start takes its already-up early return, and every test below passes without ever
# reaching the guard — green, and measuring nothing.
#
# ⚠ GUARD B IS NEUTRALISED HERE TOO, AND ITS ABSENCE COST A RED IMAGE. `cmd_start` opens with the
# sysadmin-uid guard, BEFORE the credentials door these tests aim at. Left to the runner's REAL uid,
# every test below measures the machine it runs on: green on a host whose human is uid 1017, red in
# the image `build` stage, which runs as `builder` — uid 1000, the reserved sysadmin uid — where the
# guard fires first and the door under test is never reached. Measured 2026-08-15: 4 tests red in
# the image, 0 on the host, same tree, same commit. So the comparison value is pinned OFF the
# runner's uid, exactly as the two GUARD B tests below pin it ON — a test that reads `id -u` without
# saying so is a test about the machine.
NEUTRALISED_START='export LCARS_SYSADMIN_UID=$(( $(id -u) + 1 )); dtmux() { [[ "$1" != has-session ]]; }; fleet_up_notice() { echo reached-launch; }; cmd_start'

@test "start REFUSES without claude credentials, and names the identity gesture" {
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  # message first: a death for ANOTHER reason (missing tmux) would also be non-zero
  [[ "$output" == *"credentials claude absentes"* ]]
  [[ "$output" == *"/login"* ]]
  [[ "$output" != *"reached-launch"* ]]
  [ "$status" -ne 0 ]
}

@test "an EMPTY credentials file refuses too (presence is not validity)" {
  mkdir -p "$HOME/.claude"
  : > "$HOME/.claude/.credentials.json"
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" == *"credentials claude absentes"* ]]
  [ "$status" -ne 0 ]
}

# --- cmd_start: GUARD B (no fleet under the sysadmin uid) ---
# Le BEAM herite de l'uid du lanceur et ses pods avec : lancer sous l'uid reserve du sysadmin
# (admiral, 1000) donnerait des pods root. Le garde est EN TETE de cmd_start, avant tout le reste.
# On simule l'uid via `LCARS_SYSADMIN_UID` (la valeur de comparaison), pas en changeant d'uid reel.

@test "GUARD B: le FICHIER gagne sur la variable — la dispense ne se pose plus en prefixe" {
  # ⚠ MESURE DU 2026-08-27 : `LCARS_SYSADMIN_UID=99999 fleet start` desarmait cette garde. Elle
  # lisait sa politique dans l'environnement du processus qu'elle garde. Le fichier `root:root` la
  # lui retire — a condition de GAGNER, sinon il suffit de reposer la variable.
  echo "$(id -u)" > "$LCARS_SEAT_UID_FILE"
  run bash -c "export LCARS_SYSADMIN_UID=99999; source '$SCRIPT'; cmd_start"
  [[ "$output" == *"admiral/sysadmin"* ]]
  [ "$status" -ne 0 ]
}

@test "GUARD B: le fichier fait AUTORITE aussi quand il innocente" {
  # LE PENDANT : sans lui, une garde qui refuserait TOUJOURS passerait le temoin d'a cote.
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  run bash -c "export LCARS_SYSADMIN_UID=\$(id -u); source '$SCRIPT'; cmd_start"
  [[ "$output" != *"admiral/sysadmin"* ]]
}

@test "GUARD B: un siege ILLISIBLE se REFUSE, il ne se remplace pas" {
  # ⚠ CE TEMOIN AFFIRMAIT L'INVERSE JUSQU'AU 2026-08-27 : « on retombe sur la variable ». Un defaut
  # repond par un NOMBRE la ou le garde a besoin d'un FAIT, et `1000` — premier uid humain de toute
  # distro — accuse le lecteur le plus probable. Un fichier siege qui ne porte pas un uid est un etat
  # (installeur incomplet), pas une valeur : on le NOMME et on refuse.
  printf 'pasunuid\n' > "$LCARS_SEAT_UID_FILE"
  run bash -c "export LCARS_SYSADMIN_UID=\$(id -u); source '$SCRIPT'; cmd_start"
  [[ "$output" == *"siege illisible"* ]]
  [ "$status" -ne 0 ]
}

@test "GUARD B: un siege ABSENT se REFUSE aussi — la machine n'est pas provisionnee" {
  # Le pendant du precedent, et il ferme le cas que le harnais exploitait : pas de fichier du tout.
  # Une machine sans siege est une machine ou l'installeur n'a pas tourne en entier ; la variable ne
  # peut pas y suppleer, sinon le garde lit sa politique dans l'environnement du processus qu'il garde.
  rm -f "$LCARS_SEAT_UID_FILE"
  run bash -c "export LCARS_SYSADMIN_UID=99999; source '$SCRIPT'; cmd_start"
  [[ "$output" == *"siege non declare"* ]]
  [ "$status" -ne 0 ]
}

@test "GUARD B: start REFUSE sous l'uid du sysadmin (admiral) et nomme le plan" {
  # ⚠ LE SIEGE SE POSE PAR LE FICHIER, PLUS PAR LA VARIABLE — c'est le sens meme de la garde : elle
  # ne lit pas sa politique dans l'environnement du processus qu'elle garde.
  echo "$(id -u)" > "$LCARS_SEAT_UID_FILE"
  run bash -c "source '$SCRIPT'; cmd_start"
  [[ "$output" == *"admiral/sysadmin"* ]]
  [ "$status" -ne 0 ]
}

@test "GUARD B: sous un uid worker (!= sysadmin) le garde laisse passer — on atteint la porte suivante" {
  run bash -c "export LCARS_SYSADMIN_UID=\$(( \$(id -u) + 1 )); source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"admiral/sysadmin"* ]]
  [[ "$output" == *"credentials claude absentes"* ]]
  [ "$status" -ne 0 ]
}

# --- GUARD B, second volet : le PLANCHER systeme (root compris) ---
# Le garde a laisse passer root pendant une journee : il testait une EGALITE avec l'uid du sysadmin,
# vraie pour admiral et fausse pour uid 0. Mesure du 2026-08-15 sur banc — `sudo su` puis
# `fleet start` franchissait le garde ; ce qui arretait root etait l'ABSENCE de son fleet.env,
# un accident de provisioning, pas une regle. La frontiere systeme/humain n'est pas a inventer :
# `/etc/login.defs` la declare et `human-converger.sh` la lit deja. On la simule par `PASSWD_DEFS`,
# le meme seam que le convergeur, sans changer d'uid reel.

@test "GUARD B: un uid SOUS le plancher systeme est refuse — c'est le trou par lequel root passait" {
  local defs="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t\t\t 65000\nUID_MAX\t\t\t 65535\n' > "$defs"          # tout uid reel est desormais « systeme » — les DEUX bornes, comme tout login.defs reel
  run bash -c "export PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
  [ "$status" -ne 0 ]
  [[ "$output" == *"compte SYSTEME"* ]]
  [[ "$output" == *"UID_MIN=65000"* ]]     # le refus NOMME sa source, il ne dit pas juste non
  [[ "$output" != *"reached-launch"* ]]
}

@test "GUARD B: le plancher est ARITHMETIQUE — une comparaison de chaines refuserait a tort" {
  # Temoin du MECANISME, pas du resultat. Avec UID_MIN=999 et un uid reel a quatre chiffres,
  # `[[ "1017" < "999" ]]` est VRAI en lexicographique (le '1' precede le '9') : un garde ecrit en
  # chaines refuserait ici. En arithmetique 1017 < 999 est faux, donc on passe. Ce temoin devient
  # rouge le jour ou quelqu'un reecrit la condition avec `<` dans un `[[ ]]`.
  local defs="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t\t\t 999\nUID_MAX\t\t\t 60000\n' > "$defs"
  run bash -c "export PASSWD_DEFS='$defs'; export LCARS_SYSADMIN_UID=\$(( \$(id -u) + 1 )); source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"compte SYSTEME"* ]]
  [[ "$output" == *"credentials claude absentes"* ]]   # on a bien atteint la porte suivante
}

@test "GUARD B: un login.defs illisible REFUSE — la frontiere n'est pas etablie, et le lanceur le dit avec le mot du BEAM" {
  # ⚠ CE TEMOIN AFFIRMAIT L'INVERSE (« retombe sur 1000 ») jusqu'au 2026-09-05. Un defaut repond par
  # un NOMBRE la ou le garde a besoin d'un FAIT : un UID_MIN reel a 2000 devine a 1000 laisse lancer
  # une fleet — donc des pods — a tout ce qui vit entre les deux. Le BEAM refuse de booter dans ce
  # cas (R-no-uid-min) ; le lanceur refuse AVANT lui, avec la meme phrase, et nomme le fichier.
  local defs="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  run bash -c "export PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
  [ "$status" -ne 0 ]
  [[ "$output" == *"n'est pas etablie"* ]]
  [[ "$output" == *"UID_MIN illisible dans $defs"* ]]
  [[ "$output" == *"repare $defs"* ]]
  [[ "$output" != *"1000"* ]]
  [[ "$output" != *"reached-launch"* ]]
  [[ "$output" != *"credentials claude absentes"* ]]   # la porte suivante n'est PAS atteinte
}

@test "GUARD B: la phrase du refus est CELLE du protocole des humains — un temoin tient l'egalite, pas un commentaire" {
  # `bin/fleet` ne source pas `lib/human-protocol.sh` (un vocabulaire de module, pas de lanceur) :
  # il en porte cinq lignes. Ce qui garantit que les deux disent la MEME chose au meme moment est
  # ce temoin : le remede du protocole (`UID_BOUNDS_WHY`), sur le meme fichier — absent, puis
  # sans UID_MAX — doit se lire tel quel dans le refus du lanceur, borne manquante comprise.
  local lib="$BATS_TEST_DIRNAME/../../services/lib"
  local variant defs expected
  for variant in absent sans-max; do
    case "$variant" in
      absent)   defs="$BATS_TEST_TMPDIR/nulle-part/login.defs" ;;
      sans-max) defs="$BATS_TEST_TMPDIR/login.defs"; printf 'UID_MIN\t1000\n' > "$defs" ;;
    esac
    expected="$(LCARS_HUMAN_PROTOCOL_HOST=1 LCARS_MODULE_PROTOCOL="$lib/module-protocol.sh" \
      LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR" PASSWD_DEFS="$defs" \
      bash -c '. "$1"; uid_bounds 2>/dev/null || true; printf "%s" "$UID_BOUNDS_WHY"' _ "$lib/human-protocol.sh")"
    [ -n "$expected" ] || { echo "$variant : le protocole n'a pas rendu de remede — instrument casse" >&2; return 1; }
    run bash -c "export PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]] || { echo "$variant — lanceur : $output"; echo "protocole : $expected"; return 1; }
  done
  # GARDE D'INSTRUMENT : les deux remedes nomment des bornes DIFFERENTES — sinon la boucle a
  # mesure deux fois le meme cas.
  [[ "$expected" == *"UID_MAX illisible"* ]]
}

# --- GUARD B, troisieme volet : le PLAFOND (nobody, 65534) ---
# La frontiere a DEUX bornes (protocole `uid_bounds`, `console-humans.sh`, le BEAM) : au-dessus de
# UID_MAX vivent `nobody` et les comptes de service hauts. Jusqu'au lot 15 le lanceur ne lisait
# qu'UID_MIN — nobody le passait, et le BEAM derriere ne lisait pas UID_MAX non plus. L'uid qui
# lance est ce que `id -u` repond : un `id` de decor sur le PATH le fait nobody (ou un humain de
# fleet), quel que soit celui qui joue la suite — un temoin qui lit l'uid reel mesure la machine.

id_decor() { # id_decor <uid> — un `id` sur le PATH du temoin qui repond <uid> (et `nobody` a -un)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *-un*) echo nobody ;; *) echo '"$1"' ;; esac' > "$BATS_TEST_TMPDIR/bin/id"
  chmod 0755 "$BATS_TEST_TMPDIR/bin/id"
}

@test "GUARD B: nobody (65534) est AU-DESSUS du plafond — refuse, et le refus nomme UID_MAX" {
  local defs="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$defs"
  id_decor 65534
  run bash -c "export PATH='$BATS_TEST_TMPDIR/bin:$PATH' PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uid 65534"* ]]
  [[ "$output" == *"UID_MAX=60000"* ]]     # le refus NOMME sa source, il ne dit pas juste non
  [[ "$output" != *"reached-launch"* ]]
  [[ "$output" != *"credentials claude absentes"* ]]   # la porte suivante n'est PAS atteinte
  # Et c'est bien la BORNE qui l'ecarte, pas son nom : un UID_MAX au-dessus de lui laisse passer
  # jusqu'a la porte suivante.
  printf 'UID_MIN\t1000\nUID_MAX\t70000\n' > "$defs"
  run bash -c "export PATH='$BATS_TEST_TMPDIR/bin:$PATH' PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"UID_MAX"* ]]
  [[ "$output" == *"credentials claude absentes"* ]]
}

@test "GUARD B: UID_MAX ABSENT du login.defs REFUSE — une seule borne n'etablit pas la frontiere, et le refus nomme UID_MAX" {
  # Sans plafond, `nobody` serait un humain de fleet ; le lanceur ne devine pas 60000, il refuse
  # avec le mot du protocole et nomme la borne qui manque — le remede est le fichier.
  local defs="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\n' > "$defs"
  id_decor 1001
  run bash -c "export PATH='$BATS_TEST_TMPDIR/bin:$PATH' PASSWD_DEFS='$defs'; source '$SCRIPT'; $NEUTRALISED_START"
  [ "$status" -ne 0 ]
  [[ "$output" == *"n'est pas etablie"* ]]
  [[ "$output" == *"UID_MAX illisible dans $defs"* ]]
  [[ "$output" == *"repare $defs"* ]]
  [[ "$output" != *"60000"* ]]
  [[ "$output" != *"reached-launch"* ]]
  [[ "$output" != *"credentials claude absentes"* ]]
}

# --- option parsing ---
# Until 2026-08-03 this script dispatched sub-commands and NOTHING read `$@` past that: `cmd_start`
# took its arguments and ignored them, so every flag was silently swallowed. A door that accepts
# anything and does nothing with it is worse than one that refuses — the operator types a flag,
# sees a fleet come up, and believes it is on.

@test "an unknown start flag is REFUSED, not swallowed" {
  run bash -c "source '$SCRIPT'; parse_start_opts --nawak"
  [ "$status" -ne 0 ]
  [[ "$output" == *"option inconnue"* ]]
  [[ "$output" == *"--nawak"* ]]
}

@test "--debug arms the visibility marker; without it the marker stays unset" {
  # The flag's whole mechanism is one variable the runtime reads. Asserting the variable (and not
  # just a zero exit) is what pins that it DOES something. The parser sets a MARKER: the real
  # variable is posted later, after the env file is sourced (see the test below).
  run bash -c "source '$SCRIPT'; parse_start_opts --debug; echo \"dbg=[\${DEBUG_VISIBILITY_FLAG:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbg=[1]"* ]]

  run bash -c "source '$SCRIPT'; parse_start_opts; echo \"dbg=[\${DEBUG_VISIBILITY_FLAG:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbg=[]"* ]]
}

@test "--max-fan takes a value, and the door REFUSES what it cannot honour" {
  # A flag that clamps accepts `--max-fan 99`, starts green and runs at 15: it says one thing and
  # does another, which is the defect this parser exists to end. Refusing names the mistake at the
  # only moment the operator is still looking.
  run bash -c "source '$SCRIPT'; parse_start_opts --max-fan 3; echo \"fan=[\${MAX_FAN_FLAG:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fan=[3]"* ]]

  run bash -c "source '$SCRIPT'; parse_start_opts --max-fan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"attend une valeur"* ]]

  run bash -c "source '$SCRIPT'; parse_start_opts --max-fan beaucoup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"entier"* ]]

  run bash -c "source '$SCRIPT'; parse_start_opts --max-fan 99"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hors bornes"* ]]

  run bash -c "source '$SCRIPT'; parse_start_opts --max-fan 0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hors bornes"* ]]
}

@test "--max-fan reaches the BEAM as LCARS_MAX_FAN, applied after the env file" {
  # Same rule as --debug: the parser sets a marker, `apply_start_flags` posts the variable AFTER
  # `load_env` sources the human file — so a file naming LCARS_MAX_FAN cannot silence the flag.
  local env_file="$BATS_TEST_TMPDIR/fleet.env"
  echo 'LCARS_MAX_FAN=9' > "$env_file"

  run env LCARS_FLEET_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts --max-fan 2; load_env; apply_start_flags; \
     echo \"fan=[\${LCARS_MAX_FAN:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fan=[2]"* ]]

  # No flag → the file stands: the flag adds, it does not clobber.
  run env LCARS_FLEET_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts; load_env; apply_start_flags; \
     echo \"fan=[\${LCARS_MAX_FAN:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fan=[9]"* ]]
}

@test "--debug BEATS an env file that says otherwise (the flag is applied after the sourcing)" {
  # `setup_env` sources the human env file with `set -a`. A variable assigned by the parser BEFORE
  # that sourcing is overwritten by the file: the operator types --debug, the fleet comes up green,
  # and the mode is off. The marker is applied after, and only ever ADDS.
  local env_file="$BATS_TEST_TMPDIR/fleet.env"
  echo 'LCARS_DEBUG_VISIBILITY=false' > "$env_file"

  run env LCARS_FLEET_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts --debug; load_env; apply_start_flags; \
     echo \"dbg=[\${LCARS_DEBUG_VISIBILITY:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbg=[1]"* ]]

  # And with no flag, the file is honoured — the flag adds, it does not clobber.
  run env LCARS_FLEET_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts; load_env; apply_start_flags; \
     echo \"dbg=[\${LCARS_DEBUG_VISIBILITY:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbg=[false]"* ]]
}

@test "the flag does not eat the positionals behind it" {
  # `--` ends the option list, and what follows must reach the caller untouched: a parser that
  # quietly consumes the rest would break the day `start` takes an argument.
  run bash -c "source '$SCRIPT'; parse_start_opts --debug -- keep-me; echo \"rest=[\${START_ARGS[*]}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rest=[keep-me]"* ]]
}

@test "the usage names the flag — a flag the usage hides is a flag nobody uses" {
  run bash "$SCRIPT" badcmd
  [ "$status" -ne 0 ]
  [[ "$output" == *"--debug"* ]]
  [[ "$output" == *"deja lances"* ]]
}

@test "LCARS_START_WITHOUT_CLAUDE=1 passes the door with no credentials (documented escape)" {
  run bash -c "export LCARS_START_WITHOUT_CLAUDE=1; source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"credentials claude absentes"* ]]
  [[ "$output" == *"reached-launch"* ]]
}

@test "real credentials pass the door untouched (no escape needed)" {
  mkdir -p "$HOME/.claude"
  echo '{"claudeAiOauth":{"accessToken":"t"}}' > "$HOME/.claude/.credentials.json"
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"credentials claude absentes"* ]]
  [[ "$output" == *"reached-launch"* ]]
}

# --- cmd_stop: the graceful door of the NOMINAL stop ---
# Real processes and real signals: a fake pane (bash) parenting a fake beam (sleep).
# The tmux stub equates "session alive" with "fake beam alive" — exactly the coupling
# the launcher relies on (the tmux session dies with the BEAM).

make_tmux_stub() {
  mkdir -p "$TMP_BASE/stubs"
  cat > "$TMP_BASE/stubs/tmux-stub" << 'STUB'
#!/usr/bin/env bash
# tmux stand-in for cmd_stop: -S <sock> <command> ...
shift 2
case "$1" in
  has-session)      # `kill -0` REUSSIT sur un zombie : entre la mort du faux beam et son reaping
                    # par le `wait` du wrapper, il repondrait « session vivante » sur un processus
                    # deja mort. L'etat dans /proc/<pid>/stat discrimine ; le champ est le premier
                    # caractere apres la DERNIERE parenthese (un comm peut en contenir).
                    _p="$(cat "$STUB_STATE/beam.pid" 2>/dev/null)"
                    [[ -n "$_p" && -r "/proc/$_p/stat" ]] || exit 1
                    _st="$(sed 's/.*) //' "/proc/$_p/stat" | cut -c1)"
                    [[ "$_st" != "Z" ]] ;;
  display-message)  cat "$STUB_STATE/pane.pid" ;;
  kill-server)      touch "$STUB_STATE/kill-server-called"
                    kill -9 "$(cat "$STUB_STATE/beam.pid" 2>/dev/null)" 2>/dev/null || true ;;
  *) true ;;
esac
STUB
  chmod +x "$TMP_BASE/stubs/tmux-stub"
}

# LE FAUX BEAM SE LANCE PAR ICI, ET IL Y A DEUX RAISONS A CA.
#
# (1) Les descripteurs. Un job d'arriere-plan HERITE la sortie du test, et bats lit cette sortie
#     jusqu'a EOF : tant que le `sleep 300` vit, le harnais attend. Mesure : ce fichier prenait
#     4 min 32 pour 2,7 s de test reel, et le temps ne s'imputait a AUCUN test — bats les
#     chronometre, l'attente etait entre eux. `>/dev/null 2>&1` la supprime.
# (2) La trainee, et elle est plus profonde qu'un pid. Le test du fallback lance un beam qui
#     IGNORE TERM (`bash -c 'trap "" TERM; sleep 300'`) : le `kill -9` du stub tue ce bash et
#     ORPHELINE son `sleep`, qu'aucun pid enregistre ne designe plus. D'ou `setsid` : le faux beam
#     et toute sa descendance vivent dans leur propre groupe, et le teardown tue le GROUPE. Tuer
#     des pid nommes ne ferme que les cas dont on a devine la forme.
start_fake_beam() {
  setsid bash -c "echo \$\$ > '$STUB_STATE/pane.pid'; $1 & echo \$! > '$STUB_STATE/beam.pid'; wait" \
    >/dev/null 2>&1 &
  STUB_HARNESS_PID=$!
  sleep 0.3
}

@test "nominal stop is GRACEFUL: SIGTERM reaches the beam, kill-server never fires" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  start_fake_beam "sleep 300"

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_STOP_WAIT=5; source '$SCRIPT'; cmd_stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proprement"* ]]
  [ ! -f "$STUB_STATE/kill-server-called" ]
}

@test "a beam that ignores SIGTERM falls back to kill-server after the bounded wait" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  start_fake_beam "bash -c 'trap \\\"\\\" TERM; sleep 300'"

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_STOP_WAIT=1; source '$SCRIPT'; cmd_stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback kill"* ]]
  [ -f "$STUB_STATE/kill-server-called" ]
}

# ─── Visibilite debug dans `status` — un mode qu'on ne peut pas lire est un mode qui ment ────────
# La verite du flag vit dans l'environnement du BEAM QUI TOURNE : `--debug` porte sur UNE vie de la
# fleet, il n'est ni commutable a chaud ni persiste. Lire le fichier d'env repondrait pour une fleet
# qui n'existe pas (fichier edite apres le demarrage).

@test "status: debug ON est lu dans l'environnement du BEAM, pas ailleurs" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  start_fake_beam "env -i LCARS_DEBUG_VISIBILITY=1 sleep 300"

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE'; source '$SCRIPT'; status_debug_visibility"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ON"* ]]
}

@test "status: sans le flag dans le BEAM, c'est off — et le message dit comment l'activer" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  start_fake_beam "env -i sleep 300"

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE'; source '$SCRIPT'; status_debug_visibility"
  [ "$status" -eq 0 ]
  [[ "$output" == *"off"* ]]
  [[ "$output" == *"--debug"* ]]
}

@test "status: un environnement illisible rend INDETERMINEE, jamais 'off'" {
  # Une sonde qui repond 'off' quand elle ne sait pas fabrique un faux negatif : l'operateur
  # relancerait --debug en boucle sur une fleet qui l'a deja.
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub
  : > "$STUB_STATE/pane.pid"   # pas de pane_pid -> pas de beam_pid

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE'; source '$SCRIPT'; status_debug_visibility"
  [ "$status" -eq 0 ]
  [[ "$output" == *"indeterminee"* ]]
}

# `fleet status` imprimait `ref=` suivi de RIEN. Un champ vide n'est pas une valeur : le lecteur
# devait choisir seul entre « la branche s'appelle vide », « le champ n'a pas ete rempli » et « il n'y
# a pas de branche ». Les deux causes reelles sont distinctes et se disent maintenant differemment —
# une release est batie depuis un commit (`BuildInfo.env_facts/0` rend `ref: nil` a dessein), un arbre
# de travail sans reponse de git n'a PAS ete mesure. Les confondre ferait lire « pas de branche » la
# ou il faut lire « je n'ai pas pu regarder ».
@test "release sans ref → le status DIT qu'il n'y en a pas, il n'imprime pas un champ vide" {
  local rel="$TMP_BASE/rt/rel/lcars_fleet/lib/lcars_fleet-1.0.0/priv/api"
  mkdir -p "$rel"
  printf 'sha=abc1234\ndirty=false\nref=\n' > "$rel/build_info.txt"

  run bash -c "source '$SCRIPT'; RUNTIME_DIR='$TMP_BASE/rt'; cmd_version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=release"* ]]
  [[ "$output" != *"ref= "* ]]
  [[ "$output" == *"ref=<aucune : bati depuis un commit>"* ]]
}

@test "release AVEC ref → la valeur mesuree passe telle quelle (le defaut ne l'ecrase pas)" {
  local rel="$TMP_BASE/rt/rel/lcars_fleet/lib/lcars_fleet-1.0.0/priv/api"
  mkdir -p "$rel"
  printf 'sha=abc1234\ndirty=true\nref=main\n' > "$rel/build_info.txt"

  run bash -c "source '$SCRIPT'; RUNTIME_DIR='$TMP_BASE/rt'; cmd_version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=main"* ]]
  [[ "$output" == *"abc1234-dirty"* ]]
}

@test "arbre de travail sans git → 'illisible', PAS le message de la release (les causes ne se confondent pas)" {
  mkdir -p "$TMP_BASE/nogit"

  run bash -c "source '$SCRIPT'; RUNTIME_DIR='$TMP_BASE/nogit'; cmd_version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=working_tree"* ]]
  [[ "$output" == *"ref=<illisible : git muet>"* ]]
  [[ "$output" != *"bati depuis un commit"* ]]
}
