#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/store_volumes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the STORE — what survives a destruction, and what says so

# shellcheck disable=SC2016

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2209 — affectation d'une CHAINE qui porte un nom de commande, pas d'une sortie
# shellcheck disable=SC2209

load ../refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/../.."
  STORE_LIB="$DEPLOY/lib/store.sh"
  COMPOSE="$DEPLOY/docker/docker-compose.yml"
  # shellcheck source=../../lib/store.sh
  source "$STORE_LIB"
  # Le prefixe est EXIGE par la lib (aucun defaut, pour que deux installations ne puissent pas
  # retomber sur le meme magasin). Les temoins s'en donnent un, arbitraire.
  export LCARS_STORE_PREFIX="testproj"
}

store_mounts() { grep -oE '^\s*- lcars-[a-z]+:/var/lib/lcars/[a-z.]+' "$1" | sed 's/^\s*- //'; }

@test "chaque nature declaree par store.sh est montee par le compose — aucun orphelin" {
  local nature
  for nature in "${LCARS_STORE_TREES[@]}"; do
    grep -q "^\s*- lcars-${nature}:/var/lib/lcars/${nature}\$" "$COMPOSE" \
      || { echo "nature declaree et JAMAIS montee : $nature"; return 1; }
  done
}

@test "REGRESSION — le nom REEL porte le projet : deux installations ne partagent AUCUN volume" {
  local a b
  a="$(LCARS_STORE_PREFIX=prod store_volume_names | sort)"
  b="$(LCARS_STORE_PREFIX=test store_volume_names | sort)"
  [ -n "$a" ]
  [ "$a" != "$b" ]
  # Disjoints, pas seulement differents : une seule collision suffit a faire le degat.
  [ -z "$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ]
}

@test "le prefixe n'a AUCUN defaut — sans lui, la derivation refuse au lieu de retomber sur un nom nu" {
  # Un `:-lcars` ici ressusciterait le defaut par commodite : deux installations mal cablees
  # retomberaient sur les memes noms, et rien ne le dirait.
  unset LCARS_STORE_PREFIX
  run store_volume_names
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_STORE_PREFIX"* ]]
  # RIEN d'ecrit : une liste partielle ferait croire a un appelant qui detruit qu'il a fini.
  [[ "$output" != *"-cache"* ]]
}

@test "prefixe absent : les deux gestes ECHOUENT — jamais un succes muet sur un magasin fantome" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  unset LCARS_STORE_PREFIX
  run store_ensure_volumes "$bin/dockerstub"
  [ "$status" -ne 0 ]
  run store_destroy_volumes "$bin/dockerstub"
  [ "$status" -ne 0 ]
  # Et docker n'a JAMAIS ete appele : refuser, ce n'est pas agir a moitie.
  [ ! -s "$calls" ]
}

@test "le compose EXIGE le prefixe sur ses quatre volumes — un up sans lui est refuse, jamais silencieux" {
  # `:?` et non `:-` : sans elle, la lib refuserait de creer pendant que le compose monterait un nom nu.
  [ "$(grep -c 'LCARS_STORE_PREFIX:?' "$COMPOSE")" -eq 4 ]
}

@test "REGRESSION — chaque montage du magasin a son volume EXTERNE, aucun ne tombe sur la couche conteneur" {
  local mount vol
  while read -r mount; do
    [[ -n "$mount" ]] || continue
    vol="${mount%%:*}"
    grep -A 2 "^  ${vol}:\$" "$COMPOSE" | grep -q "external: true" \
      || { echo "monte mais PAS external (donc emporte par down -v) : $vol"; return 1; }
  done < <(store_mounts "$COMPOSE")
}

@test "le chemin du magasin est ecrit par le compose SEUL, jamais par un script" {
  # store.sh possede les NOMS, le compose possede le CHEMIN.
  grep -q "LCARS_STORE_ROOT: /var/lib/lcars" "$COMPOSE"
  refute grep -q "/var/lib/lcars" "$STORE_LIB"
}

@test "store_ensure_volumes cree TOUS les volumes, et rejouer ne casse rien" {
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  store_ensure_volumes "$bin/dockerstub"
  store_ensure_volumes "$bin/dockerstub"   # idempotent : `volume create` rend 0 sur un existant

  local vol
  while read -r vol; do
    grep -q "^volume create $vol\$" "$calls" || { echo "jamais cree : $vol"; return 1; }
  done < <(store_volume_names)
  # Et ce qu'il cree porte bien le prefixe — sinon il fabriquerait le magasin d'une autre install.
  grep -q "^volume create testproj-cache\$" "$calls"
}

