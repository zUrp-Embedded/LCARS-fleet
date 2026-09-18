#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge-gestures_structure.bats
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: temoins de `cmd_apply` et `cmd_install` — l'org SYSTEME sans role metier, puis le catalogue
#         de la release installe comme n'importe quel catalogue, depuis la release
#
# CE QUE CES TEMOINS TIENNENT (⚖ user 2026-09-16, option B) :
#
#   1. le play `.` de `cmd_apply` est celui de l'org systeme : `-var org=<systeme>` et les quatre
#      listes de roles VIDES, qui l'emportent sur le `roles.auto.tfvars.json` du roster ; le play
#      `instance/` ne recoit aucun `-var` (il ne declare pas `org`, tofu refuserait) ;
#   2. `cmd_apply` enchaine sur `cmd_install <catalogue de la release>` : l'org du catalogue standard
#      n'est plus l'org systeme, elle se pose comme les autres — sinon aucun projet n'a d'org ;
#   3. pour le catalogue de la release, `cmd_install` prend sa source DANS LA RELEASE : ni
#      `tool catalogue-source` (qui le refuse, exit 4), ni clone ; la recette est jouee dans son
#      dossier de travail, SANS `-var` (son roster porte son org) ; le magasin recoit la projection,
#      avec un trailer `Source-Commit` seulement quand la machine connait sa revision ; le materiel
#      local n'est PAS pose (`Fleet.Catalogue` ignore un dossier installe de ce nom) ;
#   4. un autre catalogue passe toujours par `tool catalogue-source` et un clone ;
#   5. le depot systeme cree par `cmd_apply` vit dans l'org systeme (`<systeme>/_ops`).
#
# Le script est SOURCE (sa frontiere de sourcing existe pour ca) ; tofu, curl, git et la CLI du
# release sont des doublures qui NOTENT ce qu'on leur demande.

# shellcheck disable=SC1090

load ../support/refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../services/forge-gestures.sh"
  [ -f "$SCRIPT" ]

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export PATH="$BIN:$PATH"
  export FORGE_BASE_URL="http://forge.test"

  # la machine : jetons, seed, recette, dossier de travail, release
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  printf 'MASTER\n' > "$LCARS_PRIVATE_DIR/forge-master.token"
  printf 'graine\n' > "$LCARS_PRIVATE_DIR/forge-seed.pass"
  printf 'SYS\n' > "$LCARS_PRIVATE_DIR/system_starfleet.gitea_token"
  export LCARS_RECIPE_DIR="$BATS_TEST_TMPDIR/recette"; mkdir -p "$LCARS_RECIPE_DIR/instance"
  printf 'terraform {}\n' > "$LCARS_RECIPE_DIR/versions.tf"
  printf '{"org":"fleet","roles":["fleet_engineer"],"system_account":"system_starfleet"}\n' > "$LCARS_RECIPE_DIR/roles.auto.tfvars.json"
  export LCARS_CATALOGUES_WORK="$BATS_TEST_TMPDIR/tofu"; mkdir -p "$LCARS_CATALOGUES_WORK"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export LCARS_DEMO_CATALOGUE="$BATS_TEST_TMPDIR/absent"
  RELEASE_CAT="$BATS_TEST_TMPDIR/release/catalogue"; mkdir -p "$RELEASE_CAT"
  printf 'api_version: 1\nname: fleet\n' > "$RELEASE_CAT/catalogue.yaml"
  export RELEASE_CAT
  unset LCARS_FORGE_ORG LCARS_IMAGE_REVISION LCARS_REFERENCE_CATALOGUE

  # la CLI du release : quatre portes, chacune notee
  export LCARS_CLI="$BIN/lcars"
  cat > "$LCARS_CLI" <<'EOF'
#!/usr/bin/env bash
echo "CLI:$*" >> "$CALLS"
case "$2" in
  catalogue-root)   [[ -n "${STUB_SANS_RELEASE:-}" ]] && exit 1; printf '%s\n' "$RELEASE_CAT" ;;
  verify)           exit 0 ;;
  roles-tfvars)     printf '{"org":"%s","roles":[]}\n' "$(sed -n 's/^name: //p' "$3/catalogue.yaml")" ;;
  catalogue-source) printf 'quelquun/%s main deadbeefcafe\n' "$3" ;;
  system-project)   printf 'lcars-fleet\n' ;;
