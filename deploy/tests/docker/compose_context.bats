#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/compose_context.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: bats tests for les compose — chacun rendu par docker compose avec les constantes de l'installeur, sans daemon

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  CF="$DOCKER/docker-compose.yml"
  [ -f "$CF" ]
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

@test "le compose nomme son image et ne la bâtit pas : elle vient de pack.sh" {
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$CF" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.services[] | select(has("build") and .build != null)] | length' <<<"$output")" = 0 ]
  [ -n "$(jq -r '.services.lcars.image // empty' <<<"$output")" ]
}

@test "le magasin : chaque nature de store.sh est un volume externe au nom du projet, monté sous la racine des constantes — sans préfixe, compose refuse en le nommant" {
  # shellcheck source=../../lib/store.sh
  source "$DOCKER/../lib/store.sh"
  [ "${#LCARS_STORE_TREES[@]}" -ge 3 ]
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$CF" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local j="$output" n
  # externe : un down -v ne l'emporte pas ; au préfixe : deux instances ne partagent pas de magasin
  [ "$(jq '[.volumes[] | select(.external == true)] | length' <<<"$j")" -eq "${#LCARS_STORE_TREES[@]}" ]
  for n in "${LCARS_STORE_TREES[@]}"; do
    [ "$(jq -c --arg k "lcars-$n" '.volumes[$k] | [.external, .name]' <<<"$j")" = "[true,\"p-$n\"]" ] || { echo "nature $n : $(jq -c --arg k "lcars-$n" '.volumes[$k]' <<<"$j")"; return 1; }
    [ "$(jq -r --arg k "lcars-$n" '.services.lcars.volumes[] | select(.source == $k) | .target' <<<"$j")" = "/srv/magasin-temoin/$n" ]
  done
  run rendu docker compose --env-file "$CONST" -f "$CF" -p p config -q
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_STORE_PREFIX absent"* ]]
}

