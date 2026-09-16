#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/catalogues.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for runtime/services/forge.d/catalogues.sh — le materiel suit la FORGE (geste du produit, lot 6)
#
# CE QUE CES TEMOINS TIENNENT, ET POURQUOI CE MODULE EST LE PLUS DANGEREUX DE LA SERIE : il
# SUPPRIME. C'est legitime — le materiel local est un cache re-clonable — mais exactement une
# condition rend la suppression sure, et c'est que la lecture de la forge ait REUSSI. Une forge
# injoignable rend une liste vide, et une liste vide se lit « plus rien n'est installe ». Le module
# effacerait alors tous les catalogues du conteneur en annoncant qu'il converge.
#
# La forge est simulee par un `curl` et un `git` poses en tete de PATH : ces temoins n'ouvrent aucune
# socket et ne clonent rien de reel. Ce qui est mesure est la DECISION du module, qui est tout ce
# qu'il apporte — le clone lui-meme est le travail de git.

# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2086 — eclatement VOULU d'une liste separee par des espaces
# shellcheck disable=SC2086

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
  # la release, doublee : elle nomme son catalogue (`fleet`), que ce geste ne suit jamais
  RELEASE_CAT="$BATS_TEST_TMPDIR/release-catalogue"; mkdir -p "$RELEASE_CAT"
  printf 'api_version: 1\nname: fleet\n' > "$RELEASE_CAT/catalogue.yaml"
  printf '#!/usr/bin/env bash\n[[ "$1 $2" == "tool catalogue-root" ]] && printf "%%s\\n" "%s"\nexit 0\n' "$RELEASE_CAT" > "$BATS_TEST_TMPDIR/bin/lcars"
  chmod +x "$BATS_TEST_TMPDIR/bin/lcars"; export LCARS_CLI="$BATS_TEST_TMPDIR/bin/lcars"
}