esac
EOF
  cat > "$BIN/tofu" <<'EOF'
#!/usr/bin/env bash
echo "TOFU:${PWD#"$BATS_TEST_TMPDIR"/} $*" >> "$CALLS"
[[ "$1" != apply ]] || echo "TOFU-JETON:${PWD#"$BATS_TEST_TMPDIR"/} ${TF_VAR_gitea_token:-}" >> "$CALLS"
[[ "$1" != apply ]] || echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed."
EOF
  # curl : l'URL et la methode sont notees ; tout est « deja la » (200, corps vide ou liste vide)
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
DEF_TEAMS='[{"id":9,"name":"admins"}]'
DEF_ADMINS='[{"login":"le-siege","is_admin":true,"active":true}]'
method=GET; url=""; fmt=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -X) method="$2"; shift 2 ;; -w) fmt="$2"; shift 2 ;; -o) out="$2"; shift 2 ;;
    -K|-m|-H|-d) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
[[ -t 0 ]] || cat >/dev/null
echo "CURL:$method ${url#http://forge.test}" >> "$CALLS"
code=200
case "$url" in
  # la team des approbateurs : son ID se demande a l'org, ses membres a la team, et les site-admins
  # a l'API d'administration. Les trois portent la derivation (`derive_admins`).
  #
  # ⚠ LES DEFAUTS SONT DES VARIABLES, PAS DES `${x:-…}` : le premier `}` d'un JSON FERME
  # l'expansion, et le reste devient du texte (mesure du 2026-09-18 : `[{"id":9,"name":"admins"]}`).
  */api/v1/orgs/*/teams) rep="${STUB_TEAMS:-$DEF_TEAMS}" ;;
  */api/v1/teams/9/members) rep="${STUB_MEMBRES:-[]}" ;;
  */api/v1/teams/9/members/*) rep=''; code="${STUB_TEAM_ECRITURE:-204}" ;;
  */api/v1/admin/users*) rep="${STUB_ADMINS:-$DEF_ADMINS}" ;;
  */members|*/teams) rep='[]' ;;
  */api/v1/user) [[ -n "${STUB_SANS_SIEGE:-}" ]] && rep='' || rep='{"login":"le-siege"}' ;;
  # le magasin des catalogues : pose par la recette, SONDE par le geste
  */api/v1/repos/*/_catalogues) rep=''; [[ -z "${STUB_SANS_MAGASIN:-}" ]] || code=404 ;;
  # le projet du systeme : ABSENT par defaut (une forge neuve), pose par le geste
  */api/v1/repos/*/lcars-fleet) rep=''; code="${STUB_PROJET_CODE:-404}" ;;
  */api/v1/orgs/*/repos)        rep=''; code="${STUB_CREATION_CODE:-201}" ;;
  # l'espace de noms partage : une org REPOND aux deux routes, un compte a `/users` seul
  */api/v1/orgs/*)  rep=''; [[ -z "${STUB_ORG_ABSENTE:-}" ]]   || code="${STUB_ORG_CODE:-404}" ;;
  */api/v1/users/*) rep=''; [[ -z "${STUB_SANS_HOMONYME:-}" ]] || code="${STUB_USER_CODE:-404}" ;;
  *) rep='' ;;
esac
if [[ -n "$out" && "$out" != /dev/null ]]; then printf '%s' "$rep" > "$out"; elif [[ -z "$out" ]]; then printf '%s' "$rep"; fi
[[ -z "$fmt" ]] || printf '%s' "$code"
EOF
  cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "GIT:$*" >> "$CALLS"
[[ "$*" != *clone* ]] || mkdir -p "${@: -1}"
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "PY3" >> "$CALLS"; printf ""\n' > "$BIN/python3"
  chmod 0755 "$BIN"/*
}

apply() { run bash -c "source '$SCRIPT'; cmd_apply" < /dev/null; }
apply_stdin() { run bash -c "printf '%s' '$1' | { source '$SCRIPT'; cmd_apply; }"; }
install() { run bash -c "source '$SCRIPT'; cmd_install '$1'" < /dev/null; }

# ─── 1. l'org systeme, sans role metier ──────────────────────────────────────────────────────────

@test "apply : le play de la racine est celui de l'org systeme — -var org=lcars et les quatre listes de roles vides ; instance/ ne recoit aucun -var" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "TOFU:recette/instance apply -auto-approve -input=false -no-color" "$CALLS"
  grep -qx "TOFU:recette apply -auto-approve -input=false -no-color -var org=lcars -var roles=\[\] -var writers=\[\] -var judges=\[\] -var externals=\[\] -var approvers=\[\"le-siege\"\]" "$CALLS"
  # le tfvars du roster reste : il nomme le compte systeme, sans defaut par contrat
  [ -f "$LCARS_RECIPE_DIR/roles.auto.tfvars.json" ]
  [[ "$output" == *"apply . (org lcars, sans role metier)"* ]]
}

@test "apply : l'org systeme est LCARS_FORGE_ORG quand l'installeur la nomme" {
  LCARS_FORGE_ORG=flotte apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^TOFU:recette apply .* -var org=flotte " "$CALLS"
}

@test "apply : le depot du systeme n'est PAS cree par le geste — la recette le pose ; le siege, resolu par /api/v1/user, est son approbateur" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "^CURL:POST /api/v1/orgs/lcars/repos" "$CALLS"
  refute grep -q "^CURL:GET /api/v1/repos/lcars/_ops" "$CALLS"
  grep -qx "CURL:GET /api/v1/user" "$CALLS"
  grep -q '^TOFU:recette apply .* -var approvers=\["le-siege"\]$' "$CALLS"
  # le play du catalogue ne recoit pas d'approbateurs : il ne pose aucun depot
  refute grep -q "^TOFU:tofu/fleet apply .*approvers" "$CALLS"
}

@test "apply : un jeton dont la forge ne dit pas le proprietaire est un refus NOMME avant toute recette — la protection n'aurait aucun approbateur" {
  STUB_SANS_SIEGE=1 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la forge ne dit pas a qui appartient le jeton master (/api/v1/user) — la protection de tool_request n'aurait aucun approbateur, RIEN n'est pose"* ]]
  refute grep -q "^TOFU:" "$CALLS"
}

@test "apply : un COMPTE homonyme de l'org systeme est un refus NOMME avant toute recette — sur Gitea une org et un compte partagent l'espace de noms" {
  STUB_ORG_ABSENTE=1 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"un COMPTE nomme « lcars » existe deja sur cette forge"* ]]
  [[ "$output" == *"RIEN n'a ete pose"* ]]
  refute grep -q "^TOFU:" "$CALLS"
  # la question se pose DEUX FOIS : /orgs ne rend 200 que pour une org, /users pour les deux
  grep -qx "CURL:GET /api/v1/orgs/lcars" "$CALLS"
  grep -qx "CURL:GET /api/v1/users/lcars" "$CALLS"
}

@test "apply : un nom que PERSONNE ne porte passe — le garde refuse un homonyme, pas une forge vierge" {
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^TOFU:recette apply .* -var org=lcars " "$CALLS"
}

@test "apply : une org systeme DEJA POSEE ne fait pas sonder les comptes — /orgs a repondu, la question est close" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "CURL:GET /api/v1/orgs/lcars" "$CALLS"
  refute grep -qx "CURL:GET /api/v1/users/lcars" "$CALLS"
}

@test "apply : le compte et l'org nes du MEME plan ne peuvent pas porter le meme nom — la collision se lit sans reseau" {
  # L'INCIDENT REEL (banc vierge, 2026-09-17) : ni l'org ni le compte n'existaient, et le meme apply
  # posait les deux. Aucune sonde ne voit ca ; seule la comparaison de deux noms qu'on tient deja.
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 LCARS_BUILTIN_HUMAN=lcars apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« lcars » est demande a la fois comme COMPTE et comme nom de l'org systeme"* ]] || { echo "$output"; return 1; }
  refute grep -q "^TOFU:" "$CALLS"

  # le compte SYSTEME est pose par le meme plan : meme collision, meme refus
  : > "$CALLS"
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 LCARS_SYSTEM_ACCOUNT=lcars apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« lcars » est demande a la fois comme COMPTE et comme nom de l'org systeme"* ]]
  refute grep -q "^TOFU:" "$CALLS"

  # deux COMPTES du meme nom, poses par le meme plan : refus aussi
  : > "$CALLS"
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 LCARS_BUILTIN_HUMAN=system_starfleet apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"s'appellent tous deux « system_starfleet »"* ]] || { echo "$output"; return 1; }
  refute grep -q "^TOFU:" "$CALLS"

  # desarme : un humain de demonstration d'un AUTRE nom passe, sur la meme forge vierge
  : > "$CALLS"
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 LCARS_BUILTIN_HUMAN=ensign apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^TOFU:recette apply .* -var org=lcars " "$CALLS"
}

@test "apply : une forge qui ne dit ni 200 ni 404 est un refus NOMME — un garde qui se desarme en silence ne garde rien" {
  # un 500, un 403, une connexion coupee : lus comme « absent », ils rendraient le garde muet
  local code
  for code in 000 403 500; do
    : > "$CALLS"
    STUB_ORG_ABSENTE=1 STUB_ORG_CODE="$code" apply
    [ "$status" -eq 1 ] || { echo "code $code : $output"; return 1; }
    [[ "$output" == *"la forge ne dit pas si « lcars » est libre (/api/v1/orgs : HTTP"* ]] || { echo "$output"; return 1; }
    refute grep -q "^TOFU:" "$CALLS"
  done

  # la seconde question a le meme regime : /users muet est fatal aussi
  : > "$CALLS"
  STUB_ORG_ABSENTE=1 STUB_SANS_HOMONYME=1 STUB_USER_CODE=500 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la forge ne dit pas si « lcars » est libre (/api/v1/users : HTTP 500)"* ]] || { echo "$output"; return 1; }
  refute grep -q "^TOFU:" "$CALLS"
}

@test "install : les noms du systeme sont refuses — l'org systeme, et tout nom qui commence par _" {
  install lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"« lcars » est un nom du systeme (l'org systeme « lcars », ou un nom qui commence par « _ ») — un catalogue ne le porte pas, RIEN n'a ete pose"* ]]
  refute grep -q "^TOFU:\|^CLI:" "$CALLS"
  install _ops
  [ "$status" -eq 1 ]
  [[ "$output" == *"« _ops » est un nom du systeme"* ]]
  LCARS_FORGE_ORG=flotte install flotte
  [ "$status" -eq 1 ]
  [[ "$output" == *"« flotte » est un nom du systeme (l'org systeme « flotte »"* ]]
}

# ─── 2. puis le catalogue de la release, comme n'importe quel catalogue ─────────────────────────

@test "apply : apres la structure, le catalogue de la release est installe — son org par la recette dans SON dossier, sans -var, depuis la release, sans clone ni resolution" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # le nom vient du manifeste de la release, demande a la CLI
  grep -qx "CLI:tool catalogue-root" "$CALLS"
  refute grep -q "CLI:tool catalogue-source" "$CALLS"
  refute grep -q "GIT:clone" "$CALLS"
  grep -qx "CLI:tool verify $RELEASE_CAT" "$CALLS"
  grep -qx "CLI:tool roles-tfvars $RELEASE_CAT" "$CALLS"
  [ "$(cat "$LCARS_CATALOGUES_WORK/fleet/roles.auto.tfvars.json")" = '{"org":"fleet","roles":[]}' ]
  grep -qx "TOFU:tofu/fleet apply -auto-approve -input=false -no-color" "$CALLS"
  # l'ordre : l'org systeme d'abord, le catalogue ensuite
  local systeme catalogue
  systeme="$(grep -n "^TOFU:recette apply" "$CALLS" | cut -d: -f1)"
  catalogue="$(grep -n "^TOFU:tofu/fleet apply" "$CALLS" | cut -d: -f1)"
  [ "$systeme" -lt "$catalogue" ]
  [[ "$output" == *"fleet <- la release ($RELEASE_CAT)"* ]]
  [[ "$output" == *"fleet installe (org, comptes, teams, sa source sur lcars/_catalogues:fleet) — le materiel est celui de la release"* ]]
}

@test "apply : le magasin du catalogue de la release recoit la projection — SA BRANCHE du magasin du systeme, poussee de force, sans trailer quand la revision est inconnue, avec quand l'image la porte" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # le magasin est POSE PAR LA RECETTE : le geste le SONDE, il ne le cree pas
  grep -qx "CURL:GET /api/v1/repos/lcars/_catalogues" "$CALLS"
  refute grep -q "^CURL:POST /api/v1/orgs/fleet/repos" "$CALLS"
  grep -q "^GIT:push -q --force http://forge.test/lcars/_catalogues.git HEAD:refs/heads/fleet$" "$CALLS"
  grep -q "^GIT:-c user.name=system_starfleet -c user.email=system_starfleet@lcars.local commit -q -m chore(catalogue): projection de fleet depuis sa source$" "$CALLS"
  refute grep -q "Source-Commit" "$CALLS"
  : > "$CALLS"
  LCARS_IMAGE_REVISION=0123456789ab apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "commit -q -m chore(catalogue): projection de fleet depuis sa source -m Source-Commit: 0123456789ab$" "$CALLS"
  [[ "$output" == *"fleet <- la release ($RELEASE_CAT @ 01234567)"* ]]
}

@test "apply : le materiel local du catalogue de la release n'est PAS pose — la release est son materiel" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$LCARS_CATALOGUES_DIR/fleet" ]
  [ ! -e "$LCARS_CATALOGUES_DIR/fleet.tmp" ]
  refute grep -q "GIT:clone" "$CALLS"
}

@test "apply : une release qui ne nomme pas son catalogue est un echec NOMME, apres la structure — une forge sans org de projets n'accueille rien" {
  STUB_SANS_RELEASE=1 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la release ne nomme pas son catalogue — la structure est posee, mais AUCUNE org de projets ne l'est"* ]]
  grep -q "^TOFU:recette apply" "$CALLS"
  refute grep -q "^TOFU:tofu/" "$CALLS"
}

@test "apply : UN SEUL jeton pour tout le geste — celui de stdin sert aussi au play du catalogue de la release, le fichier n'est pas relu" {
  apply_stdin TOK-APPELANT
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "TOFU-JETON:recette TOK-APPELANT" "$CALLS"
  grep -qx "TOFU-JETON:tofu/fleet TOK-APPELANT" "$CALLS"
  refute grep -q "TOFU-JETON:.* MASTER$" "$CALLS"
}

@test "apply : le master, createur de l'org du catalogue, en est retire des Owners comme pour l'org systeme — le compte systeme est le proprietaire" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "CURL:GET /api/v1/orgs/lcars/teams" "$CALLS"
  grep -qx "CURL:GET /api/v1/orgs/fleet/teams" "$CALLS"
}

@test "apply : la release n'est demandee qu'UNE fois par geste — chaque porte outil la demarre" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^CLI:tool catalogue-root$' "$CALLS")" -eq 1 ]
}

# ─── 3. un autre catalogue : la voie de la forge, inchangee ──────────────────────────────────────

@test "install <autre> : resolu par tool catalogue-source, clone depuis la forge, recette sans -var, materiel pose" {
  install web-demo
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "CLI:tool catalogue-source web-demo" "$CALLS"
  grep -q "^GIT:clone --quiet --depth 1 --branch main http://forge.test/quelquun/web-demo.git " "$CALLS"
  grep -qx "TOFU:tofu/web-demo apply -auto-approve -input=false -no-color" "$CALLS"
  grep -q "^GIT:clone --quiet --depth 1 --branch web-demo http://forge.test/lcars/_catalogues.git " "$CALLS"
  grep -q "commit -q -m chore(catalogue): projection de web-demo depuis sa source -m Source-Commit: deadbeefcafe$" "$CALLS"
  [[ "$output" == *"web-demo <- quelquun/web-demo (main@deadbeef)"* ]]
}

@test "magasin ABSENT : refus NOMME qui renvoie a la recette — l'org est posee, la source n'est nulle part" {
  STUB_SANS_MAGASIN=1 install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"le magasin des catalogues (lcars/_catalogues) ne repond pas (HTTP 404) — la recette de la forge le pose"*"web-demo n'est PAS installe"* ]]
  refute grep -q "^GIT:push" "$CALLS"
}

@test "install <catalogue de la release> a la main : la meme voie que celle de l'apply, depuis la release" {
  install fleet
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "CLI:tool catalogue-source" "$CALLS"
  grep -qx "TOFU:tofu/fleet apply -auto-approve -input=false -no-color" "$CALLS"
  [[ "$output" == *"le materiel est celui de la release"* ]]
}

# ─── 4. LE PROJET DU SYSTEME, POSE PAR CE GESTE ─────────────────────────────────────────────────
#
# ⚠ IL SE POSE ICI, ET PAS PAR UNE PORTE DU RUNTIME. La porte aurait demande son jeton au rail
# d'autorite, qui ne sert QUE les humains de la flotte ; sur un poste neuf il n'y en a pas encore, et
# « pas encore d'humain » n'est pas une raison pour que le projet n'existe pas. Ce geste, lui, a le
# jeton master, l'adresse de la forge et git.

@test "apply : le projet du systeme est pose dans l'org du catalogue embarque, et sa source y est poussee" {
  LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" mkdir -p "$BATS_TEST_TMPDIR/source/.git"
  LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # le NOM vient de la release, jamais d'un litteral du geste
  grep -qx "CLI:tool system-project" "$CALLS"
  # l'org est celle du catalogue embarque, PAS l'org systeme : elle ne porte aucun projet
  grep -qx "CURL:GET /api/v1/repos/fleet/lcars-fleet" "$CALLS"
  grep -qx "CURL:POST /api/v1/orgs/fleet/repos" "$CALLS"
  refute grep -q "POST /api/v1/orgs/lcars/repos" "$CALLS"
  grep -q "^GIT:-C $BATS_TEST_TMPDIR/source push -q .*/fleet/lcars-fleet.git HEAD:refs/heads/main" "$CALLS" \
    || { grep '^GIT:' "$CALLS"; return 1; }
  [[ "$output" == *"fleet/lcars-fleet pose"* ]]
}

