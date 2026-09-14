#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/delivery_form.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests for prov_delivery + 15-toolchain + 16-node — LA FORME DE LA LIVRAISON

# shellcheck disable=SC2030,SC2031

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  DEPLOY="$BATS_TEST_DIRNAME/.."
  # Un FAUX arbre source, parce que `repo_root()` se derive de l'emplacement de la lib : c'est cette
  # racine-la que le discriminant interroge, et c'est donc la seule qu'un temoin ait a fabriquer.
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy"
  cp -r "$DEPLOY/lib" "$RACINE/deploy/lib"
  cp "$DEPLOY/installer-constants.env" "$DEPLOY/system.manifest" "$RACINE/deploy/"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"

  STAMP="$RACINE/.source-revision"
  # les liens, l'Elixir posé : tout se lit sous le décor, jamais sur la machine
  decor_pose
  ELIXIR_PREFIX="$LCARS_DECOR_ROOT/opt/elixir-"
  mkdir -p "$LCARS_DECOR_ROOT/opt"
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
  PROV_SOURCE_STAMP=.autre-tampon run lib 'prov_delivery'
  [ "$output" = source ]
}

@test "NODE : livraison binaire — node n'est ni mesuré ni posé, et la doc est l'affaire de 44-media" {
  # le décor ne porte aucune doc : un check qui la mesurait ici portait un drift que 16 ne converge jamais
  paquet
  node check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | refute_out 'DRIFT|node absent'
  node apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"node non posé — livraison binaire"* ]]
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

# bats test_tags=structure
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

@test "TOOLCHAIN : livraison source, erlang et le pin déjà là — rien n'est posé, ni par apt ni par le zip, et le journal n'en note rien" {
  checkout                                   # livraison source : le module travaille
  export PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/install.journal"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"\n' "$BATS_TEST_TMPDIR/apt.trace" > "$DECOR_BIN/apt-get"
  chmod 0755 "$DECOR_BIN/apt-get"
  # Le pin est DEJA pose sous le décor : le module prend la branche « deja pose » et ne telecharge
  # rien — un temoin ne sort jamais sur le reseau. Un erl doublé répond la majeure du plancher.
  local pin otp
  pin="$(sed -n 's/^PROV_ELIXIR_PIN=//p' "$DEPLOY/installer-constants.env")"
  otp="$(sed -n 's/^PROV_ELIXIR_OTP_MAJOR=//p' "$DEPLOY/installer-constants.env")"
  [ -n "$pin" ]
  printf '#!/usr/bin/env bash\necho "%s"\n' "$otp" > "$DECOR_BIN/erl"; chmod 0755 "$DECOR_BIN/erl"
  printf '#!/usr/bin/env bash\n[[ "${@: -1}" == erlang ]] && printf installed || printf not-installed\n' > "$DECOR_BIN/dpkg-query"
  chmod 0755 "$DECOR_BIN/dpkg-query"
  mkdir -p "${ELIXIR_PREFIX}${pin}/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$pin" > "${ELIXIR_PREFIX}${pin}/bin/elixir"
  chmod 0755 "${ELIXIR_PREFIX}${pin}/bin/elixir"
  local b; for b in elixirc mix iex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${ELIXIR_PREFIX}${pin}/bin/$b"
    chmod 0755 "${ELIXIR_PREFIX}${pin}/bin/$b"
  done
  run env PROVISION_LIB="$PROVISION_LIB" PROV_JOURNAL_ACC="$PROV_JOURNAL_ACC" \
      bash "$DEPLOY/modules.d/15-toolchain.sh" apply
  [[ "$output" == *"déjà posé"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/apt.trace" ]
  # le journal compte ce que la passe a posé : un paquet trouvé n'y entre pas
  refute grep -qsE 'erlang|elixir' "$PROV_JOURNAL_ACC"
}


# bats test_tags=structure
@test "PACK : le chemin du dist est celui que 44-media LIT — aucune convention nouvelle" {
  # Si les deux divergeaient, le paquet porterait sa doc a un endroit que le rail ne regarde pas :
  # un fichier de plus dans le tar, et un drift de plus sur la cible.
  local pack="$BATS_TEST_DIRNAME/../pack.sh"
  local media="$DEPLOY/modules.d/44-media.sh"
  grep -qE '^SITE_SRC=assets/github\.io$' "$pack"
  grep -qE '^SITE_SRC="\$\(repo_root\)/assets/github\.io"$' "$media"
  # et la BASE d'URL est la meme des deux cotes — servie ailleurs, chaque asset serait faux
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$pack"
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$media"
}

# bats test_tags=structure
@test "44-media : livraison binaire — il POSE la doc du paquet, il ne la batit pas" {
  local media="$DEPLOY/modules.d/44-media.sh"
  local bloc; bloc="$(sed -n '/^build_doc()/,/^}$/p' "$media")"
  [ -n "$bloc" ]
  grep -q 'prov_delivery_is_binary' <<<"$bloc"
  # la garde est AVANT le test de npm, sinon elle ne sert a rien
  local n_bin n_npm
  n_bin="$(grep -n 'prov_delivery_is_binary' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_npm="$(grep -n 'command -v npm' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_bin" ]
  [ -n "$n_npm" ]
  [ "$n_bin" -lt "$n_npm" ]
  # et un paquet SANS doc est un echec NOMME, pas un build silencieux
  grep -q 'demi-livraison' <<<"$bloc"
}

# bats test_tags=structure
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


# 60-deploy écrit ce canal, sur la livraison que dit le même discriminant : ses témoins le jouent, apply entier
@test "CANAL : prov_channel_here dit kit d'une livraison binaire, source d'un checkout — le même discriminant, pas un second" {
  paquet;   run lib 'prov_channel_here'; [ "$output" = kit ]
  checkout; run lib 'prov_channel_here'; [ "$output" = source ]
}
