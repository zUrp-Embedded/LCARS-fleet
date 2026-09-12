#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/docker/compose_context.bats
# AUTHOR: bob
# STARDATE: 2026-09-11
# STATUS: bats tests for docker-compose.yml + Dockerfile — l'image vient de pack.sh, le compose ne BATIT pas
#
# Jusqu'au 2026-09-11 le compose portait un bloc `build:` (contexte `../..`, la racine du depot) et
# ces temoins tenaient ce contexte d'accord avec chaque COPY du Dockerfile. Le contexte est
# maintenant le KIT de pack.sh (`docker build … "$STAGE/$ROOT"`), jamais un checkout : un
# `compose build` n'aurait plus de sens, et c'est ce que ces deux temoins tiennent.

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  CF="$DOCKER/docker-compose.yml"
  DF="$DOCKER/Dockerfile"
  [ -f "$CF" ]
  [ -f "$DF" ]
}

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
