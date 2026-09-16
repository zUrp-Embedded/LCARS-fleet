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
method=GET; url=""; fmt=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -X) method="$2"; shift 2 ;; -w) fmt="$2"; shift 2 ;; -o) out="$2"; shift 2 ;;
    -K|-m|-H|-d) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
[[ -t 0 ]] || cat >/dev/null
echo "CURL:$method ${url#http://forge.test}" >> "$CALLS"
case "$url" in */members|*/teams|*/admin/users*) rep='[]' ;; *) rep='' ;; esac
if [[ -n "$out" && "$out" != /dev/null ]]; then printf '%s' "$rep" > "$out"; elif [[ -z "$out" ]]; then printf '%s' "$rep"; fi
[[ -z "$fmt" ]] || printf '200'
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
  grep -qx "TOFU:recette apply -auto-approve -input=false -no-color -var org=lcars -var roles=\[\] -var writers=\[\] -var judges=\[\] -var externals=\[\]" "$CALLS"
  # le tfvars du roster reste : il nomme le compte systeme, sans defaut par contrat
  [ -f "$LCARS_RECIPE_DIR/roles.auto.tfvars.json" ]
  [[ "$output" == *"apply . (org lcars, sans role metier)"* ]]
}

@test "apply : l'org systeme est LCARS_FORGE_ORG quand l'installeur la nomme, et le depot systeme la suit" {
  LCARS_FORGE_ORG=flotte apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^TOFU:recette apply .* -var org=flotte " "$CALLS"
  grep -qx "CURL:GET /api/v1/repos/flotte/_ops" "$CALLS"
  [[ "$output" == *"depot ops flotte/_ops deja la"* ]]
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
  [[ "$output" == *"fleet installe (org, comptes, teams, sa source dans fleet/_catalogue) — le materiel est celui de la release"* ]]
}

@test "apply : le magasin du catalogue de la release recoit la projection — le depot _catalogue de SON org, poussee de force, sans trailer quand la revision est inconnue, avec quand l'image la porte" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "CURL:POST /api/v1/orgs/fleet/repos" "$CALLS"
  grep -q "^GIT:push -q --force http://forge.test/fleet/_catalogue.git main$" "$CALLS"
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
  grep -q "^GIT:clone --quiet --depth 1 http://forge.test/web-demo/_catalogue.git " "$CALLS"
  grep -q "commit -q -m chore(catalogue): projection de web-demo depuis sa source -m Source-Commit: deadbeefcafe$" "$CALLS"
  [[ "$output" == *"web-demo <- quelquun/web-demo (main@deadbeef)"* ]]
}

@test "install <catalogue de la release> a la main : la meme voie que celle de l'apply, depuis la release" {
  install fleet
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q "CLI:tool catalogue-source" "$CALLS"
  grep -qx "TOFU:tofu/fleet apply -auto-approve -input=false -no-color" "$CALLS"
  [[ "$output" == *"le materiel est celui de la release"* ]]
}
