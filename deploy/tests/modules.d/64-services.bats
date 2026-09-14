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
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=64-services
  decor_pose
  UNITDIR="$LCARS_DECOR_ROOT/etc/systemd/system"
  ENVF="$LCARS_DECOR_ROOT/etc/lcars/services.env"
  SEAT="$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
  HELPERS="$LCARS_DECOR_ROOT/opt/lcars"
  export LCARS_SERVICES_SETTLE=0
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export LCARS_SYSADMIN_UID
  LCARS_SYSADMIN_UID="$(id -u)"
  PASSWD_FILE="$LCARS_DECOR_ROOT/etc/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s::%s:/bin/bash\nzoe:x:4242:4242::/home/zoe:/bin/bash\n' \
    "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" > "$PASSWD_FILE"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  mkdir -p "$UNITDIR"
  echo "http://127.0.0.1:3000" > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge.url"

  BINDIR="$DECOR_BIN"
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
  # systemd est l'init du décor : /run/systemd/system existe
  SYSTEMD_RUN="$LCARS_DECOR_ROOT/run/systemd/system"; mkdir -p "$SYSTEMD_RUN"
  chmod 0755 "$BINDIR/systemctl"
}

mod() { run bash "$MOD" "$1"; }
sans_systemd() { rm -rf "$SYSTEMD_RUN"; }

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
  sans_systemd
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ ! -e "$UNITDIR/lcars-landing.service" ]
}

@test "apply POSE les deux unites et l'environnement" {
  mod apply
  [ -f "$UNITDIR/lcars-landing.service" ]
  [ -f "$UNITDIR/lcars-converger.service" ]
  [ -s "$ENVF" ]
  grep -q "^FORGE_BASE_URL=http://127.0.0.1:3000$" "$ENVF"
}

@test "l'environnement porte ce qu'un DAEMON ne peut pas heriter" {
  mod apply
  grep -q "^LCARS_FORGE_ORG=" "$ENVF"
  grep -q "^LCARS_HUMANS_TEAM=" "$ENVF"
  refute grep -q "^PROV_" "$ENVF"
}

@test "l'exécuteur de catalogue reçoit le dossier de travail tofu et le miroir de providers que 25 et 46 posent" {
  mod apply
  grep -qxF "LCARS_CATALOGUES_WORK=$LCARS_DECOR_ROOT/opt/lcars/var/tofu" "$ENVF"
  grep -qxF "TF_CLI_CONFIG_FILE=$LCARS_DECOR_ROOT/opt/lcars/tofu/tofurc" "$ENVF"
}

@test "les daemons reçoivent la racine du magasin de la constante — sans elle, le produit retombe sur un défaut à lui" {
  mod apply
  [ "$status" -eq 0 ]
  grep -qxF "LCARS_STORE_ROOT=$LCARS_DECOR_ROOT/var/lib/lcars" "$ENVF"
}

@test "l'uid du SIEGE traverse jusqu'a l'environnement des daemons" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  grep -qx 'LCARS_SYSADMIN_UID=1007' "$ENVF"
  refute grep -q 'LCARS_SYSADMIN_UID=1000' "$ENVF"
}

@test "l'uid du siege est POSE dans un fichier que le garde ne peut pas reecrire" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [ -f "$SEAT" ]
  [ "$(cat "$SEAT")" = "1007" ]
  [ "$(stat -c '%a' "$SEAT")" = "644" ]
}

@test "le check DERIVE quand le fichier de siege manque — le garde y retombe sur son litteral" {
  mod apply
  rm -f "$SEAT"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*seat\.uid absent'
}

@test "un fichier de siege qui CONTREDIT services.env est un ECHEC, pas une derive" {
  export LCARS_SYSADMIN_UID=1007
  mod apply
  echo 2008 > "$SEAT"
  mod check
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qE '^FAIL .*ne réservent pas le même uid'
}

@test "sans uid de siege, l'ecriture est ABANDONNEE — jamais tronquee" {
  unset LCARS_SYSADMIN_UID
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_SYSADMIN_UID non posé"* ]]
  [ ! -e "$ENVF" ]
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
  sed -i '/^LCARS_SYSADMIN_UID=/d' "$ENVF"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*aucun LCARS_SYSADMIN_UID'
}

@test "la landing demarre EN PREMIER PLAN — sinon systemd lit un service mort en une seconde" {
  mod apply
  grep -q -- "ExecStart=$HELPERS/console-landing.sh --foreground" "$UNITDIR/lcars-landing.service"
  grep -q "^Restart=always$" "$UNITDIR/lcars-landing.service"
}

@test "AUCUNE unite ne pose User= — la landing se depose ELLE-MEME, avec son groupe de console" {
  mod apply
  refute grep -q "^User=" "$UNITDIR/lcars-landing.service"
  refute grep -q "^User=" "$UNITDIR/lcars-converger.service"
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
  PROV_FORGE_ORG=equipage mod apply
  [ "$status" -eq 0 ]
  grep -q "LCARS_FORGE_ORG=equipage" "$ENVF"
  grep -q -- "systemctl try-restart lcars-landing.service" "$CALLS"
  grep -q -- "systemctl try-restart lcars-converger.service" "$CALLS"
  [[ "$output" == *"relancé sur l'unité ou l'environnement réécrit"* ]]
  : > "$CALLS"
  PROV_FORGE_ORG=equipage mod apply
  refute grep -q "try-restart" "$CALLS"
}