# La forge repond ce qu'on lui dit de repondre — TROIS endpoints : les BRANCHES du magasin des
# catalogues (corps JSON), la sonde d'org (`-w %{http_code}`) et le manifeste brut lu A UNE BRANCHE.
# Fixtures :
#   $1            les branches du magasin, une par ligne « <nom> » ; sans argument, la forge est DOWN
#   FAKE_STORE_CODE  le code HTTP du magasin lui-meme (defaut 200 ; 404 = aucun catalogue installe)
#   FAKE_ORGS     les noms qui repondent 200 sur /orgs/<nom> (des orgs)
#   FAKE_ORG_MUTE les noms dont la sonde d'org echoue (000) — ni org, ni perso : illisible
# Tout autre nom sonde repond 404 : espace perso prouve.
#
# ⚠ LE MANIFESTE, ET SON DEFAUT N'EST PAS UNE COMPLAISANCE. Une branche du magasin est une
# PROJECTION du depot du catalogue : elle porte `catalogue.yaml`, avec le `name:` de ce catalogue —
# c'est-a-dire le nom de la branche. La doublure sert cela par defaut parce que c'est ce que la
# vraie forge sert pour un vrai magasin. Les ecarts se demandent, par BRANCHE :
#   FAKE_BAD_MANIFEST   le manifeste declare un AUTRE nom que la branche
#   FAKE_NO_MANIFEST    pas de manifeste du tout (404 — une reponse : pas un catalogue)
#   FAKE_MANIFEST_MUTE  manifeste illisible (curl sort non-zero — une absence de reponse)
#   FAKE_MANIFEST_INDENTED  200, mais le `name:` est INDENTE (donc invisible en colonne zero)
fake_forge() {
  if [[ $# -eq 0 ]]; then
    printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    return
  fi
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/branches.json"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
url=""
args=("$@")
for ((i=0; i<$#; i++)); do
  case "${args[i]}" in http*) url="${args[i]}" ;; esac
done
if [[ "$url" == */api/v1/orgs/* ]]; then
  name="${url##*/}"
  for o in ${FAKE_ORG_MUTE:-}; do [[ "$o" == "$name" ]] && { echo 000; exit 0; }; done
  for o in ${FAKE_ORGS:-};     do [[ "$o" == "$name" ]] && { echo 200; exit 0; }; done
  echo 404; exit 0
fi
if [[ "$url" == */raw/catalogue.yaml* ]]; then
  branche="${url##*ref=}"
  # ⚠ EXIT 7, PAS UN CORPS FABRIQUE. Un `curl` qui ne peut pas connecter sort NON-ZERO sans rien
  # ecrire : c'est le rescue `|| raw=$'\n000'` du module qui produit alors le code. Une doublure qui
  # imprimerait `\n000` et sortirait 0 atteindrait la meme decision par un autre chemin — et un
  # refactoring qui supprimerait le rescue en le croyant redondant ne ferait rougir personne.
  for o in ${FAKE_MANIFEST_MUTE:-}; do [[ "$o" == "$branche" ]] && exit 7; done
  for o in ${FAKE_NO_MANIFEST:-};   do [[ "$o" == "$branche" ]] && { printf 'Not Found\n404'; exit 0; }; done
  for o in ${FAKE_MANIFEST_INDENTED:-}; do [[ "$o" == "$branche" ]] && { printf 'api_version: 1\nroles:\n  name: web\n\n200'; exit 0; }; done
  for o in ${FAKE_BAD_MANIFEST:-};  do [[ "$o" == "$branche" ]] && { printf 'api_version: 1\nname: autre-chose\n\n200'; exit 0; }; done
  # `main` du magasin : un README, pas de manifeste — c'est le cas NOMINAL
  [[ "$branche" != main ]] || { printf 'Not Found\n404'; exit 0; }
  printf 'api_version: 1\nname: %s\n\n200' "$branche"; exit 0
fi
# la liste des branches du magasin : le corps, puis le code
code="${FAKE_STORE_CODE:-200}"
[[ "$code" == 200 ]] || { printf 'Not Found\n%s' "$code"; exit 0; }
printf '%s\n%s' "$(cat "$FAKE_BODY_FILE")" 200
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export FAKE_BODY_FILE="$BATS_TEST_TMPDIR/branches.json"
}

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

# Les branches du magasin, dans la forme que rend la forge : `main` (le README du magasin) plus une
# branche par catalogue nomme.
branches() {
  local b out=""
  for b in main "$@"; do
    out="$out{\"name\":\"$b\",\"commit\":{\"id\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\"}},"
  done
  printf '[%s]' "${out%,}"
}
json_one() { branches "$1"; }

# ─── LA REGLE DE SURETE : on ne supprime QUE sur une lecture reussie ─────────────────────────────

@test "forge DOWN a l'apply : rien n'est supprime, et le refus le DIT" {
  fake_forge          # down
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"materiel laisse EN L'ETAT"* ]]
  # LE TEMOIN CENTRAL DE CE FICHIER : le materiel a survecu a une forge muette.
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "forge DOWN au check : DRIFT, jamais « rien n'est installe »" {
  fake_forge
  fake_git
  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"magasin des catalogues ILLISIBLE"* ]]
}

# ⚠ LES TROIS CHEMINS PAR LESQUELS UNE LECTURE RATEE POURRAIT PASSER POUR UNE FORGE VIDE. Chacun
# ferait effacer le materiel de TOUS les catalogues du conteneur (relecture hostile du 2026-09-17).
@test "magasin qui repond AUTRE CHOSE que 200/404 : refus, materiel intact" {
  fake_forge "$(branches web)"
  export FAKE_STORE_CODE=500
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"magasin des catalogues ILLISIBLE"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "un 200 dont le CORPS n'est pas un tableau JSON : refus, materiel intact" {
  # Un proxy, une page d'erreur, un corps tronque : lus comme une liste vide, ils effaceraient tout.
  fake_forge '<html>proxy</html>'
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"magasin des catalogues ILLISIBLE"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

# Un PATH qui porte tout ce que la machine a, SAUF un outil : c'est la seule facon de mesurer une
# absence sans mettre en scene un outil qui ment (un `jq` qui sort 127 EXISTE, `command -v` le trouve).
sans_outil() { # sans_outil <outil> → un dossier de liens vers tout le PATH, prive de <outil>
  local d="$BATS_TEST_TMPDIR/sans-$1" dir f n
  local -A vu=()
  local -a dirs liens=()
  mkdir -p "$d"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      [[ -f "$f" && -x "$f" && -z "${vu[$n]:-}" ]] || continue
      [[ "$n" != "$1" ]] || continue
      vu[$n]=1; liens+=("$f")
    done
  done
  ln -s -t "$d" "${liens[@]}" 2>/dev/null || true
  printf '%s\n' "$d"
}

@test "jq ABSENT : refus, materiel intact — une absence d'outil n'est pas une forge vide" {
  fake_forge "$(branches web)"
  fake_git
  seed_local "web"
  local sans; sans="$(sans_outil jq)"
  # le decor d'abord (curl et git doubles), puis tout le PATH sauf jq
  PATH="$BATS_TEST_TMPDIR/bin:$sans" run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"magasin des catalogues ILLISIBLE"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "une page PLEINE au budget est une liste TRONQUEE : refus, materiel intact" {
  # La forge borne la page a SA limite : une page pleine veut dire « il y en a peut-etre d'autres ».
  # Sans ce garde, les catalogues au-dela de la borne seraient « plus installes », donc effaces.
  fake_forge "$(branches $(seq -f 'cat%g' 1 60))"
  export FAKE_PAGES_PLEINES=1
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"liste tronquee"* ]] || [[ "$output" == *"ILLISIBLE"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "forge JOIGNABLE et vide : le materiel orphelin est retire" {
  fake_forge "$(branches)"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"la forge ne l'installe plus"* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "magasin ABSENT (404) et RIEN en local : une REPONSE — la fleet tourne sur le catalogue de la release" {
  # Une forge qui n'a jamais rien installe n'est pas une forge en panne : le magasin est pose par la
  # recette, et tant que personne n'a joue « catalogue install », il ne porte que son README.
  fake_forge "$(branches)"
  export FAKE_STORE_CODE=404
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"magasin des catalogues absent de la forge"*"rien d'installe ici"* ]]
}

# ⚠ LE MEME 404, AVEC DU MATERIEL EN LOCAL, N'EST PLUS UNE REPONSE. Gitea le rend aussi pour un depot
# PRIVE lu en anonyme (ce geste lit en anonyme), pour une org renommee, pour une recette jamais jouee.
# Trois causes sur quatre ne justifient aucun effacement.
@test "magasin ABSENT (404) avec du materiel en local : DRIFT, et RIEN n'est supprime" {
  fake_forge "$(branches)"
  export FAKE_STORE_CODE=404
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"magasin des catalogues ABSENT"*"1 catalogue(s) sont installes ici"*"RIEN n'est supprime"* ]]
  [[ "$output" == *"il est peut-etre prive"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
}

# ─── CE QUI COMPTE COMME CATALOGUE ──────────────────────────────────────────────────────────────

@test "la branche par defaut du magasin porte un README, pas un catalogue — elle ne signe RIEN" {
  # `main` n'est le magasin de personne : elle porte ce que le depot EST. Un 404 sur son manifeste
  # est le cas NOMINAL, pas un refus a annoncer.
  fake_forge "$(branches)"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ ! -d "$LCARS_CATALOGUES_DIR/main" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [[ "$output" != *"main"* ]]
}



@test "un repertoire local SANS manifeste n'est pas un catalogue — ni compte, ni supprime" {
  # Un clone interrompu ou un `lost+found`. Le compter le ferait verifier par le boot ; le supprimer
  # ferait de ce module le nettoyeur d'un repertoire dont il ne sait rien.
  fake_forge "$(branches)"
  fake_git
  mkdir -p "$LCARS_CATALOGUES_DIR/moitie-de-clone"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$LCARS_CATALOGUES_DIR/moitie-de-clone" ]
}

# ─── LA CONVERGENCE ELLE-MEME ───────────────────────────────────────────────────────────────────

@test "materiel absent : il est clone, et le clone atterrit a cote avant d'etre renomme" {
  # Le staging est ce qui empeche un clone interrompu de laisser un demi-catalogue SOUS son nom
  # definitif — le boot suivant le verifierait comme s'il etait entier.
  fake_forge "$(branches web)"
  export FAKE_ORGS="web"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"clone --quiet --depth 1 --branch web http://forge.invalid/lcars/_catalogues.git $LCARS_CATALOGUES_DIR/web.tmp"* ]]
  [ ! -e "$LCARS_CATALOGUES_DIR/web.tmp" ]
}

@test "le magasin du catalogue de la release est sur la forge, et il n'est ni signe ni clone : la release est son materiel" {
  fake_forge "$(branches fleet web)"
  export FAKE_ORGS="fleet web"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  [ ! -e "$LCARS_CATALOGUES_DIR/fleet" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *"--branch fleet"* ]]
  [[ "$output" != *"catalogue fleet"* ]]
  [[ "$output" != *"nom du catalogue de la release inconnu"* ]]

  # sans release qui reponde, rien n'est exclu, et c'est dit : le magasin est suivi comme un installe
  : > "$GIT_TRACE_FILE"; rm -rf "$LCARS_CATALOGUES_DIR/web"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$LCARS_CLI"
  run bash "$MOD" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"WARN  50-catalogues: nom du catalogue de la release inconnu (« lcars tool catalogue-root » ne repond pas)"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"--branch fleet"* ]]
}

