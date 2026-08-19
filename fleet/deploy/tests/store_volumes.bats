#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/store_volumes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the STORE — what survives a destruction, and what says so
#
# WHY THIS EXISTS, AND IT IS NOT HYPOTHETICAL. The store was declared with TWO volumes for FIVE
# declared paths, and the defect was found by a human reader, not by a test:
#
#   - the volume was named `lcars-toolchain` and the path is `toolchains/` — ONE character, and the
#     artefact that costs three hours of CPU lands NEXT TO its own volume, on the container layer,
#     where the next rebuild takes it;
#   - `sysroots/` had no volume at all;
#   - `env.d/` and `egress.d/` had none either — and losing those costs NOTHING VISIBLE: the
#     toolchain stays, the pod simply stops seeing it, the install reports green and the build
#     fails with nothing linking the two symptoms.
#
# So the contract under test is not "a volume exists". It is: EVERY path the store mounts is backed
# by an external volume, and no mount silently falls through to the container layer. That is a
# structural property of the compose files, and it is checked by reading them.
#
# WHAT IS PROVEN HERE: the declared names, that every store mount is external, that the two compose
# files agree, and that both destruction gestures NAME what they spare. WHAT IS NOT: that docker
# actually spares them — that is docker's behaviour, measured live on 2026-08-19 (marker written in
# `lcars-toolchains`, `-p storetest down -v`, project volume destroyed, the four externals and the
# marker intact) and recorded in `docker-compose.yml`. A stub cannot answer for it.

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  STORE_LIB="$DEPLOY/lib/store.sh"
  COMPOSE="$DEPLOY/docker/docker-compose.yml"
  COMPOSE_INSTALL="$DEPLOY/docker/docker-compose.install.yml"
  # shellcheck source=../lib/store.sh
  source "$STORE_LIB"
}

# Les montages du magasin declares dans un compose : « <volume>:<chemin> » sous `/var/lib/lcars`.
store_mounts() { grep -oE '^\s*- lcars-[a-z]+:/var/lib/lcars/[a-z.]+' "$1" | sed 's/^\s*- //'; }

@test "chaque volume declare par store.sh est monte par le compose — aucun orphelin" {
  local vol
  for vol in "${LCARS_STORE_VOLUMES[@]}"; do
    grep -q "^\s*- ${vol}:/var/lib/lcars/" "$COMPOSE" \
      || { echo "volume declare et JAMAIS monte : $vol"; return 1; }
  done
}

@test "REGRESSION — chaque montage du magasin a son volume EXTERNE, aucun ne tombe sur la couche conteneur" {
  # LE TEMOIN QUI MANQUAIT. Un montage dont le volume n'est pas declare `external: true` est cree
  # par compose, prefixe par le projet, et EMPORTE par `down -v` — silencieusement. C'est le
  # defaut qui a mis `toolchains/` a cote de `lcars-toolchain`.
  local mount vol
  while read -r mount; do
    [[ -n "$mount" ]] || continue
    vol="${mount%%:*}"
    grep -A 1 "^  ${vol}:\$" "$COMPOSE" | grep -q "external: true" \
      || { echo "monte mais PAS external (donc emporte par down -v) : $vol"; return 1; }
  done < <(store_mounts "$COMPOSE")
}

@test "les deux compose qui portent la boite montent EXACTEMENT le meme magasin" {
  # `docker-compose.install.yml` porte la meme boite que `docker-compose.yml` (le banc l'utilise).
  # Un magasin present d'un cote et pas de l'autre donnerait une install ou un banc qui perd ses
  # artefacts sans que rien ne le dise — et c'est le banc qui les fabrique.
  [ "$(store_mounts "$COMPOSE" | sort)" = "$(store_mounts "$COMPOSE_INSTALL" | sort)" ]
}

@test "le chemin du magasin est ecrit par les compose SEULS, jamais par un script" {
  # store.sh possede les NOMS, le compose possede le CHEMIN. Un `/var/lib/lcars` en dur dans un
  # script serait une seconde verite, et c'est celle qu'on ne relit pas qui derive.
  grep -q "LCARS_STORE_ROOT: /var/lib/lcars" "$COMPOSE"
  grep -q "LCARS_STORE_ROOT: /var/lib/lcars" "$COMPOSE_INSTALL"
  ! grep -q "/var/lib/lcars" "$STORE_LIB"
}

@test "store_ensure_volumes cree TOUS les volumes, et rejouer ne casse rien" {
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  store_ensure_volumes "$bin/dockerstub"
  store_ensure_volumes "$bin/dockerstub"   # idempotent : `volume create` rend 0 sur un existant

  local vol
  for vol in "${LCARS_STORE_VOLUMES[@]}"; do
    grep -q "^volume create $vol\$" "$calls" || { echo "jamais cree : $vol"; return 1; }
  done
}

@test "store_ensure_volumes ECHOUE bruyamment quand docker refuse — jamais un up sur un magasin absent" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/dockerko"; chmod 0755 "$bin/dockerko"
  run store_ensure_volumes "$bin/dockerko"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusera de demarrer"* ]]
}

@test "LA CONTREPARTIE — la destruction NOMME les quatre volumes qu'elle epargne" {
  # Sans ca, « banc detruit » se lit comme « la machine est propre » alors que des heures de
  # toolchain restent. Un effacement silencieux sur ce qu'il LAISSE est un mensonge par omission,
  # et il ne se decouvre qu'au moment ou quelqu'un purge un cache.
  run store_spared_line
  [ "$status" -eq 0 ]
  local vol
  for vol in "${LCARS_STORE_VOLUMES[@]}"; do
    [[ "$output" == *"$vol"* ]] || { echo "epargne mais NON NOMME : $vol"; return 1; }
  done
  # Et elle donne le geste qui les detruit vraiment : nommer sans dire comment est un demi-aveu.
  [[ "$output" == *"docker volume rm"* ]]
}

@test "les deux gestes de destruction appellent la contrepartie" {
  grep -q "store_spared_line" "$DEPLOY/docker/bench/bench-down.sh"
  grep -q "store_spared_line" "$DEPLOY/../../docker.sh"
}

@test "les deux gestes qui montent la boite posent le magasin AVANT" {
  # `external: true` = compose refuse de demarrer sur un volume absent. L'appel doit donc preceder
  # le up/create, et ces deux scripts sont les seuls a s'executer avant.
  grep -q "store_ensure_volumes" "$DEPLOY/docker/bench/bench-up.sh"
  grep -q "store_ensure_volumes" "$DEPLOY/../../docker.sh"

  local up_line ensure_line
  ensure_line="$(grep -n "store_ensure_volumes" "$DEPLOY/../../docker.sh" | head -1 | cut -d: -f1)"
  up_line="$(grep -n "compose up -d" "$DEPLOY/../../docker.sh" | head -1 | cut -d: -f1)"
  [ "$ensure_line" -lt "$up_line" ]
}
