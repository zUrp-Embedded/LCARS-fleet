#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/bench_seed.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for the bench seed — the bench forge carries the BOX's code, and nothing of this workshop
#
# ⚖ user 2026-09-04 (lot 9 : DI-05, DI-06, point 9). Trois choses tenaient au poste de l'auteur et
# partaient avec la beta : le HEAD du clone hote pousse comme `main` (au lieu de la revision de
# l'image), le corpus ops cherche sous `/home/projects.ops/LCARS/work`, et un relais docker
# `/run/docker-fleet.sock` devine. Et `--forge-project` avait trois sens. Ces temoins lisent le CODE.

load ../refute

setup() {
  BENCH="$BATS_TEST_DIRNAME/../../docker/bench"
  BOOT="$BENCH/bench-forge-bootstrap.sh"
  UP="$BENCH/bench-up.sh"
  DOWN="$BENCH/bench-down.sh"
  SWAP="$BENCH/bench-swap-image.sh"
  INSTALL="$BATS_TEST_DIRNAME/../../../install.sh"
}
code() { grep -vE '^\s*#' "$1"; }

@test "DI-06 : le banc seme la REVISION DE L'IMAGE, pas le HEAD du clone hote" {
  code "$BOOT" | grep -qE 'org.opencontainers.image.revision.*\$BOX_IMAGE'
  code "$BOOT" | grep -qE 'push -q --force "\$LCARS_REMOTE" "\$\{BOX_REV\}:refs/heads/main"'
  refute grep -qE 'push -q --force "\$LCARS_REMOTE" main:main' <(code "$BOOT")
}

@test "DI-06 : une revision absente du clone se REFUSE — on ne seme pas un autre code" {
  code "$BOOT" | grep -qE 'rev-parse -q --verify "\$\{BOX_REV\}\^\{commit\}"'
  code "$BOOT" | grep -q "n'est pas dans ce clone"
  code "$BOOT" | grep -qE 'BOX_REV" != "unknown"'
}

@test "point 9 : le corpus ops n'a AUCUN chemin d'atelier en defaut — LCARS_WORK_TREE ou rien, et le recap le dit" {
  refute grep -q 'projects.ops' <(code "$BOOT")
  code "$BOOT" | grep -qE 'WORK_TREE="\$\{LCARS_WORK_TREE:-\}"'
  code "$BOOT" | grep -q 'LCARS_WORK_TREE non pose'
}

@test "point 9 : le relais docker n'a AUCUN chemin en defaut — LCARS_DOCKER_RELAY_SOCK ou la socket Docker Desktop" {
  refute grep -q 'docker-fleet.sock' <(code "$UP")
  code "$UP" | grep -qE 'LCARS_DOCKER_RELAY_SOCK'
}

@test "DI-05 : UN sens — la base N donne N-fleet, N-forge, N-runner dans les trois scripts du banc" {
  local f
  for f in "$UP" "$DOWN" "$SWAP"; do
    code "$f" | grep -qxE 'BOX_PROJECT="\$\{PROJECT\}-fleet"' || { echo "$f : pas de BOX_PROJECT=<N>-fleet" >&2; return 1; }
    code "$f" | grep -qxE 'FORGE_PROJECT="\$\{PROJECT\}-forge"' || { echo "$f : pas de FORGE_PROJECT=<N>-forge" >&2; return 1; }
    refute grep -qE '\$\{PROJECT\}forge' <(code "$f")
  done
  code "$UP" | grep -q -- '--project "${PROJECT}-runner"'
}

@test "DI-05 : la base se definit AVANT le prefixe du magasin qui en derive (set -u tuerait le script)" {
  local f def use
  for f in "$UP" "$DOWN" "$SWAP"; do
    def="$(grep -n 'BOX_PROJECT="${PROJECT}-fleet"' "$f" | head -1 | cut -d: -f1)"
    use="$(grep -n 'LCARS_STORE_PREFIX="$BOX_PROJECT"' "$f" | head -1 | cut -d: -f1)"
    [ -n "$def" ] && [ -n "$use" ] && [ "$def" -lt "$use" ] || { echo "$f : def=$def use=$use" >&2; return 1; }
  done
}

@test "DI-05 : sur le rail boite, --forge-project N est la BASE (LCARS_BASE) — la boite s'appelle N-fleet comme chez deploy/box" {
  code "$INSTALL" | grep -qE 'export LCARS_BASE="\$\{PASSTHRU\[\$\(\(_i \+ 1\)\)\]\}"'
  refute grep -qE 'export LCARS_PROJECT="\$\{PASSTHRU' <(code "$INSTALL")
  grep -qE 'PROJECT="\$\{LCARS_PROJECT:-\$\{LCARS_BASE:-lcars\}-fleet\}"' "$BATS_TEST_DIRNAME/../../box"
}