@test "apply : un projet DEJA sur la forge n'est PAS reecrit — la seconde passe ne pousse rien" {
  # `main` est ce que le projet est DEVENU : le remplacer par l'arbre d'installation effacerait du travail
  LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" mkdir -p "$BATS_TEST_TMPDIR/source/.git"
  STUB_PROJET_CODE=200 LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"fleet/lcars-fleet est deja sur la forge — la source n'est PAS reecrite"* ]]
  refute grep -q "POST /api/v1/orgs/fleet/repos" "$CALLS"
  refute grep -q "GIT:.*lcars-fleet.git" "$CALLS"
}

@test "apply : sans arbre a publier, le projet n'est pas pose — et la structure, elle, l'est" {
  # un kit sans historique, ou un appelant qui ne dit pas d'ou vient la source
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "CLI:tool system-project" "$CALLS"
  refute grep -q "POST /api/v1/orgs/fleet/repos" "$CALLS"
  grep -q "^TOFU:recette apply .* -var org=lcars " "$CALLS"
}

@test "apply : une forge qui ne dit pas si le projet existe est un refus NOMME — rien n'est pose a l'aveugle" {
  LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" mkdir -p "$BATS_TEST_TMPDIR/source/.git"
  STUB_PROJET_CODE=500 LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la forge ne dit pas si fleet/lcars-fleet existe (HTTP 500)"* ]] || { echo "$output"; return 1; }
  refute grep -q "POST /api/v1/orgs/fleet/repos" "$CALLS"
}

