#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/delivery_form.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests for prov_delivery + 15-toolchain + 16-node — LA FORME DE LA LIVRAISON

# shellcheck disable=SC2030,SC2031

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  # Un FAUX arbre source, parce que `repo_root()` se derive de l'emplacement de la lib : c'est cette
  # racine-la que le discriminant interroge, et c'est donc la seule qu'un temoin ait a fabriquer.
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy"
  cp -r "$DEPLOY/lib" "$RACINE/deploy/lib"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"

  STAMP="$RACINE/.source-revision"
  # Le CANAL est a nous, meme quand on ne le lit pas : un temoin qui joue un module lecteur du
  # canal ne lit jamais celui de la machine (MUR I21).
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/channel"
  export PROV_ROOT="$BATS_TEST_TMPDIR/opt-lcars"
  mkdir -p "$PROV_ROOT"

  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export LCARS_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
  [[ "$LCARS_ELIXIR_PREFIX" == "$BATS_TEST_TMPDIR"/* ]] \
    || { echo "couture Elixir hors du tmp du test : $LCARS_ELIXIR_PREFIX — le module viserait la vraie machine"; return 1; }
  mkdir -p "$PROV_LINK_DIR" "$BATS_TEST_TMPDIR/opt"
}

# La livraison BINAIRE se declare : `pack.sh` ecrit le tampon a la racine du paquet.
paquet() { printf 'abc1234\n' > "$STAMP"; }
# La livraison SOURCE ne se declare pas — c'est l'absence du tampon qui la dit.
checkout() { rm -f "$STAMP"; }

lib() { bash -c '. "$1"; shift; eval "$@"' _ "$PROVISION_LIB" "$@"; }
node()      { run bash "$DEPLOY/modules.d/16-node.sh" "$1"; }
toolchain() { run bash "$DEPLOY/modules.d/15-toolchain.sh" "$1"; }

@test "DISCRIMINANT : le tampon DIT paquet, son absence dit source" {
  paquet;   run lib 'prov_delivery'; [ "$output" = binary ]
  checkout; run lib 'prov_delivery'; [ "$output" = source ]
}

@test "DISCRIMINANT : il est EXPLICITE — un depot sans .git ne suffit pas a dire « paquet »" {
  checkout
  refute test -e "$RACINE/.git"
  run lib 'prov_delivery'
  [ "$output" = source ]
}

@test "DISCRIMINANT : le nom du tampon ne se surcharge pas — pack, kit-verify, deploy-release et l'installeur écrivent tous .source-revision" {
  printf 'x\n' > "$RACINE/.autre-tampon"
  LCARS_SOURCE_STAMP=.autre-tampon run lib 'prov_delivery'
  [ "$output" = source ]
}

@test "NODE : livraison binaire — la doc est EXIGEE, node n'est pas posé" {
  paquet
  node apply
  [[ "$output" == *"node non posé"* ]]
  [[ "$output" == *"livraison binaire"* ]]
}

@test "NODE : livraison binaire — le check mesure la DOC, jamais la version de node" {
  paquet
  node check
  [[ "$output" == *"doc du deck"* ]]
  printf '%s\n' "$output" | refute_out 'node absent'
}

@test "NODE : livraison source — c'est node qui est mesuré, pas la doc" {
  # Le sens qui manquait : sans lui, un module qui repondrait « rien a batir » a TOUT passerait les
  # deux temoins ci-dessus en ayant cesse de faire son travail.
  checkout
  node check
  [[ "$output" == *"node absent"* || "$output" == *"node "*" posé"* || "$output" == *"≠ pin"* ]]
  printf '%s\n' "$output" | refute_out 'livraison binaire|stage . site|doc du deck (absente|bâtie)'
}

@test "TOOLCHAIN : livraison binaire — erlang et elixir ne sont ni exigés ni posés" {
  paquet
  toolchain check
  [[ "$output" == *"toolchain non requise"* ]]
  toolchain apply
  [[ "$output" == *"non posés"* ]]
}

@test "TOOLCHAIN : livraison binaire — le nettoyage des reliquats PASSE QUAND MEME" {
  paquet
  ln -sf "${LCARS_ELIXIR_PREFIX}1.14.0/bin/elixir" "$PROV_LINK_DIR/elixir"
  toolchain check
  [[ "$output" == *"toolchain non requise"* ]]
  [[ "$output" == *"DEVANT apt"* ]]   # le nettoyage a bien ete evalue, pas saute
}

@test "LES DEUX MODULES LISENT LE MEME DISCRIMINANT — jamais une moitié de forme" {
  # La faute que ce temoin interdit : un discriminant recopie, qui derive dans un seul des deux
  # modules. Une machine porterait alors node sans la toolchain, ou l'inverse.
  local n=0
  grep -q 'prov_delivery_is_binary' "$DEPLOY/modules.d/16-node.sh"     && n=$((n + 1))
  grep -q 'prov_delivery_is_binary' "$DEPLOY/modules.d/15-toolchain.sh" && n=$((n + 1))
  [ "$n" -eq 2 ]
  # et aucun des deux ne se fabrique le sien — dans du CODE. Un commentaire a le droit de nommer le
  # tampon pour expliquer ce qu'il discrimine ; c'est une ligne qui le LIT qui serait la copie.
  grep -hvE '^[[:space:]]*#' "$DEPLOY/modules.d/16-node.sh" "$DEPLOY/modules.d/15-toolchain.sh" \
    | refute_out 'source-revision'
}

@test "TOOLCHAIN : seuil DEJA atteint — le journal porte quand meme erlang, et elixir n'y entre PLUS par apt" {
  checkout                                   # livraison source : le module travaille
  export PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/install.journal"
  # Le pin est DEJA pose sous la couture : le module prend la branche « deja pose » et ne telecharge
  # rien — un temoin ne sort jamais sur le reseau.
  local pin; pin="$(sed -n 's/^: "${PROV_ELIXIR_PIN:=\([^}]*\)}".*/\1/p' "$PROVISION_LIB")"
  [ -n "$pin" ]
  mkdir -p "${LCARS_ELIXIR_PREFIX}${pin}/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$pin" > "${LCARS_ELIXIR_PREFIX}${pin}/bin/elixir"
  chmod 0755 "${LCARS_ELIXIR_PREFIX}${pin}/bin/elixir"
  local b; for b in elixirc mix iex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${LCARS_ELIXIR_PREFIX}${pin}/bin/$b"
    chmod 0755 "${LCARS_ELIXIR_PREFIX}${pin}/bin/$b"
  done
  run env PROVISION_LIB="$PROVISION_LIB" PROV_JOURNAL_ACC="$PROV_JOURNAL_ACC" \
          PROV_LINK_DIR="$PROV_LINK_DIR" LCARS_ELIXIR_PREFIX="$LCARS_ELIXIR_PREFIX" \
          PROV_ELIXIR_OTP_MAJOR=1 PROV_ELIXIR_MIN=0.0.1 \
      bash "$DEPLOY/modules.d/15-toolchain.sh" apply
  grep -q '^apt_already .*erlang' "$PROV_JOURNAL_ACC"
  [[ "$output" == *"déjà posé"* ]]
  refute grep -qE '^apt_already .*elixir' "$PROV_JOURNAL_ACC"
}


@test "PACK : le chemin du dist est celui que 44-media LIT — aucune convention nouvelle" {
  # Si les deux divergeaient, le paquet porterait sa doc a un endroit que le rail ne regarde pas :
  # un fichier de plus dans le tar, et un drift de plus sur la cible.
  local pack="$BATS_TEST_DIRNAME/../pack.sh"
  local media="$DEPLOY/modules.d/44-media.sh"
  grep -qE '^SITE_SRC="\$\{LCARS_SITE_SRC:-assets/github\.io\}"' "$pack"
  grep -qE 'SITE_SRC="\$\{LCARS_SITE_SRC:-\$\(repo_root\)/assets/github\.io\}"' "$media"
  # et la BASE d'URL est la meme des deux cotes — servie ailleurs, chaque asset serait faux
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$pack"
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$media"
}

@test "44-media : livraison binaire — il POSE la doc du paquet, il ne la batit pas" {
  local media="$DEPLOY/modules.d/44-media.sh"
  local bloc; bloc="$(sed -n '/^build_doc()/,/^}$/p' "$media")"
  [ -n "$bloc" ]
  grep -q 'prov_delivery_is_binary' <<<"$bloc"
  # la garde est AVANT le test de npm, sinon elle ne sert a rien
  local n_bin n_npm
  n_bin="$(grep -n 'prov_delivery_is_binary' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_npm="$(grep -n 'command -v "\$NPM_BIN"' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_bin" ]
  [ -n "$n_npm" ]
  [ "$n_bin" -lt "$n_npm" ]
  # et un paquet SANS doc est un echec NOMME, pas un build silencieux
  grep -q 'demi-livraison' <<<"$bloc"
}

@test "44-media : la POSE est commune aux deux livraisons — une seule copie" {
  local media="$DEPLOY/modules.d/44-media.sh"
  [ "$(grep -c 'poser_doc' "$media")" -ge 3 ]           # la fonction + ses deux appelants
  # les lignes de CODE (commentaires exclus) qui copient le dist, quelle que soit la primitive
  local n_copies
  n_copies="$(grep -vE '^\s*#' "$media" | grep -E '\$SITE_SRC/dist' | grep -cE '\b(cp|rsync|install)\b')"
  [ "$n_copies" -eq 1 ] \
    || { echo "$n_copies gestes copient \$SITE_SRC/dist — une seule pose, sinon les deux formes derivent"; \
         grep -vE '^\s*#' "$media" | grep -nE '\$SITE_SRC/dist' >&2; return 1; }
}


@test "15-toolchain : livraison binaire — le plancher OTP n est PAS verifie" {
  local mod="$DEPLOY/modules.d/15-toolchain.sh"
  # ⚠ HORS COMMENTAIRES, pour la meme raison : la prose du correctif CITE le message qu il corrige.
  local bloc; bloc="$(sed -n "/^apply()/,\$p" "$mod" | grep -vE "^\\s*#")"
  local n_garde n_plancher
  n_garde="$(grep -n 'plancher OTP/Elixir non vérifié' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_plancher="$(grep -n 'toujours sous le plancher' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_garde" ]
  [ -n "$n_plancher" ]
  [ "$n_garde" -lt "$n_plancher" ]
}

@test "60-deploy : livraison binaire — \`mix\` n est pas exige" {
  # La release arrive faite ; `deploy-release.sh` la voit et ne compile pas. Exiger `mix` renvoyait
  # vers `15-toolchain`, dont l etat-cible en binaire est de ne RIEN poser.
  local mod="$DEPLOY/modules.d/60-deploy.sh"
  # ⚠ HORS COMMENTAIRES, pour la meme raison : la prose du correctif CITE le message qu il corrige.
  local bloc; bloc="$(sed -n "/^apply()/,\$p" "$mod" | grep -vE "^\\s*#")"
  grep -q 'prov_delivery_is_binary' <<<"$bloc"
  # l exigence vit DANS la branche source, pas avant elle
  local n_bin n_mix
  n_bin="$(grep -n 'prov_delivery_is_binary' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_mix="$(grep -n 'mix absent' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ "$n_bin" -lt "$n_mix" ]
}


canal_60() { # canal_60 <code> — 60-deploy source SANS son dispatch, sous la racine du decor
  local m="$BATS_TEST_TMPDIR/60.sh"
  sed '/^case "${1:?usage/,$d' "$DEPLOY/modules.d/60-deploy.sh" > "$m"
  run env LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/channel" LCARS_CHANNEL_OWNER="$(id -un):$(id -gn)" \
      PROVISION_MODULE=60-deploy XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" \
      bash -c "set -euo pipefail; mkdir -p '$RACINE/runtime/etc'; . '$m' >/dev/null 2>&1; $1"
}

@test "CANAL : 60-deploy ecrit KIT d'une livraison binaire, SOURCE d'un checkout — le MEME discriminant, pas un second" {
  paquet;   canal_60 'poser_canal'; [ "$status" -eq 0 ]; [ "$(cat "$BATS_TEST_TMPDIR/channel")" = "kit" ]
  checkout; canal_60 'poser_canal'; [ "$status" -eq 0 ]; [ "$(cat "$BATS_TEST_TMPDIR/channel")" = "source" ]
  # et la decision vit dans la LIB (prov_channel_here : binaire -> kit, sinon source), lue aussi par
  # le preflight et workstation — jamais le tampon par son nom (meme regle que 15/16)
  local corps; corps="$(sed -n '/^poser_canal()/,/^}/p' "$DEPLOY/modules.d/60-deploy.sh")"
  grep -q 'prov_channel_write "$(prov_channel_here)"' <<<"$corps"
  grep -vE '^\s*#' <<<"$corps" | refute_out 'source-revision|prov_delivery'
  paquet;   run lib 'prov_channel_here'; [ "$output" = kit ]
  checkout; run lib 'prov_channel_here'; [ "$output" = source ]
}

@test "CANAL : 60-deploy ECRIT le canal (poser_canal, dans apply seulement) et ne le LIT jamais" {
  # Le seul ecrivain du canal sur ce rail est `poser_canal`, et il ne vit que dans `apply()` ; la
  # lecture est l'affaire du preflight — aucun module ne branche dessus depuis que `deb` est parti.
  local mod="$DEPLOY/modules.d/60-deploy.sh" code
  code="$(grep -vE '^\s*#' "$mod")"
  [ "$(grep -c 'prov_channel_write' <<<"$code")" -eq 1 ]                 # dans poser_canal seul
  sed -n '/^poser_canal()/,/^}/p' "$mod" | grep -q 'prov_channel_write'
  sed -n '/^check()/,/^}/p' "$mod" | grep -vE '^\s*#' | refute_out 'poser_canal|prov_channel_write'
  refute_out 'prov_channel( |$|\))|poseur_is_dpkg|prov_channel_or_verdict|PROV_CHANNEL\b' <<<"$code"
}
