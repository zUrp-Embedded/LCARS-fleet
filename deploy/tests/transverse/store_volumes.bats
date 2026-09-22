#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/store_volumes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the STORE — what survives a destruction, and what says so

# shellcheck disable=SC2016
# SC2209 : les affectations portent une chaîne qui nomme une commande, pas sa sortie
# shellcheck disable=SC2209

load ../refute

# le préfixe posé au projet par chaque appelant, et le magasin posé avant compose, se jouent chez
# eux : container_config.bats, docker/bench/bench-up.bats, bench-down.bats, bench-swap-image.bats
setup() {
  DEPLOY="$BATS_TEST_DIRNAME/../.."
  STORE_LIB="$DEPLOY/lib/store.sh"
  # shellcheck source=../../lib/store.sh
  source "$STORE_LIB"
  # Le prefixe est EXIGE par la lib (aucun defaut, pour que deux installations ne puissent pas
  # retomber sur le meme magasin). Les temoins s'en donnent un, arbitraire.
  export LCARS_STORE_PREFIX="testproj"
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
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"LCARS_STORE_PREFIX absent"* ]]
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