@test "une unité réécrite sous un service debout est relancée ; une unité neuve ou identique ne l'est pas" {
  mod apply
  refute grep -q "try-restart" "$CALLS"
  printf '[Unit]\nDescription=ancienne\n' > "$UNITDIR/lcars-landing.service"
  : > "$CALLS"
  mod apply
  [ "$status" -eq 0 ]
  grep -q -- "systemctl try-restart lcars-landing.service" "$CALLS"
  [ "$(grep -c "try-restart" "$CALLS")" -eq 1 ]
  [[ "$output" == *"POSÉ  64-services: lcars-landing.service relancé sur l'unité ou l'environnement réécrit"* ]]
  echo 1 > "$ACTIVE"
  printf '[Unit]\nDescription=ancienne\n' > "$UNITDIR/lcars-converger.service"
  : > "$CALLS"
  mod apply
  refute grep -q "try-restart" "$CALLS"
}

@test "une relance qui ne laisse pas le service debout est dite, pas annoncée comme faite" {
  mod apply
  printf '[Unit]\nDescription=ancienne\n' > "$UNITDIR/lcars-landing.service"
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
  echo "# bricolage" >> "$UNITDIR/lcars-converger.service"
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
  grep -qx 'LCARS_LANDING_PORT=20997' "$ENVF"
  grep -q 'sur :20997' "$UNITDIR/lcars-landing.service"
}

@test "sans choix, le deck garde son port par defaut" {
  mod apply
  grep -qx 'LCARS_LANDING_PORT=20999' "$ENVF"
}

@test "un port arbitraire TRAVERSE jusqu'au fichier d'environnement" {
  export PROV_DECK_PORT=31337
  mod apply
  grep -qx 'LCARS_LANDING_PORT=31337' "$ENVF"
  refute grep -q '20999' "$ENVF"
}

@test "l'echec devient TERMINAL — sans borne, aucun observateur ne peut voir un service echouer" {
  mod apply
  grep -q '^StartLimitIntervalSec=' "$UNITDIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$UNITDIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$UNITDIR/lcars-converger.service"
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

stub_converger() { # stub_converger <rc> [<ligne passwd a creer>…] — le convergeur à sa place sous la racine
  local conv="$HELPERS/human-converger.sh"
  mkdir -p "$HELPERS"
  CONV_ENV="$BATS_TEST_TMPDIR/conv.env"
  local rc="$1"; shift
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "env | sort > '$CONV_ENV'"
    printf '%s\n' "printf 'ARGS=%s\\n' \"\$*\" >> '$CONV_ENV'"
    local l; for l in "$@"; do printf '%s\n' "printf '%s\\n' '$l' >> '$PASSWD_FILE'"; done
    printf '%s\n' "exit $rc"
  } > "$conv"
  chmod 0755 "$conv"
}

humans_are() {
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
  rm -rf "$LCARS_DECOR_ROOT/etc/lcars"
  : > "$LCARS_DECOR_ROOT/etc/lcars"
  mod apply
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/conv.env" ]
}

@test "check SANS systemd sonde quand meme la population — le cas exact du conteneur" {
  humans_are
  sans_systemd
  container_services_present
  mod check
  [[ "$output" == *"aucun humain de fleet sur cette machine"* ]]
  [[ "$output" == *"fleet start"* ]]
}

@test "check SANS systemd et SANS humain : la sonde DIT l'absence sans la compter comme derive" {
  humans_are
  sans_systemd
  container_services_present
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^WARN .*aucun humain de fleet sur cette machine'
}

container_services_present() { # le superviseur et les programmes qu'il tient, sous la racine
  local p
  mkdir -p "$HELPERS"
  for p in supervise.sh console-landing.sh human-converger.sh catalogue-executor.py privileged-executor.py; do
    printf '#!/bin/sh\n' > "$HELPERS/$p"
    chmod 0755 "$HELPERS/$p"
  done
}

@test "check SANS systemd et AVEC un humain : la sonde le nomme et ne derive pas" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  sans_systemd
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
  PROV_FORGE_URL_FILE="$BATS_TEST_TMPDIR/tokens/forge.url"
  run forge_url
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$BATS_TEST_TMPDIR/tokens"; printf 'http://forge.test:3000\n' > "$PROV_FORGE_URL_FILE"
  run forge_url
  [ "$status" -eq 0 ]
  [ "$output" = "http://forge.test:3000" ]
}

@test "check : un services.env illisible ne rend pas « aucun LCARS_SYSADMIN_UID » — non sondable, dit sans drift" {
  # joué par un compte qui ne lit pas un 0000
  [ "$(id -u)" -ne 0 ]
  mod apply
  chmod 0000 "$ENVF"
  mod check
  chmod 0640 "$ENVF"
  [[ "$output" == *"WARN  64-services: LCARS_SYSADMIN_UID non sondable — $ENVF"* ]]
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
  sans_systemd
  PROV_SUBSTRATE=wsl mod check
  [[ "$output" == *"pas de systemd"* ]]
  [[ "$output" != *"superviseur"* ]]
}

@test "TEMOIN DU TEMOIN : sur DOCKER, c'est bien le superviseur qu'on regarde" {
  sans_systemd
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
  sans_systemd
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ "$(cat "$SEAT")" = "1007" ]
  grep -q '^LCARS_SYSADMIN_UID=1007$' "$ENVF"
  [ ! -e "$UNITDIR/lcars-landing.service" ]
}
