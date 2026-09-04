#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/compose_context.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — le contexte de build du compose est la RACINE du depot, et le Dockerfile s'y lit
#
# DI-09 (lot 11), DI-08 : un contexte de compose faux passe vert au gate (rien ne le joue) et rouge au
# premier `box build`. Le Dockerfile fait `COPY fleet …`, `COPY deploy …`, `COPY catalogues …`,
# `COPY assets …` : son contexte est la racine du depot, deux niveaux au-dessus de `deploy/docker/`.

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  ROOT="$(cd "$DOCKER/../.." && pwd)"
  CF="$DOCKER/docker-compose.yml"
  [ -f "$CF" ]
}

@test "le contexte est ../.. depuis deploy/docker — la racine du depot — et le Dockerfile s'y resout" {
  local ctx df
  ctx="$(sed -n 's/^\s*context:\s*//p' "$CF" | head -1)"
  df="$(sed -n 's/^\s*dockerfile:\s*//p' "$CF" | head -1)"
  [ "$ctx" = "../.." ]
  [ "$(cd "$DOCKER/$ctx" && pwd)" = "$ROOT" ]
  [ -f "$DOCKER/$ctx/$df" ]
  [ "$(cd "$DOCKER/$ctx" && readlink -f "$df")" = "$(readlink -f "$DOCKER/Dockerfile")" ]
}

@test "chaque COPY du Dockerfile designe un chemin qui EXISTE sous ce contexte (sauf --from, qui lit un stage)" {
  local src bad=0
  while read -r src; do
    [[ "$src" == *\[* ]] && continue   # un motif optionnel (`.source-revisio[n]`) n'exige rien
    [[ -e "$ROOT/$src" ]] || { echo "COPY $src : absent sous $ROOT" >&2; bad=1; }
  done < <(grep -vE '^\s*#' "$DOCKER/Dockerfile" | grep -E '^COPY ' | grep -v -- '--from=' \
           | sed -E 's/^COPY\s+//; s/--[a-z-]+(=\S+)?\s+//g' | awk '{ for (i = 1; i < NF; i++) print $i }' \
           | sort -u)
  [ "$bad" -eq 0 ]
}