@test "materiel present : fetch + reset --hard, JAMAIS pull" {
  # Le cache n'a pas d'historique a preserver. Un `pull` sur un depot reecrit par son proprietaire
  # s'arrete sur un conflit de merge que personne ne viendra resoudre dans un provisionnement.
  fake_forge "$(branches web)"
  export FAKE_ORGS="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"fetch --quiet --depth 1 origin refs/heads/web"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"reset --quiet --hard FETCH_HEAD"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" != *" pull"* ]]
}

@test "check : materiel en retard sur sa source = DRIFT nomme" {
  fake_forge "$(branches web)"
  export FAKE_ORGS="web"
  fake_git   # ls-remote rend deadbeef…, rev-parse rend 0000… : deux shas differents
  seed_local "web"

  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"web en retard sur sa source"* ]]
}

# ─── D1 : le nom reserve vaut aussi pour les STORES ─────────────────────────────────────────────

@test "D1: un depot catalogue dans un espace PERSO ne signe rien — le gate admin ne se pousse pas" {
  # ⚠ LE TROU DU TROISIEME REGARD : orgs et comptes perso partagent l'espace de noms, et rien ne
  # verifiait le type du proprietaire. `alice` poussait un depot public `catalogue` chez elle ->
  # clone de son materiel dans /home/catalogues, roster derive pour le mint. La sonde /orgs/alice
  # rend 404 (espace perso prouve) : rien n'est clone, et un materiel local sous ce nom est retire
  # comme tout catalogue que la forge n'installe plus.
  fake_forge "$(branches alice)"
  export FAKE_ORGS=""
  fake_git
  seed_local "alice"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/alice" ]
}

