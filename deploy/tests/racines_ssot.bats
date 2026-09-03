#!/usr/bin/env bats
# SOURCE: deploy/tests/racines_ssot.bats
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
  # ⚠ `/home/private` EST UNE RACINE MORTE, ET ELLE RESTE DANS LA LISTE. Les jetons sont descendus
  # sous `/opt/lcars/var/tokens` ; plus une ligne du rail ne la nomme. La garder ici ne garde donc
  # plus un accord — ca interdit son RETOUR, ce qui est le seul service qu'une racine fermee peut
  # encore rendre. L'accord des huit defauts qui nomment la nouvelle, lui, est tenu par
  # `racine_jetons.bats` : un mur par propriete, jamais un mur qui fait les deux a moitie.
  # ⚠ `/home/catalogues` EST LA DEUXIEME RACINE MORTE, meme statut que `/home/private` : le cache des
  # catalogues est passe sous `/opt/lcars/var/catalogues` le 2026-09-01, quand `/home` est sorti du
  # perimetre d'uninstall. Elle reste ici pour interdire son RETOUR. Un seul site la nomme encore, et
  # par un repli nomme (`45-catalogues.sh`, le reliquat qu'on signale sans pouvoir le retirer) : la
  # forme `${VAR:-defaut}` est une couture, que `code_seul` exempte deja.
  RACINES='/opt/lcars/runtime|/home/private|/var/lib/lcars|/usr/share/lcars|/etc/lcars|/home/catalogues|/opt/lcars/var/catalogues'
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

# ─── AUCUN CONSOMMATEUR NE MASQUE UN DEFAUT DE LA LIB AVANT DE LA SOURCER ────────────────────────
#
# ⚠ LE DEFAUT QUE CE MUR FERME A TOURNE EN SILENCE. `deploy/provision` posait `PROV_ROOT` en tete
# — l'arbre `deploy/` de ce script — puis sourçait la lib, dont `PROV_ROOT` designe la RACINE
# D'INSTALL. Le `:=` de la lib ne tire pas sur une variable deja posee : le runner resolvait donc
# `PROV_PREFIX`, `PROV_TOKENS_DIR` et `PROV_CATALOGUES_WORK` sous son propre repertoire.
#
# CE QUE CA COUTAIT : le plan d'`uninstall` ne nommait pas les vrais chemins, l'`audit` mesurait a
# cote, et le JOURNAL enregistrait « prefix <depot>/deploy/runtime » — il mentait sur ce qui
# venait d'etre installe. Les MODULES, eux, posaient au bon endroit : ce sont des processus separes
# et la variable n'etait pas exportee. Seul le runner divergeait, ce qui est le pire des deux
# mondes — la machine juste, sa trace fausse.
#
# ⚠ AVANT LE `source`, ET PAS APRES : le runner exporte deliberement `PROV_SUBSTRATE` APRES, pour
# le propager aux modules. Une surcharge voulue et une collision de nom ont la meme forme ; seule
# leur POSITION les distingue. Un mur qui interdirait les deux serait faux.

consommateurs() { printf '%s\n' "$DEPLOY/provision" "$DEPLOY"/modules.d/*.sh; }

# Les noms que la lib DECLARE avec un defaut.
noms_lib() { sed -n 's/^: "${\([A-Z_][A-Z0-9_]*\):[=-].*/\1/p' "$DEPLOY/lib/provision-lib.sh" | sort -u; }

@test "GARDE D'INSTRUMENT : la lib declare des defauts, et des fichiers la sourcent" {
  [ "$(noms_lib | wc -l)" -ge 20 ]
  [ "$(consommateurs | wc -l)" -ge 10 ]
}

@test "RACINE : nul ne pose un nom de la lib AVANT de la sourcer" {
  local f n src bad=()
  while read -r f; do
    [[ -f "$f" ]] || continue
    # La ligne qui source la lib. Sans elle, le fichier n'est pas un consommateur : rien a verifier.
    src="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*(PROVISION_LIB|provision-lib\.sh)' "$f" \
           | head -1 | cut -d: -f1)"
    [[ -n "$src" ]] || continue
    while read -r n; do
      [[ -n "$n" ]] || continue
      awk -v n="$n" -v lim="$src" 'NR<lim && $0 ~ "^(export[ \t]+)?" n "=" { print NR; exit }' "$f" \
        | while read -r l; do echo "${f##*/}:$l: $n"; done
    done < <(noms_lib)
  done < <(consommateurs) > "$BATS_TEST_TMPDIR/hits"
  mapfile -t bad < "$BATS_TEST_TMPDIR/hits"
  [ "${#bad[@]}" -eq 0 ] || {
    echo "MASQUAGE — ces noms sont poses AVANT le source, donc le defaut de la lib ne tire pas :" >&2
    printf '  %s\n' "${bad[@]}" >&2
    echo "  renomme la variable locale : le nom appartient au contrat de la lib." >&2
    return 1
  }
}
