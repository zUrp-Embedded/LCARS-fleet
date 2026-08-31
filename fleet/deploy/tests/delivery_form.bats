#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/delivery_form.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for prov_delivery + 15-toolchain + 16-node — LA FORME DE LA LIVRAISON
#
# ─── LA DOCTRINE QUE CES TEMOINS TIENNENT ───────────────────────────────────────────────────────
#
#   binary  la release Elixir ET la doc sont deja baties. Rien n'est a batir sur la cible, donc
#           aucun outil de build n'y est pose.
#   source  on bâtit les deux. Les compilateurs vivent le temps du build.
#
# ⚠ ON N'EN FAIT JAMAIS LA MOITIE, et c'est la moitie qui est le vrai risque. Une machine qui porte
# node mais pas la toolchain Elixir — ou l'inverse — n'est ni une boite de prod ni un poste de dev :
# c'est un etat que personne n'a decrit, et sur lequel aucun diagnostic ne se prononce. Les deux
# modules lisent donc LE MEME discriminant, et ces temoins mesurent qu'ils le lisent pareil.
#
# ⚠ CE QUI EST MESURE EST LA DECISION. Aucun de ces temoins ne telecharge, ne compile, ni ne pose
# quoi que ce soit : le cas « source » de `16-node apply` n'est deliberement pas joue jusqu'au bout
# (il irait chercher 60 Mo chez nodejs.org). Ce qui distingue les deux formes se decide AVANT.

# shellcheck disable=SC2030,SC2031

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  # Un FAUX arbre source, parce que `repo_root()` se derive de l'emplacement de la lib : c'est cette
  # racine-la que le discriminant interroge, et c'est donc la seule qu'un temoin ait a fabriquer.
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/fleet/deploy"
  # ⚠ TOUT `lib/`, PAS LE SEUL `provision-lib.sh` : la lib en source d'autres (`docker-endpoint.sh`)
  # par un chemin relatif a elle-meme. N'en copier qu'un fichier fait rendre a chaque appel un « No
  # such file » sur stderr — que `run` agrege dans `$output`, ou il fait echouer toute egalite
  # stricte. Le harnais mesurait alors le message d'erreur de son propre decor.
  cp -r "$DEPLOY/lib" "$RACINE/fleet/deploy/lib"
  export PROVISION_LIB="$RACINE/fleet/deploy/lib/provision-lib.sh"

  STAMP="$RACINE/.source-revision"
  export PROV_ROOT="$BATS_TEST_TMPDIR/opt-lcars"
  mkdir -p "$PROV_ROOT"

  # ⚠ LES DEUX SEAMS DE `15-toolchain`, ET LEUR ABSENCE A MORDU. Sans eux, `legacy_elixir_links`
  # sonde le VRAI `/usr/local/bin` : sur un poste de dev qui porte un elixir, l'`apply` du temoin
  # tentait de le supprimer, echouait faute de root, et sortait par `verdict_apply` AVANT le bloc
  # qu'on croyait mesurer. Un temoin qui touche la machine qui le joue ne mesure ni l'une ni l'autre.
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export LCARS_LEGACY_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
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
  # La deduction « pas de .git donc paquet » se trompe deux fois : sur un paquet detare DANS un
  # depot, et sur un clone dont le `.git` a ete retire pour l'expedier. Le tampon, lui, est ecrit
  # par celui qui sait — `pack.sh`.
  checkout
  refute test -e "$RACINE/.git"
  run lib 'prov_delivery'
  [ "$output" = source ]
}

@test "DISCRIMINANT : le nom du tampon a UNE source, et elle se surcharge" {
  # `PROV_SOURCE_STAMP` est la SSoT du nom de fichier. Un module qui ecrirait « .source-revision »
  # en dur ne suivrait pas une machine qui l'a deplace.
  printf 'x\n' > "$RACINE/.autre-tampon"
  LCARS_SOURCE_STAMP=.autre-tampon run lib 'prov_delivery'
  [ "$output" = binary ]
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
  # ⚠ ON REFUTE LE MOTIF DU CAS BINAIRE, PAS LE MOT « doc ». Le message du cas source NOMME la doc
  # lui aussi — « la doc du deck ne peut pas être bâtie » est sa consequence. Une refutation sur
  # « doc du deck » rougissait donc sur le bon comportement.
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
  # Un `/usr/local/bin/elixir` qui masque apt est un dechet dans les deux formes : c'est une
  # convergence d'ABSENCE, elle ne depend pas de ce qu'on a a batir. Sauter tout le module sur le
  # discriminant aurait emporte ce nettoyage avec le reste — sans que rien ne le dise.
  paquet
  ln -sf "${LCARS_LEGACY_ELIXIR_PREFIX}1.14.0/bin/elixir" "$PROV_LINK_DIR/elixir"
  toolchain check
  [[ "$output" == *"toolchain non requise"* ]]
  [[ "$output" == *"TOUJOURS DEVANT apt"* ]]   # le nettoyage a bien ete evalue, pas saute
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

@test "TOOLCHAIN : seuil DEJA atteint — le journal porte quand meme les deux paquets" {
  # ⚠ LA BRANCHE QUI NE FAIT RIEN LAISSE UNE TRACE, et c'est le trou que le geste sur `10-packages`
  # ne couvrait PAS : celui-la porte sur les depots apt, celui-ci sur `apt_ensure erlang elixir`, qui
  # n'est appelee QUE si le seuil n'est pas atteint. Machine deja au niveau : ni `apt_installed` ni
  # `apt_already` n'entraient au journal, et plus rien ne distinguait « LCARS les a poses » de « ils
  # etaient la avant nous » — la question meme a laquelle le journal existe pour repondre.
  checkout                                   # livraison source : le module travaille
  export PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/install.journal"
  run env PROVISION_LIB="$PROVISION_LIB" PROV_JOURNAL_ACC="$PROV_JOURNAL_ACC" \
          PROV_LINK_DIR="$PROV_LINK_DIR" LCARS_LEGACY_ELIXIR_PREFIX="$LCARS_LEGACY_ELIXIR_PREFIX" \
          PROV_ELIXIR_OTP_MAJOR=1 PROV_ELIXIR_MIN=0.0.1 \
      bash "$DEPLOY/modules.d/15-toolchain.sh" apply
  grep -q '^apt_already .*erlang' "$PROV_JOURNAL_ACC"
  grep -q '^apt_already .*elixir' "$PROV_JOURNAL_ACC"
}
