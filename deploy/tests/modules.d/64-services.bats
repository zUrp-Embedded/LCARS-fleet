#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/64-services.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 64-services — la landing et le convergeur TENUS, pas seulement poses
#

# shellcheck disable=SC2016,SC2030,SC2031

# shellcheck disable=SC2034

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=64-services
  export LCARS_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export LCARS_SERVICES_ENV="$BATS_TEST_TMPDIR/etc/lcars/services.env"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_SERVICES_OWNER
  LCARS_SERVICES_OWNER="$(id -un):$(id -gn)"
  export LCARS_SERVICES_SETTLE=0
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export LCARS_SYSADMIN_UID
  LCARS_SYSADMIN_UID="$(id -u)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s::%s:/bin/bash\nzoe:x:4242:4242::/home/zoe:/bin/bash\n' \
    "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" > "$PASSWD_FILE"
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  mkdir -p "$LCARS_SYSTEMD_DIR" "$PROV_TOKENS_DIR"
  echo "http://127.0.0.1:3000" > "$PROV_TOKENS_DIR/forge.url"

  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/systemctl.calls"
  ACTIVE="$BATS_TEST_TMPDIR/active"; echo 0 > "$ACTIVE"
  RESTARTS="$BATS_TEST_TMPDIR/restarts.d"; mkdir -p "$RESTARTS"
  LOOP="$BATS_TEST_TMPDIR/looping"
  RESTART_TUE="$BATS_TEST_TMPDIR/restart-tue"
  SPIN="$BATS_TEST_TMPDIR/spinning"
  cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALLS"
[[ "\$1" == "is-active" ]] && exit "\$(cat "$ACTIVE")"
[[ "\$1" == "show" && -f "$SPIN" ]] && { u="\${@: -1}"; f="$RESTARTS/\${u%.service}"; v=\$(cat "\$f" 2>/dev/null || echo 0); echo \$((v+1)) > "\$f"; echo "\$v"; exit 0; }
[[ "\$1" == "show" ]] && { u="\${@: -1}"; cat "$RESTARTS/\${u%.service}" 2>/dev/null || echo 0; exit 0; }
[[ "\$1" == "enable" && -f "$LOOP" ]] && { u="\${@: -1}"; echo 9 > "$RESTARTS/\${u%.service}"; }
[[ "\$1" == "try-restart" && -f "$RESTART_TUE" ]] && echo 1 > "$ACTIVE"
exit 0
EOF
  export LCARS_SYSTEMD_RUN="$BATS_TEST_TMPDIR/run-systemd"; mkdir -p "$LCARS_SYSTEMD_RUN"
  chmod 0755 "$BINDIR/systemctl"
  export LCARS_SYSTEMCTL="$BINDIR/systemctl"
  export PATH="$BINDIR:$PATH"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "sans systemd, on ne pose RIEN et on le DIT — un fichier d'unite sans init est un decor" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ ! -e "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
}

@test "apply POSE les deux unites et l'environnement" {
  mod apply
  [ -f "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
  [ -f "$LCARS_SYSTEMD_DIR/lcars-converger.service" ]
  [ -s "$LCARS_SERVICES_ENV" ]
  grep -q "^FORGE_BASE_URL=http://127.0.0.1:3000$" "$LCARS_SERVICES_ENV"
}

@test "l'environnement porte ce qu'un DAEMON ne peut pas heriter" {
  mod apply
  grep -q "^LCARS_FORGE_ORG=" "$LCARS_SERVICES_ENV"
  grep -q "^LCARS_HUMANS_TEAM=" "$LCARS_SERVICES_ENV"
  refute grep -q "^PROV_" "$LCARS_SERVICES_ENV"
}

@test "l'exécuteur de catalogue reçoit le dossier de travail tofu et le miroir de providers que 25 et 46 posent" {
  export PROV_CATALOGUES_WORK="$BATS_TEST_TMPDIR/opt/lcars/var/tofu" LCARS_TOFU_DIR="$BATS_TEST_TMPDIR/opt/lcars/tofu"
  mod apply
  grep -qxF "LCARS_CATALOGUES_WORK=$BATS_TEST_TMPDIR/opt/lcars/var/tofu" "$LCARS_SERVICES_ENV"
  grep -qxF "TF_CLI_CONFIG_FILE=$BATS_TEST_TMPDIR/opt/lcars/tofu/tofurc" "$LCARS_SERVICES_ENV"
}

@test "l'uid du SIEGE traverse jusqu'a l'environnement des daemons" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  grep -qx 'LCARS_SYSADMIN_UID=1007' "$LCARS_SERVICES_ENV"
  refute grep -q 'LCARS_SYSADMIN_UID=1000' "$LCARS_SERVICES_ENV"
}