@test "apply : un depot cree mais une source NON poussee est un refus qui dit que le depot est vide" {
  LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" mkdir -p "$BATS_TEST_TMPDIR/source/.git"
  # SEUL le push du projet echoue : le reste du geste doit atteindre cette etape
  printf '#!/usr/bin/env bash\necho "GIT:$*" >> "$CALLS"\n[[ "$*" != *lcars-fleet.git* ]] || exit 1\nexit 0\n' > "$BIN/git"
  chmod 0755 "$BIN/git"
  STUB_PROJET_CODE=404 LCARS_SYSTEM_SOURCE="$BATS_TEST_TMPDIR/source" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"source NON poussee sur fleet/lcars-fleet"*"le depot est cree et VIDE"* ]] || { echo "$output"; return 1; }
}

# ─── 5. L'ETAT QUI NOMME UN COMPTE DISPARU ──────────────────────────────────────────────────────
#
# ⚠ LE PENDANT DE L'IMPORT. `existing.tf` reprend dans l'etat ce qui existe deja ; le cas MIROIR
# n'avait rien. Le provider ne rafraichit pas un compte supprime de la forge, il MEURT dessus —
# mesure du 2026-09-17 sur LCARS-beta, ou l'architecte avait retire le compte homonyme de l'org :
#
#     gitea_user.human[0]: Refreshing state... [id=2]
#     Error: user not found with id 2
#
# Et il meurt au PLAN, donc avant que le moindre objet ne soit pose : l'installation entiere
# s'arretait sur un compte que plus personne ne voulait.

