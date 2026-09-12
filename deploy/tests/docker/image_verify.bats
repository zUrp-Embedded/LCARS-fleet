#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/docker/image_verify.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for le stage `verify` du Dockerfile — l'ISO des rails se mesure au build, pas chez l'operateur

load ../refute

setup() {
  DF="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  [ -f "$DF" ]
  MANIFEST="$BATS_TEST_DIRNAME/../../system.manifest"
}

code() { grep -vE '^\s*#|^\s*`#' "$DF"; }

@test "le stage verify EXISTE, part de runtime, et joue le doctor sur le substrat docker" {
  code | grep -qE '^FROM runtime AS verify$'
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE 'provision doctor --substrate docker' <<<"$v"
  # et il ecrit le marqueur SEULEMENT si le doctor est vert (`&&`, pas `;`)
  grep -qE 'doctor --substrate docker.*\\$' <<<"$v"
  grep -qE '^\s*&& printf .*> /verified' <<<"$v"
}

@test "verify joue le doctor SANS --only, depuis la copie que 62 embarque — la selection est celle des CHECK-ON" {
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE '/opt/lcars/deploy/provision doctor --substrate docker' <<<"$v"
  refute grep -qE -- '--only' <<<"$v"
  refute grep -qE '^COPY ' <<<"$v"
  grep -q 'PROV_KERNEL_PROBES=0' <<<"$v"
}

@test "final DEPEND de verify par le marqueur — un stage dont personne ne depend n'est pas bati" {
  code | grep -qE '^FROM runtime AS final$'
  code | grep -qE '^COPY --from=verify /verified /opt/lcars/.verified$'
  # et final est le DERNIER stage : c'est lui que compose et `container build` produisent sans --target
  [ "$(code | grep -E '^FROM ' | tail -n1)" = "FROM runtime AS final" ]
}

@test "le marqueur est un objet du PRODUIT — hors de la table de l'installeur, nomme par container/README" {
  refute grep -qE '^anchor +/opt/lcars/\.verified' "$MANIFEST"
  refute grep -qE '^(anchor|runtime|dir|file|link) +\S+ +\S+ +\S+ +docker$' "$MANIFEST"
  grep -q '\.verified' "$BATS_TEST_DIRNAME/../../../runtime/services/container/README.md"
}