@test "l'uid du siege est POSE dans un fichier que le garde ne peut pas reecrire" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [ -f "$LCARS_SEAT_UID_FILE" ]
  [ "$(cat "$LCARS_SEAT_UID_FILE")" = "1007" ]
  [ "$(stat -c '%a' "$LCARS_SEAT_UID_FILE")" = "644" ]
}

@test "le check DERIVE quand le fichier de siege manque — le garde y retombe sur son litteral" {
  mod apply
  rm -f "$LCARS_SEAT_UID_FILE"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*seat\.uid absent'
}

@test "un fichier de siege qui CONTREDIT services.env est un ECHEC, pas une derive" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  echo 2008 > "$LCARS_SEAT_UID_FILE"
  mod check
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qE '^FAIL .*ne réservent pas le même uid'
}

@test "sans uid de siege, l'ecriture est ABANDONNEE — jamais tronquee" {
  unset LCARS_SYSADMIN_UID
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_SYSADMIN_UID non posé"* ]]
  [ ! -e "$LCARS_SERVICES_ENV" ]
}

@test "le check NOMME le siege qu'il reserve, au lieu de le supposer" {
  mod apply
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE "^OK .*siege : « $(id -un) » \(uid $(id -u)\)"
}

@test "un uid de siege que PERSONNE ne porte est un DRIFT — une garde qui ne garde rien" {
  export LCARS_SYSADMIN_UID=4294967294
  mod apply
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*ne correspond a AUCUN compte'
}

@test "un environnement SANS ligne de siege derive — le champ absent n'est pas un champ vert" {
  mod apply
  sed -i '/^LCARS_SYSADMIN_UID=/d' "$LCARS_SERVICES_ENV"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*aucun LCARS_SYSADMIN_UID'
}

@test "la landing demarre EN PREMIER PLAN — sinon systemd lit un service mort en une seconde" {
  mod apply
  grep -q -- "ExecStart=$LCARS_HELPERS_DIR/console-landing.sh --foreground" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q "^Restart=always$" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
}

@test "AUCUNE unite ne pose User= — la landing se depose ELLE-MEME, avec son groupe de console" {
  mod apply
  refute grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  refute grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-converger.service"
}

@test "daemon-reload passe AVANT enable — systemd sert l'unite qu'il a en memoire" {
  mod apply
  local reload enable
  reload="$(grep -n "daemon-reload" "$CALLS" | head -1 | cut -d: -f1)"
  enable="$(grep -n "enable --now" "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$reload" ]
  [ -n "$enable" ]
  [ "$reload" -lt "$enable" ]
}

@test "les deux services sont ACTIVES — ce sont l'infrastructure, pas un choix par humain (D11)" {
  mod apply
  grep -q -- "systemctl enable --now lcars-landing.service" "$CALLS"
  grep -q -- "systemctl enable --now lcars-converger.service" "$CALLS"
}

@test "un services.env changé relance les unités debout, même sans unité réécrite ; inchangé, rien n'est relancé" {
  mod apply
  : > "$CALLS"
  PROV_HUMANS_TEAM=equipage mod apply
  [ "$status" -eq 0 ]
  grep -q "LCARS_HUMANS_TEAM=equipage" "$LCARS_SERVICES_ENV"
  grep -q -- "systemctl try-restart lcars-landing.service" "$CALLS"
  grep -q -- "systemctl try-restart lcars-converger.service" "$CALLS"
  [[ "$output" == *"relancé sur l'unité ou l'environnement réécrit"* ]]
  : > "$CALLS"
  PROV_HUMANS_TEAM=equipage mod apply
  refute grep -q "try-restart" "$CALLS"
}

@test "une unité réécrite sous un service debout est relancée ; une unité neuve ou identique ne l'est pas" {
  mod apply
  refute grep -q "try-restart" "$CALLS"
  printf '[Unit]\nDescription=ancienne\n' > "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  : > "$CALLS"
  mod apply
  [ "$status" -eq 0 ]
  grep -q -- "systemctl try-restart lcars-landing.service" "$CALLS"
  [ "$(grep -c "try-restart" "$CALLS")" -eq 1 ]
  [[ "$output" == *"POSÉ  64-services: lcars-landing.service relancé sur l'unité ou l'environnement réécrit"* ]]
  echo 1 > "$ACTIVE"
  printf '[Unit]\nDescription=ancienne\n' > "$LCARS_SYSTEMD_DIR/lcars-converger.service"
  : > "$CALLS"
  mod apply
  refute grep -q "try-restart" "$CALLS"
}

