#!/usr/bin/env bats
# SOURCE: deploy/tests/delivery_form.bats
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
# node mais pas la toolchain Elixir — ou l'inverse — n'est ni un conteneur de prod ni un poste de dev :
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
  mkdir -p "$RACINE/deploy"
  # ⚠ TOUT `lib/`, PAS LE SEUL `provision-lib.sh` : la lib en source d'autres (`docker-endpoint.sh`)
  # par un chemin relatif a elle-meme. N'en copier qu'un fichier fait rendre a chaque appel un « No
  # such file » sur stderr — que `run` agrege dans `$output`, ou il fait echouer toute egalite
  # stricte. Le harnais mesurait alors le message d'erreur de son propre decor.
  cp -r "$DEPLOY/lib" "$RACINE/deploy/lib"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"

  STAMP="$RACINE/.source-revision"
  # Le CANAL est a nous, meme quand on ne le lit pas : un temoin qui joue un module lecteur du
  # canal ne lit jamais celui de la machine (MUR I21).
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/channel"
  export PROV_ROOT="$BATS_TEST_TMPDIR/opt-lcars"
  mkdir -p "$PROV_ROOT"

  # ⚠ LES DEUX SEAMS DE `15-toolchain`, ET LEUR ABSENCE A MORDU. Sans eux, `legacy_elixir_links`
  # sonde le VRAI `/usr/local/bin` : sur un poste de dev qui porte un elixir, l'`apply` du temoin
  # tentait de le supprimer, echouait faute de root, et sortait par `verdict_apply` AVANT le bloc
  # qu'on croyait mesurer. Un temoin qui touche la machine qui le joue ne mesure ni l'une ni l'autre.
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/link"
  export LCARS_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
  # ⚠ GARDE DE COUTURE, ET ELLE A UNE CICATRICE. `apply` fait `rm -rf "$LCARS_ELIXIR_PREFIX"*` : le
  # jour ou la variable du module a ete renommee sans ce fichier (2026-09-07), la couture n'a plus
  # rien couvert et le geste a vise `/opt/elixir-1.18.4`, l'Elixir du poste — sauve par le seul fait
  # que bats tourne sans root. Un temoin qui joue une branche destructive PROUVE d'abord ou elle tire.
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
  # ⚠ LA BRANCHE QUI NE FAIT RIEN LAISSE UNE TRACE, et c'est le trou que le geste sur `10-packages`
  # ne couvrait PAS : celui-la porte sur les depots apt, celui-ci sur `apt_ensure`, qui n'est appelee
  # QUE si le seuil n'est pas atteint. Machine deja au niveau : rien n'entrait au journal, et plus
  # rien ne distinguait « LCARS l'a pose » de « il etait la avant nous » — la question meme a
  # laquelle le journal existe pour repondre.
  #
  # ⚠ ET LA PAIRE A ETE DEFAITE (2026-09-06) : la cible LTS sert Elixir 1.18, le plancher est 1.20 —
  # erlang reste a apt, Elixir vient du zip officiel epingle. Le journal ne peut donc plus porter
  # « apt_already … elixir », et l'exiger serait exiger le retour de la distro. La trace d'Elixir,
  # quand le rail le pose, est `posed_dir` / `posed_link` (mesure : modules.d/15-toolchain.bats).
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

# ─── LE PAQUET PORTE LES DEUX MOITIES ───────────────────────────────────────────────────────────

