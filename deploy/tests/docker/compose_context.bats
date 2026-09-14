#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/docker/compose_context.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: bats tests for les compose et le Dockerfile — l'image vient de pack.sh, et chaque compose se lit avec les constantes de l'installeur

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  CF="$DOCKER/docker-compose.yml"
  DF="$DOCKER/Dockerfile"
  [ -f "$CF" ]
  [ -f "$DF" ]
  # des valeurs que rien d'autre n'écrit : un compose qui les rend les a lues dans le fichier donné
  CONST="$BATS_TEST_TMPDIR/installer-constants.env"
  local cles='PROV_STORE_ROOT|PROV_SSH_PORT_DEFAULT|PROV_DECK_PORT_DEFAULT|PROV_FORGE_INTERNAL_URL|PROV_RUNNER_LABELS'
  { grep -vE "^($cles)=" "$DOCKER/../installer-constants.env"
    printf '%s\n' PROV_STORE_ROOT=/srv/magasin-temoin PROV_SSH_PORT_DEFAULT=4222 PROV_DECK_PORT_DEFAULT=4999 \
      PROV_FORGE_INTERNAL_URL=http://forge-temoin:3000 PROV_RUNNER_LABELS=shell:docker://alpine:temoin
  } > "$CONST"
}

# compose rend le fichier sans daemon : aucune adresse de daemon ne répond, et l'environnement de
# l'appelant ne fournit rien que le cas ne pose
rendu() { env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" "$@"; }

@test "le compose n'a AUCUN bloc build: — l'image se nomme (image:), elle vient de pack.sh" {
  refute grep -qE '^\s*build:' "$CF"
  refute grep -qE '^\s*context:' "$CF"
  refute grep -qE '^\s*dockerfile:' "$CF"
  grep -qE '^\s*image:' "$CF"
}

@test "le Dockerfile ne copie QUE le contexte entier vers /src — le kit, tel que pack.sh le scelle" {
  local copies; copies="$(grep -vE '^\s*#' "$DF" | grep -E '^COPY ' | grep -v -- '--from=')"
  [ "$(grep -c . <<<"$copies")" -eq 1 ]
  grep -qE '^COPY --chown=builder:builder \. /src/lcars_install$' <<<"$copies"
  # et pack.sh batit bien depuis le stage du kit, avec ce Dockerfile
  local pk="$BATS_TEST_DIRNAME/../../pack.sh"
  grep -qE -- '-f "\$STAGE/\$ROOT/deploy/docker/Dockerfile"' "$pk"
  grep -qE '"\$STAGE/\$ROOT" \\$' "$pk"
}

@test "docker-compose.yml publie ses ports par défaut et monte le magasin d'après les constantes" {
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$CF" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local j="$output"
  [ "$(jq -c '[.services.lcars.ports[] | [.host_ip, .published, .target]]' <<<"$j")" = '[["127.0.0.1","4222",22],["127.0.0.1","4999",4999]]' ]
  [ "$(jq -r '.services.lcars.environment.LCARS_STORE_ROOT' <<<"$j")" = /srv/magasin-temoin ]
  [ "$(jq -c '[.services.lcars.volumes[] | select(.source | startswith("lcars-cache", "lcars-toolchains", "lcars-sysroots", "lcars-state")) | .target]' <<<"$j")" \
    = '["/srv/magasin-temoin/cache","/srv/magasin-temoin/toolchains","/srv/magasin-temoin/sysroots","/srv/magasin-temoin/state"]' ]
}

@test "docker-compose.yml sans le fichier de constantes est refusé, et le refus nomme la variable" {
  run rendu LCARS_STORE_PREFIX=p docker compose -f "$CF" -p p config -q
  [ "$status" -ne 0 ]
  # compose interpole dans un ordre qui change d'un appel à l'autre : la variable nommée est l'une des constantes
  local nommee; nommee="$(grep -oE 'PROV_[A-Z_]+ absent' <<<"$output" | head -n1)"
  [ -n "$nommee" ] || { echo "$output"; return 1; }
  grep -q "^${nommee% absent}=" "$DOCKER/../installer-constants.env"
}

@test "forge-compose.yml rend ROOT_URL sur l'adresse interne des constantes quand LCARS_DEVFORGE_ROOT_URL manque" {
  run rendu docker compose --env-file "$CONST" -f "$DOCKER/forge-compose.yml" -p f config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.gitea.environment.GITEA__server__ROOT_URL' <<<"$output")" = http://forge-temoin:3000/ ]
}

@test "runner-compose.yml rend les labels des constantes quand LCARS_RUNNER_LABELS manque" {
  run rendu LCARS_FORGE_URL=http://f.invalid docker compose --env-file "$CONST" -f "$DOCKER/runner-compose.yml" -p r config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_RUNNER_LABELS' <<<"$output")" = shell:docker://alpine:temoin ]
}

@test "l'override des secrets exige ses deux chemins, et monte ceux qu'on lui donne" {
  local base=(docker compose --env-file "$CONST" -f "$CF" -f "$DOCKER/docker-compose.secrets.yml" -p p config)
  run rendu LCARS_STORE_PREFIX=p LCARS_CONTAINER_MASTER_TOKEN=/s/maitre "${base[@]}" -q
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_CONTAINER_SEED absent"* ]]
  run rendu LCARS_STORE_PREFIX=p LCARS_CONTAINER_SEED=/s/graine "${base[@]}" -q
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_CONTAINER_MASTER_TOKEN absent"* ]]
  run rendu LCARS_STORE_PREFIX=p LCARS_CONTAINER_MASTER_TOKEN=/s/maitre LCARS_CONTAINER_SEED=/s/graine "${base[@]}" --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.secrets.forge_master_token.file, .secrets.forge_seed_password.file]' <<<"$output")" = '["/s/maitre","/s/graine"]' ]
}