@test "D1: type du proprietaire ILLISIBLE — ni converge, ni supprime, et c'est DIT" {
  # `{:error}` n'est pas « pas une org » : conclure de l'absence de reponse retrograderait un
  # catalogue installe sur un hoquet — ou, dans l'autre sens, clonerait un depot non signe.
  fake_forge "$(branches web)"
  export FAKE_ORGS="" FAKE_ORG_MUTE="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  # ⚠ LA CAUSE EST NOMMEE, et le temoin jumeau (manifeste ILLISIBLE) attend l'AUTRE mot. Deux facons
  # de ne pas savoir sous un seul message enverraient l'operateur regarder le mauvais objet.
  [[ "$output" == *"proprietaire illisible"* ]]
  [[ "$output" != *"manifeste illisible"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}

# ─── L'IDENTITE : un depot ne signe QUE le catalogue qu'il DECLARE ──────────────────────────────
#
# L'adresse dit ou regarder, le manifeste dit ce que c'est. Sans ce garde, tout depot pose a
# l'adresse d'un magasin dans une org quelconque etait clone et SERVI sous le nom de cette org — et
# ses roles descendaient dans le roster du mint.

@test "IDENTITE: un depot a l'adresse d'un magasin qui declare un AUTRE nom ne signe rien" {
  # `web/_catalogue` est exactement la ou un magasin se pose, dans une vraie org. Ce qui le disqualifie
  # est son manifeste : il ne declare pas `web`, donc il n'est pas le magasin de `web`.
  fake_forge "$(branches web)"
  export FAKE_ORGS="web" FAKE_BAD_MANIFEST="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  # Non signe = non vu : le materiel local part au balayage, comme pour tout catalogue desinstalle.
  # Et ca SE DIT — ce module supprime, il ne le fait pas en silence.
  [[ "$output" == *"se declare"* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: un depot SANS manifeste ne signe rien — 404 est une reponse" {
  fake_forge "$(branches web)"
  export FAKE_ORGS="web" FAKE_NO_MANIFEST="web"
  fake_git
  # ⚠ LE MATERIEL EST POSE AVANT, et sans lui ce temoin ne mesurait rien : `[ ! -d ... ]` passait
  # parce que le repertoire n'avait jamais existe. Ce qu'il faut tenir est que le 404 est une
  # REPONSE, donc qu'il autorise la SUPPRESSION — pas seulement qu'il n'autorise pas le clone.
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: un 200 qui ne declare RIEN en colonne zero ne signe pas, et le DIT" {
  # ⚠ LE SEUL CHEMIN QUI SUPPRIMAIT SANS UN MOT. Le manifeste repond 200, `awk` ne trouve pas de
  # `name:` en colonne zero, `declared` est vide : ni HOLD, ni signature, et le balayage efface le
  # materiel. La seule sortie etait « materiel de web retire » — l'operateur ne savait pas quelle
  # couche avait dit non. Un espace d'indentation devant `name:` suffisait a le declencher.
  fake_forge "$(branches web)"
  export FAKE_ORGS="web" FAKE_BAD_MANIFEST="web" FAKE_MANIFEST_INDENTED="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"COLONNE ZERO"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$LCARS_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: manifeste ILLISIBLE — ni converge, ni supprime, et c'est DIT" {
  # ⚠ LA DIFFERENCE QUI COUTE. 404 est une reponse (« pas un magasin ») et autorise la suppression ;
  # une forge muette est une ABSENCE de reponse et n'autorise rien. Les confondre effacerait le
  # materiel d'un catalogue bien installe sur un hoquet reseau — la faute que ce fichier entier
  # existe pour empecher, un endpoint plus loin.
  fake_forge "$(branches web)"
  export FAKE_ORGS="web" FAKE_MANIFEST_MUTE="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifeste illisible"* ]]
  [[ "$output" != *"proprietaire illisible"* ]]
  [ -d "$LCARS_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}


# ─── LE ROSTER DERIVE ───────────────────────────────────────────────────────────────────────────

@test "FORGE INCONNUE : sans catalogue installe, c est un WARN — il n y a rien a comparer" {
  FORGE_BASE_URL="" run bash "$MOD" check
  [ "$status" -eq 0 ] || { echo "un WARN ne doit pas colorer le verdict : $output"; return 1; }
  [[ "$output" == *"AUCUN catalogue installé"* ]]
}

@test "FORGE INCONNUE : avec du materiel LOCAL, c est un DRIFT — un etat-cible cesse d etre tenu" {
  mkdir -p "$LCARS_CATALOGUES_DIR/web-demo"
  FORGE_BASE_URL="" run bash "$MOD" check
  # ⚠ 1, PAS 2 : les deux verbes n ont pas le meme bareme. `verdict_check` rend 1 sur drift et 2 sur
  # echec ; `verdict_apply` l inverse — un apply qui n a pas converge est un ECHEC, un check qui
  # constate un ecart ne l est pas. Les deux temoins voisins le montrent en s opposant.
  [ "$status" -eq 1 ] || { echo "le drift n a pas colore le verdict (rc=$status) : $output"; return 1; }
  [[ "$output" == *"1 catalogue(s) sont déjà installés"* ]]
  # et le refus NOMME la sortie, pour chacun des deux hotes du geste
  [[ "$output" == *"deploy/workstation up"* ]]
  [[ "$output" == *"deploy/container config"* ]]
}

@test "FORGE INCONNUE : l apply distingue les deux cas comme le check — meme fonction" {
  mkdir -p "$LCARS_CATALOGUES_DIR/web-demo"
  FORGE_BASE_URL="" run bash "$MOD" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"déjà installés"* ]]
}
