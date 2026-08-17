#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/lcars_catalogue.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for bin/lcars — l'etat d'un catalogue vient de la FORGE, et de nulle part ailleurs
#
# CE QUI EST EPINGLE, ET POURQUOI. Il y avait TROIS etats et il en reste DEUX. Un catalogue etait
# `available` (le materiel quelque part), `installed` (la forge porte son org) et `active` (une ligne
# dans `~/.lcars/catalogues.active`, tenue a la main). Le troisieme est mort le 2026-08-16, avec les
# verbes qui l'ecrivaient — et ce fichier a perdu cinq temoins d'un coup.
#
# Ce qui les rendait necessaires est ce qui condamne l'objet qu'ils gardaient : quatre commandes ont
# menti EN MEME TEMPS parce que la CLI lisait le fichier pendant que le runtime appliquait « pas de
# declaration = le catalogue livre, seul ». Mesure du 2026-08-12 sur une boite dont tout tournait
# sur `fleet` : `list` l'affichait « inactif », `enable web` le faisait sortir sans un mot, et
# `disable fleet` repondait « n'est pas actif ». Trois sens du meme modele faux.
#
# Un fait tenu a deux endroits derive ; la reparation n'est pas de synchroniser les deux copies,
# c'est d'en supprimer une. Ce que ces temoins tiennent maintenant : la CLI n'a AUCUN etat de
# catalogue a elle, elle relaie celui du release, et sans release elle le DIT.

setup() {
  SUT="$BATS_TEST_DIRNAME/../../bin/lcars"
  [ -x "$SUT" ]
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export LCARS_CATALOGUES_SHIPPED="$BATS_TEST_TMPDIR/shipped"
  mkdir -p "$LCARS_CATALOGUES_DIR" "$LCARS_CATALOGUES_SHIPPED/web"
}

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

@test "list: la porte CHARGE fleet_v2.env — l'adresse forge ne vit que la (D3)" {
  # ⚠ Mesure du 2026-08-11, payee une premiere fois par `project migrate` : l'environ d'un login
  # humain ne porte AUCUN FORGE_*, et rien ne source ce fichier hors fleet_v2. Sans ce chargement,
  # la porte rendait `{:config, {:missing, :base_url}}` sous « la forge n'a pas repondu » — une
  # panne de config habillee en panne reseau, sur la commande qu'un operateur lit en premier.
  bin="$BATS_TEST_TMPDIR/fake_env_release"
  cat > "$bin" <<'FAKE'
#!/usr/bin/env bash
printf 'INSTALLED fleet -
'
printf 'ENV %s
' "${FORGE_BASE_URL:-ABSENTE}" >> "${ENV_PROBE:?}"
FAKE
  chmod +x "$bin"

  printf 'FORGE_BASE_URL=http://forge-du-fichier:3000
' > "$BATS_TEST_TMPDIR/fleet_v2.env"

  run env LCARS_FLEET_BIN="$bin" ENV_PROBE="$BATS_TEST_TMPDIR/env.probe"     LCARS_FLEET_V2_ENV="$BATS_TEST_TMPDIR/fleet_v2.env" "$SUT" catalogue list
  [ "$status" -eq 0 ]
  grep -q 'ENV http://forge-du-fichier:3000' "$BATS_TEST_TMPDIR/env.probe"
}

@test "list: SANS fichier env, la porte part quand meme — le fichier est un apport, pas un prerequis" {
  # Une boite dont l'env est deja cable (le conteneur exporte FORGE_BASE_URL) n'a pas ce fichier
  # sous ce HOME ; la porte ne doit pas refuser pour autant.
  bin="$BATS_TEST_TMPDIR/fake_noenv_release"
  printf '#!/usr/bin/env bash
printf "INSTALLED fleet -\n"
' > "$bin"
  chmod +x "$bin"

  run env LCARS_FLEET_BIN="$bin" LCARS_FLEET_V2_ENV="$BATS_TEST_TMPDIR/inexistant.env"     "$SUT" catalogue list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet"*"installe"* ]]
}

@test "les verbes d'ACTIVITE n'existent plus, et le refus enumere ce qui reste" {
  # ⚖ user, 2026-08-16 : UN SEUL VERBE. Un `enable` survivant ecrirait une declaration que plus
  # rien ne lit — la pire des sorties : code 0, message de succes, aucun effet.
  for verbe in enable disable remove; do
    run "$SUT" catalogue "$verbe" fleet
    [ "$status" -ne 0 ]
    [[ "$output" == *"list|install|verify"* ]]
  done
}

@test "aucune declaration d'activite n'est ecrite, par aucun verbe" {
  # Le fichier a disparu du modele ; ce temoin tient qu'il ne revient pas par la porte de service.
  run "$SUT" catalogue list
  [ ! -e "$HOME/.lcars/catalogues.active" ]
  [ ! -e "$BATS_TEST_TMPDIR/catalogues.active" ]
}

# ─── `project reconcile` : la porte de reconvergence de /home ────────────────────────────────────
# La CLI n'agit pas plus ici qu'ailleurs — elle transmet un mode au release. Ce qui se mesure est
# donc ce qu'elle refuse et ce qu'elle instruit.

@test "project reconcile: un mode inconnu est refuse, et les deux modes sont nommes" {
  # Le footgun exact : `reconcile --apply`, `reconcile all`, `reconcile now`. Un mode non reconnu
  # qui retomberait sur `check` rendrait un succes muet a qui croyait importer.
  run "$SUT" project reconcile maintenant
  [ "$status" -ne 0 ]
  [[ "$output" == *"check|apply"* ]]
}

@test "project: le verbe est INSTRUIT — l'usage et le refus nomment les deux sous-commandes" {
  # Un verbe absent de l'usage est un verbe que personne n'instruit : c'est ce que ce depot a deja
  # paye une fois, sur une commande vivante et invisible.
  run "$SUT" project
  [ "$status" -ne 0 ]
  [[ "$output" == *"migrate|reconcile"* ]]

  run "$SUT" help
  [[ "$output" == *"project reconcile"* ]]
}
