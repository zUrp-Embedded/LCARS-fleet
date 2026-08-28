#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/catalogue_converger.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for modules.d/45-catalogues.sh + prov_roles — le materiel suit la FORGE
#
# CE QUE CES TEMOINS TIENNENT, ET POURQUOI CE MODULE EST LE PLUS DANGEREUX DE LA SERIE : il
# SUPPRIME. C'est legitime — le materiel local est un cache re-clonable — mais exactement une
# condition rend la suppression sure, et c'est que la lecture de la forge ait REUSSI. Une forge
# injoignable rend une liste vide, et une liste vide se lit « plus rien n'est installe ». Le module
# effacerait alors tous les catalogues de la boite en annoncant qu'il converge.
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
  MOD="$BATS_TEST_DIRNAME/../modules.d/45-catalogues.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  # `-f`, pas `-x` : un module est joue par `bash`, jamais lance directement — il refuse meme de
  # l'etre. Epingler `-x` ici a rendu la derive des modes invisible pendant cinq commits.
  [ -f "$MOD" ]
  export PROVISION_LIB="$LIB"
  export PROV_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export PROV_FORGE_URL="http://forge.invalid"
  mkdir -p "$PROV_CATALOGUES_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# La forge repond ce qu'on lui dit de repondre — TROIS endpoints : la recherche (corps JSON + header
