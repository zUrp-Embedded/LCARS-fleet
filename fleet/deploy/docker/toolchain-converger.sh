#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/toolchain-converger.sh
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: PROTO — l'UNIQUE geste privilegie du rail d'outillage : appliquer un manifeste deja signe
#
# ─── CE QU'IL EST, ET SURTOUT CE QU'IL N'EST PAS ────────────────────────────────────────────────
# Il n'interprete RIEN. Son entree est un manifeste YAML qu'un humain a approuve sur une branche
# protegee, a un SHA que le reconciliateur lui passe. Il en lit des champs TYPES et joue des
# gabarits de commande fixes. Aucun champ libre n'est lu : `evidence` existe pour l'humain qui
# signe, et ce script ne le regarde pas.
#
# C'est la difference entre « un humain a approuve D » et « un humain a approuve D, puis un agent a
# interprete D, puis root a execute l'interpretation ». La seconde chaine n'est pas gardee : ce que
# l'humain a lu n'est plus ce que root fait. Ici il n'y a pas d'etape d'interpretation.
#
# ─── UN SEUL VERBE EST PRIVILEGIE ───────────────────────────────────────────────────────────────
# `apt-get install` touche /usr et demande root. Tout le reste — l'installeur d'un SDK, l'assemblage
# d'un sysroot — ecrit SOUS LE MAGASIN et tourne sans privilege. La mesure du 2026-08-19 a retire du
# rail le seul verbe non-monotone qui restait (`dpkg --add-architecture`) : une racine apt PRIVEE
# resout et telecharge sans toucher au dpkg de l'hote, donc un sysroot s'assemble en non-root, et
# l'hote ne bouge pas d'un octet.
#
# ─── LA FERMETURE, PAS LE PAQUET NOMME ──────────────────────────────────────────────────────────
# `apt-get download <pkg>` reussit, extrait proprement, et rend un sysroot MORT : `libssl.so ->
# libssl.so.3` pend, parce que la cible vit dans `libssl3`, un AUTRE paquet. Vert a l'extraction,
# casse a l'edition de liens. `install --print-uris` est ce qui l'evite, et ce n'est pas une astuce
# d'optimisation : c'est la condition pour que le sysroot linke.
#
# USAGE : toolchain-converger.sh <sha>
#   Lit `ops/toolchains.d/*.yaml` du depot ops AU SHA donne, et applique chaque manifeste.
#   Idempotent : rejouer applique le meme etat. Un ecosysteme deja pose est saute.
#
# EXIT : 0 tout applique · 1 usage/dependance manquante · 2 manifeste refuse (forme, motif)
#      · 3 une application a echoue (le reconciliateur ne notera PAS le SHA)

set -euo pipefail

STORE="${LCARS_STORE_ROOT:-/var/lib/lcars}"
OPS_REPO="${LCARS_OPS_REPO:-fleet/lcars}"
FORGE="${FORGE_BASE_URL:-}"
TOKEN_FILE="${FORGE_TOKEN_FILE:-/home/private/system.gitea_token}"
WORK="${LCARS_TOOLCHAIN_WORK:-/var/lib/lcars/tofu/toolchain}"

# LE VERROU EST PRIS AVANT TOUT LE RESTE, et il n'est pas defensif. Deux invocations peuvent se
# croiser — un tick pendant le boot, deux ticks qui se chevauchent sur un `apt` long — et `apt-get`
# n'est PAS reentrant : deux processus root en parallele se battent sur /var/lib/dpkg/lock et l'un
# des deux meurt en laissant dpkg a moitie configure. Meme geste que le verrou d'apply de
# `forge-gestures.sh`.
LOCK="${LCARS_TOOLCHAIN_LOCK:-/var/lock/lcars-toolchain.lock}"

die() { echo "toolchain-converger: $2" >&2; exit "$1"; }

