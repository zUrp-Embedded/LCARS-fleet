#!/usr/bin/env bats
# SOURCE: runtime/test/services/uid_bounds.bats
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: bats tests — `services/lib/uid-bounds.sh`, l'unique lecture shell de la frontiere
#
# ⚖ Phase 5 du plan runtime : « la regle des bornes d'uid ecrite une fois par langage ». Elle
# l'etait TROIS fois cote produit. Ce que ce temoin tient est ce qui rend l'unification SURE :
#
#   · AUCUN REPLI. Un `login.defs` illisible ne veut pas dire « la frontiere est a 1000 » mais
#     « elle n'est pas etablie ». C'est fail-CLOSED : la console ne rend personne, le lanceur
#     refuse, le convergeur ne converge pas.
#   · LES DEUX BORNES. Une seule lisible n'etablit rien — au-dessus de UID_MAX vivent `nobody`
#     (65534, sur toute machine) et les comptes de service hauts.
#   · LES VARIABLES SONT VIDEES SUR UN ECHEC. Un appelant qui ignorerait le code de retour
#     comparerait un uid a une borne VIDE, que bash lit comme 0 : tout deviendrait humain.
#   · RIEN NE VIENT DE L'ENVIRONNEMENT DU GARDE. « La frontiere obeirait a qui la franchit. »

setup() {
  LIB="$BATS_TEST_DIRNAME/../../services/lib/uid-bounds.sh"
  [ -f "$LIB" ]
  DEFS="$BATS_TEST_TMPDIR/login.defs"
}

# lit <contenu de login.defs, ou ABSENT> <expression bash apres l'appel>
lit() {
  local defs="$DEFS"
  if [ "$1" = ABSENT ]; then defs="$BATS_TEST_TMPDIR/nulle-part/login.defs"; else printf '%s' "$1" > "$DEFS"; fi
  run env -u UID_MIN -u UID_MAX PASSWD_DEFS="$defs" \
    bash -c "set -euo pipefail; . '$LIB'; rc=0; uid_bounds_read || rc=\$?; $2"
}

@test "les deux bornes lisibles : elles sont posees, et le code dit oui" {
  lit $'UID_MIN\t1000\nUID_MAX\t60000\n' 'printf "%s|%s|%s" "$rc" "$UID_MIN" "$UID_MAX"'
  [ "$status" -eq 0 ]
  [ "$output" = "0|1000|60000" ]
}

@test "⚠ AUCUN REPLI : un login.defs ABSENT rend 1, et NE POSE RIEN" {
  lit ABSENT 'printf "%s|%s|%s" "$rc" "$UID_MIN" "$UID_MAX"'
  [ "$status" -eq 0 ]
  [ "$output" = "1||" ]
}

@test "⚠ UNE SEULE BORNE N'ETABLIT PAS LA FRONTIERE — et la MOITIE manquante est nommee" {
  lit $'UID_MIN\t1000\n' 'printf "%s|%s|%s|%s" "$rc" "$UID_MIN" "$UID_MAX" "$UID_BOUNDS_WHY"'
  [ "$status" -eq 0 ]
  [[ "$output" == "1|||"*"UID_MAX illisible"* ]]

  lit $'UID_MAX\t60000\n' 'printf "%s|%s" "$rc" "$UID_BOUNDS_WHY"'
  [[ "$output" == "1|"*"UID_MIN illisible"* ]]
}

@test "⚠ LES DEUX SONT VIDEES sur un echec — une borne a moitie posee ferait humain tout le monde" {
  # `(( uid < UID_MIN ))` avec UID_MIN vide vaut `(( uid < 0 ))` : faux pour tout uid. Un appelant
  # qui ignore le code de retour laisserait passer la machine entiere.
  lit $'UID_MIN\t1000\n' '[[ -z "$UID_MIN" && -z "$UID_MAX" ]] && printf vides'
  [ "$output" = "vides" ]
}

@test "⚠ RIEN NE VIENT DE L'ENVIRONNEMENT : un UID_MIN herite ne survit pas a la lecture" {
  # « La frontiere obeirait a qui la franchit » : un processus garde qui exporterait UID_MIN=0
  # s'ouvrirait la porte. Les deux variables sont RE-ECRITES a chaque appel.
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$DEFS"
  run env UID_MIN=0 UID_MAX=99999 PASSWD_DEFS="$DEFS" \
    bash -c "set -euo pipefail; . '$LIB'; uid_bounds_read; printf '%s|%s' \"\$UID_MIN\" \"\$UID_MAX\""
  [ "$status" -eq 0 ]
  [ "$output" = "1000|60000" ]
}

@test "le motif est STRICT : une clef dont UID_MIN n'est que le prefixe ne signe pas" {
  # `/^UID_MIN/` — la forme qu'avait la console — matche `UID_MIN_QUELQUE_CHOSE`. La frontiere se
  # lirait alors sur une clef qui n'est pas la sienne.
  lit $'UID_MIN_AUTRE\t42\nUID_MIN\t1000\nUID_MAX\t60000\n' 'printf "%s" "$UID_MIN"'
  [ "$output" = "1000" ]
}

@test "le CHEMIN retenu est PUBLIC — un appelant qui le nomme ne le recalcule pas" {
  lit $'UID_MIN\t1000\nUID_MAX\t60000\n' 'printf "%s" "$UID_BOUNDS_FILE"'
  [ "$output" = "$DEFS" ]
}

@test "⚠ LA LECTURE N'IMPRIME RIEN — c'est ce qui la rend sourcable hors d'un protocole" {
  # Le protocole des modules en fait un `p_warn`, la console une liste vide, le lanceur un refus.
  # Une lecture qui parlerait imposerait son mot a ses trois hotes.
  lit ABSENT 'true'
  [ -z "$output" ]
}
