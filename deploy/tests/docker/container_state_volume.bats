#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/container_state_volume.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — l'etat de l'instance vit dans un VOLUME, jamais dans le systeme de fichiers du conteneur
#
# ⚖ user 2026-09-04 (Q1) : l'image est le produit, le conteneur une instance, l'ETAT DANS LE VOLUME.
# DI-11 : le client OAuth2 du deck vivait sous /etc/lcars dans le conteneur et se reposait a chaque
# conteneur recree. Ce temoin lit les DEUX composes : chaque chemin d'etat que le boot ecrit doit
# tomber sous un point de montage d'un volume nomme du service.
#
# ⚠ ET « CHAQUE CHEMIN » SE DERIVE, IL NE S'ECRIT PAS EN DUR (relecture hostile 2026-09-04, M9) :
# les deux premiers temoins mesurent deux chemins nommes ; le dernier lit ce que l'init de
# l'instance et le protocole des modules POSENT, et n'admet hors volume que ce qui est nomme ici
# avec sa raison.

load ../refute

setup() {
  DOCKER="$(cd "$BATS_TEST_DIRNAME/../../docker" && pwd)"
  DEV="$DOCKER/docker-compose.yml"; PULL="$DOCKER/docker-compose.install.yml"
  PROTO="$DOCKER/../../runtime/services/lib/module-protocol.sh"
}
env_of() { sed 's/#.*//' "$1" | sed -nE "s/^[[:space:]]+$2:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" | head -1; }
mounts_of() { sed 's/#.*//' "$1" | sed -nE 's/^[[:space:]]+-[[:space:]]+[a-z-]+:(\/[^:]+).*$/\1/p'; }
under_mount() { local m; while read -r m; do [[ "$1" == "$m" || "$1" == "$m"/* ]] && return 0; done < <(mounts_of "$2"); return 1; }

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
  grep -q 'os.environ.get("LCARS_DECK_OIDC_FILE"' "$DOCKER/../../runtime/services/console-deck.py"
  refute grep -q '"LCARS_DECK_OIDC"' "$DOCKER/../../runtime/services/console-deck.py"
  grep -q 'LCARS_DECK_OIDC_FILE' "$DOCKER/../../runtime/services/forge.d/deck-oidc.sh"
}

@test "le repertoire prive (jetons) est aussi sous le volume var — l'etat ne se separe pas" {
  local priv; priv="$(sed -nE 's/^: "\$\{LCARS_PRIVATE_DIR:=([^}]+)\}"/\1/p' "$PROTO" | head -1)"
  [ -n "$priv" ]
  under_mount "$priv" "$DEV" && under_mount "$priv" "$PULL"
}

@test "TOUT chemin d'etat que l'init ou le protocole nomme tombe sous un volume — ou dans la liste d'exceptions ECRITE ici" {
  local INIT="$DOCKER/../../runtime/services/container/init.sh"
  [ -f "$INIT" ]
  # Les cibles absolues des ensure_dir/write_atomic de l'init, les defauts absolus de ses variables,
  # et les defauts LCARS_*_FILE/_DIR du protocole — la valeur que le compose pose PRIME sur le defaut
  # (c'est le sujet du premier temoin : le poste garde /etc, le conteneur deplace sous le volume).
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

  # LES EXCEPTIONS, CHACUNE AVEC SA RAISON — une exemption groupee cacherait qu'elles ne disent pas
  # la meme chose :
  #   /run/…                     volatile par doctrine (classe `runtime` du manifeste) : le boot efface
  #                              ses verdicts, tout y est refait a chaque demarrage
  #   /etc/lcars, seat.uid       re-derives A CHAQUE BOOT par l'init (seat_resolve) — pas un etat
  #   /var/lib/lcars             le PARENT des quatre arbres du magasin, montes un par un (store.sh)
  #   /var/tmp/lcars…            scratch de la convergence d'outillage, jetable par construction
  #   /usr/local/bin             l'image (les liens du release), pas l'instance
  local exceptions=" /etc/lcars /etc/lcars/seat.uid /var/lib/lcars /var/tmp/lcars /var/tmp/lcars/toolchain-work /usr/local/bin "
  local p rompu=0
  while read -r p; do
    [ -n "$p" ] || continue
    [[ "$p" == /run/* ]] && continue
    [[ "$exceptions" == *" $p "* ]] && continue
    under_mount "$p" "$DEV" && under_mount "$p" "$PULL" && continue
    echo "$p : ecrit par l'init ou le protocole, hors de tout volume des deux composes, et pas nomme dans les exceptions" >&2
    rompu=1
  done <<<"$chemins"
  [ "$rompu" -eq 0 ]
}