@test "le conteneur reçoit SYS_ADMIN sous le profil seccomp durci, jamais sans confinement — et un seul compose le porte" {
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$CF" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '.services.lcars.cap_add' <<<"$output")" = '["SYS_ADMIN"]' ]
  jq -r '.services.lcars.security_opt[]' <<<"$output" | grep -qx 'seccomp=./lcars-hardened-seccomp.json'
  jq -r '.services.lcars.security_opt[]' <<<"$output" | refute_out '^seccomp=unconfined$'
  [ -f "$DOCKER/lcars-hardened-seccomp.json" ]
  # bench et secrets sont des surcouches : aucun autre compose ne déclare le service
  local c porteurs=0
  for c in "$DOCKER"/*compose*.yml; do
    run rendu LCARS_STORE_PREFIX=p LCARS_BENCH_BASE=b LCARS_DEVFORGE_NETWORK=n LCARS_CONTAINER_MASTER_TOKEN=/m LCARS_CONTAINER_SEED=/s \
      LCARS_RUNNER_NETWORK=n docker compose --env-file "$CONST" -f "$c" -p p config --format json
    [ "$status" -eq 0 ] || continue
    [ "$(jq -r '.services.lcars.image // empty' <<<"$output")" = "" ] || porteurs=$((porteurs + 1))
  done
  [ "$porteurs" -eq 1 ]
}

@test "le runner : dind rootless sans le socket de l'hôte, son magasin dans un volume nommé, celui du dind rootful en tmpfs" {
  run rendu docker compose --env-file "$CONST" -f "$DOCKER/runner-compose.yml" -p r config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local j="$output"
  # une étiquette mouvante, pas un digest : la variante suit sa branche
  [[ "$(jq -r '.services.act.image' <<<"$j")" =~ ^gitea/runner:[a-z0-9.]+-dind-rootless$ ]]
  [ "$(jq -r '.services.act.privileged' <<<"$j")" = true ]
  jq -r '.services.act.security_opt[]' <<<"$j" | grep -qx 'apparmor=rootlesskit'
  [ "$(jq -r '.services.act.environment.DOCKER_HOST' <<<"$j")" = unix:///var/run/user/1000/docker.sock ]
  jq -r '.services.act.volumes[] | .source // "", .target' <<<"$j" | refute_out 'docker\.sock'
  [ "$(jq -c '.services.act.volumes[] | select(.target == "/home/rootless/.local/share/docker") | [.type, .source]' <<<"$j")" = '["volume","dind"]' ]
  [ "$(jq -r '.volumes | has("dind")' <<<"$j")" = true ]
  [ "$(jq -c '.services.act.tmpfs' <<<"$j")" = '["/var/lib/docker"]' ]
  jq -r '.services.act.volumes[].target' <<<"$j" | refute_out '^/var/lib/docker$'
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

@test "runner-compose.yml se lit sans adresse de forge, et rend les labels des constantes quand LCARS_RUNNER_LABELS manque" {
  run rendu docker compose --env-file "$CONST" -f "$DOCKER/runner-compose.yml" -p r config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_RUNNER_LABELS' <<<"$output")" = shell:docker://alpine:temoin ]
}

@test "runner-network.yml met le runner sur le réseau externe qu'on lui nomme, et l'exige" {
  local base=(docker compose --env-file "$CONST" -f "$DOCKER/runner-compose.yml" -f "$DOCKER/runner-network.yml" -p r config)
  run rendu "${base[@]}" -q
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_RUNNER_NETWORK absent"* ]]
  run rendu LCARS_RUNNER_NETWORK=bt-forge_default "${base[@]}" --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '.networks.default | [.name, .external]' <<<"$output")" = '["bt-forge_default",true]' ]
}

@test "lcars-home et lcars-var portent un nom écrit, celui que compose leur donnait : <projet>_<clé>, qu'une clé renommée ne change pas" {
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$CF" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.volumes["lcars-home"].name, .volumes["lcars-var"].name]' <<<"$output")" = '["p_lcars-home","p_lcars-var"]' ]
  # compose remplit toujours le nom du projet (mesuré : -p "", variable vide, fichier d'env) ; un compose qui ne le
  # remplirait pas rendrait « _lcars-home », un /home vide : l'écriture du nom refuse le vide
  [ "$(grep -cE '^    name: "\$\{COMPOSE_PROJECT_NAME:\?[^}]+\}_lcars-(home|var)"$' "$CF")" -eq 2 ]
  # la même instance, clés renommées dans une copie : le volume monté sur /home ne change pas de nom
  local copie="$BATS_TEST_TMPDIR/docker-compose.yml"
  sed -E 's/^(  |      - )lcars-home:/\1maisons:/; s/^(  |      - )lcars-var:/\1etat:/' "$CF" > "$copie"
  cp "$DOCKER/lcars-hardened-seccomp.json" "$BATS_TEST_TMPDIR/"
  run rendu LCARS_STORE_PREFIX=p docker compose --env-file "$CONST" -f "$copie" -p p config --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.lcars.volumes[] | select(.target == "/home") | .source' <<<"$output")" = maisons ]
  [ "$(jq -r '.volumes.maisons.name' <<<"$output")" = p_lcars-home ]
  [ "$(jq -r '.volumes.etat.name' <<<"$output")" = p_lcars-var ]
}

@test "l'override de banc : la forge interne et la source des constantes, et le marqueur du banc sur le conteneur et ses volumes" {
  local base=(docker compose --env-file "$CONST" -f "$CF" -f "$DOCKER/docker-compose.bench.yml" -p bt-fleet config)
  run rendu LCARS_STORE_PREFIX=bt-fleet LCARS_DEVFORGE_NETWORK=bt-forge_default "${base[@]}" -q
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_BENCH_BASE absent"* ]]
  run rendu LCARS_STORE_PREFIX=bt-fleet LCARS_DEVFORGE_NETWORK=bt-forge_default LCARS_BENCH_BASE=bt "${base[@]}" --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local j="$output"
  [ "$(jq -r '.services.lcars.environment.FORGE_BASE_URL' <<<"$j")" = http://forge-temoin:3000 ]
  [ "$(jq -r '.services.lcars.environment.LCARS_SOURCE_REMOTE' <<<"$j")" = "http://forge-temoin:3000/$(sed -n 's/^PROV_FORGE_ORG_DEFAULT=//p' "$CONST")/lcars.git" ]
  [ "$(jq -c '[.services.lcars.labels["lcars.bench"], .volumes["lcars-home"].labels["lcars.bench"], .volumes["lcars-var"].labels["lcars.bench"]]' <<<"$j")" = '["bt","bt","bt"]' ]
  [ "$(jq -c '.networks.devforge | [.name, .external]' <<<"$j")" = '["bt-forge_default",true]' ]
}

@test "la forge et le runner d'un poste ne portent aucun label ; leur surcouche de banc marque service et volumes, et exige la base" {
  local f svc j
  for f in forge-compose:gitea runner-compose:act; do
    svc="${f#*:}"; f="${f%:*}"
    # un label, même vide, entre dans l'empreinte que compose compare : la forge d'un poste reprise à la main serait recréée
    run rendu LCARS_BENCH_BASE=bt docker compose --env-file "$CONST" -f "$DOCKER/$f.yml" -p x config --format json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(jq -c --arg s "$svc" '[.services[$s].labels, (.volumes[] | .labels)] | map(select(. != null))' <<<"$output")" = '[]' ]
    run rendu docker compose --env-file "$CONST" -f "$DOCKER/$f.yml" -f "$DOCKER/$f.bench.yml" -p x config -q
    [ "$status" -ne 0 ]
    [[ "$output" == *"LCARS_BENCH_BASE absent"* ]]
    run rendu LCARS_BENCH_BASE=bt docker compose --env-file "$CONST" -f "$DOCKER/$f.yml" -f "$DOCKER/$f.bench.yml" -p x config --format json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    j="$output"
    [ "$(jq -c --arg s "$svc" '[.services[$s].labels["lcars.bench"]] + [.volumes[].labels["lcars.bench"]]' <<<"$j")" = '["bt","bt","bt"]' ]
  done
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