etat_avec() { # etat_avec <dossier du play> <login>… — un tfstate qui NOMME ces comptes
  local dir="$1"; shift
  mkdir -p "$dir"
  local n=1 insts=""
  for l in "$@"; do
    insts="$insts${insts:+,}{\"index_key\":0,\"attributes\":{\"id\":\"$n\",\"username\":\"$l\"}}"
    n=$((n + 1))
  done
  printf '{"resources":[{"type":"gitea_user","name":"human","instances":[%s]}]}\n' "$insts" \
    > "$dir/terraform.tfstate"
}

@test "apply : un compte de l'etat que la forge n'a PLUS est retire, et la recette rejoue" {
  etat_avec "$LCARS_RECIPE_DIR/instance" disparu
  # `disparu` rend 404 sur /users ; tout le reste de la forge repond
  STUB_SANS_HOMONYME=1 apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"gitea_user.human[0] (« disparu ») n'est plus sur la forge — retire de l'etat"* ]] \
    || { echo "$output"; return 1; }
  # -F : l'adresse porte des crochets, qu'une expression reguliere lirait comme une classe
  grep -qxF "TOFU:recette/instance state rm -no-color gitea_user.human[0]" "$CALLS" \
    || { grep '^TOFU:' "$CALLS"; return 1; }
  # et le play est joue APRES, pas a la place
  grep -qx "TOFU:recette/instance apply -auto-approve -input=false -no-color" "$CALLS"
}