@test "store_destroy_volumes n'efface QUE le magasin de son projet" {
  local calls="$BATS_TEST_TMPDIR/calls"; : > "$calls"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "$*" >> %s\nexit 0\n' "$calls" > "$bin/dockerstub"
  chmod 0755 "$bin/dockerstub"

  LCARS_STORE_PREFIX=banc2 store_destroy_volumes "$bin/dockerstub"

  [ "$(grep -c '^volume rm -f banc2-' "$calls")" -eq 4 ]
  # Le temoin qui compte : AUCUN nom nu, donc rien qui appartienne a une autre installation.
  refute grep -qE '^volume rm -f lcars-(cache|toolchains|sysroots|state)$' "$calls"
}

@test "store_ensure_volumes ECHOUE bruyamment quand docker refuse — jamais un up sur un magasin absent" {
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/dockerko"; chmod 0755 "$bin/dockerko"
  run store_ensure_volumes "$bin/dockerko"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusera de démarrer"* ]]
}

@test "LA CONTREPARTIE — ce que \`container reset\` epargne, il le NOMME" {
  run store_spared_line
  [ "$status" -eq 0 ]
  local vol
  while read -r vol; do
    [[ "$output" == *"$vol"* ]] || { echo "epargne mais NON NOMME : $vol"; return 1; }
  done < <(store_volume_names)
  # Et elle donne le geste qui les detruit vraiment : nommer sans dire comment est un demi-aveu.
  [[ "$output" == *"docker volume rm"* ]]
}

@test "les DEUX gestes de destruction, et ils ne font PAS la meme chose" {
  grep -q "store_spared_line" "$DEPLOY/container"
  refute grep -q "store_spared_line" "$DEPLOY/docker/bench/bench-down.sh"
  grep -q "store_destroy_volumes" "$DEPLOY/docker/bench/bench-down.sh"
  refute grep -q "store_destroy_volumes" "$DEPLOY/container"
}

@test "tout appelant du magasin POSE le prefixe avant d'appeler compose ou la lib" {
  # Le prefixe n'a pas de defaut : un appelant qui l'oublie ne partage pas — il ECHOUE. Ce temoin
  # garde la moitie qu'un `:?` ne peut pas garder : qu'il soit pose, et pose au PROJET.
  local f
  # lot 9 (DI-05) : chez `container` le projet EST celui du conteneur ; sur le banc c'est `<N>-fleet`,
  # derive de la base — le prefixe suit le projet du conteneur dans les deux cas
  grep -qE '^export LCARS_STORE_PREFIX="\$PROJECT"$' "$DEPLOY/container" \
    || { echo "n'exporte pas le prefixe au nom du projet : $DEPLOY/container"; return 1; }
  for f in "$DEPLOY/docker/bench/bench-up.sh" "$DEPLOY/docker/bench/bench-down.sh"; do
    grep -qE '^export LCARS_STORE_PREFIX="\$CONTAINER_PROJECT"$' "$f" \
      || { echo "n'exporte pas le prefixe au nom du projet du conteneur : $f"; return 1; }
    grep -qE '^CONTAINER_PROJECT="\$\{PROJECT\}-fleet"$' "$f" \
      || { echo "ne derive pas le projet du conteneur de la base : $f"; return 1; }
  done
}

@test "les deux gestes qui montent le conteneur posent le magasin AVANT" {
  # `external: true` = compose refuse de demarrer sur un volume absent. L'appel doit donc preceder
  # le up/create, et ces deux scripts sont les seuls a s'executer avant.
  grep -q "store_ensure_volumes" "$DEPLOY/docker/bench/bench-up.sh"
  grep -q "store_ensure_volumes" "$DEPLOY/container"

  local up_line ensure_line
  ensure_line="$(grep -n "store_ensure_volumes" "$DEPLOY/container" | head -1 | cut -d: -f1)"
  up_line="$(grep -n "compose up -d" "$DEPLOY/container" | head -1 | cut -d: -f1)"
  [ "$ensure_line" -lt "$up_line" ]
}
