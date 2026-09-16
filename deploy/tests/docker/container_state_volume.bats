#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/container_state_volume.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — l'etat de l'instance vit dans un VOLUME, jamais dans le systeme de fichiers du conteneur

load ../refute
load ../support/compose

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  DEV="$DOCKER/docker-compose.yml"
  PROTO="$DOCKER/../../runtime/services/lib/module-protocol.sh"
  CONSTANTES="$DOCKER/../installer-constants.env"
  [ -r "$CONSTANTES" ]
  RENDU="$BATS_TEST_TMPDIR/rendu.json"
}
rendre() { # rendre — le compose rendu par docker compose avec les constantes de l'installeur, sans daemon, dans RENDU
  compose_requis
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" LCARS_STORE_PREFIX=p \
    docker compose --env-file "$CONSTANTES" -f "$DEV" -p p config --format json > "$RENDU"
  [ "$(jq '.services.lcars.volumes | length' "$RENDU")" -ge 2 ]
}
constante() { sed -n "s/^$1=//p" "$CONSTANTES"; }
env_rendu() { jq -r --arg v "$1" '.services.lcars.environment[$v] // empty' "$RENDU"; }
under_mount() { # under_mount <chemin> — sous la cible d'un volume du conteneur rendu
  local m
  while read -r m; do [[ "$1" == "$m" || "$1" == "$m"/* ]] && return 0; done \
    < <(jq -r '.services.lcars.volumes[] | select(.type == "volume") | .target' "$RENDU")
  return 1
}

@test "le client OAuth2 du deck est sous un volume du compose" {
  rendre
  local dev
  dev="$(env_rendu LCARS_DECK_OIDC_FILE)"
  [ -n "$dev" ]
  under_mount "$dev" || { echo "$dev hors de tout volume de $DEV" >&2; return 1; }
}

# bats test_tags=structure
@test "le poste garde le defaut du protocole, celui des constantes — la, /etc persiste" {
  local poste; poste="$(constante PROV_DECK_OIDC_FILE)"
  [ -n "$poste" ]
  grep -qxF ": \"\${LCARS_DECK_OIDC_FILE:=$poste}\"" "$PROTO"
}

# bats test_tags=structure
@test "le deck LIT le fichier sous le MEME nom que le geste qui l'ecrit — un seul nom" {
  grep -q 'os.environ.get("LCARS_DECK_OIDC_FILE"' "$DOCKER/../../runtime/services/console-deck.py"
  refute grep -q '"LCARS_DECK_OIDC"' "$DOCKER/../../runtime/services/console-deck.py"
  grep -q 'LCARS_DECK_OIDC_FILE' "$DOCKER/../../runtime/services/forge.d/deck-oidc.sh"
}

@test "le repertoire des jetons est sous un volume du compose — l'etat ne se separe pas" {
  rendre
  local jetons; jetons="$(constante PROV_TOKENS_DIR)"
  [ -n "$jetons" ]
  under_mount "$jetons"
}

# bats test_tags=structure
@test "TOUT chemin d'etat que l'init ou le protocole nomme tombe sous un volume — ou dans la liste d'exceptions ECRITE ici" {
  rendre
  local INIT="$DOCKER/../../runtime/services/container/init.sh"
  [ -f "$INIT" ]
  local chemins var val ov
  chemins="$( {
    sed 's/#.*//' "$INIT" | grep -oE '(ensure_dir|write_atomic) +"?/[^" ]+' | sed -E 's/^[a-z_]+ +"?//'
    # le layout de l'init est une TABLE (« chemin mode proprietaire ») et non plus une suite
    # d'appels : ses chemins absolus se lisent la, sinon ce mur ne balaie plus que la moitie du fichier
    sed -n '/^layout_table() {/,/^}/p' "$INIT" | sed 's/#.*//' | grep -oE '"/[^" ]+' | tr -d '"'
    sed 's/#.*//' "$INIT" | grep -oE '\$\{LCARS_[A-Z_]+:-/[^}]+\}' | sed -E 's/^\$\{[A-Z_]+:-//; s/\}$//'
    while IFS='=' read -r var val; do
      [ -n "$var" ] || continue
      ov="$(env_rendu "$var")"; [ -n "$ov" ] && val="$ov"
      printf '%s\n' "$val"
    done < <(sed 's/#.*//' "$PROTO" | sed -nE 's/^: "\$\{(LCARS_[A-Z_]+_(FILE|DIR)):=(\/[^}]+)\}".*/\1=\3/p')
  } | sort -u)"
  local n; n="$(grep -c . <<<"$chemins")"
  [ "$n" -ge 12 ] || { echo "seulement $n chemins derives — l'instrument ne lit plus init.sh ni le protocole" >&2; return 1; }

  local exceptions=" /etc/lcars /etc/lcars/seat.uid /var/lib/lcars /var/tmp/lcars /var/tmp/lcars/toolchain-work /usr/local/bin "
  local p rompu=0
  while read -r p; do
    [ -n "$p" ] || continue
    [[ "$p" == /run/* ]] && continue
    [[ "$exceptions" == *" $p "* ]] && continue
    under_mount "$p" && continue
    echo "$p : ecrit par l'init ou le protocole, hors de tout volume du compose, et pas nomme dans les exceptions" >&2
    rompu=1
  done <<<"$chemins"
  [ "$rompu" -eq 0 ]
}