@test "une relance qui ne laisse pas le service debout est dite, pas annoncée comme faite" {
  mod apply
  printf '[Unit]\nDescription=ancienne\n' > "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  : > "$RESTART_TUE"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN  64-services: lcars-landing.service : relance sur l'unité réécrite sans service debout derrière"* ]]
  [[ "$output" != *"relancé sur l'unité réécrite"* ]]
  [[ "$output" == *"FAIL  64-services: lcars-landing.service posé mais pas debout"* ]]
}

@test "rejoue : une unite deja identique n'est pas re-ecrite, donc pas de daemon-reload" {
  mod apply
  : > "$CALLS"
  mod apply
  refute grep -q "daemon-reload" "$CALLS"
}

@test "POSEE n'est pas DEBOUT : le check DERIVE sur une unite presente mais inactive" {
  mod apply
  echo 1 > "$ACTIVE"    # is-active : non
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"posé mais pas actif"* ]]
  [[ "$output" == *"personne ne peut entrer"* ]]
  [[ "$output" == *"personne ne sera enrôlé"* ]]
}

@test "check CONFORME quand les deux unites sont posees ET actives" {
  mod apply
  echo 0 > "$ACTIVE"    # is-active : oui
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"lcars-landing.service actif"* ]]
  [[ "$output" == *"lcars-converger.service actif"* ]]
}

@test "une unite modifiee A LA MAIN est un DRIFT — la source de verite est le module" {
  mod apply
  echo "# bricolage" >> "$LCARS_SYSTEMD_DIR/lcars-converger.service"
  echo 0 > "$ACTIVE"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-converger.service absente ou divergente"* ]]
}

@test "l'environnement ne REDIT pas les defauts de la lib — un littéral mort se lit comme une décision" {
  refute grep -qE 'LCARS_FORGE_ORG=\$\{PROV_FORGE_ORG:-' "$MOD"
  refute grep -qE 'LCARS_HUMANS_TEAM=\$\{PROV_HUMANS_TEAM:-' "$MOD"
  grep -q 'echo "LCARS_FORGE_ORG=\$PROV_FORGE_ORG"' "$MOD"
}

@test "le port du deck choisi atteint le DAEMON, pas seulement les callbacks OIDC" {
  export PROV_DECK_PORT=20997
  mod apply
  grep -qx 'LCARS_LANDING_PORT=20997' "$LCARS_SERVICES_ENV"
  grep -q 'sur :20997' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
}

@test "sans choix, le deck garde son port par defaut" {
  mod apply
  grep -qx 'LCARS_LANDING_PORT=20999' "$LCARS_SERVICES_ENV"
}

@test "un port arbitraire TRAVERSE jusqu'au fichier d'environnement" {
  export PROV_DECK_PORT=31337
  mod apply
  grep -qx 'LCARS_LANDING_PORT=31337' "$LCARS_SERVICES_ENV"
  refute grep -q '20999' "$LCARS_SERVICES_ENV"
}

@test "l'echec devient TERMINAL — sans borne, aucun observateur ne peut voir un service echouer" {
  mod apply
  grep -q '^StartLimitIntervalSec=' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$LCARS_SYSTEMD_DIR/lcars-converger.service"
}

@test "un service qui BOUCLE VRAIMENT (le compteur grimpe encore) fait echouer l'apply" {
  : > "$SPIN"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"redémarre en boucle"* ]]
}

@test "un service qui a REBONDI puis tient rend un apply vert — et le rebond est DIT" {
  : > "$LOOP"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"redémarrage(s)"* ]]
  refute_out 'redémarre en boucle' <<<"$output"
}

@test "un service stable ET actif rend un apply vert" {
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"activé et debout"* ]]
}

@test "un service pose mais MORT fait echouer l'apply" {
  echo 1 > "$ACTIVE"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas debout"* ]]
}

@test "un port DEJA PRIS se dit, et nomme --port-deck" {
  python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(120)
' "$BATS_TEST_TMPDIR/port" &
  local squatter=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.2; done
  [ -s "$BATS_TEST_TMPDIR/port" ]

  export PROV_DECK_PORT
  PROV_DECK_PORT="$(cat "$BATS_TEST_TMPDIR/port")"
  : > "$SPIN"   # une VRAIE boucle : ces deux temoins veulent atteindre `loop_hint`
  mod apply
  kill "$squatter" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"le port $PROV_DECK_PORT est déjà pris"* ]]
  [[ "$output" == *"--port-deck"* ]]
}

