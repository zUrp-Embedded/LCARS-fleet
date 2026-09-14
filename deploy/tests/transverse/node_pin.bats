#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/node_pin.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for 16-node — TROIS producteurs de la meme doc, et rien ne les confrontait

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui doivent
# atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell.
# shellcheck disable=SC2016

setup() {
  MOD="$BATS_TEST_DIRNAME/../../modules.d/16-node.sh"
  SITE_WF="$BATS_TEST_DIRNAME/../../../.github/workflows/site.yml"
  [ -f "$MOD" ]
  [ -f "$SITE_WF" ]
}

# La majeure de chacun des trois. Chaque extraction est nommee : une seule qui rate rendrait une
# chaine VIDE, et deux vides sont EGAUX — un mur vert sur n'importe quelle derive.
maj_module()   { sed -n 's/^NODE_VERSION=\([0-9]\+\)\..*/\1/p' "$MOD"; }
maj_workflow() { sed -n 's/^ *node-version: *\([0-9]\+\) *$/\1/p' "$SITE_WF"; }

@test "les deux producteurs de la doc sont sur la MEME majeure de node — le poste (16) et le site en ligne" {
  # Le stage « site » de l'image est parti avec le jumeau Dockerfile (2026-09-11) : la doc de l'image
  # est celle du kit, batie par pack.sh sur le poste — donc par 16-node. Il reste deux producteurs.
  local m w
  m="$(maj_module)"; w="$(maj_workflow)"

  [ -n "$m" ] || { echo "extraction ratee : NODE_VERSION dans $MOD"; return 1; }
  [ -n "$w" ] || { echo "extraction ratee : node-version dans $SITE_WF"; return 1; }

  [ "$m" = "$w" ] || { echo "majeure node : module $m, workflow GitHub $w — la doc en ligne ne serait pas celle du deck"; return 1; }
}

@test "le pin du poste est un patch EXACT — un sha256 ne verifie pas une balise mouvante" {
  local v
  v="$(sed -n 's/^NODE_VERSION=\([0-9.]\+\)$/\1/p' "$MOD")"
  [ -n "$v" ] || { echo "extraction ratee : NODE_VERSION dans $MOD"; return 1; }
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "NODE_VERSION « $v » n'est pas un patch complet — l'URL du tarball ne se composerait pas"; return 1; }
}

@test "les deux sha256 sont poses, distincts, et de la bonne longueur" {
  local x a
  x="$(sed -n 's/^NODE_SHA256_X64=\([0-9a-f]*\)$/\1/p' "$MOD")"
  a="$(sed -n 's/^NODE_SHA256_ARM64=\([0-9a-f]*\)$/\1/p' "$MOD")"
  [ "${#x}" -eq 64 ] || { echo "NODE_SHA256_X64 : $((${#x})) caracteres, attendu 64"; return 1; }
  [ "${#a}" -eq 64 ] || { echo "NODE_SHA256_ARM64 : $((${#a})) caracteres, attendu 64"; return 1; }
  [ "$x" != "$a" ] || { echo "les deux arch portent le MEME sha256 — une des deux lignes n'a pas ete bumpee"; return 1; }
}

@test "le module ne demande PAS node a apt — la mesure des 459 paquets tient toujours" {
  grep -q 'fetch_verify' "$MOD" \
    || { echo "ce temoin ne lit pas 16-node, ou le module ne recupere plus le tarball officiel"; return 1; }
  ! grep -qE 'apt_ensure[^#]*\b(nodejs|npm)\b' "$MOD" \
    || { echo "$MOD demande node a apt : 459 paquets, cf. la mesure en tete du module"; return 1; }
}