@test "PACK : le paquet emporte la DOC autant que la release — sinon c'est une demi-livraison" {
  # ⚠ LE DEFAUT QUE CE TEMOIN FERME EST NE DE R4, ET IL ETAIT INVISIBLE AVANT. Tant que la cible
  # posait node dans tous les cas, un paquet sans doc se rattrapait tout seul : `44-media` la
  # batissait sur place. Depuis que `16-node` lit le discriminant, une cible qui installe un paquet
  # n'a plus node — donc si le paquet n'apporte pas la doc, PERSONNE ne la batira jamais, et le
  # drift « doc du deck absente » ne se converge par aucun geste.
  local pack="$BATS_TEST_DIRNAME/../../pack.sh"
  [ -f "$pack" ]
  grep -q 'npm run build' "$pack"                       # il la BATIT
  grep -qE 'cp -a "\$SITE_SRC/dist"' "$pack"            # et il l EMPORTE
  # les deux produits partent cote a cote, pour la meme raison : gitignores, donc hors `git archive`
  local n_rel n_doc
  n_rel="$(grep -n '_build/prod/rel/lcars_fleet' "$pack" | tail -1 | cut -d: -f1)"
  n_doc="$(grep -n 'cp -a "\$SITE_SRC/dist"' "$pack" | head -1 | cut -d: -f1)"
  [ -n "$n_rel" ] && [ -n "$n_doc" ]
  [ "$n_rel" -lt "$n_doc" ]
  # et le tar se ferme APRES les deux
  local n_tar; n_tar="$(grep -n 'tar -czf' "$pack" | head -1 | cut -d: -f1)"
  [ "$n_doc" -lt "$n_tar" ]
}

@test "PACK : le chemin du dist est celui que 44-media LIT — aucune convention nouvelle" {
  # Si les deux divergeaient, le paquet porterait sa doc a un endroit que le rail ne regarde pas :
  # un fichier de plus dans le tar, et un drift de plus sur la cible.
  local pack="$BATS_TEST_DIRNAME/../../pack.sh"
  local media="$DEPLOY/modules.d/44-media.sh"
  grep -qE '^SITE_SRC="\$\{LCARS_SITE_SRC:-assets/github\.io\}"' "$pack"
  grep -qE 'SITE_SRC="\$\{LCARS_SITE_SRC:-\$\(repo_root\)/assets/github\.io\}"' "$media"
  # et la BASE d'URL est la meme des deux cotes — servie ailleurs, chaque asset serait faux
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$pack"
  grep -qE 'SITE_BASE="\$\{LCARS_SITE_BASE:-/doc/\}"' "$media"
}