@test "une unite qui n'ecoute sur rien renvoie au journal, pas au port" {
  : > "$SPIN"   # une VRAIE boucle : ces deux temoins veulent atteindre `loop_hint`
  mod apply
  [[ "$output" == *"lcars-converger.service redémarre en boucle — « journalctl"* ]]
  [[ "$output" != *"lcars-converger.service redémarre en boucle — le port"* ]]
}

stub_converger() { # stub_converger <rc> [<ligne passwd a creer>…]
  export LCARS_HUMAN_CONVERGER="$BATS_TEST_TMPDIR/conv.sh"
  CONV_ENV="$BATS_TEST_TMPDIR/conv.env"
  local rc="$1"; shift
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "env | sort > '$CONV_ENV'"
    printf '%s\n' "printf 'ARGS=%s\\n' \"\$*\" >> '$CONV_ENV'"
    local l; for l in "$@"; do printf '%s\n' "printf '%s\\n' '$l' >> '$PASSWD_FILE'"; done
    printf '%s\n' "exit $rc"
  } > "$LCARS_HUMAN_CONVERGER"
  chmod 0755 "$LCARS_HUMAN_CONVERGER"
}

humans_are() {
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$PASSWD_FILE"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$PASSWD_FILE"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$PASSWD_FILE"; done
  export LCARS_SYSADMIN_UID=1000
}

absent_de_l_env() { # absent_de_l_env <motif ancre>
  if grep -q "$1" "$CONV_ENV"; then
    echo "FUITE : « $1 » present dans l'environnement de la passe, alors que le daemon ne l'aura jamais"
    return 1
  fi
  return 0
}

@test "convergeur ABSENT : on le DIT, et ce n'est pas un echec d'apply" {
  humans_are
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"convergeur d'humains absent"* ]]
}

@test "la passe est TIREE UNE FOIS, en --once — pas un daemon de plus" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [ -f "$CONV_ENV" ]
  grep -qx 'ARGS=--once' "$CONV_ENV"
}

@test "L'ENVIRONNEMENT DE LA PASSE EST CELUI DU DAEMON, PAS CELUI DE L'APPLY" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  grep -q '^LCARS_HUMANS_TEAM=' "$CONV_ENV"
  grep -q '^FORGE_BASE_URL=http://127.0.0.1:3000$' "$CONV_ENV"
  absent_de_l_env '^PROV_TOKENS_DIR='
  absent_de_l_env '^PROV_SUBSTRATE='
}

@test "un humain CREE PAR CETTE PASSE est annonce comme tel, et compte comme une mutation" {
  humans_are
  stub_converger 0 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  mod apply
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^POSÉ .*matérialisé\(s\) par cette passe : lcars'
}

@test "un humain DEJA LA n'est pas annonce comme cree — le cas du RE-ROLL" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"par cette passe : "* ]]
  printf '%s\n' "$output" | grep -qE '^OK .*déjà présent\(s\) : lcars'
  printf '%s\n' "$output" | refute_out '^POSÉ .*(déjà présent|lcars.*matérialis)'
}

@test "AUCUN humain a materialiser : la team vide est DITE, et ce n'est pas une derive" {
  humans_are
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun humain à matérialiser"* ]]
  [[ "$output" != *"WARN"*"aucun humain"* ]]
  [[ "$output" != *"DRIFT"*"aucun humain à matérialiser"* ]]
  [[ "$output" != *"pré-sème"* ]]
}

@test "un environnement de services NON POSE arrete l'apply AVANT la passe — pas de garde en double" {
  humans_are
  stub_converger 0
  rm -rf "$BATS_TEST_TMPDIR/etc/lcars"
  : > "$BATS_TEST_TMPDIR/etc/lcars"
  mod apply
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/conv.env" ]
}

@test "check SANS systemd sonde quand meme la population — le cas exact du conteneur" {
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  container_services_present
  mod check
  [[ "$output" == *"aucun humain de fleet sur cette machine"* ]]
  [[ "$output" == *"fleet start"* ]]
}

@test "check SANS systemd et SANS humain : la sonde DIT l'absence sans la compter comme derive" {
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  container_services_present
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^WARN .*aucun humain de fleet sur cette machine'
}

container_services_present() {
  local d="$BATS_TEST_TMPDIR/helpers" p
  mkdir -p "$d"
  for p in supervise.sh console-landing.sh human-converger.sh catalogue-executor.py privileged-executor.py; do
    printf '#!/bin/sh\n' > "$d/$p"
    chmod 0755 "$d/$p"
  done
  export LCARS_HELPERS_DIR="$d" LCARS_SUPERVISE_BIN="$d/supervise.sh"
}