[[ $# -eq 1 ]] || die 1 "usage: toolchain-converger.sh <sha>"
SHA="$1"
[[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] || die 1 "sha invalide: '$SHA' (attendu 7-40 hex)"

for _b in curl jq apt-get dpkg-deb; do
  command -v "$_b" >/dev/null 2>&1 || die 1 "dependance manquante: $_b"
done

mkdir -p "$(dirname "$LOCK")" "$WORK"
exec 9>"$LOCK" || die 1 "verrou inouvrable ($LOCK)"
flock -n 9 || die 0 "une convergence tourne deja — celle-ci n'a rien a faire (ce n'est PAS un echec)"

[[ -n "$FORGE" ]] || die 1 "FORGE_BASE_URL absent — impossible de lire le manifeste"
[[ -r "$TOKEN_FILE" ]] || die 1 "jeton illisible ($TOKEN_FILE)"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

api() { curl -sS -m 30 -H "Authorization: token $TOKEN" "$FORGE/api/v1$1"; }

# ─── LE MANIFESTE EST LU AU SHA, JAMAIS SUR LA BRANCHE ──────────────────────────────────────────
# Lire « la derniere version de la branche » ouvrirait une fenetre entre le moment ou le
# reconciliateur a constate l'ecart et celui ou ce script lit : un merge qui atterrit entre les deux
# serait applique SANS que le SHA note lui corresponde. Le SHA est le pin, et c'est lui qu'un humain
# a signe.
list_manifests() {
  api "/repos/$OPS_REPO/contents/ops/toolchains.d?ref=$SHA" \
    | jq -r 'if type=="array" then .[] | select(.name|endswith(".yaml")) | .path else empty end'
}

fetch_manifest() {
  api "/repos/$OPS_REPO/contents/$1?ref=$SHA" | jq -r '.content' | base64 -d
}

# ─── LECTURE DES CHAMPS : TYPEE, ET AUCUN CHAMP LIBRE ───────────────────────────────────────────
# `yq` n'est pas garanti present ; le manifeste est genere par `Fleet.Toolchain` et sa forme est
# donc connue et stable. On lit ce dont on a besoin avec des motifs ancres, et TOUT ce qui ne matche
# pas un motif est ignore — un champ inconnu n'est pas une erreur, c'est un champ qu'on ne joue pas.
field() { sed -n "s/^$1: *//p" <<< "$2" | head -1 | tr -d '"'; }

list_under() { # list_under <cle> <yaml> -> une entree par ligne
  awk -v key="$2:" '
    $0 == key         { inb=1; next }
    inb && /^  - /    { sub(/^  - /,""); gsub(/^"|"$/,""); print; next }
    inb && /^[^ ]/    { inb=0 }
  ' <<< "$1"
}

# ⚠ LA CEINTURE EST ICI, ET ELLE EST LA DERNIERE. Le schema de l'outil MCP borne deja ce qu'un pod
# peut exprimer, mais ce script lit un FICHIER : un manifeste pose a la main, ou une PR editee apres
# coup, n'est pas passe par ce schema. Un nom de paquet qui commence par `-` serait pris pour une
# option d'`apt-get`.
safe_pkg() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.:-]*$ ]]; }
safe_eco() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,31}$ ]]; }

applied_marker() { echo "$STORE/state/eco.d/$1.applied"; }

apply_apt() { # apply_apt <yaml>
  local pkgs=() p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    safe_pkg "$p" || die 2 "nom de paquet refuse: '$p'"
    pkgs+=("$p")
  done < <(list_under "$1" "  packages")

  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  echo "toolchain-converger: apt-get install ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -- "${pkgs[@]}"
}

