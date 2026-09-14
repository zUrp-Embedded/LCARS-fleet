#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench/bench-swap-image.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: témoins de bench-swap-image.sh — joué contre une doublure docker : projet, drapeaux, override de banc, verdicts

load ../../refute
load ../../support/decor

setup() {
  decor_pose
  # un arbre dont les constantes portent des défauts que rien d'autre n'écrit : le script qui les rend les a lus
  local vrai="$BATS_TEST_DIRNAME/../../.." cles='PROV_FORGE_BASE_DEFAULT|PROV_FORGE_ORG_DEFAULT|PROV_FORGE_HOST_PORT_DEFAULT|PROV_DECK_PORT_DEFAULT|PROV_SSH_PORT_DEFAULT|PROV_FORGE_INTERNAL_URL'
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/docker/bench" "$ARBRE/deploy/lib"
  cp "$vrai/docker/bench/bench-swap-image.sh" "$ARBRE/deploy/docker/bench/"
  cp "$vrai/lib/provision-lib.sh" "$vrai/lib/docker-endpoint.sh" "$vrai/lib/forge-bootstrap.sh" "$ARBRE/deploy/lib/"
  CONSTANTES="$ARBRE/deploy/installer-constants.env"
  { grep -vE "^($cles)=" "$vrai/installer-constants.env"
    printf '%s\n' PROV_FORGE_BASE_DEFAULT=banc-temoin PROV_FORGE_ORG_DEFAULT=flotte-temoin PROV_FORGE_HOST_PORT_DEFAULT=4100 \
      PROV_DECK_PORT_DEFAULT=4999 PROV_SSH_PORT_DEFAULT=4222 PROV_FORGE_INTERNAL_URL=http://forge-temoin:3000
  } > "$CONSTANTES"
  SUT="$ARBRE/deploy/docker/bench/bench-swap-image.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export NETWORKS="banc-temoin-forge_default bt-forge_default"
  export TOKENS_TAR="$BATS_TEST_TMPDIR/tokens.tar" CREDS_TAR="$BATS_TEST_TMPDIR/creds.tar"
  mkdir -p "$BATS_TEST_TMPDIR/t/tokens"; : > "$BATS_TEST_TMPDIR/t/tokens/fleet_engineer.gitea_token"
  tar -C "$BATS_TEST_TMPDIR/t" -cf "$TOKENS_TAR" tokens
  printf 'CREDS' > "$BATS_TEST_TMPDIR/t/.credentials.json"
  tar -C "$BATS_TEST_TMPDIR/t" -cf "$CREDS_TAR" .credentials.json

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
[[ -p /dev/stdin || -f /dev/stdin ]] && cat > /dev/null
echo "DOCKER:$*" >> "$CALLS"
case "$*" in
  "network inspect "*) [[ " $NETWORKS " == *" $3 "* ]]; exit ;;
  *" create lcars")    env | grep '^LCARS_\|^FORGE_' | sort | sed 's/^/ENV:/' >> "$CALLS"; exit 0 ;;
  "inspect -f {{.State.Health.Status}}"*) echo healthy; exit 0 ;;
  "cp "*":/opt/lcars/var/tokens -")        cat "$TOKENS_TAR"; exit 0 ;;
  "cp "*"credentials.json -")              cat "$CREDS_TAR"; exit 0 ;;
  "inspect -f {{range .Config.Env}}"*)     echo "LCARS_IMAGE_REVISION=cafe1234"; exit 0 ;;
esac
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"
  export PATH="$BINDIR:$PATH" DOCKER_BIN=dockerstub
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.claude"; printf 'CREDS' > "$HOME/.claude/.credentials.json"
}

run_swap() { run bash "$SUT" --image lcars-fleet:neuve --advertise 10.0.0.9 "$@"; }

@test "sans --image : refus en 1, et le conteneur n'est pas touché" {
  run bash "$SUT" --advertise 10.0.0.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"--image est obligatoire"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
}

@test "le projet par défaut est la base des constantes, celle que « container --bench » et install.sh créent" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'DOCKER:network inspect banc-temoin-forge_default' "$CALLS"
  grep -qx 'DOCKER:rm -f banc-temoin-fleet-lcars-1' "$CALLS"
}

@test "sans drapeau, ports et forge interne viennent des constantes, et arrivent dans l'environnement de compose" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENV:LCARS_SSH_PORT=0.0.0.0:4222' "$CALLS"
  grep -qx 'ENV:LCARS_LANDING_PORT_BIND=0.0.0.0:4999' "$CALLS"
  grep -qx 'ENV:FORGE_PUBLIC_URL=http://10.0.0.9:4100' "$CALLS"
  grep -qx 'ENV:FORGE_BASE_URL=http://forge-temoin:3000' "$CALLS"
  grep -qx 'ENV:LCARS_SOURCE_REMOTE=http://forge-temoin:3000/flotte-temoin/lcars.git' "$CALLS"
}

