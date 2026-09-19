#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/catalogues.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-19
# STATUS: temoins de forge.d/catalogues.sh — l'APPELANT MINCE qui POSE le materiel des catalogues
#
# CE QUE CES TEMOINS TIENNENT, ET POURQUOI CE MODULE EST LE PLUS DANGEREUX DE LA SERIE : il
# SUPPRIME. C'est legitime — le materiel local est un cache re-clonable — mais exactement une
# condition rend la suppression sure, et c'est que la lecture de la forge ait REUSSI. Une lecture
# ratee lue comme une forge vide effacerait tous les catalogues du conteneur en annoncant qu'elle
# converge.
#
# ⚖ PHASE 7 : LA MESURE A DEMENAGE, PAS LA REGLE. Ce geste ne parle plus a la forge — la porte
# `lcars tool catalogue-installed` mesure (`Fleet.Application.CatalogueMaterial`, temoins en
# ExUnit), et son CODE porte la distinction qui interdit d'effacer a tort : 0 lu entier · 2 magasin
# ABSENT · 1 illisible. Sont partis d'ici avec elle : la pagination, le corps JSON, `jq`, les
# quatre temoins d'identite du manifeste et la sonde d'org. Restent ceux que rien d'autre ne
# tiendrait : les gardes AVANT la porte, le RELAI de chacun de ses trois codes, et la CONVERGENCE
# locale — cloner, mettre a jour, balayer.
#
# La porte est doublee par un `lcars` pose en tete de PATH, `git` par une doublure qui trace : ces
# temoins n'ouvrent aucune socket et ne clonent rien de reel.

# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

load ../../support/refute

setup() {
  MOD="$BATS_TEST_DIRNAME/../../../services/forge.d/catalogues.sh"
  LIB="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  # `-f`, pas `-x` : un module est joue par `bash`, jamais lance directement — il refuse meme de
  # l'etre. Epingler `-x` ici a rendu la derive des modes invisible pendant cinq commits.
  [ -f "$MOD" ]
  export LCARS_MODULE_PROTOCOL="$LIB"
  export LCARS_MODULE_TAG=50-catalogues
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export FORGE_BASE_URL="http://forge.invalid"
  mkdir -p "$LCARS_CATALOGUES_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export LCARS_CLI="$BATS_TEST_TMPDIR/bin/lcars"
  URL="http://forge.invalid/lcars/_catalogues.git"
}

# stub_porte <code de sortie> <stdout de la porte> [stderr de la porte]
# Note l'argv complet et l'adresse recue : les temoins mesurent COMMENT la porte est appelee, pas
# seulement ce qu'elle rend.
stub_porte() {
  cat > "$LCARS_CLI" <<EOF
#!/usr/bin/env bash
printf 'ARGV:%s\n' "\$*" >> "$CALLS"
printf 'ENVURL:%s\n' "\${FORGE_BASE_URL:-}" >> "$CALLS"
printf '%s' '${3:-}' >&2
printf '%s' '$2'
exit ${1}
EOF
  chmod +x "$LCARS_CLI"
}

# Une ligne signee, dans la forme EXACTE de la porte : trois champs separes par une TABULATION, et
# le saut de ligne que `IO.puts` pose — le geste tolere son absence, mais le double ne la simule pas.
signe()  { printf 'OK\t%s\t%s\n' "$1" "$URL"; }
retient(){ printf 'HOLD\t%s\t%s\n' "$1" "$2"; }
dit()    { printf 'WARN\t%s\t%s\n' "$1" "$2"; }

# `git` qui trace ce qu'on lui demande sans rien faire. `clone` cree la cible pour que la suite du
# module trouve ce qu'il attend.
fake_git() {
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_TRACE_FILE"
case "$1" in
  clone) mkdir -p "${@: -1}/.git"; printf 'api_version: 1\nname: x\n' > "${@: -1}/catalogue.yaml"; exit 0 ;;
  ls-remote) [[ -n "${STUB_SANS_TETE:-}" ]] || echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef	refs/heads/${*: -1}"; exit 0 ;;