# X-Total-Count vers le fichier -D), la sonde d'org (`-w %{http_code}`, depuis D1) et le manifeste
# brut d'un depot (corps + code, depuis le garde d'identite). Fixtures :
#   $1            corps JSON de la recherche ; sans argument, la forge est DOWN
#   FAKE_ORGS     les noms qui repondent 200 sur /orgs/<nom> (des orgs)
#   FAKE_ORG_MUTE les noms dont la sonde d'org echoue (000) — ni org, ni perso : illisible
#   FAKE_TOTAL    X-Total-Count force (defaut : la taille reelle de .data — pas de troncature)
# Tout autre nom sonde repond 404 : espace perso prouve.
#
# ⚠ LE MANIFESTE, ET SON DEFAUT N'EST PAS UNE COMPLAISANCE. Un magasin est une PROJECTION du depot
# de son catalogue : il porte donc `catalogue.yaml`, avec le `name:` de ce catalogue — c'est-a-dire
# le nom de son org. La doublure sert cela par defaut parce que c'est ce que la vraie forge sert
# pour un vrai magasin. Les ecarts se demandent, par PROPRIETAIRE :
#   FAKE_BAD_MANIFEST   le manifeste declare un AUTRE nom que l'org
#   FAKE_NO_MANIFEST    pas de manifeste du tout (404 — une reponse : ce n'est pas un magasin)
#   FAKE_MANIFEST_MUTE  manifeste illisible (curl sort non-zero — une absence de reponse)
#   FAKE_MANIFEST_INDENTED  200, mais le `name:` est INDENTE (donc invisible en colonne zero)
fake_forge() {
  if [[ $# -eq 0 ]]; then
    printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    return
  fi
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/search.json"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
hdr="" url=""
args=("$@")
for ((i=0; i<$#; i++)); do
  case "${args[i]}" in
    -D) hdr="${args[i+1]}" ;;
    http*) url="${args[i]}" ;;
  esac
done
if [[ "$url" == */api/v1/orgs/* ]]; then
  name="${url##*/}"
  for o in ${FAKE_ORG_MUTE:-}; do [[ "$o" == "$name" ]] && { echo 000; exit 0; }; done
  for o in ${FAKE_ORGS:-};     do [[ "$o" == "$name" ]] && { echo 200; exit 0; }; done
  echo 404; exit 0
fi
if [[ "$url" == */raw/catalogue.yaml ]]; then
  rest="${url#*/api/v1/repos/}"; owner="${rest%%/*}"
  # ⚠ EXIT 7, PAS UN CORPS FABRIQUE. Un `curl` qui ne peut pas connecter sort NON-ZERO sans rien
  # ecrire : c'est le rescue `|| raw=$'\n000'` du module qui produit alors le code. Une doublure qui
  # imprimerait `\n000` et sortirait 0 atteindrait la meme decision par un autre chemin — et un
  # refactoring qui supprimerait le rescue en le croyant redondant ne ferait rougir personne.
  for o in ${FAKE_MANIFEST_MUTE:-}; do [[ "$o" == "$owner" ]] && exit 7; done
  for o in ${FAKE_NO_MANIFEST:-};   do [[ "$o" == "$owner" ]] && { printf 'Not Found\n404'; exit 0; }; done
  for o in ${FAKE_MANIFEST_INDENTED:-}; do [[ "$o" == "$owner" ]] && { printf 'api_version: 1\nroles:\n  name: web\n\n200'; exit 0; }; done
  for o in ${FAKE_BAD_MANIFEST:-};  do [[ "$o" == "$owner" ]] && { printf 'api_version: 1\nname: autre-chose\n\n200'; exit 0; }; done
  printf 'api_version: 1\nname: %s\n\n200' "$owner"; exit 0
fi
body="$(cat "$FAKE_BODY_FILE")"
if [[ -n "$hdr" ]]; then
  t="${FAKE_TOTAL:-$(printf '%s' "$body" | jq -r '.data | length')}"
  printf 'X-Total-Count: %s\r\n' "$t" > "$hdr"
fi
printf '%s' "$body"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export FAKE_BODY_FILE="$BATS_TEST_TMPDIR/search.json"
}

# `git` qui trace ce qu'on lui demande sans rien faire. `clone` cree la cible pour que la suite du
# module trouve ce qu'il attend.
fake_git() {
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_TRACE_FILE"
case "$1" in
  clone) mkdir -p "${@: -1}/.git"; printf 'api_version: 1\nname: x\n' > "${@: -1}/catalogue.yaml"; exit 0 ;;
  ls-remote) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef	HEAD"; exit 0 ;;
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
  mkdir -p "$PROV_CATALOGUES_DIR/$1/.git"
  printf 'api_version: 1\nname: %s\n' "$1" > "$PROV_CATALOGUES_DIR/$1/catalogue.yaml"
}

# `full_name` est porte parce que le module en a besoin pour ALLER LIRE le manifeste : l'adresse du
# depot vient de la reponse de la forge, jamais d'une recomposition `<owner>/<convention>` ici.
json_one() {
  printf '{"data":[{"name":"_catalogue","full_name":"%s/_catalogue","empty":false,"owner":{"login":"%s"},"clone_url":"http://forge.invalid/%s/_catalogue.git"}]}' \
    "$1" "$1" "$1"
}

# ─── LA REGLE DE SURETE : on ne supprime QUE sur une lecture reussie ─────────────────────────────

@test "forge DOWN a l'apply : rien n'est supprime, et le refus le DIT" {
  fake_forge          # down
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"materiel laisse EN L'ETAT"* ]]
  # LE TEMOIN CENTRAL DE CE FICHIER : le materiel a survecu a une forge muette.
  [ -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "forge DOWN au check : DRIFT, jamais « rien n'est installe »" {
  fake_forge
  fake_git
  run bash "$MOD" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"forge injoignable"* ]]
}

