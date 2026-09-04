#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/61-forge-structure.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for 61-forge-structure — la structure de la forge se derive de la release POSEE, sans mix
#
# CE QUE CE FICHIER GARDE, ET D'OU IL VIENT. Ces temoins vivaient dans `forge_host_reach.bats`, sur
# `48-forge-host`, quand ce module posait la structure de la forge dans le meme geste que son
# amorcage. La structure exige le roster du catalogue, donc la release — que `60-deploy` pose douze
# rangs plus loin. `48` la contournait en COMPILANT l'arbre (hex, rebar, deps.get, `mix run`) et en
# devinant quelle release lire (`prov_release_bin`). ⚖ user 2026-09-04 (point 1 du chantier
# deploy-independance) : couper `48`, poser la structure APRES 60. Ici la release est posee par
# construction : un chemin, aucun `mix`, aucune devinette.
#
# ⚠ CES TEMOINS NE LANCENT NI DOCKER NI TOFU. Ce qui se mesure est la FORME de l'appel — c'est la
# que les fautes etaient, et la seule partie qui serait silencieuse.
# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  SRC="$BATS_TEST_DIRNAME/../../modules.d/61-forge-structure.sh"
  [ -f "$SRC" ]
  SRC48="$BATS_TEST_DIRNAME/../../modules.d/48-forge-host.sh"
  G="$BATS_TEST_DIRNAME/../../../fleet/services/forge-gestures.sh"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=61-forge-structure
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
}

code() { grep -vE '^\s*#|^\s*`#' "$SRC"; }

# ─── LE RANG, ET CE QU'IL ACHETE ────────────────────────────────────────────────────────────────

@test "le module vient APRES 60 et le DECLARE — la dependance etait un commentaire, elle est un AFTER" {
  grep -qE '^# AFTER: .*\b60-deploy\b' "$SRC"
  grep -qE '^# AFTER: .*\b48-forge-host\b' "$SRC"
  grep -qE '^# AFTER: .*\b46-tofu\b' "$SRC"
  # et le rang est l'ordre : le glob du runner met 60 avant 61
  local _mods _ia _ib d="$BATS_TEST_DIRNAME/../../modules.d"
  _mods="$(cd "$d" && printf '%s\n' *.sh)"
  _ia="$(grep -nx '60-deploy.sh' <<<"$_mods" | cut -d: -f1)"
  _ib="$(grep -nx '61-forge-structure.sh' <<<"$_mods" | cut -d: -f1)"
  [ -n "$_ia" ] && [ -n "$_ib" ] && [ "$_ia" -lt "$_ib" ]
}

@test "48 ne pose PLUS la structure, ni le roster — il monte et amorce, c'est tout" {
  local c48; c48="$(grep -vE '^\s*#|^\s*`#' "$SRC48")"
  refute grep -q 'forge-gestures.sh" apply' <<<"$c48"
  refute grep -q 'enroll-catalogue.sh' <<<"$c48"
  refute grep -qE 'mix (local\.|deps\.|run |compile)' <<<"$c48"
  refute grep -q 'prov_release_bin' <<<"$c48"
  refute grep -q 'tofu init' <<<"$c48"
  # et il le dit : celui qui structure est nomme
  grep -q '61-forge-structure' "$SRC48"
}

# ─── LE ROSTER, DEPUIS LA RELEASE POSEE — ET RIEN D'AUTRE ───────────────────────────────────────

@test "le roster se derive de la release POSEE — un seul chemin, derive du prefixe" {
  code | grep -q 'RELEASE_BIN="\$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"'
  code | grep -q 'enroll-catalogue.sh" --tofu-dir "\$enroll" --release "\$RELEASE_BIN"'
  # ni l'arbre, ni une image, ni le paquet : la devinette est morte avec 48
  code | refute_out '--repo'
  code | refute_out '--image'
  code | refute_out '_build/prod/rel'
  code | refute_out 'prov_release_bin'
  code | refute_out 'ref_catalogue'
  code | refute_out 'Fleet.Catalogue.root'
}

