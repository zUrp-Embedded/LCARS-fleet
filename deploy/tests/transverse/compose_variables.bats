#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/compose_variables.bats
# AUTHOR: bob
# STARDATE: 2026-09-13
# STATUS: le mur des variables compose, dans les deux sens — lue par un compose et posée par quelqu'un, posée pour un compose et lue par lui

setup() {
  D="$BATS_TEST_DIRNAME/../.."
  COMPOSES=("$D/docker/docker-compose.yml" "$D/docker/docker-compose.bench.yml" "$D/docker/docker-compose.secrets.yml"
            "$D/docker/forge-compose.yml" "$D/docker/forge-compose.bench.yml" "$D/docker/runner-compose.yml"
            "$D/docker/runner-compose.bench.yml" "$D/docker/runner-network.yml")
  POSEURS=("$D/container" "$D/docker/bench/bench-up.sh" "$D/docker/bench/bench-swap-image.sh" "$D/docker/bench/bench-down.sh"
           "$D/docker/forge-runner.sh" "$D/lib/bench.sh" "$D/lib/forge-bootstrap.sh" "$D/lib/store.sh" "$D/installer-constants.env")
}

sans_commentaires() { sed 's/#.*//' "$@"; }

conf_keys() { sed -n '/^CONF_KEYS=(/,/)/p' "$D/container" | tr ' ()' '\n\n\n' | grep -E '^[A-Z][A-Z0-9_]+$' | grep -v CONF_KEYS; }

@test "chaque variable lue par un compose est posée : par un script qui le pilote, ou par la conf de container" {
  local lues poseurs keys n bad=0
  lues="$(sans_commentaires "${COMPOSES[@]}" | grep -oE '\$\{[A-Z][A-Z0-9_]+' | tr -d '${' | sort -u)"
  [ "$(grep -c . <<<"$lues")" -ge 15 ] || { echo "moins de 15 variables lues — l'instrument ne lit plus les compose" >&2; return 1; }
  poseurs="$(sans_commentaires "${POSEURS[@]}")"
  keys="$(conf_keys)"
  while read -r n; do
    # compose pose lui-même le nom du projet qu'il interpole
    [[ "$n" != COMPOSE_PROJECT_NAME ]] || continue
    grep -qx "$n" <<<"$keys" && continue
    grep -qE "(^|[^A-Z0-9_])$n=" <<<"$poseurs" && continue
    echo "$n : lue par un compose, posée par personne" >&2; bad=1
  done <<<"$lues"
  [ "$bad" -eq 0 ]
}

@test "chaque clé de conf de container est annoncée par son aide" {
  local aide n bad=0
  aide="$(sed -n '/^# ENV (optionnels)/,/^# EXIT :/p' "$D/container" | grep -oE '^#   [A-Z][A-Z0-9_]+' | sed 's/^#   //')"
  while read -r n; do
    grep -qx "$n" <<<"$aide" || { echo "$n : clé de conf, absente de l'aide" >&2; bad=1; }
  done < <(conf_keys)
  [ "$bad" -eq 0 ]
}

@test "chaque variable posée pour un compose du banc ou du runner est lue par un compose" {
  local lues posees n bad=0
  lues="$(sans_commentaires "${COMPOSES[@]}" | grep -oE '\$\{[A-Z][A-Z0-9_]+' | tr -d '${' | sort -u)"
  posees="$(
    { sed -n '/^bench_conteneur_monte()/,/^}/p' "$D/lib/bench.sh"
      grep -E '^[[:space:]]*export ' "$D/lib/bench.sh"
      grep -E '^LCARS_[A-Z_]+="' "$D/docker/forge-runner.sh"
    } | grep -oE '(^|[[:space:]])[A-Z][A-Z0-9_]+=' | tr -d ' ='
  )"
  [ "$(sort -u <<<"$posees" | grep -c .)" -ge 10 ] || { echo "moins de 10 variables posées — l'instrument ne lit plus les appelants" >&2; echo "$posees" >&2; return 1; }
  while read -r n; do
    [ -n "$n" ] || continue
    grep -qx "$n" <<<"$lues" || { echo "$n : posée pour un compose, lue par aucun" >&2; bad=1; }
  done < <(sort -u <<<"$posees")
  [ "$bad" -eq 0 ]
}
