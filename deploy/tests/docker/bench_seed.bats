#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/bench_seed.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for the bench seed — the bench forge carries the CONTAINER's code, and nothing of this workshop
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
  code "$BOOT" | grep -qE 'org.opencontainers.image.revision.*\$CONTAINER_IMAGE'
  code "$BOOT" | grep -qE 'push -q "\$\{seed_force\[@\]\}" "\$LCARS_REMOTE" "\$\{CONTAINER_REV\}:refs/heads/main"'
  refute grep -qE 'push -q .*main:main' <(code "$BOOT")
}

@test "semis : PAS de --force par defaut — le hook pre-push refuse un non-ff sur main ; le rejeu d'une forge jetable le leve, et le DIT (mesure vanille)" {
  # un premier semis ou une avance rapide : seed_force vide ; un rejeu : --force + hook leve, precede d'un say
  code "$BOOT" | grep -qE '^\s*seed_force=\(\)$'
  code "$BOOT" | grep -qE 'seed_hooks=\(-c core.hooksPath=/dev/null\); seed_force=\(--force\)'
  code "$BOOT" | grep -qE 'merge-base --is-ancestor "\$remote_main" "\$CONTAINER_REV"'
  refute grep -qE 'push -q --force' <(code "$BOOT")
  # le say precede la levee du hook
  local l_say l_hook
  l_say="$(grep -nE 'REJEU sur une forge jetable : le hook pre-push est leve' "$BOOT" | head -1 | cut -d: -f1)"
  l_hook="$(grep -nE 'seed_hooks=\(-c core.hooksPath=/dev/null\)' "$BOOT" | head -1 | cut -d: -f1)"
  [ -n "$l_say" ] && [ -n "$l_hook" ] && [ "$l_say" -lt "$l_hook" ]
}

@test "semis : le jeton du systeme n'est JAMAIS dans l'URL du remote ni dans un argv de git — il passe par GIT_CONFIG_* (environnement)" {
  refute grep -qE 'LCARS_REMOTE="http://.*\$\{?SYS_TOKEN' <(code "$BOOT")
  code "$BOOT" | grep -qE '^\s*LCARS_REMOTE="\$\{FORGE_URL%/\}/fleet/lcars.git"$'
  code "$BOOT" | grep -qE 'GIT_CONFIG_VALUE_0="Authorization: token \$\{SYS_TOKEN\}"'
  refute grep -qE 'git .*-c http\.[^ ]*extraheader' <(code "$BOOT")
  # chaque git qui parle a la forge passe par git_forge
  code "$BOOT" | grep -qE 'git_forge -C "\$REPO_ROOT" "\$\{seed_hooks\[@\]\}" push'
  code "$BOOT" | grep -qE 'git_forge ls-remote --heads "\$LCARS_REMOTE"'
}

@test "DI-06 : une revision absente du clone se REFUSE — on ne seme pas un autre code" {
  code "$BOOT" | grep -qE 'rev-parse -q --verify "\$\{CONTAINER_REV\}\^\{commit\}"'
  code "$BOOT" | grep -q "n'est pas dans ce clone"
  code "$BOOT" | grep -qE 'CONTAINER_REV" != "unknown"'
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
    code "$f" | grep -qxE 'CONTAINER_PROJECT="\$\{PROJECT\}-fleet"' || { echo "$f : pas de CONTAINER_PROJECT=<N>-fleet" >&2; return 1; }
    code "$f" | grep -qxE 'FORGE_PROJECT="\$\{PROJECT\}-forge"' || { echo "$f : pas de FORGE_PROJECT=<N>-forge" >&2; return 1; }
    refute grep -qE '\$\{PROJECT\}forge' <(code "$f")
  done
  code "$UP" | grep -q -- '--project "${PROJECT}-runner"'
}

@test "DI-05 : la base se definit AVANT le prefixe du magasin qui en derive (set -u tuerait le script)" {
  local f def use
  for f in "$UP" "$DOWN" "$SWAP"; do
    def="$(grep -n 'CONTAINER_PROJECT="${PROJECT}-fleet"' "$f" | head -1 | cut -d: -f1)"
    use="$(grep -n 'LCARS_STORE_PREFIX="$CONTAINER_PROJECT"' "$f" | head -1 | cut -d: -f1)"
    [ -n "$def" ] && [ -n "$use" ] && [ "$def" -lt "$use" ] || { echo "$f : def=$def use=$use" >&2; return 1; }
  done
}

@test "DI-05 : --forge-project N passe tel quel de l'installeur au conteneur, qui s'appelle N-fleet" {
  # l'installeur ne traduit rien : le drapeau va au délégué, et c'est lui qui dérive le projet
  code "$INSTALL" | grep -qE '^\s*--forge-project\)\s+PROJET_PORTS\+='
  refute grep -qE 'export LCARS_(BASE|PROJECT)=' <(code "$INSTALL")
  local container="$BATS_TEST_DIRNAME/../../container"
  grep -qE '^\s*--forge-project\)' "$container"
  grep -qE 'PROJECT="\$2-fleet"' "$container"
  grep -qE 'PROJECT="\$\{LCARS_PROJECT:-\$\{LCARS_BASE:-lcars\}-fleet\}"' "$container"
}
