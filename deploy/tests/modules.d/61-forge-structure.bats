#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/61-forge-structure.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 61-forge-structure — les préconditions, le roster dérivé de la release, la recette jouée sur une copie, le verdict lu dans la sortie de tofu
#
# Le module se joue entier dans un dépôt de décor : la lib y est copiée (repo_root y mène),
# enroll-catalogue.sh et forge-gestures.sh sont des doublures qui notent ce qu'elles reçoivent,
# tofu et curl aussi.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/61-forge-structure.sh"; [ -f "$MOD" ]
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy/lib" "$RACINE/runtime/services/forge-recipe/instance"
  cp "$BATS_TEST_DIRNAME"/../../lib/*.sh "$RACINE/deploy/lib/"
  printf 'terraform {}\n' > "$RACINE/runtime/services/forge-recipe/versions.tf"
  printf 'terraform {}\n' > "$RACINE/runtime/services/forge-recipe/instance/versions.tf"
  mkdir -p "$RACINE/runtime/services/forge-recipe/.terraform"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=61-forge-structure PROV_SUBSTRATE=linux PROV_AUTHORITY_USER=root
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$PROV_TOKENS_DIR"
  export PROV_MASTER_TOKEN_FILE="$PROV_TOKENS_DIR/forge-master.token"; printf 'tok\n' > "$PROV_MASTER_TOKEN_FILE"
  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet/bin"; printf '#!/bin/sh\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"; chmod 0755 "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  export LCARS_TOFU_DIR="$BATS_TEST_TMPDIR/tofu"; mkdir -p "$LCARS_TOFU_DIR"; printf 'x\n' > "$LCARS_TOFU_DIR/tofurc"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export GESTE_ENV="$BATS_TEST_TMPDIR/geste.env"; : > "$GESTE_ENV"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN" "$BATS_TEST_TMPDIR/hors-path"; export PATH="$BIN:$PATH"
  # tofu vit hors du PATH (sous apt, DPkg::Path n'a pas /usr/local/bin) ; un tofu et un mix du PATH sont des pièges
  export LCARS_TOFU_BIN="$BATS_TEST_TMPDIR/hors-path/tofu"
  cat > "$LCARS_TOFU_BIN" <<'EOF'
#!/usr/bin/env bash
echo "TOFU $PWD $*" >> "$CALLS"
[[ -z "${STUB_INIT_KO:-}" ]] || { echo "init: provider introuvable dans le miroir" >&2; exit 1; }
EOF
  printf '#!/usr/bin/env bash\necho "PIEGE tofu du PATH $*" >> "$CALLS"; exit 127\n' > "$BIN/tofu"
  printf '#!/usr/bin/env bash\necho "PIEGE mix $*" >> "$CALLS"; exit 127\n' > "$BIN/mix"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_FORGE_UP:-1}" == 1 ]] && exit 0 || exit 7
EOF
  cat > "$RACINE/deploy/lib/enroll-catalogue.sh" <<'EOF'
#!/usr/bin/env bash
echo "ENROLL $* TOOL_EVAL=${LCARS_TOOL_EVAL:-}" >> "$CALLS"
while [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done
[[ "${STUB_ROSTER:-}" == vide ]] || printf '{"roles":{"admiral":{}}}\n' > "$dir/roles.auto.tfvars.json"
EOF
  cat > "$RACINE/runtime/services/forge-gestures.sh" <<'EOF'
#!/usr/bin/env bash
echo "GESTE $*" >> "$CALLS"
{ env | grep -E '^(FORGE_BASE_URL|LCARS_PRIVATE_DIR|LCARS_RECIPE_DIR|LCARS_DEMO_CATALOGUE|LCARS_AUTHORITY_USER|TF_CLI_CONFIG_FILE|LCARS_BUILTIN_HUMAN)=' | sort
  echo "recette: $(ls -A "$LCARS_RECIPE_DIR" | sort | tr '\n' ' ')"
  echo "instance: $(ls -A "$LCARS_RECIPE_DIR/instance" | sort | tr '\n' ' ')"
} > "$GESTE_ENV"
case "${STUB_GESTE:-pose}" in
  pose)   echo "Apply complete! Resources: 3 added, 0 changed, 0 destroyed." ;;
  rien)   echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed." ;;
  echec)  echo "Error: gitea_org.fleet: 401 Unauthorized" >&2; exit 1 ;;
esac
EOF
  chmod 0755 "$BIN"/* "$LCARS_TOFU_BIN" "$RACINE/deploy/lib/enroll-catalogue.sh" "$RACINE/runtime/services/forge-gestures.sh"
}

mod() { run bash "$MOD" "$@"; }
copies_restantes() { find "$TMPDIR" -mindepth 1 -maxdepth 1 \( -name 'prov-enroll.*' -o -name 'prov-recipe.*' -o -name 'prov-tofu.*' \); }

@test "check : forge muette — un drift qui renvoie à 48, rien d'autre n'est sondé" {
  STUB_FORGE_UP=0 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 61-forge-structure: forge muette (http://127.0.0.1:21000) — rien à structurer tant que 48-forge-host"* ]]
  [[ "$output" != *"release"* ]]
}

@test "check : forge vivante sans autorité, sans release, sans tofu — trois drifts qui nomment leur poseur" {
  rm -f "$PROV_MASTER_TOKEN_FILE" "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet" "$LCARS_TOFU_BIN"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune autorité de création ($PROV_MASTER_TOKEN_FILE) — 48-forge-host la minte"* ]]
  [[ "$output" == *"release absente ($PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet) — 60-deploy ne l'a pas posée"* ]]
  [[ "$output" == *"tofu absent ($LCARS_TOFU_BIN) — 46-tofu le pose"* ]]
}

@test "check : tout en place — conforme, et la structure elle-même est renvoyée à 63" {
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge vivante"*"autorité de création présente"*"release posée"*"tofu présent"*"sondée compte par compte par 63-forge-tokens"* ]]
}

@test "apply : forge muette — échec, aucun geste" {
  STUB_FORGE_UP=0 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: forge muette (http://127.0.0.1:21000)"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans autorité de création — échec qui nomme 48, aucun geste" {
  rm -f "$PROV_MASTER_TOKEN_FILE"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: aucune autorité de création"*"48-forge-host la minte"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans tofu — échec qui nomme 46, aucun geste" {
  rm -f "$LCARS_TOFU_BIN"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  61-forge-structure: tofu absent ($LCARS_TOFU_BIN) — 46-tofu le pose"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : sans release posée — échec qui nomme 60 et le chemin, aucun geste" {
  rm -f "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune release exécutable posée ($PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet) — 60-deploy n'a pas abouti"* ]]
  [ ! -s "$CALLS" ]
}

@test "apply : le roster est dérivé de la release sous l'humain en mode outil, déposé dans une copie de la recette initialisée hors-ligne, le geste reçoit la forge et l'autorité, les copies partent, la pose est comptée" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^ENROLL --tofu-dir $TMPDIR/prov-enroll\..* --release $PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet TOOL_EVAL=1$" "$CALLS"
  [ "$(grep -c "^TOFU $TMPDIR/prov-recipe\.[^/ ]* init -input=false -no-color$" "$CALLS")" -eq 1 ]
  [ "$(grep -c "^TOFU $TMPDIR/prov-recipe\.[^/]*/instance init -input=false -no-color$" "$CALLS")" -eq 1 ]
  grep -q '^GESTE apply$' "$CALLS"
  grep -q "^FORGE_BASE_URL=http://127.0.0.1:21000$" "$GESTE_ENV"
  grep -q "^LCARS_PRIVATE_DIR=$PROV_TOKENS_DIR$" "$GESTE_ENV"
  grep -q "^LCARS_RECIPE_DIR=$TMPDIR/prov-recipe\." "$GESTE_ENV"
  grep -q "^LCARS_DEMO_CATALOGUE=$RACINE/catalogues/web-demo$" "$GESTE_ENV"
  grep -q "^TF_CLI_CONFIG_FILE=$LCARS_TOFU_DIR/tofurc$" "$GESTE_ENV"
  grep -q '^recette: instance roles.auto.tfvars.json versions.tf $' "$GESTE_ENV"
  refute grep -q '^LCARS_BUILTIN_HUMAN=' "$GESTE_ENV"
  refute grep -q '^PIEGE' "$CALLS"
  [ -z "$(copies_restantes)" ]
  [ ! -e "$RACINE/runtime/services/forge-recipe/roles.auto.tfvars.json" ]
  [[ "$output" == *"POSÉ  61-forge-structure: structure de la forge posée — 63-forge-tokens peut minter les jetons de rôle"* ]]
}

@test "apply : une recette qui n'a rien bougé est conforme, rien n'est compté" {
  STUB_GESTE=rien mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    61-forge-structure: structure de la forge déjà conforme — rien à poser"* ]]
  [[ "$output" != *"POSÉ"* ]]
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

@test "apply : une recette non initialisable hors-ligne est un échec qui nomme 46-tofu, le geste n'est pas joué" {
  STUB_INIT_KO=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"recette non initialisable (instance) — le miroir de providers de 46-tofu"* ]]
  refute grep -q '^GESTE' "$CALLS"
  [ -z "$(copies_restantes)" ]
}
