#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/box_state_volume.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — l'etat de l'instance vit dans un VOLUME, jamais dans le systeme de fichiers du conteneur
#
# ⚖ user 2026-09-04 (Q1) : l'image est le produit, le conteneur une instance, l'ETAT DANS LE VOLUME.
# DI-11 : le client OAuth2 du deck vivait sous /etc/lcars dans le conteneur et se reposait a chaque
# conteneur recree. Ce temoin lit les DEUX composes : chaque chemin d'etat que le boot ecrit doit
# tomber sous un point de montage d'un volume nomme du service.

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  DEV="$DOCKER/docker-compose.yml"; PULL="$DOCKER/docker-compose.install.yml"
  PROTO="$DOCKER/../../fleet/services/lib/module-protocol.sh"
}
env_of() { sed 's/#.*//' "$1" | sed -nE "s/^[[:space:]]+$2:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" | head -1; }
mounts_of() { sed 's/#.*//' "$1" | sed -nE 's/^[[:space:]]+-[[:space:]]+[a-z-]+:(\/[^:]+).*$/\1/p'; }
under_mount() { local m; while read -r m; do [[ "$1" == "$m"/* ]] && return 0; done < <(mounts_of "$2"); return 1; }

@test "le client OAuth2 du deck est sous un volume, dans les deux composes, au MEME chemin" {
  local dev pull
  dev="$(env_of "$DEV" LCARS_DECK_OIDC_FILE)"; pull="$(env_of "$PULL" LCARS_DECK_OIDC_FILE)"
  [ -n "$dev" ] && [ "$dev" = "$pull" ]
  under_mount "$dev" "$DEV"  || { echo "$dev hors de tout volume de $DEV" >&2; return 1; }
  under_mount "$pull" "$PULL" || { echo "$pull hors de tout volume de $PULL" >&2; return 1; }
  refute grep -qE '^\s*LCARS_DECK_OIDC_FILE:\s*/etc/' "$DEV"
}

@test "le poste garde le defaut du protocole (/etc/lcars) — la, /etc persiste" {
  grep -qE '^: "\$\{LCARS_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json\}"' "$PROTO"
}

@test "le deck LIT le fichier sous le MEME nom que le geste qui l'ecrit — un seul nom" {
  grep -q 'os.environ.get("LCARS_DECK_OIDC_FILE"' "$DOCKER/../../fleet/services/console-deck.py"
  refute grep -q '"LCARS_DECK_OIDC"' "$DOCKER/../../fleet/services/console-deck.py"
  grep -q 'LCARS_DECK_OIDC_FILE' "$DOCKER/../../fleet/services/forge.d/deck-oidc.sh"
}

@test "le repertoire prive (jetons) est aussi sous le volume var — l'etat ne se separe pas" {
  local priv; priv="$(sed -nE 's/^: "\$\{LCARS_PRIVATE_DIR:=([^}]+)\}"/\1/p' "$PROTO" | head -1)"
  [ -n "$priv" ]
  under_mount "$priv" "$DEV" && under_mount "$priv" "$PULL"
}
