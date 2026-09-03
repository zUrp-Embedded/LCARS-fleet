#!/usr/bin/env bats
# SOURCE: deploy/tests/node_pin.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for 16-node — TROIS producteurs de la meme doc, et rien ne les confrontait
#
# ⚠ CE TEMOIN EST NE D'UN COMMENTAIRE QUI MENTAIT. `16-node.sh` portait « LA VERSION SUIT LES DEUX
# AUTRES BUILDS, ET UN TEMOIN L'EPINGLE » : le premier membre etait une intention, le second etait
# faux. Aucun fichier de ce depot ne comparait les trois. La phrase a survecu a un bump de majeure
# (20 -> 24) qu'elle n'a pas aide a faire, et elle aurait survecu a une divergence.
#
# LES TROIS PRODUCTEURS DE `/doc/`, ET CE QUE CHACUN SERT :
#   `modules.d/16-node.sh`       le poste — tarball officiel pinne version+sha256
#   `docker/Dockerfile`          l'image — stage `site`, `FROM node:<majeure>-slim`
#   `.github/workflows/site.yml` GitHub Pages — `node-version: <majeure>`
#
# CE QUI EST COMPARE EST LA MAJEURE, ET RIEN DE PLUS. Le poste epingle un patch exact parce qu'il
# verifie un sha256 ; les deux autres suivent une balise mouvante, par construction. Exiger l'egalite
# des trois patchs rendrait ce mur rouge chaque fois que Docker Hub republie `node:24-slim` — un
# temoin qui rougit sans qu'aucun humain n'ait rien change finit par etre desarme, et c'est ce
# desarmement qui coute, pas la divergence de patch qu'il pretendait attraper.
#
# ⚠ CE QUE CE MUR NE PEUT PAS VOIR, ET IL FAUT LE DIRE : que la doc BATIE par les trois soit la
# meme. Il compare des declarations, pas des artefacts. Seul un build la mesure.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui doivent
# atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell.
# shellcheck disable=SC2016

setup() {
  MOD="$BATS_TEST_DIRNAME/../../modules.d/16-node.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  SITE_WF="$BATS_TEST_DIRNAME/../../../.github/workflows/site.yml"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ] && [ -f "$SITE_WF" ]
}

# La majeure de chacun des trois. Chaque extraction est nommee : une seule qui rate rendrait une
# chaine VIDE, et deux vides sont EGAUX — un mur vert sur n'importe quelle derive.
maj_module()   { sed -n 's/^NODE_VERSION="${LCARS_NODE_VERSION:-\([0-9]\+\)\..*/\1/p' "$MOD"; }
# ⚠ L'EXTRACTION TOLERE LE DIGEST, ET C'EST LE POINT. La ligne est passee de `FROM node:24-slim AS
# site` a `FROM node:24-slim@sha256:… AS site` : un motif qui exigeait `-slim AS site` colles rendait
# la chaine VIDE, et deux extractions vides sont EGALES — le mur serait devenu vert a vide au moment
# meme ou on l'epinglait. La garde d'instrument du test l'aurait attrape ; le motif est corrige pour
# qu'elle n'ait pas a le faire.
maj_image()    { sed -n 's/^FROM node:\([0-9]\+\)-slim[^ ]* AS site.*/\1/p' "$DOCKERFILE"; }
maj_workflow() { sed -n 's/^ *node-version: *\([0-9]\+\) *$/\1/p' "$SITE_WF"; }

@test "les trois producteurs de la doc sont sur la MEME majeure de node" {
  local m i w
  m="$(maj_module)"; i="$(maj_image)"; w="$(maj_workflow)"

  [ -n "$m" ] || { echo "extraction ratee : NODE_VERSION dans $MOD"; return 1; }
  [ -n "$i" ] || { echo "extraction ratee : FROM node:<maj>-slim AS site dans $DOCKERFILE"; return 1; }
  [ -n "$w" ] || { echo "extraction ratee : node-version dans $SITE_WF"; return 1; }

  [ "$m" = "$i" ] || { echo "majeure node : module $m, image $i — deux resolveurs de modules pour une meme doc"; return 1; }
  [ "$m" = "$w" ] || { echo "majeure node : module $m, workflow GitHub $w — la doc en ligne ne serait pas celle du deck"; return 1; }
}

@test "le pin du poste est un patch EXACT — un sha256 ne verifie pas une balise mouvante" {
  # `fetch_verify` compare un sha256 : il exige une URL stable, donc une version complete. Une
  # valeur tronquee (`24`, `24.20`) fabriquerait une URL qui n'existe pas, et l'echec parlerait de
  # reseau au lieu de parler du pin.
  local v
  v="$(sed -n 's/^NODE_VERSION="${LCARS_NODE_VERSION:-\([0-9.]\+\)}".*/\1/p' "$MOD")"
  [ -n "$v" ] || { echo "extraction ratee : NODE_VERSION dans $MOD"; return 1; }
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "NODE_VERSION « $v » n'est pas un patch complet — l'URL du tarball ne se composerait pas"; return 1; }
}

@test "les deux sha256 sont poses, distincts, et de la bonne longueur" {
  # ⚠ DEUX ARCHS, DEUX SOMMES — ET LES CONFONDRE EST UN COPIER-COLLER QUI PASSE INAPERCU. Un bump
  # qui ne remplace qu'une des deux lignes livre une arch dont la verification echouera au premier
  # poste arm64, c'est-a-dire nulle part ou on la testera.
  local x a
  x="$(sed -n 's/^NODE_SHA256_X64=\([0-9a-f]*\)$/\1/p' "$MOD")"
  a="$(sed -n 's/^NODE_SHA256_ARM64=\([0-9a-f]*\)$/\1/p' "$MOD")"
  [ "${#x}" -eq 64 ] || { echo "NODE_SHA256_X64 : $((${#x})) caracteres, attendu 64"; return 1; }
  [ "${#a}" -eq 64 ] || { echo "NODE_SHA256_ARM64 : $((${#a})) caracteres, attendu 64"; return 1; }
  [ "$x" != "$a" ] || { echo "les deux arch portent le MEME sha256 — une des deux lignes n'a pas ete bumpee"; return 1; }
}

@test "le module ne demande PAS node a apt — la mesure des 459 paquets tient toujours" {
  # `16-node` porte sa propre mesure : `nodejs npm` tire 459 paquets sur une 26.04 vierge, `nodejs`
  # seul en tire 21 mais n'a pas npm, donc ne batit rien. C'est ce qui distingue node d'Elixir, dont
  # le pin est tombe au profit de l'apt. Un cliquet, parce que la symetrie est trompeuse.
  grep -q 'fetch_verify' "$MOD" \
    || { echo "ce temoin ne lit pas 16-node, ou le module ne recupere plus le tarball officiel"; return 1; }
  ! grep -qE 'apt_ensure[^#]*\b(nodejs|npm)\b' "$MOD" \
    || { echo "$MOD demande node a apt : 459 paquets, cf. la mesure en tete du module"; return 1; }
}
