#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/enroll-catalogue.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-18
# STATUS: bats tests for deploy/lib/enroll-catalogue.sh — la dérivation du roster, jouée contre une image doublée

load ../refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../lib/enroll-catalogue.sh"
  [ -x "$SUT" ]
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/tofu"
  mkdir -p "$BIN" "$OUT"
  export PATH="$BIN:$PATH"
  export DOCKER_BIN="$BIN/docker"
  export ROSTER="$BATS_TEST_TMPDIR/roster.json"

  # `system_*` est dans le roster : la ligne des rôles les remet devant les rôles métier
  cat > "$ROSTER" <<'JSON'
{"org":"fleet","roles":["fleet_dev"],"system_roles":["system_architect"],
 "writers":["fleet_dev"],"judges":[],"externals":[]}
JSON
  cat > "$BIN/docker" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/argv"
cat "\$ROSTER"
SH
  chmod +x "$BIN/docker"
}

@test "--image SANS --catalogue : l'image lit le SIEN, aucun chemin d'hote ne transite" {
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 0 ]
  [[ "$output" == *"rôles     : system_architect fleet_dev"* ]]
  [[ "$output" == *"org       : fleet"* ]]
  [ -f "$OUT/roles.auto.tfvars.json" ]

  # Ni `-v`, ni argument de racine : la commande est nue.
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == "run --rm lcars-fleet:2 roles-tfvars" ]]
}

@test "--image AVEC --catalogue : l'arbre de l'hote est monte a la MEME place, en lecture seule" {
  # Le cas de l'operateur qui APPORTE son catalogue. Le chemin doit etre identique des deux cotes,
  # sinon la porte lit le cwd du conteneur.
  CAT="$BATS_TEST_TMPDIR/mon-catalogue"
  mkdir -p "$CAT"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2 --catalogue "$CAT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == *"-v $CAT:$CAT:ro"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == *"roles-tfvars $CAT"* ]]
}

@test "un --catalogue RELATIF est absolutise avant de traverser la frontiere" {
  # Un chemin relatif monte « quelque part » et se lit ailleurs : les deux cotes du `-v` doivent
  # etre absolus, et l'argument passe a la porte aussi.
  mkdir -p "$BATS_TEST_TMPDIR/rel/cat"
  cd "$BATS_TEST_TMPDIR/rel"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2 --catalogue cat
  [ "$status" -eq 0 ]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" != *" cat "* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/argv")" == *"-v $BATS_TEST_TMPDIR/rel/cat:"* ]]
}

@test "--repo sans mix.exs REFUSE et nomme la sortie — jamais un roster devine" {
  # `--repo` exige un toolchain sur la machine appelante. Le refus doit nommer `--image`, sinon il
  # envoie l'operateur installer Elixir pour une raison qui n'existe pas.
  mkdir -p "$BATS_TEST_TMPDIR/pas-un-depot"
  run "$SUT" --tofu-dir "$OUT" --catalogue "$BATS_TEST_TMPDIR" --repo "$BATS_TEST_TMPDIR/pas-un-depot"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--image"* ]]
  [ ! -f "$OUT/roles.auto.tfvars.json" ]
}

@test "sans --catalogue NI --image, le refus dit que l'image porte le sien" {
  run "$SUT" --tofu-dir "$OUT" --repo "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--catalogue"* ]]
}

@test "--served est un argument inconnu, et rien n'est écrit" {
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2 --served "fleet_old"
  [ "$status" -eq 1 ]
  [[ "$output" == *"argument inconnu: --served"* ]]
  [ ! -f "$OUT/roles.auto.tfvars.json" ]
}

@test "la ligne des rôles met les rôles système devant, sans doublon, et l'org suit" {
  printf '%s\n' '{"org":"escadre","roles":["fleet_dev","system_architect","fleet_scribe"],"system_roles":["system_architect","system_chief"]}' > "$ROSTER"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 0 ]
  [ "${lines[-2]}" = '[enroll-catalogue] rôles     : system_architect system_chief fleet_dev fleet_scribe' ]
  [ "${lines[-1]}" = '[enroll-catalogue] org       : escadre' ]
}

@test "un roster sans org est écrit et rend 0 : la recette porte l'org par défaut" {
  printf '%s\n' '{"roles":["fleet_dev"]}' > "$ROSTER"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = '[enroll-catalogue] org       : <non déclarée>' ]
  [ -f "$OUT/roles.auto.tfvars.json" ]
}

@test "un roster sans rôle rend 2 sans rien écrire, et nomme le catalogue lu" {
  printf '%s\n' '{"org":"fleet","roles":[],"system_roles":["system_architect"]}' > "$ROSTER"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 2 ]
  [[ "$output" == *"roster illisible ou sans rôle pour son catalogue livré" ]]
  [ ! -e "$OUT/roles.auto.tfvars.json" ]
}

@test "un roster illisible rend 2 sans rien écrire" {
  printf 'pas du json\n' > "$ROSTER"
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 2 ]
  [[ "$output" == *"roster illisible ou sans rôle"* ]]
  [ ! -e "$OUT/roles.auto.tfvars.json" ]
}

@test "sans jq sur la machine : refus en 1 qui le nomme, avant de demander le roster à l'image" {
  local sans="$BATS_TEST_TMPDIR/sans-jq" t
  mkdir -p "$sans"
  for t in bash dirname mv cat; do ln -s "$(command -v "$t")" "$sans/$t"; done
  run env PATH="$sans" "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq requis sur cette machine"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
  [ ! -e "$OUT/roles.auto.tfvars.json" ]
}

@test "le roster se lit sans python3 : un PATH qui ne le porte pas rend la ligne des rôles" {
  local sans="$BATS_TEST_TMPDIR/sans-python" t
  mkdir -p "$sans"
  for t in bash dirname mv jq cat; do ln -s "$(command -v "$t")" "$sans/$t"; done
  run env PATH="$sans" "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 0 ]
  [[ "$output" == *"rôles     : system_architect fleet_dev"* ]]
  [ -f "$OUT/roles.auto.tfvars.json" ]
}