@test "les drapeaux de container et de bench-up sont acceptés, et arrivent dans l'environnement de compose" {
  run_swap --forge-project bt --port-forge 31000 --port-deck 30999 --port-ssh 3222 --bind 127.0.0.1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENV:LCARS_SSH_PORT=127.0.0.1:3222' "$CALLS"
  grep -qx 'ENV:LCARS_LANDING_PORT_BIND=127.0.0.1:30999' "$CALLS"
  grep -qx 'ENV:FORGE_PUBLIC_URL=http://10.0.0.9:31000' "$CALLS"
  grep -qx 'ENV:LCARS_DECK_ORIGINS=http://10.0.0.9:30999' "$CALLS"
  grep -qx 'ENV:LCARS_DEVFORGE_NETWORK=bt-forge_default' "$CALLS"
  grep -qx 'ENV:LCARS_STORE_PREFIX=bt-fleet' "$CALLS"
  refute grep -q '^ENV:LCARS_BIND=' "$CALLS"
}

@test "le conteneur est recréé avec les constantes et l'override de banc : bench-down et container le reconnaissent encore" {
  run_swap --forge-project bt
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxE "DOCKER:compose --env-file [^ ]+ -f $ARBRE/deploy/docker/docker-compose.yml -f $ARBRE/deploy/docker/docker-compose.bench.yml -p bt-fleet create lcars" "$CALLS"
  grep -qxE "DOCKER:compose --env-file [^ ]+ -f $ARBRE/deploy/docker/docker-compose.yml -f $ARBRE/deploy/docker/docker-compose.bench.yml -p bt-fleet start lcars" "$CALLS"
  local f
  for f in $(grep -oE '^DOCKER:compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$CONSTANTES" ]
  done
  refute grep -q '^DOCKER:network connect' "$CALLS"
}

@test "pas de réseau de forge : pas de banc, refus en 1 avant de détruire le conteneur" {
  run_swap --forge-project absent
  [ "$status" -eq 1 ]
  [[ "$output" == *"réseau absent-forge_default absent"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
}

@test "aucun jeton de rôle après la relance : sortie 6" {
  mkdir -p "$BATS_TEST_TMPDIR/vide/tokens"; tar -C "$BATS_TEST_TMPDIR/vide" -cf "$TOKENS_TAR" tokens
  run_swap
  [ "$status" -eq 6 ]
  [[ "$output" == *"aucun jeton de rôle"* ]]
}

@test "le récapitulatif lit jetons, credentials et révision par cp et inspect" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"image     : lcars-fleet:neuve   (révision cafe1234)"* ]]
  # sous un décor, le dossier des jetons lu dans le conteneur reste son chemin canonique
  [[ "$output" == *"jetons    : 1 fichiers dans /opt/lcars/var/tokens"$'\n'* ]]
  [[ "$output" == *"creds     : oui"* ]]
}

@test "--no-creds : rien n'est lu ni posé, et le récapitulatif dit non" {
  : > "$CREDS_TAR"
  run_swap --no-creds --creds-from "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"credentials non posées (--no-creds)"*"creds     : non"* ]]
  refute grep -q 'mkdir -p ~/.claude' "$CALLS"
}

@test "la taille des credentials se lit au champ 3 du listing tar" {
  printf '%0.s.' $(seq 1 509) > "$BATS_TEST_TMPDIR/.credentials.json"
  run bash -c "tar -C '$BATS_TEST_TMPDIR' -cf - .credentials.json | tar -tv | awk 'NR==1 {print \$3}'"
  [ "$status" -eq 0 ]
  [ "$output" = "509" ]
}

@test "les trois scripts de banc dérivent le préfixe du magasin du projet du conteneur" {
  local d="$BATS_TEST_DIRNAME/../../../docker/bench" f
  for f in bench-up.sh bench-down.sh bench-swap-image.sh; do
    grep -qE '^export LCARS_STORE_PREFIX="\$CONTAINER_PROJECT"$' "$d/$f" \
      || { echo "$f ne dérive pas le préfixe de \$CONTAINER_PROJECT" >&2; false; }
    grep -qE '^CONTAINER_PROJECT="\$\{PROJECT\}-fleet"$' "$d/$f" \
      || { echo "$f ne dérive pas CONTAINER_PROJECT de la base \$PROJECT" >&2; false; }
  done
}
