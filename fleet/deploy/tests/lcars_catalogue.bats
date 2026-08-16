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

# ─── `list` : l'etat vient de la FORGE, et sans release on le DIT ───────────────────────────────
# Les quatre temoins qui vivaient ici epinglaient l'ACTIVITE (« fleet actif », le bloc ACTIFS, la
# numerotation de precedence). Ce modele est retire : un catalogue est INSTALLE (la forge porte sa
# source, tout le monde est servi) ou DISPONIBLE, et l'activation n'existe plus. La liste ne peut
# donc plus repondre seule — et c'est ca que ces temoins tiennent maintenant.

@test "list: SANS release, il REFUSE de deviner et nomme la raison" {
  # LE MENSONGE QUE CE TEMOIN INTERDIT est celui qu'on vient de retirer : imprimer « installe »
  # pour tout dossier present. Un banc a affiche `web` installe pendant que la forge n'avait jamais
  # porte d'org `web`. Sans release, on ne SAIT pas, et on le dit a l'endroit qu'un operateur lit
  # en premier.
  run env LCARS_FLEET_BIN=/inexistant "$SUT" catalogue list
  [ "$status" -eq 127 ]
  [[ "$output" == *"fait de FORGE"* ]]
  [[ "$output" != *"installe"* ]]
}

@test "list: SANS release, il montre quand meme le MATERIEL present, et d'ou il vient" {
  # Le contre-temoin du precedent : refuser de conclure ne doit pas vouloir dire ne rien montrer.
  # L'operateur voit ce qu'il a sous la main, sans qu'on prononce son etat.
  mkdir -p "$LCARS_CATALOGUES_DIR/mobile"
  run env LCARS_FLEET_BIN=/inexistant "$SUT" catalogue list
  [[ "$output" == *"mobile"* ]]
  [[ "$output" == *"web"* ]]
  [[ "$output" == *"fleet"* ]]
}

@test "list: la porte du release parle en MOTS, et la CLI les traduit" {
  # La porte rend `<ETAT> <nom> <source>`, la CLI met en forme. Un tableau formate cote release
  # obligerait deux langages a s'accorder sur une colonne le jour ou on en ajoute une.
  bin="$BATS_TEST_TMPDIR/fake_release"
  cat > "$bin" <<'FAKE'
#!/usr/bin/env bash
printf 'INSTALLED fleet -\nUPDATABLE web alice/web\nAVAILABLE mobile bob/mob\n'
FAKE
  chmod +x "$bin"

  run env LCARS_FLEET_BIN="$bin" "$SUT" catalogue list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet"*"installe"* ]]
  [[ "$output" == *"mobile"*"disponible"*"bob/mob"* ]]
  # `updatable` NE S'APPLIQUE PAS TOUT SEUL : la ligne montre le geste, elle ne le fait pas.
  [[ "$output" == *"catalogue install web"* ]]
}

@test "list: un DOUBLON refuse, et nomme les DEUX proprietaires" {
  # On ne choisit pas. Devenir arbitre ici rendrait une reponse a celui qui perd sans qu'il puisse
  # savoir pourquoi.
  bin="$BATS_TEST_TMPDIR/fake_dup"
  cat > "$bin" <<'FAKE'
#!/usr/bin/env bash
printf 'DUPLICATE web alice/web bob/web\n' >&2
exit 3
FAKE
  chmod +x "$bin"

  run env LCARS_FLEET_BIN="$bin" "$SUT" catalogue list
  [ "$status" -eq 3 ]
  [[ "$output" == *"alice/web"* ]]
  [[ "$output" == *"bob/web"* ]]
  [[ "$output" == *"Aucun des deux n'est choisi"* ]]
}

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