@test "apply : un compte TOUJOURS la n'est PAS retire — on n'oublie que sur un 404 franc" {
  etat_avec "$LCARS_RECIPE_DIR/instance" toujours-la
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "state rm" "$CALLS"
  refute_out "n'est plus sur la forge" <<<"$output"
}

@test "apply : une forge qui ne dit NI 200 NI 404 ne fait oublier personne" {
  # une forge qu'on lit mal n'autorise a effacer aucun etat : 500 laisse tout en place
  etat_avec "$LCARS_RECIPE_DIR/instance" douteux
  STUB_SANS_HOMONYME=1 STUB_USER_CODE=500 apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "state rm" "$CALLS"
}

@test "apply : un « state rm » qui echoue est un refus NOMME — le plan mourrait dessus" {
  etat_avec "$LCARS_RECIPE_DIR/instance" disparu
  printf '#!/usr/bin/env bash\necho "TOFU:${PWD#"$BATS_TEST_TMPDIR"/} $*" >> "$CALLS"\n[[ "$1" != "state" ]] || exit 1\n[[ "$1" != apply ]] || echo "Apply complete!"\n' > "$BIN/tofu"
  chmod 0755 "$BIN/tofu"
  STUB_SANS_HOMONYME=1 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"nomme un compte absent de la forge et ne sort pas de l'etat"* ]] || { echo "$output"; return 1; }
  refute grep -q "apply -auto-approve" "$CALLS"
}

