#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/61-forge-structure.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 61-forge-structure — les préconditions, le roster dérivé de la release, la recette jouée sur une copie, le verdict lu dans la sortie de tofu

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/61-forge-structure.sh"; [ -f "$MOD" ]
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy/lib" "$RACINE/runtime/services/forge-recipe/instance"
  cp "$BATS_TEST_DIRNAME"/../../lib/*.sh "$RACINE/deploy/lib/"
  cp "$BATS_TEST_DIRNAME/../../installer-constants.env" "$BATS_TEST_DIRNAME/../../system.manifest" "$RACINE/deploy/"
  printf 'terraform {}\n' > "$RACINE/runtime/services/forge-recipe/versions.tf"
  printf 'terraform {}\n' > "$RACINE/runtime/services/forge-recipe/instance/versions.tf"
  mkdir -p "$RACINE/runtime/services/forge-recipe/.terraform"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=61-forge-structure PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  decor_pose
  TOKENS="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  MASTER="$TOKENS/forge-master.token"; printf 'tok\n' > "$MASTER"
  PREFIX="$LCARS_DECOR_ROOT/opt/lcars/runtime"
  mkdir -p "$PREFIX/rel/lcars_fleet/bin"; printf '#!/bin/sh\n' > "$PREFIX/rel/lcars_fleet/bin/lcars_fleet"; chmod 0755 "$PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  TOFU_DIR="$LCARS_DECOR_ROOT/opt/lcars/tofu"; mkdir -p "$TOFU_DIR"; printf 'x\n' > "$TOFU_DIR/tofurc"
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.24.0"}'
  # sans forge fournie, la forge est celle du poste : la loopback au port choisi, celui de la forge locale
  export PROV_FORGE_HOST_PORT="${FORGE_DOUBLE_URL##*:}"
  POSTE="http://127.0.0.1:$PROV_FORGE_HOST_PORT"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export GESTE_ENV="$BATS_TEST_TMPDIR/geste.env"; : > "$GESTE_ENV"
  BIN="$DECOR_BIN"
  # tofu vit hors du PATH (sous apt, DPkg::Path n'a pas /usr/local/bin) ; un tofu et un mix du PATH sont des pièges
  TOFU_BIN="$LCARS_DECOR_ROOT/usr/local/bin/tofu"
  cat > "$TOFU_BIN" <<'EOF'
#!/usr/bin/env bash
echo "TOFU $PWD $*" >> "$CALLS"
[[ -z "${STUB_INIT_KO:-}" ]] || { echo "init: provider introuvable dans le miroir" >&2; exit 1; }
EOF
  printf '#!/usr/bin/env bash\necho "PIEGE tofu du PATH $*" >> "$CALLS"; exit 127\n' > "$BIN/tofu"
  printf '#!/usr/bin/env bash\necho "PIEGE mix $*" >> "$CALLS"; exit 127\n' > "$BIN/mix"
  cat > "$RACINE/deploy/lib/enroll-catalogue.sh" <<'EOF'
#!/usr/bin/env bash
echo "ENROLL $* TOOL_EVAL=${LCARS_TOOL_EVAL:-}" >> "$CALLS"
while [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done
[[ "${STUB_ROSTER:-}" == vide ]] || printf '{"roles":{"admiral":{}}}\n' > "$dir/roles.auto.tfvars.json"
EOF
  # la doublure tient le contrat du vrai geste : un jeton lu sur l'entrée, la recette initialisée par le tofu du PATH
  cat > "$RACINE/runtime/services/forge-gestures.sh" <<'EOF'
#!/usr/bin/env bash
echo "GESTE $*" >> "$CALLS"
IFS= read -r jeton_tape || true
{ env | grep -E '^(FORGE_BASE_URL|LCARS_PRIVATE_DIR|LCARS_RECIPE_DIR|LCARS_DEMO_CATALOGUE|LCARS_AUTHORITY_USER|TF_CLI_CONFIG_FILE|LCARS_BUILTIN_HUMAN|LCARS_FORGE_ORG|LCARS_CATALOGUES_WORK|LCARS_MASTER_TOKEN_FILE|LCARS_FORGE_SEED_FILE)=' | sort
  echo "recette: $(ls -A "$LCARS_RECIPE_DIR" | sort | tr '\n' ' ')"
  echo "instance: $(ls -A "$LCARS_RECIPE_DIR/instance" | sort | tr '\n' ' ')"
  echo "stdin: [$jeton_tape]"
} > "$GESTE_ENV"
for m in instance .; do
  ( cd "$LCARS_RECIPE_DIR/$m" && tofu init -input=false -no-color ) || { echo "forge-gestures: init $m en echec" >&2; exit 1; }
  # l'état : repris s'il est là, réécrit par chaque apply, même en échec
  [[ ! -f "$LCARS_RECIPE_DIR/$m/terraform.tfstate" ]] || echo "ETAT REPRIS $m $(cat "$LCARS_RECIPE_DIR/$m/terraform.tfstate")" >> "$CALLS"
  echo "etat-de-$m-${STUB_GESTE:-pose}" > "$LCARS_RECIPE_DIR/$m/terraform.tfstate"
done
case "${STUB_GESTE:-pose}" in
  pose)    echo "Apply complete! Resources: 12 imported, 3 added, 0 changed, 0 destroyed." ;;
  importe) echo "Apply complete! Resources: 4 imported, 0 added, 0 changed, 0 destroyed." ;;
  rien)    echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed." ;;
  echec)   echo "Error: gitea_org.fleet: 401 Unauthorized" >&2; exit 1 ;;
esac
EOF
  chmod 0755 "$BIN"/* "$TOFU_BIN" "$RACINE/deploy/lib/enroll-catalogue.sh" "$RACINE/runtime/services/forge-gestures.sh"
}

teardown() { forge_double_stop; }

mod() { run bash "$MOD" "$@"; }
copies_restantes() { find "$TMPDIR" -mindepth 1 -maxdepth 1 \( -name 'prov-enroll.*' -o -name 'prov-recipe.*' -o -name 'prov-tofu.*' \); }

@test "check : forge muette — un drift qui renvoie à 48, rien d'autre n'est sondé" {
  PROV_FORGE_HOST_PORT=9 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 61-forge-structure: forge muette (http://127.0.0.1:9) — rien à structurer tant que 48-forge-host"* ]]
  [[ "$output" != *"release"* ]]
}

@test "check : forge vivante sans autorité — un seul drift, qui nomme 48 ; release et tofu restent aux modules qui les posent" {
  rm -f "$MASTER" "$PREFIX/rel/lcars_fleet/bin/lcars_fleet" "$TOFU_BIN"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune autorité de création ($MASTER) — 48-forge-host la minte"* ]]
  [ "$(grep -c '^DRIFT' <<<"$output")" -eq 1 ]
}

@test "check : forge vivante et autorité présente — conforme" {
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge vivante ($POSTE), autorité de création présente ($MASTER)"* ]]
}

@test "apply : forge muette — échec, aucun geste" {
  PROV_FORGE_HOST_PORT=9 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: forge muette (http://127.0.0.1:9)"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans autorité de création — échec qui nomme 48, aucun geste" {
  rm -f "$MASTER"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: aucune autorité de création"*"48-forge-host la minte"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans tofu — échec qui nomme 46, aucun geste" {
  rm -f "$TOFU_BIN"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: tofu absent ($TOFU_BIN) — 46-tofu le pose"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans release posée — échec qui nomme 60 et le chemin, aucun geste" {
  rm -f "$PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune release exécutable posée ($PREFIX/rel/lcars_fleet/bin/lcars_fleet) — 60-deploy n'a pas abouti"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : le geste reçoit l'organisation choisie, le dossier de travail tofu et les fichiers d'autorité des constantes" {
  export PROV_FORGE_ORG=flotte-temoin
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF "LCARS_FORGE_ORG=flotte-temoin" "$GESTE_ENV"
  grep -qxF "LCARS_CATALOGUES_WORK=$LCARS_DECOR_ROOT/opt/lcars/var/tofu" "$GESTE_ENV"
  grep -qxF "LCARS_MASTER_TOKEN_FILE=$MASTER" "$GESTE_ENV"
  grep -qxF "LCARS_FORGE_SEED_FILE=$TOKENS/forge-seed.pass" "$GESTE_ENV"
}

@test "apply : le roster est déposé dans une copie de la recette que le geste initialise avec le tofu épinglé, il reçoit la forge et l'autorité, les copies partent, la pose est comptée" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # le tofu du PATH est un piège : le geste trouve l'épinglé de 46 en tête du sien
  [ "$(grep -c "^TOFU $TMPDIR/prov-recipe\.[^/ ]* init -input=false -no-color$" "$CALLS")" -eq 1 ]
  [ "$(grep -c "^TOFU $TMPDIR/prov-recipe\.[^/]*/instance init -input=false -no-color$" "$CALLS")" -eq 1 ]
  grep -q '^GESTE apply$' "$CALLS"
  grep -q "^FORGE_BASE_URL=$POSTE$" "$GESTE_ENV"
  grep -q "^LCARS_PRIVATE_DIR=$TOKENS$" "$GESTE_ENV"
  grep -q "^LCARS_RECIPE_DIR=$TMPDIR/prov-recipe\." "$GESTE_ENV"
  grep -q "^LCARS_DEMO_CATALOGUE=$RACINE/catalogues/web-demo$" "$GESTE_ENV"
  grep -q "^TF_CLI_CONFIG_FILE=$TOFU_DIR/tofurc$" "$GESTE_ENV"
  grep -q '^recette: instance roles.auto.tfvars.json versions.tf $' "$GESTE_ENV"
  # hors banc, le geste ne reçoit aucun humain de démonstration
  refute grep -q '^LCARS_BUILTIN_HUMAN=.' "$GESTE_ENV"
  refute grep -q '^PIEGE' "$CALLS"
  [ -z "$(copies_restantes)" ]
  [ ! -e "$RACINE/runtime/services/forge-recipe/roles.auto.tfvars.json" ]
  [[ "$output" == *"POSÉ  61-forge-structure: structure de la forge posée — 63-forge-tokens peut minter les jetons de rôle"* ]]
}