esac
# `-C <dir> rev-parse HEAD`
[[ "$*" == *rev-parse* ]] && { echo "0000000000000000000000000000000000000000"; exit 0; }
exit 0
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export GIT_TRACE_FILE="$BATS_TEST_TMPDIR/git.log"
  : > "$GIT_TRACE_FILE"
}

# Du materiel deja pose, avec son manifeste — ce qui le rend visible du module.
seed_local() {
  mkdir -p "$LCARS_CATALOGUES_DIR/$1/.git"
  printf 'api_version: 1\nname: %s\n' "$1" > "$LCARS_CATALOGUES_DIR/$1/catalogue.yaml"
}

# ─── LA REGLE DE SURETE : on ne supprime QUE sur une lecture reussie ─────────────────────────────

@test "porte ILLISIBLE a l'apply : rien n'est supprime, et le refus le DIT" {
  stub_porte 1 '' 'UNREADABLE {:http, 500, "boom"}'
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"materiel laisse EN L'ETAT"* ]]
  # LE TEMOIN CENTRAL DE CE FICHIER : le materiel a survecu a une lecture ratee.
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "porte ILLISIBLE au check : DRIFT, jamais « rien n'est installe »" {
  stub_porte 1 '' 'UNREADABLE :timeout'
  fake_git
  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"magasin des catalogues ILLISIBLE"* ]]
}

@test "⚠ LA PORTE ABSENTE N'EST PAS UNE FORGE VIDE : refus, materiel intact" {
  # Sans release posee, `lcars_cli` ne rend rien de lisible. Lu comme « aucun catalogue installe »,
  # ce cas effacerait le materiel de TOUS les catalogues du conteneur.
  export LCARS_CLI="$BATS_TEST_TMPDIR/absente"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"porte catalogue-installed injouable"* ]]
  [[ "$output" == *"la release n'est pas posée"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "forge JOIGNABLE et vide : le materiel orphelin est retire" {
  # La porte a lu le magasin ENTIER et il n'installe rien : c'est une mesure, pas une panne.
  stub_porte 0 ''
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"materiel de web retire"* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "magasin ABSENT (404) et RIEN en local : une REPONSE — la fleet tourne sur le catalogue de la release" {
  stub_porte 2 '' 'ABSENT lcars/_catalogues'
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"magasin des catalogues absent de la forge"*"rien d'installe ici"* ]]
  # le nom lu par la porte est celui que la phrase porte : il n'est pas recopie dans le geste
  [[ "$output" == *"lcars/_catalogues"* ]]
}

@test "magasin ABSENT (404) avec du materiel en local : DRIFT, et RIEN n'est supprime" {
  stub_porte 2 '' 'ABSENT lcars/_catalogues'
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"magasin des catalogues ABSENT"*"RIEN n'est supprime"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "un repertoire local SANS manifeste n'est pas un catalogue — ni compte, ni supprime" {
  stub_porte 0 ''
  fake_git
  mkdir -p "$LCARS_CATALOGUES_DIR/pas-un-catalogue"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  refute [[ "$output" == *"pas-un-catalogue"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/pas-un-catalogue" ]
}

# ─── LA CONVERGENCE : ce qui reste au shell, et que rien d'autre ne tiendrait ────────────────────

@test "materiel absent : il est clone, et le clone atterrit a cote avant d'etre renomme" {
  stub_porte 0 "$(signe web)"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"clone --quiet --depth 1 --branch web $URL $LCARS_CATALOGUES_DIR/web.tmp"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  [ ! -d "$LCARS_CATALOGUES_DIR/web.tmp" ]
}

@test "materiel present : fetch + reset --hard, JAMAIS pull" {
  stub_porte 0 "$(signe web)"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"fetch --quiet --depth 1 origin refs/heads/web"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"reset --quiet --hard FETCH_HEAD"* ]]
  refute [[ "$(cat "$GIT_TRACE_FILE")" == *" pull"* ]]
}

@test "check : materiel en retard sur sa source = DRIFT nomme" {
  stub_porte 0 "$(signe web)"
  fake_git
  seed_local "web"

  run bash "$MOD" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"web en retard sur sa source"* ]]
}