@test "44-media : livraison binaire — il POSE la doc du paquet, il ne la batit pas" {
  # Le symetrique de R4 : « rien a batir sur la cible ». Sans cette branche le module mourait sur
  # « npm absent — 16-node pose le precompile ; joue-le d abord » — une instruction impossible,
  # puisque l etat-cible de `16-node` en livraison binaire est justement de ne rien poser.
  local media="$DEPLOY/modules.d/44-media.sh"
  local bloc; bloc="$(sed -n '/^build_doc()/,/^}$/p' "$media")"
  [ -n "$bloc" ]
  grep -q 'prov_delivery_is_binary' <<<"$bloc"
  # la garde est AVANT le test de npm, sinon elle ne sert a rien
  local n_bin n_npm
  n_bin="$(grep -n 'prov_delivery_is_binary' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_npm="$(grep -n 'command -v "\$NPM_BIN"' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_bin" ] && [ -n "$n_npm" ]
  [ "$n_bin" -lt "$n_npm" ]
  # et un paquet SANS doc est un echec NOMME, pas un build silencieux
  grep -q 'demi-livraison' <<<"$bloc"
}

@test "44-media : la POSE est commune aux deux livraisons — une seule copie" {
  # Ce qui change est QUI a bati le dist, pas ce qu on en fait. Deux copies de la pose deriveraient
  # sur le mode, le proprietaire ou l atomicite, et une des deux formes servirait une doc que
  # personne n a relue.
  # ⚠ CE TEMOIN PINNAIT LA CHAINE `cp -a "$SITE_SRC/dist/."`, ET LA FORME A DU CHANGER pour une
  # raison mesuree : le `.` designe le REPERTOIRE source, donc `cp -a` recopiait ses attributs sur la
  # destination — le mode et le proprietaire du checkout par-dessus ceux que `prov_scaffold_dir`
  # venait de poser. Et `-exec … \;` rendait 0 meme quand `cp` echouait (mesure du 2026-09-08 : rc 0
  # sous `\;`, rc 1 sous `+`). La PROPRIETE, elle, n'a pas bouge : le dist ne se copie qu'a UN seul
  # endroit. On la mesure sans imposer la forme — sinon le prochain correctif juste rougit ici.
  local media="$DEPLOY/modules.d/44-media.sh"
  [ "$(grep -c 'poser_doc' "$media")" -ge 3 ]           # la fonction + ses deux appelants
  # les lignes de CODE (commentaires exclus) qui copient le dist, quelle que soit la primitive
  local n_copies
  n_copies="$(grep -vE '^\s*#' "$media" | grep -E '\$SITE_SRC/dist' | grep -cE '\b(cp|rsync|install)\b')"
  [ "$n_copies" -eq 1 ] \
    || { echo "$n_copies gestes copient \$SITE_SRC/dist — une seule pose, sinon les deux formes derivent"; \
         grep -vE '^\s*#' "$media" | grep -nE '\$SITE_SRC/dist' >&2; return 1; }
}

# ─── CE QUE LA PREMIERE INSTALL BINAIRE REELLE A TROUVE (banc 2006, 2026-09-01) ─────────────────

@test "PACK : un arbre MODIFIE est REFUSE — le gate et le tar liraient deux codes differents" {
  # ⚠ LE DEFAUT LE PLUS CHER DE CE SCRIPT, ET IL ETAIT INVISIBLE. `pack.sh` s EXECUTE depuis l arbre
  # de travail (`mix gate`, `mix release`, `npm run build` lisent l arbre) et ARCHIVE `HEAD`. Les
  # deux divergent des qu une modification n est pas commitee : le paquet contient alors un code que
  # le gate n a jamais vu.
  #
  # Mesure : le tar portait la doc que la section neuve venait de batir — donc l arbre avait bien
  # tourne — ET la version HEAD des modules, sans le correctif qui va avec. `44-media` est mort sur
  # « npm absent », le message exact que ce correctif absent devait empecher.
  local pack="$BATS_TEST_DIRNAME/../../pack.sh"
  grep -qE 'git diff --quiet HEAD .*\|\| die' "$pack"
  # et le refus arrive AVANT le gate : echouer apres sept minutes de compilation est une punition
  local n_refus n_gate
  # ⚠ HORS COMMENTAIRES : l en-tete CITE « mix gate » pour dire ce que le script ne reimplemente pas.
  # Un `grep -n` nu comparait donc le refus a une ligne de PROSE, et rougissait sur du code juste.
  local code; code="$(grep -vnE "^\\s*#" "$pack" | sed "s/^\\([0-9]*\\):/\\1:/")"
  n_refus="$(grep -E "git diff --quiet HEAD" <<<"$code" | head -1 | cut -d: -f1)"
  n_gate="$(grep -E "mix gate" <<<"$code" | head -1 | cut -d: -f1)"
  [ "$n_refus" -lt "$n_gate" ]
}

@test "PACK : le tampon ne porte plus « +local » — il decrit le PAQUET, pas l arbre" {
  # Il mentait dans les DEUX sens : il disait « arbre modifie » d un paquet qui ne contenait AUCUNE
  # de ces modifications. `+local` garde tout son sens dans `prov_source_rev`, qui decrit un arbre.
  local pack="$BATS_TEST_DIRNAME/../../pack.sh"
  grep -vE '^\s*#' "$pack" | refute_out '\+local'
  grep -q 'rev-parse --short=8 HEAD' "$pack"
}

@test "15-toolchain : livraison binaire — le plancher OTP n est PAS verifie" {
  # Le module s est contredit en trois lignes sur le banc 2006 : « erlang et elixir non poses,
  # livraison binaire » puis « Erlang/OTP « 0 » toujours sous le plancher 27 » puis rc=1. La release
  # embarque son ERTS : le plancher OTP de la MACHINE ne decide de rien quand rien ne compile.
  local mod="$DEPLOY/modules.d/15-toolchain.sh"
  # ⚠ HORS COMMENTAIRES, pour la meme raison : la prose du correctif CITE le message qu il corrige.
  local bloc; bloc="$(sed -n "/^apply()/,\$p" "$mod" | grep -vE "^\\s*#")"
  local n_garde n_plancher
  n_garde="$(grep -n 'plancher OTP/Elixir non vérifié' <<<"$bloc" | head -1 | cut -d: -f1)"
  n_plancher="$(grep -n 'toujours sous le plancher' <<<"$bloc" | head -1 | cut -d: -f1)"
  [ -n "$n_garde" ] && [ -n "$n_plancher" ]
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

@test "PACK : la release est assemblee dans un repertoire VIDE, et le paquet est refuse si elle porte plus d'une lib ou un tampon qui n'est pas HEAD" {
  # 2026-09-05, banc 2003 : le tar portait une lib/lcars_fleet-0.1.0 de passe5 a cote de la 0.9.0 —
  # `mix release --overwrite` ne nettoie pas. Le pack vide d'abord, puis atteste : une lib, sha = HEAD.
  local pack="$BATS_TEST_DIRNAME/../../pack.sh"
  [ -f "$pack" ]
  local body; body="$(grep -vE '^\s*#' "$pack")"
  grep -qE '^rm -rf runtime/_build/prod/rel/lcars_fleet$' <<<"$body"
  # le rm vient AVANT mix release
  local l_rm l_rel
  l_rm="$(grep -nE '^rm -rf runtime/_build/prod/rel/lcars_fleet$' <<<"$body" | cut -d: -f1)"
  l_rel="$(grep -nE 'mix release --overwrite' <<<"$body" | head -1 | cut -d: -f1)"
  [ "$l_rm" -lt "$l_rel" ]
  grep -qE 'lib/lcars_fleet-\*' <<<"$body"
  grep -qE 'eq 1 .*die' <<<"$body" || grep -qE '"\$\{#_libs\[@\]\}" -eq 1' <<<"$body"
  grep -qE '"\$_built" == "\$SHA"' <<<"$body"
}

# ─── LE CANAL — QUI A POSE (lot 2 du chantier release, 2026-09-05) ──────────────────────────────
#
# `prov_delivery` dit la FORME de ce qu'on pose (binary/source) ; `prov_channel` dit QUI a pose
# (source/kit/deb). Les deux se rejoignent en un point, et un seul : `60-deploy` ecrit `kit` quand
# la livraison etait binaire et `source` sinon — et il ne l'ecrit JAMAIS sous `deb`, ou c'est le
# postinst du paquet qui parle et ou ce module ne pose rien.

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

@test "CANAL : sous deb, 60-deploy n'ecrit JAMAIS le canal — apply est branche sur check avant d'atteindre poser_canal" {
  # Le seul ecrivain du canal sur ce rail est `poser_canal`, et il ne vit que dans `apply()` ; sous
  # `deb` le dispatch ne joue pas `apply`. Deux faits, mesures separement.
  local mod="$DEPLOY/modules.d/60-deploy.sh" code
  code="$(grep -vE '^\s*#' "$mod")"
  [ "$(grep -c 'prov_channel_write' <<<"$code")" -eq 1 ]                 # dans poser_canal seul
  sed -n '/^poser_canal()/,/^}/p' "$mod" | grep -q 'prov_channel_write'
  sed -n '/^check()/,/^}/p' "$mod" | grep -vE '^\s*#' | refute_out 'poser_canal|prov_channel_write'
  local disp; disp="$(sed -n '/^case "${1:?usage/,$p' "$mod" | grep -vE '^\s*#')"
  grep -q 'if poseur_is_dpkg; then check --dpkg' <<<"$disp"
}
