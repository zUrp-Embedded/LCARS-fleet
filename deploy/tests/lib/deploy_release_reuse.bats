#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/deploy_release_reuse.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: bats tests for deploy/lib/deploy-release.sh — une release n'est reutilisee que si elle ATTESTE la source
#
# ⚠ CE QUE CE FICHIER GARDE, ET POURQUOI SON ABSENCE COUTAIT CHER. `build_release` sautait le gate
# ET la compilation sur une seule condition : « un binaire existe sous `_build/prod/rel` ». Le
# commentaire justifiait ca par « c'est un paquet, pas un checkout » — une DEDUCTION, fausse des que
# le script tourne depuis un clone, ce qui est le chemin nominal du rail poste.
#
# ET LE GARDE D'EN FACE ETAIT DEFAIT EXACTEMENT QUAND IL SERVAIT : `60-deploy` verifie sha + arbre
# propre + release presente ; quand l'une manque il conclut « il faut batir » et delegue a
# `install.sh`, qui reutilisait le vieux build. Le rail annonçait un deploiement du HEAD apres avoir
# pose autre chose — un mensonge operationnel, pas une lenteur.
#
# ⚠ ON EXERCE LA FONCTION, PAS LE SCRIPT. `install.sh` porte une frontiere de sourcing
# (`BASH_SOURCE[0] != $0` -> `return 0`) et `build_release` vit AU-DESSUS : un temoin peut donc
# l'appeler seule, sans jouer la pose. Le chemin de REBUILD est reconnu a son message, pas a un
# `mix` reellement lance — on n'a pas de toolchain ici, et un temoin qui compile ne mesure plus rien.

setup() {
  SUT="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  [ -f "$SUT" ]
  RT="$BATS_TEST_TMPDIR/repo/fleet"          # `runtime_dir` = le fleet/ d'un arbre
  REL="$RT/_build/prod/rel/lcars_fleet"
  mkdir -p "$REL/bin" "$REL/lib/lcars_fleet-1.0.0/priv/api"
  printf '#!/bin/sh\nexit 0\n' > "$REL/bin/lcars_fleet"; chmod +x "$REL/bin/lcars_fleet"
}

# La release atteste <sha>.
atteste() { printf 'sha=%s\n' "$1" > "$REL/lib/lcars_fleet-1.0.0/priv/api/build_info.txt"; }

# Un depot git minimal dont le HEAD est connu ; rend le sha court.
depot() {
  git -C "$RT" init -q 2>/dev/null
  git -C "$RT" config user.email t@t; git -C "$RT" config user.name t
  echo x > "$RT/mix.exs"; git -C "$RT" add -A >/dev/null
  git -C "$RT" -c commit.gpgsign=false commit -qm x >/dev/null
  git -C "$RT" rev-parse --short HEAD
}

appel() { run bash -c ". '$SUT' >/dev/null 2>&1; build_release '$RT' 2>&1"; }

@test "GARDE D'INSTRUMENT : build_release est ATTEIGNABLE par sourcing" {
  # Sans ce garde, la fonction posee sous la frontiere de sourcing rendrait « command not found »
  # et les temoins ci-dessous accuseraient le test au lieu du produit.
  run bash -c ". '$SUT' >/dev/null 2>&1; declare -F build_release"
  [ "$status" -eq 0 ]
}

@test "PAQUET : le marqueur .source-revision DIT paquet — reutilisation sans gate" {
  # C'est le cas nominal d'une install depuis un tar : `pack.sh` a joue le gate et le build a cote
  # du marqueur qu'il vient d'ecrire. Rien a recompiler, et surtout rien a deduire.
  printf 'abcd1234\n' > "$RT/../.source-revision"
  appel
  [ "$status" -eq 0 ]
  [[ "$output" == *"paquet"* ]]
}

@test "CLONE PROPRE, sha qui CORRESPOND : reutilisation, et elle est dite ATTESTEE" {
  local sha; sha="$(depot)"; atteste "$sha"
  appel
  [ "$status" -eq 0 ]
  [[ "$output" == *"ATTESTEE"* ]]
}

@test "LE DEFAUT : un vieux _build dans un clone ne se reutilise PAS" {
  # LE TEMOIN QUI COMPTE. Avant, cette situation sautait le gate et la compilation, et posait un
  # binaire vieux de trois semaines en annonçant le HEAD.
  depot > /dev/null; atteste "deadbeef"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
  [[ "$output" != *"ni gate ni compilation"* ]]
}

@test "CLONE SALE : le sha correspond mais l'arbre est modifie — pas de reutilisation" {
  # Le sha seul ne suffit pas : un fichier modifie apres le build rend la release fausse sans
  # changer le HEAD. C'est la troisieme condition de `60-deploy`, et elle manquait ici.
  local sha; sha="$(depot)"; atteste "$sha"
  echo "modifie" >> "$RT/mix.exs"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
}

@test "NI MARQUEUR NI GIT : provenance inconnue — on rebatit" {
  # Le sens du doute va vers la recompilation : une release dont personne ne peut dire d'ou elle
  # vient ne se pose pas.
  atteste "abcd1234"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
}