@test "l'adresse de clone vient de la PORTE, elle n'est pas rebatie ici" {
  # Le geste ne connait plus ni le nom du magasin ni l'org : il clone ce que la porte lui donne.
  stub_porte 0 "$(printf 'OK\tweb\thttp://ailleurs.test/autre/_cat.git')"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"http://ailleurs.test/autre/_cat.git"* ]]
}

@test "la porte est appelee UNE fois, avec l'adresse de la forge dans son environnement" {
  stub_porte 0 "$(signe web)"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ARGV:tool catalogue-installed$' "$CALLS")" -eq 1 ]
  [[ "$(grep '^ENVURL:' "$CALLS")" == "ENVURL:http://forge.invalid" ]]
}

# ─── HOLD : la lecture n'a pas conclu — ni converge, ni supprime ─────────────────────────────────

@test "HOLD proprietaire : materiel laisse EN L'ETAT, et le balayage ne l'emporte pas" {
  stub_porte 0 "$(retient web proprietaire)"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"web : proprietaire illisible"*"EN L'ETAT"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  refute [[ "$(cat "$GIT_TRACE_FILE")" == *clone* ]]
}

@test "HOLD manifeste : la MOITIE qui n'a pas conclu est nommee — pas l'autre" {
  # Deux facons de ne pas savoir, et un refus qui nomme la mauvaise envoie l'operateur
  # regarder le mauvais objet.
  stub_porte 0 "$(retient web manifeste)"
  fake_git
  seed_local "web"

  run bash "$MOD" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"web : manifeste illisible"* ]]
  refute [[ "$output" == *proprietaire* ]]
}

# ─── WARN : la branche a repondu et n'est PAS un magasin ─────────────────────────────────────────

@test "WARN : la phrase de la porte est rendue telle quelle, et rien n'est clone" {
  stub_porte 0 "$(dit web 'lcars/_catalogues:web se déclare « autre » — ce n est pas le magasin de web')"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"se déclare « autre »"* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
  refute [[ "$(cat "$GIT_TRACE_FILE")" == *clone* ]]
}

@test "⚠ UN WARN NE RETIENT RIEN : du materiel local de ce nom est un reliquat, et il est retire" {
  # La branche existe mais n'est pas le magasin de `web` : garder son materiel servirait un
  # catalogue sous un nom que la forge ne lui reconnait pas.
  stub_porte 0 "$(dit web 'non signe')"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"materiel de web retire"* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

# ─── FORGE INCONNUE : le verbe depend de ce que la machine porte deja ────────────────────────────

@test "FORGE INCONNUE : sans catalogue installe, c est un WARN — il n y a rien a comparer" {
  export FORGE_BASE_URL=""
  run bash "$MOD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUCUN catalogue installé ici"* ]]
}

@test "FORGE INCONNUE : avec du materiel LOCAL, c est un DRIFT — un etat-cible cesse d etre tenu" {
  export FORGE_BASE_URL=""
  seed_local "web"
  run bash "$MOD" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"adresse de forge inconnue alors que 1 catalogue(s)"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "FORGE INCONNUE : l apply distingue les deux cas comme le check — meme fonction" {
  export FORGE_BASE_URL=""
  seed_local "web"
  run bash "$MOD" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"adresse de forge inconnue alors que 1 catalogue(s)"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

# ─── LE RELIQUAT DE L'ANCIEN CACHE ───────────────────────────────────────────────────────────────

@test "l ancien cache sous /home est DIT aux deux verbes, et il n est jamais touche" {
  export LCARS_LEGACY_CATALOGUES_DIR="$BATS_TEST_TMPDIR/ancien"
  mkdir -p "$LCARS_LEGACY_CATALOGUES_DIR/web"
  stub_porte 0 ''
  fake_git

  run bash "$MOD" check
  [[ "$output" == *"$LCARS_LEGACY_CATALOGUES_DIR subsiste"* ]]
  run bash "$MOD" apply
  [[ "$output" == *"$LCARS_LEGACY_CATALOGUES_DIR subsiste"* ]]
  [ -d "$LCARS_LEGACY_CATALOGUES_DIR/web" ]
}