# ─── LE SYSROOT S'ASSEMBLE, IL NE SE PRELEVE PAS ────────────────────────────────────────────────
# Racine apt PRIVEE : l'hote garde son `dpkg --print-foreign-architectures` vide, son apt intact, et
# ce repertoire se jette avec un `rm -rf`. La fermeture est resolue par `--print-uris`, jamais un
# paquet nomme seul (cf. l'en-tete).
apply_sysroot() { # apply_sysroot <yaml> <eco>
  local arch; arch="$(field arch "$1")"
  [[ "$arch" =~ ^[a-z0-9]+$ ]] || die 2 "arch refusee: '$arch'"

  local root="$WORK/aptroot-$2" target="$STORE/sysroots/$2"
  rm -rf "$root"; mkdir -p "$root"/etc/apt/{sources.list.d,preferences.d,apt.conf.d,trusted.gpg.d} \
                          "$root"/var/lib/apt/lists/partial "$root"/var/cache/apt/archives/partial \
                          "$root"/var/lib/dpkg
  : > "$root/var/lib/dpkg/status"
  list_under "$1" "  sources" > "$root/etc/apt/sources.list"

  # ⚠ LE KEYRING N'EST PAS OPTIONNEL. Un convergeur qui telecharge des paquets non signes est le
  # trou supply-chain qu'on refuse d'ouvrir par commodite — et la commodite serait grande, puisque
  # `AllowInsecureRepositories` fait marcher le reste tout de suite.
  local keyring; keyring="$(field keyring "$1")"
  [[ -n "$keyring" && -r "$keyring" ]] || die 2 "keyring de la cible absent ou illisible: '$keyring'"
  cp "$keyring" "$root/etc/apt/trusted.gpg.d/target.gpg"

  local O=(-o "Dir::State=$root/var/lib/apt" -o "Dir::State::status=$root/var/lib/dpkg/status"
           -o "Dir::Cache=$root/var/cache/apt" -o "Dir::Etc=$root/etc/apt"
           -o "APT::Architecture=$arch" -o "APT::Architectures::=$arch")

  apt-get "${O[@]}" update
  local pkgs=() p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    safe_pkg "$p" || die 2 "nom de paquet refuse: '$p'"
    pkgs+=("$p")
  done < <(list_under "$1" "  packages")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  mkdir -p "$target"
  ( cd "$root" && apt-get "${O[@]}" install --print-uris -y -- "${pkgs[@]}" \
      | grep "^'http" | sed "s/^'//;s/'.*//" | xargs -r -n1 curl -sSO )
  for d in "$root"/*.deb; do [[ -e "$d" ]] && dpkg-deb -x "$d" "$target"; done
  rm -rf "$root"
  echo "toolchain-converger: sysroot $2 assemble dans $target"
}

rc=0
for path in $(list_manifests); do
  eco="$(basename "$path" .yaml)"
  safe_eco "$eco" || die 2 "nom d'ecosysteme refuse: '$eco'"

  # IDEMPOTENCE PAR LE SHA, PAS PAR LA PRESENCE D'UN REPERTOIRE. Un arbre a moitie telecharge
  # existe et n'est pas installe : le marqueur n'est pose qu'APRES un succes, et il porte le SHA qui
  # l'a produit.
  marker="$(applied_marker "$eco")"
  [[ -r "$marker" && "$(cat "$marker")" == "$SHA" ]] && { echo "toolchain-converger: $eco deja a $SHA"; continue; }

  yaml="$(fetch_manifest "$path")"
  grep -q '^kind: ecosystem_enable' <<< "$yaml" || die 2 "$path: kind inattendu"

  if ( set -e
       grep -q '^apt:'     <<< "$yaml" && apply_apt     "$yaml"
       grep -q '^sysroot:' <<< "$yaml" && apply_sysroot "$yaml" "$eco"
       true )
  then
    mkdir -p "$(dirname "$marker")"; printf '%s\n' "$SHA" > "$marker"
    echo "toolchain-converger: $eco applique a $SHA"
  else
    echo "toolchain-converger: $eco A ECHOUE — le marqueur n'est PAS pose" >&2
    rc=3
  fi
done

exit "$rc"
