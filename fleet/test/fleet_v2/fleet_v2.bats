#!/usr/bin/env bats
# SOURCE: test/fleet_v2/fleet_v2.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.227
# STATUS: bats tests for bin/fleet_v2 env semantics (maintenance override)
#
# The launcher used to clobber LCARS_BOOT_PERMANENT_AT_START with an unconditional
# export: an operator booting in maintenance (=false) got the permanent pods anyway
# (real spend, forge effects). setup_env must PRESERVE the operator's intent; the
# asymmetry with LCARS_PILOT_STEP (already override-preserving) was the tell.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/fleet_v2"
  TMP_BASE="$(mktemp -d)"
  export HOME="$TMP_BASE"
  mkdir -p "$HOME/.lcars"
  # setup_env fail-louds on a missing forge URL (legitimate guard) — satisfied here.
  export FORGE_BASE_URL="http://forge.test"
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

@test "the env file's own false is honoured too (operator intent from fleet_v2.env)" {
  echo 'LCARS_BOOT_PERMANENT_AT_START=false' > "$HOME/.lcars/fleet_v2.env"
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
NEUTRALISED_START='dtmux() { [[ "$1" != has-session ]]; }; fleet_up_notice() { echo reached-launch; }; cmd_start'

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

@test "GUARD B: start REFUSE sous l'uid du sysadmin (admiral) et nomme le plan" {
  run bash -c "export LCARS_SYSADMIN_UID=\$(id -u); source '$SCRIPT'; cmd_start"
  [[ "$output" == *"admiral/sysadmin"* ]]
  [ "$status" -ne 0 ]
}

@test "GUARD B: sous un uid worker (!= sysadmin) le garde laisse passer — on atteint la porte suivante" {
  run bash -c "export LCARS_SYSADMIN_UID=\$(( \$(id -u) + 1 )); source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"admiral/sysadmin"* ]]
  [[ "$output" == *"credentials claude absentes"* ]]
  [ "$status" -ne 0 ]
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
  local env_file="$BATS_TEST_TMPDIR/fleet_v2.env"
  echo 'LCARS_MAX_FAN=9' > "$env_file"

  run env LCARS_FLEET_V2_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts --max-fan 2; load_env; apply_start_flags; \
     echo \"fan=[\${LCARS_MAX_FAN:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fan=[2]"* ]]

  # No flag → the file stands: the flag adds, it does not clobber.
  run env LCARS_FLEET_V2_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts; load_env; apply_start_flags; \
     echo \"fan=[\${LCARS_MAX_FAN:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"fan=[9]"* ]]
}

@test "--debug BEATS an env file that says otherwise (the flag is applied after the sourcing)" {
  # `setup_env` sources the human env file with `set -a`. A variable assigned by the parser BEFORE
  # that sourcing is overwritten by the file: the operator types --debug, the fleet comes up green,
  # and the mode is off. The marker is applied after, and only ever ADDS.
  local env_file="$BATS_TEST_TMPDIR/fleet_v2.env"
  echo 'LCARS_DEBUG_VISIBILITY=false' > "$env_file"

  run env LCARS_FLEET_V2_ENV="$env_file" bash -c \
    "source '$SCRIPT'; parse_start_opts --debug; load_env; apply_start_flags; \
     echo \"dbg=[\${LCARS_DEBUG_VISIBILITY:-}]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"dbg=[1]"* ]]

  # And with no flag, the file is honoured — the flag adds, it does not clobber.
  run env LCARS_FLEET_V2_ENV="$env_file" bash -c \
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

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_V2_STOP_WAIT=5; source '$SCRIPT'; cmd_stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proprement"* ]]
  [ ! -f "$STUB_STATE/kill-server-called" ]
}

@test "a beam that ignores SIGTERM falls back to kill-server after the bounded wait" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  start_fake_beam "bash -c 'trap \\\"\\\" TERM; sleep 300'"

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_V2_STOP_WAIT=1; source '$SCRIPT'; cmd_stop"
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

# `fleet_v2 status` imprimait `ref=` suivi de RIEN. Un champ vide n'est pas une valeur : le lecteur
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
