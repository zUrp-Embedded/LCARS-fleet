#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/enroll_catalogue.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for etc/enroll-catalogue.sh — la derivation du roster ne demande pas de
#         toolchain a la machine qui l'appelle
#
# CE QUE CES TEMOINS TIENNENT, ET CE QU'ILS ONT COUTE. `enroll-catalogue.sh` a deux chemins de
# lecture pour la MEME autorite (`CatalogueRoles`) : `--repo`, qui compile l'arbre source avec
# `mix`, et `--image`, qui joue la porte du release livre. Le banc prenait le premier.
#
# Mesure du 2026-08-18, machine Debian neuve, chemin de livraison exact du README : `mix: ABSENT`,
# rc 2, « le depot ne compile pas », amorcage forge mort en passe 1. Le README de la beta promet
# en toutes lettres « No Elixir, no Erlang, no toolchain on your machine » — la promesse etait
# fausse, et c'est la premiere machine autre que celle de dev qui l'a dit.
#
# Ce fichier n'ouvre aucune socket : `docker` est une doublure posee en tete de PATH, et ce qui est
# mesure est l'ARGV qu'on lui passe — c'est-a-dire la decision du script.

load ../refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../fleet/etc/enroll-catalogue.sh"
  [ -x "$SUT" ]
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/tofu"
  mkdir -p "$BIN" "$OUT"
  export PATH="$BIN:$PATH"
  export DOCKER_BIN="$BIN/docker"

  # La doublure trace son argv et rend un roster valide. `system_*` y est, parce que la ligne
  # PROV_ROLES doit les remettre devant les roles metier.
  cat > "$BIN/docker" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/argv"
cat <<'JSON'
{"org":"fleet","roles":["fleet_dev"],"system_roles":["system_architect"],
 "writers":["fleet_dev"],"judges":[],"externals":[]}
JSON
SH
  chmod +x "$BIN/docker"
}

@test "--image SANS --catalogue : l'image lit le SIEN, aucun chemin d'hote ne transite" {
  # LE POINT. Un chemin d'hote passe a un conteneur designe un chemin que le conteneur n'a pas, et
  # le monter ne suffit pas toujours : la porte de l'image tourne en `nobody`, et un `/home/<user>`
  # en 0700 lui reste ferme. Une image PORTE son catalogue — c'est la seule lecture qui ne depende
  # ni d'un chemin, ni d'un montage, ni de droits.
  run "$SUT" --tofu-dir "$OUT" --image lcars-fleet:2
  [ "$status" -eq 0 ]
  [[ "$output" == *'PROV_ROLES="system_architect fleet_dev"'* ]]
  [[ "$output" == *'PROV_FORGE_ORG="fleet"'* ]]
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

# ─── le banc ne redemande PAS de toolchain a la machine ──────────────────────────────────────────

@test "bench-forge-bootstrap derive le roster par l'IMAGE, jamais par --repo" {
  # TEMOIN STRUCTUREL, et il garde la regression exacte qui a tue le premier deploiement ailleurs :
  # « simplifier » ce site en revenant a `--repo` remet un `mix` sur le chemin de livraison, et ca
  # ne se voit sur aucune machine de dev.
  SRC="$BATS_TEST_DIRNAME/../../docker/bench/bench-forge-bootstrap.sh"
  [ -f "$SRC" ]
  grep -q -- "--image \"\$BOX_IMAGE\"" "$SRC"
  refute grep -q -- "--repo \"\$REPO_ROOT/fleet\"" "$SRC"
  # ET SANS `--catalogue` : nommer l'arbre de l'hote le fait monter dans le conteneur, ou la porte
  # tourne en `nobody`. Ca passe la ou le clone est world-readable et ca echoue ailleurs — une
  # dependance a la permission d'un parent, invisible sur la machine qui l'a ecrite.
  refute grep -q -- "--catalogue \"\$REPO_ROOT" "$SRC"
}