# ─── 6. UN ETAT QUI DECRIT UNE AUTRE ORG ────────────────────────────────────────────────────────
#
# ⚠ TOFU NE VOIT PAS UN RENOMMAGE, IL VOIT UNE RESSOURCE EN TROP — et la DETRUIT. Quand l'org du
# systeme a change de nom (lot 1, `fleet` → `lcars`), l'etat d'avant decrivait une org que ce play
# ne possede plus. Mesure du 2026-09-18 sur LCARS-beta, mise a jour par-dessus l'instance :
#
#     Error: user is the last member of owner team [uid: 4]
#
# C'etait la destruction de l'org `fleet` qui parlait : celle qui porte desormais les PROJETS.

etat_org() { # etat_org <dossier du play> <nom d org>
  mkdir -p "$1"
  printf '{"resources":[{"type":"gitea_org","name":"fleet","instances":[{"attributes":{"name":"%s"}}]}]}\n' \
    "$2" > "$1/terraform.tfstate"
  : > "$1/terraform.tfstate.backup"
}

@test "apply : un etat qui decrit une AUTRE org est mis de cote — rien n'est detruit sur la forge" {
  etat_org "$LCARS_RECIPE_DIR" fleet
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"l'etat decrivait l'org « fleet », ce play porte « lcars » — etat mis de cote"* ]] \
    || { echo "$output"; return 1; }
  # MIS DE COTE, pas supprime : le fichier est la, date, et le play repart d'un etat vierge
  [ ! -f "$LCARS_RECIPE_DIR/terraform.tfstate" ]
  ls "$LCARS_RECIPE_DIR"/terraform.tfstate.autre-org-fleet.* >/dev/null
  [ ! -f "$LCARS_RECIPE_DIR/terraform.tfstate.backup" ]
  # et AUCUN destroy : la recette est jouee normalement
  grep -q "^TOFU:recette apply .* -var org=lcars " "$CALLS"
  refute grep -q "destroy" "$CALLS"
}

