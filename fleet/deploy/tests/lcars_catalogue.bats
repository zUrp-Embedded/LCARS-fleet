#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/lcars_catalogue.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for bin/lcars — l'ACTIVITE d'un catalogue, et le defaut implicite
#
# CE QUI EST EPINGLE, ET POURQUOI. La regle du runtime vit dans `Fleet.Catalogue.active_roots/0` :
# *pas de declaration, ou une declaration vide, signifie le catalogue livre dans le release SEUL*.
# C'est l'etat de TOUTE boite neuve — le fichier `catalogues.active` n'existe pas tant que personne
# n'a rien active. La CLI, elle, ne lisait que le fichier, et cet ecart faisait mentir quatre
# commandes a la fois. Mesure du 2026-08-12 sur une boite dont tout tournait sur `fleet` :
#
#   lcars catalogue list      ->  « fleet   inactif »   alors que c'est CE QUI TOURNE
#   lcars catalogue enable web ->  declaration « web » SEULE : fleet vient de sortir, sans un mot,
#                                  et avec lui tous les projets de son org (le poller scanne les
#                                  orgs des catalogues ACTIFS)
#   lcars catalogue disable fleet -> « n'est pas actif », le troisieme sens du meme modele faux
#
# Ces tests tiennent la regle du cote CLI. Ils n'invoquent aucun sous-verbe qui parle a la forge ou
# au release : `enable` d'un catalogue non-livre exige un `verify` qui charge le runtime, donc les
# cas testes ici sont ceux qui n'en ont pas besoin — le predicat, la liste, le refus de `disable`,
# et la materialisation du defaut par un `enable` du catalogue livre lui-meme.

setup() {
  SUT="$BATS_TEST_DIRNAME/../../bin/lcars"
  [ -x "$SUT" ]
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export LCARS_CATALOGUES_ACTIVE="$BATS_TEST_TMPDIR/catalogues.active"
  export LCARS_CATALOGUES_SHIPPED="$BATS_TEST_TMPDIR/shipped"
  mkdir -p "$LCARS_CATALOGUES_DIR" "$LCARS_CATALOGUES_SHIPPED/web"
}

# ─── le predicat ────────────────────────────────────────────────────────────────────────────────

@test "SANS declaration : le catalogue LIVRE est actif, et lui seul" {
  run "$SUT" catalogue list
  [ "$status" -eq 0 ]
  # La ligne d'inventaire disait « inactif » pour le catalogue qui tourne.
  [[ "$output" == *"fleet"*"actif"* ]]
  [[ "$output" != *"fleet          inactif"* ]]
  # Et le bloc ACTIFS le NOMME, au lieu de le decrire sans le nommer.
  [[ "$output" == *"1. fleet"* ]]
  [[ "$output" == *"par defaut"* ]]
}

@test "SANS declaration : un catalogue installe reste inactif" {
  run "$SUT" catalogue list
  [ "$status" -eq 0 ]
  [[ "$output" == *"web"*"inactif"* ]]
}

@test "AVEC une declaration qui ne le nomme pas : le livre est bien inactif" {
  printf 'web\n' > "$LCARS_CATALOGUES_ACTIVE"
  run "$SUT" catalogue list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet          inactif"* ]]
  [[ "$output" == *"web"*"actif"* ]]
}

@test "un commentaire et des lignes vides ne font pas une declaration" {
  printf '# rien\n\n   \n' > "$LCARS_CATALOGUES_ACTIVE"
  run "$SUT" catalogue list
  [ "$status" -eq 0 ]
  # Fichier non vide mais declaration vide : la regle du defaut s'applique quand meme.
  [[ "$output" == *"1. fleet"* ]]
  [[ "$output" == *"par defaut"* ]]
}

# ─── le defaut ne se retire pas par soustraction ────────────────────────────────────────────────

@test "disable du livre SANS declaration : refuse, et dit qu'un defaut se REMPLACE" {
  run "$SUT" catalogue disable fleet
  [ "$status" -ne 0 ]
  [[ "$output" == *"PAR DEFAUT"* ]]
  [[ "$output" == *"REMPLACE"* ]]
  # Rien n'a ete ecrit : le refus ne laisse pas de declaration a moitie posee.
  [ ! -f "$LCARS_CATALOGUES_ACTIVE" ]
}

@test "disable d'un catalogue qui n'est actif nulle part : refuse comme avant" {
  printf 'web\n' > "$LCARS_CATALOGUES_ACTIVE"
  run "$SUT" catalogue disable fleet
  [ "$status" -ne 0 ]
  [[ "$output" == *"n'est pas actif"* ]]
}

@test "disable du livre AVEC declaration : passe, et ne vide pas le reste" {
  printf 'fleet\nweb\n' > "$LCARS_CATALOGUES_ACTIVE"
  run "$SUT" catalogue disable fleet
  [ "$status" -eq 0 ]
  run cat "$LCARS_CATALOGUES_ACTIVE"
  [ "$output" = "web" ]
}

# ─── la premiere declaration ne doit pas eteindre ce qui tournait ───────────────────────────────

@test "enable du livre SANS declaration : deja actif, rien d'ecrit" {
  run "$SUT" catalogue enable fleet
  [ "$status" -eq 0 ]
  [[ "$output" == *"deja actif"* ]]
  [ ! -f "$LCARS_CATALOGUES_ACTIVE" ]
}

@test "enable du livre APRES qu'une declaration l'a exclu : il revient" {
  printf 'web\n' > "$LCARS_CATALOGUES_ACTIVE"
  run "$SUT" catalogue enable fleet
  [ "$status" -eq 0 ]
  run cat "$LCARS_CATALOGUES_ACTIVE"
  [[ "$output" == *"web"* ]]
  [[ "$output" == *"fleet"* ]]
}
