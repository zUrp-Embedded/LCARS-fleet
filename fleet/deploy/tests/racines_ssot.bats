#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/racines_ssot.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: bats tests — une racine se DEMANDE, elle ne se recopie pas
#
# POURQUOI CE FICHIER, ET POURQUOI MAINTENANT. Le lot va deplacer l'arbre sous un prefixe unique.
# Sans ce mur, ce deplacement est un `sed` qu'on rejouera : les coutures existent deja
# (`PROV_PREFIX`, `PROV_TOKENS_DIR`, `MEDIA_ROOT`, `HELPERS_DIR`…), et ce qui les contourne est ce
# qui casse au deplacement suivant. Mesure du 2026-08-28 sur le rail : SEPT litteraux, dont cinq
# dans des MESSAGES et deux dans du code.
#
# ⚠ LA PROPRIETE N'EST PAS « AUCUN LITTERAL », ET C'EST TOUT L'INTERET DE CE FICHIER.
#
# Un message qui NOMME un chemin a l'operateur fait son metier : « il ne lira ni /home/private ni
# … » est precisement ce qu'on veut lire quand ca casse. Une prose qui cite la racine pour
# l'expliquer aussi. Ce qui est interdit est qu'un chemin soit DECIDE ailleurs que dans sa source :
# une AFFECTATION ou un TEST qui porte la racine en dur cree un second decideur, et celui qui derive
# est toujours celui qu'on ne relit pas.
#
# Un temoin qui interdirait le litteral partout interdirait d'expliquer — c'est le piege que ce lot
# a rencontre deux fois (l'anti-litteral de `box`, le refute anti-`docker volume rm`), et il est
# ecrit ici pour qu'on ne le refasse pas une troisieme.

# ⚠ SC2016 : ce temoin LIT DU CODE, ses motifs doivent atteindre `grep` tels quels.
# shellcheck disable=SC2016

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  RACINES='/local/LCARS_v2|/home/private|/var/lib/lcars|/usr/share/lcars|/etc/lcars|/home/catalogues'
  # ⚠ `/opt/lcars` N'EST PAS DANS LA LISTE, ET C'EST DELIBERE : c'est la racine de l'IMAGE, que le
  # Dockerfile pose litteralement (`COPY fleet/services/X /opt/lcars/X`). Un `COPY` derive serait un
  # Dockerfile qui ne se lit plus. Elle entrera ici le jour ou la phase B en fait un prefixe unique.
}

# Le perimetre : ce qui DECIDE. Le Dockerfile et l'entrypoint portent le layout de l'image.
sources() { printf '%s\n' "$DEPLOY"/modules.d/*.sh "$DEPLOY"/lib/*.sh "$DEPLOY"/provision "$DEPLOY"/box; }

# Une ligne de CODE QUI DECIDE : ni commentaire, ni message, ni la DECLARATION elle-meme.
#
# ⚠ LA FORME `: "${VAR:=defaut}"` EST LA SOURCE, PAS UNE COPIE — c'est l'endroit qui a le DROIT de
# nommer la racine, et il faut bien qu'un endroit le fasse. La premiere version de ce mur l'attrapait
# et accusait `provision-lib.sh` d'avoir recopie ce qu'il DEFINIT. Un mur qui refuse a la source
# d'etre la source n'a plus de source du tout.
# Meme raison pour `${VAR:-defaut}` : un repli nomme est une couture, pas un contournement.
code_seul() {
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
    | grep -vE ':=|:-' \
    | grep -vE '(^|[[:space:]])(echo|printf|say|p_ok|p_chg|p_warn|p_drift|p_fail|p_step|p_die|die)([[:space:]]|$)'
}

@test "GARDE D'INSTRUMENT : les sources existent et sont nombreuses" {
  # Sans ce garde, un glob casse rendrait zero fichier, donc VERT en n'ayant rien lu — la forme
  # d'echec la plus chere, celle qui certifie.
  [ "$(sources | wc -l)" -ge 25 ]
  local f; while read -r f; do [ -f "$f" ]; done < <(sources)
}

@test "AUCUNE racine n'est AFFECTEE en dur — elle se demande a sa couture" {
  local f bad=0 hit
  while read -r f; do
    hit="$(code_seul "$f" | grep -nE "^[^=]*=[\"']?($RACINES)" || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine AFFECTEE en dur"; echo "$hit"; bad=1; }
  done < <(sources)
  [ "$bad" -eq 0 ]
}

@test "AUCUNE racine n'est TESTEE en dur — un test qui la connait la decide" {
  # `[[ -d /home/private ]]` fige la racine aussi surement qu'une affectation : le jour ou elle
  # bouge, le test rend faux et la branche saute, en silence.
  local f bad=0 hit
  while read -r f; do
    hit="$(code_seul "$f" | grep -nE "\[\[? +-[a-z] +($RACINES)" || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine TESTEE en dur"; echo "$hit"; bad=1; }
  done < <(sources)
  [ "$bad" -eq 0 ]
}

# ─── LA RACINE UNIQUE ───────────────────────────────────────────────────────────────────────────
#
# `PROV_ROOT` est l'endroit — le seul — qui nomme la racine du produit. Ce que la phase B fait
# ensuite est de faire descendre les huit autres dessous ; ce que ce temoin empeche est qu'un
# SECOND endroit se remette a la nommer entre-temps, ce qui rendrait le deplacement suivant aussi
# cher que celui-ci.

@test "RACINE : \`PROV_ROOT\` est declaree UNE fois, dans la lib" {
  local lib="$DEPLOY/lib/provision-lib.sh"
  [ "$(grep -c '^: "\${PROV_ROOT:=' "$lib")" -eq 1 ]
}

@test "RACINE : aucun module ne redefinit \`/opt/lcars\` en dur — il derive" {
  # Trois modules portaient leur propre `${LCARS_…:-/opt/lcars}`. Trois defauts pour une racine, ce
  # sont trois endroits a corriger le jour ou elle bouge — et deux qu'on oubliera.
  local f bad=0 hit
  while read -r f; do
    hit="$(grep -vE '^[[:space:]]*#' "$f" | grep -nE '^[A-Z_]+="\$\{[A-Z_]+:-/opt/lcars' || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine du produit redefinie"; echo "$hit"; bad=1; }
  done < <(printf '%s\n' "$DEPLOY"/modules.d/*.sh)
  [ "$bad" -eq 0 ]
}

@test "un MESSAGE a le droit de nommer une racine — c'est son metier" {
  # Contre-temoin des deux precedents. Sans lui, quelqu'un « reparerait » le mur en interdisant le
  # litteral partout, et les messages cesseraient de dire OU ca casse.
  local n
  n="$(grep -rhE "(p_drift|p_fail|say|echo)[^|]*($RACINES)" "$DEPLOY"/modules.d/*.sh 2>/dev/null | grep -c . || true)"
  [ "$n" -ge 1 ]
}