@test "apply : un etat qui decrit NOTRE org reste en place — on ne jette pas un etat juste" {
  etat_org "$LCARS_RECIPE_DIR" lcars
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$LCARS_RECIPE_DIR/terraform.tfstate" ]
  refute_out "mis de cote" <<<"$output"
}

@test "apply : le play instance n'est PAS juge sur l'org — il ne porte que des comptes" {
  # `instance/` pose les comptes partages, aucune org : lui appliquer cette regle le viderait
  etat_org "$LCARS_RECIPE_DIR/instance" fleet
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$LCARS_RECIPE_DIR/instance/terraform.tfstate" ]
}

# ─── 7. QUI APPROUVE SE DERIVE, IL NE SE DECLARE PAS ────────────────────────────────────────────
#
# ⚠ Gitea n'accepte dans une whitelist de protection QUE les membres d'une team de l'org : un
# collaborateur de depot, fut-il site-admin, en est ecarte EN SILENCE (mesure du 2026-09-18, banc
# VIERGE 2004). La recette nomme donc une TEAM et aucun compte ; sa composition est ici, et elle se
# derive du drapeau site-admin de la forge.
#
# ⚖ user 2026-09-18 : « une autre table tenue a la main va diverger, c'est perdu d'avance ».

@test "apply : les site-admins ABSENTS de la team y entrent — la composition se derive, elle ne se declare pas" {
  STUB_ADMINS='[{"login":"le-siege","is_admin":true,"active":true},{"login":"ensign","is_admin":true,"active":true}]' \
    STUB_MEMBRES='[]' apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  grep -qx "CURL:PUT /api/v1/teams/9/members/le-siege" "$CALLS" || { grep '^CURL:' "$CALLS"; return 1; }
  grep -qx "CURL:PUT /api/v1/teams/9/members/ensign" "$CALLS"
  [[ "$output" == *"admins += le-siege (site-admin de la forge)"* ]]
  [[ "$output" == *"admins += ensign (site-admin de la forge)"* ]]
}

@test "apply : un membre qui n'est PLUS site-admin en SORT — sinon il approuverait encore" {
  STUB_ADMINS='[{"login":"le-siege","is_admin":true,"active":true}]' \
    STUB_MEMBRES='[{"login":"le-siege"},{"login":"ancien"}]' apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  grep -qx "CURL:DELETE /api/v1/teams/9/members/ancien" "$CALLS" || { grep '^CURL:' "$CALLS"; return 1; }
  [[ "$output" == *"admins -= ancien (n'est plus site-admin)"* ]]
  # celui qui est toujours admin n'est ni ajoute ni retire
  refute grep -q "members/le-siege" "$CALLS"
}

@test "apply : un compte admin mais DESACTIVE n'entre pas — il ne signerait rien" {
  STUB_ADMINS='[{"login":"le-siege","is_admin":true,"active":true},{"login":"dormant","is_admin":true,"active":false}]' \
    STUB_MEMBRES='[]' apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "members/dormant" "$CALLS"
  grep -qx "CURL:PUT /api/v1/teams/9/members/le-siege" "$CALLS"
}

@test "apply : une forge SANS aucun site-admin actif est un refus NOMME — la protection serait un piege" {
  STUB_ADMINS='[]' apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la forge ne nomme AUCUN site-admin actif"* ]] || { echo "$output"; return 1; }
}

@test "apply : la team ABSENTE de la forge est un refus qui renvoie a la recette" {
  STUB_TEAMS='[{"id":9,"name":"humans"}]' apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"la team « admins » n'est pas sur la forge"* ]] || { echo "$output"; return 1; }
}

@test "apply : une ecriture de team REFUSEE est un refus NOMME — l'approbateur ne signerait pas" {
  STUB_MEMBRES='[]' STUB_TEAM_ECRITURE=403 apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"est site-admin et n'entre pas dans la team « admins » (HTTP 403)"* ]] || { echo "$output"; return 1; }
}