@test "apply : le roster est dérivé de la release par enroll-catalogue.sh appelé nu — le mode outil est l'affaire du délégué" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "ENROLL --tofu-dir $TMPDIR/prov-enroll\.[^ ]* --release $PREFIX/rel/lcars_fleet/bin/lcars_fleet TOOL_EVAL=" "$CALLS"
}

@test "apply : une forge fournie est celle que le geste structure, son adresse sans barre finale" {
  FORGE_BASE_URL="$FORGE_DOUBLE_URL/" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "FORGE_BASE_URL=$FORGE_DOUBLE_URL" "$GESTE_ENV"
}

@test "apply : une recette qui n'a rien bougé, ou qui n'a fait qu'importer, est conforme" {
  local geste
  for geste in rien importe; do
    STUB_GESTE="$geste" mod apply
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"OK    61-forge-structure: structure de la forge déjà conforme — rien à poser"* ]] || { echo "$geste : $output"; return 1; }
    [[ "$output" != *"POSÉ  61-forge-structure: structure"* ]]
  done
}

@test "apply : l'état tofu survit à la copie jetable — gardé en 0600 dans le dossier d'état, repris par la passe suivante, gardé aussi après un échec" {
  local etats="$LCARS_DECOR_ROOT/opt/lcars/tofu/forge-state"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$etats")" = 700 ]
  [ "$(cat "$etats/instance.tfstate")" = etat-de-instance-pose ]
  [ "$(cat "$etats/structure.tfstate")" = etat-de-.-pose ]
  [ "$(stat -c %a "$etats/structure.tfstate")" = 600 ]
  refute grep -q '^ETAT REPRIS' "$CALLS"
  STUB_GESTE=echec mod apply
  [ "$status" -eq 1 ]
  grep -qx 'ETAT REPRIS instance etat-de-instance-pose' "$CALLS"
  grep -qx 'ETAT REPRIS \. etat-de-\.-pose' "$CALLS"
  [ "$(cat "$etats/structure.tfstate")" = etat-de-.-echec ]
}

@test "apply : un geste en échec est un échec qui montre sa sortie, les copies partent" {
  STUB_GESTE=echec mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: structure non posée (rc=1)"*"401 Unauthorized"* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 \( -name 'prov-enroll.*' -o -name 'prov-recipe.*' \))" ]
}

@test "apply : un roster vide est refusé, le geste n'est pas joué" {
  STUB_ROSTER=vide mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: roster vide — la recette serait appliquée sans comptes"* ]]
  refute grep -q '^GESTE' "$CALLS"
  [ -z "$(copies_restantes)" ]
}

@test "apply : une recette non initialisable hors-ligne est un échec qui montre la sortie du geste, les copies partent" {
  STUB_INIT_KO=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: structure non posée (rc=1)"*"provider introuvable dans le miroir"* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 \( -name 'prov-enroll.*' -o -name 'prov-recipe.*' \))" ]
}

@test "apply : une ligne sur l'entrée du module n'atteint pas le geste, qui la prendrait pour le jeton master" {
  run bash "$MOD" apply <<<"ligne-tapee"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'stdin: \[\]' "$GESTE_ENV"
}