@test "check SANS systemd et AVEC un humain : la sonde le nomme et ne derive pas" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  container_services_present
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^OK .*humain\(s\) de fleet sur cette machine : lcars'
}

@test "rc 2 (configuration absente) : DRIFT residuel, JAMAIS un echec d'apply" {
  humans_are
  stub_converger 2
  mod apply
  [ "$status" -eq 2 ]     # apply : 2 = applique, drift residuel — PAS 1
  [[ "$output" == *"configuration absente"* ]]
}

@test "rc 1 (dependance absente) : DRIFT residuel aussi — le daemon reessaiera" {
  humans_are
  stub_converger 1
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"journalctl"* ]]
}

@test "un rc INATTENDU reste un echec entier — la tolerance est bornee, pas generale" {
  humans_are
  stub_converger 7
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "unit_body sur une unite INCONNUE rend 1 sans rien ecrire — et l'apply capture ce rc" {
  eval "$(sed -n '/^unit_body()/,/^}/p' "$MOD")"
  run unit_body lcars-nexistepas
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -vE '^[[:space:]]*#' "$MOD" | grep -qE 'body="\$\(unit_body "\$u"\)"'
  grep -vE '^[[:space:]]*#' "$MOD" | grep -qE 'write_atomic "\$\(unit_path "\$u"\)" [^<]*<<<"\$body"'
}

@test "forge_url : sans forge.url, vide et 0 — une adresse pas encore annoncee n'est pas un echec" {
  eval "$(sed -n '/^forge_url()/,/^}/p' "$MOD")"
  PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  run forge_url
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$PROV_TOKENS_DIR"; printf 'http://forge.test:3000\n' > "$PROV_TOKENS_DIR/forge.url"
  run forge_url
  [ "$status" -eq 0 ]
  [ "$output" = "http://forge.test:3000" ]
}

@test "check : un services.env illisible ne rend pas « aucun LCARS_SYSADMIN_UID » — non sondable, dit sans drift" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : l'illisible ne se joue pas ici"
  mod apply
  chmod 0000 "$LCARS_SERVICES_ENV"
  mod check
  chmod 0640 "$LCARS_SERVICES_ENV"
  [[ "$output" == *"WARN  64-services: LCARS_SYSADMIN_UID non sondable — $LCARS_SERVICES_ENV"* ]]
  [[ "$output" != *"aucun LCARS_SYSADMIN_UID"* ]]
}

@test "probe_seat_uid : services.env ABSENT est une derive DITE, pas une mort de sed sous pipefail" {
  run bash -c 'set -euo pipefail; export PROVISION_MODULE=64-services; source "$PROVISION_LIB"
    SERVICES_ENV="$1"; SEAT_UID_FILE=/nonexistent/seat.uid
    eval "$(sed -n "/^probe_seat_uid()/,/^}/p" "$2")"; probe_seat_uid' _ "$BATS_TEST_TMPDIR/absent/services.env" "$MOD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"*"LCARS_SYSADMIN_UID"* ]]
}

@test "WSL sans systemd ACTIF : on ne cherche pas un superviseur de conteneur" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  PROV_SUBSTRATE=wsl mod check
  [[ "$output" == *"pas de systemd"* ]]
  [[ "$output" != *"superviseur"* ]]
}

@test "TEMOIN DU TEMOIN : sur DOCKER, c'est bien le superviseur qu'on regarde" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  PROV_SUBSTRATE=docker mod check
  [[ "$output" == *"superviseur"* ]]
}

@test "un service qui ne monte pas PORTE sa cause — il ne renvoie pas a un second geste" {
  local code; code="$(grep -vE '^\s*#' "$MOD")"
  grep -q 'p_fail "$u.service redémarre en boucle — $(loop_hint' <<<"$code"
  grep -q 'p_fail "$u.service posé mais pas debout$(unit_cause' <<<"$code"
  refute grep -q 'pas debout — « \$SYSTEMCTL status' <<<"$code"
  local corps; corps="$(sed -n '/^unit_cause()/,/^}/p' "$MOD")"
  grep -q 'loop_hint' <<<"$corps"
  grep -q '|| true' <<<"$corps"
}

@test "sans systemd, seat.uid et services.env sont POSES quand meme — seules les unites s'abstiennent" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ "$(cat "$LCARS_SEAT_UID_FILE")" = "1007" ]
  grep -q '^LCARS_SYSADMIN_UID=1007$' "$LCARS_SERVICES_ENV"
  [ ! -e "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
}
