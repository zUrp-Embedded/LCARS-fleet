#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/pack_secrets.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for pack.sh — ce que le packageur DIT d'un secret, jamais le secret
#
# CE QUE CE CORPUS FERME, ET IL EST NE D'UNE FUITE REELLE. Mesure du 2026-08-25, sortie de
# `./pack.sh` sur une machine sans remote http :
#
#     pack: forge ou jeton indeterminables — le tar est dans dist/, pousse-le a la main si tu veux
#     pack:   forge : <aucun remote origin http> · jeton : trouve9172f605fa091018d1857f1d776d5a39…
#
# Quarante caracteres de jeton de forge dans le terminal, dans le scrollback, et dans tout journal
# qui capture ce script. La ligne se voulait un ETAT (« trouve » / « absent ») et s'ecrivait
# `${TOKEN:+trouve}${TOKEN:-absent}` : la premiere moitie rend bien `trouve`, mais `:-` ne substitue
# QUE sur vide ou non defini — donc la seconde rend LA VALEUR juste apres.
#
# ⚠ LA BRANCHE MENTEUSE EST CELLE QUI REUSSIT. Sur un jeton ABSENT la ligne est parfaitement
# correcte : `${TOKEN:-absent}` ne se declenche que la ou il n'y a rien a fuiter. Elle se relisait
# donc comme juste a chaque passage. C'est pourquoi ce temoin pose un jeton NON VIDE — le seul etat
# ou la faute existe.
#
# ⚠ ET IL EXECUTE LA LIGNE REELLE, EXTRAITE DU FICHIER. Un temoin qui `grep`-erait un motif interdit
# mesurerait l'orthographe d'une correction, pas son effet : la prochaine forme fautive s'ecrira
# autrement. On extrait le bloc, on lui donne un jeton sentinelle, et on regarde ce qui sort.

setup() {
  PACK="$BATS_TEST_DIRNAME/../../../pack.sh"
  [ -f "$PACK" ]
  # Un jeton qui ne ressemble a rien d'autre : s'il apparait dans la sortie, il vient de la ligne.
  SENTINEL="s3cr3t-de-forge-a-ne-jamais-imprimer"
}

# ⚠ LE DECOR PORTE `PACK_DIR`, ET CE N'EST PAS UNE COMMODITE. Depuis le 2026-08-26 la premiere
# ligne du bloc nomme le tiroir ou le tar attend (`fix(pack)`), donc le bloc DEPEND d'une variable
# posee plus haut dans `pack.sh`. Sous le `set -u` de ce fichier ET celui de `pack.sh`, un bloc
# remonte au-dessus de cette affectation tuerait le packageur sur variable non liee. Le decor
# modelise donc le contexte reel ; l'ORDRE, lui, est tenu par `pack_outdir.bats`.
# Le bloc qui calcule l'etat puis le dit — depuis `_tok_state` jusqu'a la ligne qui l'imprime.
verdict_block() { sed -n '/_tok_state=/,/jeton :/p' "$PACK"; }

@test "le bloc de verdict existe et se laisse extraire — sinon les temoins suivants ne mesurent rien" {
  # ⚠ SANS CETTE GARDE, UN `sed` QUI NE TROUVE RIEN REND LE VIDE, et un bloc vide n'imprime aucun
  # jeton : les deux temoins ci-dessous passeraient au VERT en n'ayant rien execute. Une sonde qui
  # rend « conforme » sur une population vide est le defaut que ce depot traque partout.
  run verdict_block
  [ "$status" -eq 0 ]
  [[ "$output" == *"jeton :"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 2 ]
}

@test "UN JETON PRESENT NE S'IMPRIME PAS — on dit son etat, pas sa valeur" {
  run bash -c "
    set -euo pipefail
    say() { printf 'pack: %s\n' \"\$*\"; }
    FORGE=''
    TOKEN='$SENTINEL'
    PACK_DIR='/tiroir-du-temoin'
    $(verdict_block)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]]
  [[ "$output" == *"trouvé"* ]]
}

@test "UN JETON ABSENT se dit absent — la branche qui marchait deja doit continuer" {
  # Le pendant. Sans lui, une correction qui dirait « trouvé » dans les DEUX cas passerait le temoin
  # precedent : elle ne fuiterait rien et ne dirait plus rien de vrai non plus.
  run bash -c "
    set -euo pipefail
    say() { printf 'pack: %s\n' \"\$*\"; }
    FORGE=''
    TOKEN=''
    PACK_DIR='/tiroir-du-temoin'
    $(verdict_block)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent"* ]]
  [[ "$output" != *"trouvé"* ]]
}

@test "AUCUN secret n'est ecrit en dur dans le packageur — il les LIT, il ne les porte pas" {
  # Ce fichier est suivi par git : un litteral partirait sur la forge, sur le remote github, ET dans
  # chaque tar que ce script produit — le paquet livrerait la cle de la forge qui le sert. Le
  # commentaire de `pack.sh` l'affirme depuis toujours ; rien ne le mesurait.
  local code; code="$(grep -vE '^\s*#' "$PACK")"
  # Un jeton Gitea est 40 hexa. On epingle la FORME, pas un nom de variable : c'est elle qui fuite.
  ! grep -qE '[0-9a-f]{40}' <<<"$code"
}