@test "AUCUN mix dans ce module — la release porte la fonction, le detour n'a plus d'objet" {
  code | refute_out 'mix local'
  code | refute_out 'mix deps'
  code | refute_out 'mix run'
  code | refute_out 'mix compile'
}

@test "la derivation se joue sous l'humain, en mode OUTIL (GUARD B)" {
  # La release refuse de s'evaluer sous le siege ; `LCARS_TOOL_EVAL=1` est le seam prevu pour un
  # outil. Le dossier de sortie est cede a l'humain, sinon il ne peut pas y ecrire.
  code | grep -q 'as_human env LCARS_TOOL_EVAL=1 "\$(dirname "\$PROVISION_LIB")/enroll-catalogue.sh"'
  code | grep -q 'chown "\$PROV_HUMAN" "\$enroll"'
  local rt="$BATS_TEST_DIRNAME/../../../fleet/config/runtime.exs"
  grep -q 'tool_mode? = System.get_env("LCARS_TOOL_EVAL") == "1"' "$rt"
}

@test "sans release posee, le REFUS nomme le poseur (60-deploy) et le chemin — jamais l'arbre" {
  # Le fragment est joue contre des doublures : c'est du choix de chemin, il ne parle a personne.
  local frag="$BATS_TEST_TMPDIR/frag.sh"
  sed -n '/^  \[\[ -x "\$RELEASE_BIN" \]\] || {$/,/^  }$/p' "$SRC" > "$frag"
  [ -s "$frag" ] || { echo "extraction du fragment ratee"; return 1; }
  run bash -c "
    p_fail() { echo \"FAIL \$*\"; }
    verdict_apply() { exit 9; }
    RELEASE_BIN='$BATS_TEST_TMPDIR/inexistant/lcars_fleet'
    source '$frag'
    echo CONTINUE"
  [ "$status" -eq 9 ] || { echo "le module a continue sans release (rc=$status) : $output"; return 1; }
  [[ "$output" == *"60-deploy"* ]]
  [[ "$output" == *"inexistant/lcars_fleet"* ]]
  refute grep -q 'roster non dérivable' <<<"$output"
  [[ "$output" != *"CONTINUE"* ]]
}

# ─── LA STRUCTURE SE POSE SUR LA MACHINE, PLUS DANS UN CONTENEUR ────────────────────────────────
#
# ⚖ USER 2026-08-22 : « tu build une image complete de 1,2 Go juste pour executer 100 ko de recette
# tofu ? » — la structure se jouait dans un conteneur transitoire. Elle se joue par le geste.

@test "la structure est jouee par le GESTE, pas par un conteneur transitoire" {
  code | grep -q 'forge-gestures.sh" apply'
  code | refute_out 'd create --network'
  code | refute_out 'd cp '
  code | refute_out 'volume create'
  code | refute_out 'forge-apply'
  code | refute_out 'PROV_FORGE_IMAGE'
  code | refute_out 'lcars-fleet:2'
  code | refute_out 'image inspect'
}

@test "l'AUTORITE est lue la ou 48 l'a ECRITE — LCARS_PRIVATE_DIR, jamais recomposee" {
  grep -q 'LCARS_PRIVATE_DIR="\$PROV_TOKENS_DIR"' "$SRC"
  grep -q 'PROV_MASTER_TOKEN_FILE' "$SRC"
  grep -q 'MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-\$PRIVATE_DIR/forge-master.token}"' "$G"
  grep -q 'SEED_FILE="${LCARS_FORGE_SEED_FILE:-\$PRIVATE_DIR/forge-seed.pass}"' "$G"
  # et 48 pose bien les deux noms que le geste cherche
  grep -q 'SEED_FILE="\$PROV_TOKENS_DIR/forge-seed.pass"' "$SRC48"
}

@test "l'URL passee est la LOOPBACK de l'hote, plus le nom de service du reseau compose — UNE fois" {
  [ "$(code | grep -c 'FORGE_BASE_URL="\$FORGE_URL"')" -eq 1 ]
  code | refute_out 'FORGE_BASE_URL="http://forge:3000"'
}

@test "la recette est une COPIE — le checkout de l'operateur ne recoit pas le roster genere" {
  code | grep -q 'recipe="\$(mktemp -d'
  code | grep -q 'LCARS_RECIPE_DIR="\$recipe"'
  code | grep -q 'cp "\$enroll/roles.auto.tfvars.json" "\$recipe/roles.auto.tfvars.json"'
  code | refute_out 'deps/roles\.auto\.tfvars\.json'
  code | grep -q 'rm -rf "\$recipe" "\$enroll"'
}

@test "la copie est INITIALISEE hors-ligne — le geste appelle \`tofu apply\` NU" {
  sed -n '/^  for m in instance \.; do/,/^  done/p' "$G" | refute_out 'tofu init'
  code | grep -q 'tofu init -input=false -no-color'
  code | grep -q 'TF_CLI_CONFIG_FILE='
}

@test "le \`.terraform\` de l'arbre NE VOYAGE PAS — un etat decrit un chemin, pas une recette" {
  code | grep -q 'rm -rf "\$recipe/.terraform" "\$recipe/instance/.terraform"'
}

@test "le pre-requis manquant est NOMME avec le module qui le pose" {
  grep -q '46-tofu' "$SRC"
  code | grep -q 'LCARS_TOFU_BIN:-/usr/local/bin/tofu'
  refute grep -q 'box build' "$SRC"
}

@test "le depot de demo est recable, la REFERENCE se demande a son autorite — ce module ne la nomme pas" {
  local racines racine
  racines="$(sed -nE 's|^COPY[[:space:]]+catalogues[[:space:]]+([^[:space:]]+)[[:space:]]*$|\1|p' \
               "$BATS_TEST_DIRNAME/../../docker/Dockerfile" | grep -v '^/src/' || true)"
  [ "$(printf '%s\n' "$racines" | grep -c .)" -eq 1 ]
  racine="$racines"
  grep -q "DEMO_CATALOGUE=\"\${LCARS_DEMO_CATALOGUE:-$racine/web-demo}\"" "$G"
  code | grep -q 'LCARS_DEMO_CATALOGUE='
  # ⚠ LA REFERENCE N'EST PLUS PASSEE : 48 la derivait par `mix run` ; le geste la demande lui-meme
  # a la release (`catalogue-root`), qui « existe pour que personne ne RECOMPOSE ce chemin ».
  code | refute_out 'LCARS_REFERENCE_CATALOGUE'
  grep -q 'catalogue-root' "$G"
  [ -d "$BATS_TEST_DIRNAME/../../../catalogues/web-demo" ]
}

@test "ce module ne nomme AUCUN humain — l'autorite du nom est forge-gestures, et le banc seul le pose" {
  code | refute_out 'LCARS_BUILTIN_HUMAN'
  code | refute_out 'DISPOSABLE'
  refute grep -qE '"lcars"|:-lcars\}' <<<"$(code)"
  grep -qE '^\s*export TF_VAR_builtin_human=' "$G"
}

@test "« APPLIQUE » n'est pas « CHANGE » — le verdict compte les ressources que tofu dit avoir bougees" {
  code | grep -q 'Apply complete!'
  code | grep -q 'PROV_CHANGED=\$((PROV_CHANGED + 1))'
  grep -q 'structure de la forge déjà conforme' "$SRC"
  grep -q '63-forge-tokens peut minter' "$SRC"
}

@test "le check mesure les PRECONDITIONS et dit qui sonde la structure — il ne rejoue pas la recette" {
  local c_check; c_check="$(sed -n '/^check() {/,/^}/p' "$SRC")"
  grep -q 'RELEASE_BIN' <<<"$c_check"
  grep -q 'PROV_MASTER_TOKEN_FILE' <<<"$c_check"
  grep -q '63-forge-tokens' <<<"$c_check"
  refute grep -q 'tofu plan' <<<"$c_check"
  refute grep -q 'forge-gestures' <<<"$c_check"
}
