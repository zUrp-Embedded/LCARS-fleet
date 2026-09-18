#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/docker/container_state_volume.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — l'etat de l'instance vit dans un VOLUME, jamais dans le systeme de fichiers du conteneur

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  DEV="$DOCKER/docker-compose.yml"
  PROTO="$DOCKER/../../runtime/services/lib/module-protocol.sh"
}
env_of() { sed 's/#.*//' "$1" | sed -nE "s/^[[:space:]]+$2:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" | head -1; }
mounts_of() { sed 's/#.*//' "$1" | sed -nE 's/^[[:space:]]+-[[:space:]]+[a-z-]+:(\/[^:]+).*$/\1/p'; }
under_mount() { local m; while read -r m; do [[ "$1" == "$m" || "$1" == "$m"/* ]] && return 0; done < <(mounts_of "$2"); return 1; }

@test "le client OAuth2 du deck est sous un volume du compose" {
  local dev
  dev="$(env_of "$DEV" LCARS_DECK_OIDC_FILE)"
  [ -n "$dev" ]
  under_mount "$dev" "$DEV"  || { echo "$dev hors de tout volume de $DEV" >&2; return 1; }
  refute grep -qE '^\s*LCARS_DECK_OIDC_FILE:\s*/etc/' "$DEV"
}

@test "le poste garde le defaut du protocole (/etc/lcars) — la, /etc persiste" {
  grep -qE '^: "\$\{LCARS_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json\}"' "$PROTO"
}

@test "le deck LIT le fichier sous le MEME nom que le geste qui l'ecrit — un seul nom" {
  grep -q 'os.environ.get("LCARS_DECK_OIDC_FILE"' "$DOCKER/../../runtime/services/console-deck.py"
  refute grep -q '"LCARS_DECK_OIDC"' "$DOCKER/../../runtime/services/console-deck.py"
  grep -q 'LCARS_DECK_OIDC_FILE' "$DOCKER/../../runtime/services/forge.d/deck-oidc.sh"
}

@test "le repertoire prive (jetons) est aussi sous le volume var — l'etat ne se separe pas" {
  local priv; priv="$(sed -nE 's/^: "\$\{LCARS_PRIVATE_DIR:=([^}]+)\}"/\1/p' "$PROTO" | head -1)"
  [ -n "$priv" ]
  under_mount "$priv" "$DEV"
}

@test "TOUT chemin d'etat que l'init ou le protocole nomme tombe sous un volume — ou dans la liste d'exceptions ECRITE ici" {
  local INIT="$DOCKER/../../runtime/services/container/init.sh"
  [ -f "$INIT" ]
  local chemins var val ov
  chemins="$( {
    sed 's/#.*//' "$INIT" | grep -oE '(ensure_dir|write_atomic) +"?/[^" ]+' | sed -E 's/^[a-z_]+ +"?//'
    sed 's/#.*//' "$INIT" | grep -oE '\$\{LCARS_[A-Z_]+:-/[^}]+\}' | sed -E 's/^\$\{[A-Z_]+:-//; s/\}$//'
    while IFS='=' read -r var val; do
      [ -n "$var" ] || continue
      ov="$(env_of "$DEV" "$var")"; [ -n "$ov" ] && val="$ov"
      printf '%s\n' "$val"
    done < <(sed 's/#.*//' "$PROTO" | sed -nE 's/^: "\$\{(LCARS_[A-Z_]+_(FILE|DIR)):=(\/[^}]+)\}".*/\1=\3/p')
  } | sort -u)"
  local n; n="$(grep -c . <<<"$chemins")"
  [ "$n" -ge 12 ] || { echo "seulement $n chemins derives — l'instrument ne lit plus init.sh ni le protocole" >&2; return 1; }

  # ⚠ LES EXCEPTIONS SONT DU TRAVAIL, PAS DE L'ETAT. `/var/tmp/lcars/deposit` est la zone de
  # transit de la boite de depot : le deck y ecrit le fichier, la porte le lit, et il est retire
  # tout de suite. La faire survivre a un redemarrage serait un defaut, pas un service rendu.
  local exceptions=" /etc/lcars /etc/lcars/seat.uid /var/lib/lcars /var/tmp/lcars /var/tmp/lcars/toolchain-work /var/tmp/lcars/deposit /usr/local/bin "
  local p rompu=0
  while read -r p; do
    [ -n "$p" ] || continue
    [[ "$p" == /run/* ]] && continue
    [[ "$exceptions" == *" $p "* ]] && continue
    under_mount "$p" "$DEV" && continue
    echo "$p : ecrit par l'init ou le protocole, hors de tout volume du compose, et pas nomme dans les exceptions" >&2
    rompu=1
  done <<<"$chemins"
  [ "$rompu" -eq 0 ]
}