@test "forge JOIGNABLE et vide : le materiel orphelin est retire" {
  fake_forge '{"data":[]}'
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"la forge ne l'installe plus"* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

# ─── CE QUI COMPTE COMME CATALOGUE ──────────────────────────────────────────────────────────────

@test "un repo nomme catalogue-perso ne signe RIEN — le filtre est exact, pas une sous-chaine" {
  # `q=catalogue` est un match de sous-chaine cote Gitea. Sans le filtre exact, le depot personnel
  # d'un humain ferait installer un catalogue que personne n'a installe.
  fake_forge '{"data":[{"name":"catalogue-perso","full_name":"alice/catalogue-perso","empty":false,"owner":{"login":"alice"},"clone_url":"http://forge.invalid/alice/catalogue-perso.git"}]}'
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ ! -d "$PROV_CATALOGUES_DIR/alice" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}

@test "un depot VIDE ne signe rien — une org creee sans sa source est un install interrompu" {
  fake_forge '{"data":[{"name":"_catalogue","full_name":"web/_catalogue","empty":true,"owner":{"login":"web"},"clone_url":"http://forge.invalid/web/_catalogue.git"}]}'
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "un repertoire local SANS manifeste n'est pas un catalogue — ni compte, ni supprime" {
  # Un clone interrompu ou un `lost+found`. Le compter le ferait verifier par le boot ; le supprimer
  # ferait de ce module le nettoyeur d'un repertoire dont il ne sait rien.
  fake_forge '{"data":[]}'
  fake_git
  mkdir -p "$PROV_CATALOGUES_DIR/moitie-de-clone"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$PROV_CATALOGUES_DIR/moitie-de-clone" ]
}

# ─── LA CONVERGENCE ELLE-MEME ───────────────────────────────────────────────────────────────────

@test "materiel absent : il est clone, et le clone atterrit a cote avant d'etre renomme" {
  # Le staging est ce qui empeche un clone interrompu de laisser un demi-catalogue SOUS son nom
  # definitif — le boot suivant le verifierait comme s'il etait entier.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web"
  fake_git

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [ -d "$PROV_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"clone --quiet --depth 1 http://forge.invalid/web/_catalogue.git $PROV_CATALOGUES_DIR/web.tmp"* ]]
  [ ! -e "$PROV_CATALOGUES_DIR/web.tmp" ]
}

@test "materiel present : fetch + reset --hard, JAMAIS pull" {
  # Le cache n'a pas d'historique a preserver. Un `pull` sur un depot reecrit par son proprietaire
  # s'arrete sur un conflit de merge que personne ne viendra resoudre dans un provisionnement.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"fetch --quiet --depth 1 origin HEAD"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" == *"reset --quiet --hard FETCH_HEAD"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" != *" pull"* ]]
}

@test "check : materiel en retard sur sa source = DRIFT nomme" {
  fake_forge "$(json_one web)"
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
  fake_forge "$(json_one alice)"
  export FAKE_ORGS=""
  fake_git
  seed_local "alice"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/alice" ]
}

@test "D1: type du proprietaire ILLISIBLE — ni converge, ni supprime, et c'est DIT" {
  # `{:error}` n'est pas « pas une org » : conclure de l'absence de reponse retrograderait un
  # catalogue installe sur un hoquet — ou, dans l'autre sens, clonerait un depot non signe.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="" FAKE_ORG_MUTE="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  # ⚠ LA CAUSE EST NOMMEE, et le temoin jumeau (manifeste ILLISIBLE) attend l'AUTRE mot. Deux facons
  # de ne pas savoir sous un seul message enverraient l'operateur regarder le mauvais objet.
  [[ "$output" == *"proprietaire illisible"* ]]
  [[ "$output" != *"manifeste illisible"* ]]
  [ -d "$PROV_CATALOGUES_DIR/web" ]
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
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web" FAKE_BAD_MANIFEST="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  # Non signe = non vu : le materiel local part au balayage, comme pour tout catalogue desinstalle.
  # Et ca SE DIT — ce module supprime, il ne le fait pas en silence.
  [[ "$output" == *"se declare"* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: un depot SANS manifeste ne signe rien — 404 est une reponse" {
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web" FAKE_NO_MANIFEST="web"
  fake_git
  # ⚠ LE MATERIEL EST POSE AVANT, et sans lui ce temoin ne mesurait rien : `[ ! -d ... ]` passait
  # parce que le repertoire n'avait jamais existe. Ce qu'il faut tenir est que le 404 est une
  # REPONSE, donc qu'il autorise la SUPPRESSION — pas seulement qu'il n'autorise pas le clone.
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: un 200 qui ne declare RIEN en colonne zero ne signe pas, et le DIT" {
  # ⚠ LE SEUL CHEMIN QUI SUPPRIMAIT SANS UN MOT. Le manifeste repond 200, `awk` ne trouve pas de
  # `name:` en colonne zero, `declared` est vide : ni HOLD, ni signature, et le balayage efface le
  # materiel. La seule sortie etait « materiel de web retire » — l'operateur ne savait pas quelle
  # couche avait dit non. Un espace d'indentation devant `name:` suffisait a le declencher.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web" FAKE_BAD_MANIFEST="web" FAKE_MANIFEST_INDENTED="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"COLONNE ZERO"* ]]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
  [ ! -d "$PROV_CATALOGUES_DIR/web" ]
}

@test "IDENTITE: manifeste ILLISIBLE — ni converge, ni supprime, et c'est DIT" {
  # ⚠ LA DIFFERENCE QUI COUTE. 404 est une reponse (« pas un magasin ») et autorise la suppression ;
  # une forge muette est une ABSENCE de reponse et n'autorise rien. Les confondre effacerait le
  # materiel d'un catalogue bien installe sur un hoquet reseau — la faute que ce fichier entier
  # existe pour empecher, un endpoint plus loin.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web" FAKE_MANIFEST_MUTE="web"
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifeste illisible"* ]]
  [[ "$output" != *"proprietaire illisible"* ]]
  [ -d "$PROV_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}

@test "D4: une liste TRONQUEE refuse — jamais une convergence sur une liste partielle" {
  # Le serveur borne la page a SA limite. Une page lue comme la totalite ferait SUPPRIMER le
  # materiel des catalogues au-dela de la borne — la meme classe que la forge muette, en pire :
  # la reponse a l'air entiere.
  fake_forge "$(json_one web)"
  export FAKE_ORGS="web" FAKE_TOTAL=7
  fake_git
  seed_local "web"

  run bash "$MOD" apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"TRONQUEE"* ]]
  [ -d "$PROV_CATALOGUES_DIR/web" ]
  [[ "$(cat "$GIT_TRACE_FILE")" != *clone* ]]
}

# ─── LE ROSTER DERIVE ───────────────────────────────────────────────────────────────────────────

@test "prov_roles sans release : le plancher tenu a la main, et rien de plus" {
  # Chemin WSL avant `60-deploy`, ou boite sans release pose. Une boite doit pouvoir minter de quoi
  # demarrer meme quand la derivation est impossible.
  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT=/inexistant; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system_architect"* ]]
  [[ "$output" == *"fleet_engineer"* ]]
}

@test "prov_roles avec un catalogue installe : ses roles ENTRENT, dedupliques et tries" {
  # LA QUATRIEME LISTE TENUE A LA MAIN MEURT ICI. Un catalogue installe apporte ses comptes sans
  # qu'aucun fichier de deploiement ne le sache — c'est tout l'interet de la derivation.
  seed_local "web"
  cat > "$BATS_TEST_TMPDIR/bin/entrypoint" <<'SH'
#!/usr/bin/env bash
# ⚠ LA PORTE EST `roles-tfvars`, PAS `roles`. La premiere rend des COMPTES (`web_dev`), la seconde
# des noms de ROLE (`dev`) — et `PROV_ROLES` est une liste de comptes. La doublure REFUSE `roles`
# pour que le temoin tombe si la derivation y revenait : mesure sur banc du 2026-08-16, branchee sur
# `roles`, elle faisait entrer `dev` et `writer` dans le roster a minter.
[[ "$1" == "roles-tfvars" ]] || exit 1
printf '{"roles":["web_dev","web_writer","fleet_engineer"],"system_roles":["system_architect"]}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_dev"* ]]
  [[ "$output" == *"web_writer"* ]]
  # `fleet_engineer` est dans le plancher ET dans la sortie du catalogue : il ne sort qu'une fois.
  [ "$(printf '%s\n' $output | grep -c '^fleet_engineer$')" -eq 1 ]
}

@test "prov_roles : un catalogue dont la porte REFUSE n'ajoute rien, et ne casse pas le mint" {
  # Un catalogue incoherent est un catalogue que le boot refusera. Ce n'est pas au mint de trancher,
  # et faire echouer la derivation entiere priverait de jetons les catalogues sains.
  seed_local "casse"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/entrypoint"
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_ENTRYPOINT='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_engineer"* ]]
}
