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

# ⚠ EXIGE PAR `run -<code>`, ET C'EST UNE DECLARATION DE CONTRAT, PAS UNE FORMALITE. Sans cette
# ligne, bats avertit qu'il ne garantit pas la semantique de `run -127` avant 1.5 — et en 1.11 un
# avertissement suffit a rendre la suite ROUGE. Le fichier dit donc de quelle version il depend.
bats_require_minimum_version 1.5.0

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
  # ⚠ `run -127`, ET LE CODE EST DECLARE PLUTOT QUE CONSTATE. Ce `run` etait nu : bats 1.11 emet
  # alors un avertissement BW01 (« exited with 127, indicating command not found ») et sort en
  # **exit 1 malgre zero echec**. Mesure du 2026-08-20 : le meme arbre rend le gate VERT sous bats
  # 1.10 (poste WSL) et ROUGE sous 1.11 (poste natif Mintie), 853 tests `ok` des deux cotes. Un
  # verdict qui depend de la version de l'outil n'est pas un verdict.
  #
  # Declarer le code est aussi meilleur en soi : 127 est ce que ce temoin ATTEND — le binaire
  # n'existe pas, c'est le sujet — et le dire au harnais vaut mieux que le verifier apres coup.
  run -127 env LCARS_FLEET_BIN=/inexistant "$SUT" catalogue list
  [[ "$output" == *"fait de FORGE"* ]]
  [[ "$output" != *"installe"* ]]
}

@test "list: SANS release, il montre quand meme le MATERIEL present, et d'ou il vient" {
  # Le contre-temoin du precedent : refuser de conclure ne doit pas vouloir dire ne rien montrer.
  # L'operateur voit ce qu'il a sous la main, sans qu'on prononce son etat.
  mkdir -p "$LCARS_CATALOGUES_DIR/mobile"
  # `run -127` pour la meme raison qu'au temoin precedent : sans release, la porte sort en 127 et
  # bats 1.11 en fait un avertissement fatal.
  run -127 env LCARS_FLEET_BIN=/inexistant "$SUT" catalogue list
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
  #
  # ⚠ CE TEMOIN MESURAIT LA MACHINE, ET IL ETAIT VIDE SUR LA MOITIE DU PARC. Il lancait la porte
  # SANS decor : elle cherchait donc un release sur la machine hote. Sur un poste qui n'en a pas,
  # elle sortait en 127 — la porte ne s'executait JAMAIS, et « aucune declaration n'est ecrite »
  # etait vrai parce que rien n'avait tourne. Sur un poste qui en a un, elle sortait en 0. Le
  # `run -127` pose le 2026-08-20 pour taire un avertissement bats 1.11 a fige la reponse d'UNE
  # machine dans l'assertion : rouge partout ailleurs, et vert pour la mauvaise raison ici.
  #
  # Le decor est donc POSE, comme chez les deux temoins ci-dessus : la porte part pour de vrai, et
  # ce qu'on mesure est ce qu'elle ECRIT — la seule question que ce test pose. Un temoin qui ne fait
  # pas tourner son sujet ne le teste pas, il le contourne.
  bin="$BATS_TEST_TMPDIR/fake_release_activite"
  printf '#!/usr/bin/env bash\nprintf "INSTALLED fleet -\\n"\n' > "$bin"
  chmod +x "$bin"

  run -0 env LCARS_FLEET_BIN="$bin" LCARS_FLEET_V2_ENV="$BATS_TEST_TMPDIR/inexistant.env" \
    "$SUT" catalogue list
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

# ─── `catalogue install` : DEUX etats, DEUX messages ─────────────────────────────────────────────
# MESURE DU 2026-08-20, en vol. `-r` sur le jeton master echoue pour deux raisons qui n'ont rien a
# voir — le compte n'administre pas, ou il l'est devenu APRES l'ouverture de la session — et un
# message unique annoncait la premiere. Un humain DEJA promu s'est vu prescrire sa propre promotion,
# et a cherche une heure du cote de la forge un defaut qui etait dans son shell.
#
# Un process porte ses groupes supplementaires depuis son LOGIN. `usermod -aG` ecrit `/etc/group` et
# ne touche aucun process vivant : `id -nG <compte>` lit la base, `id -nG` nu lit le process. C'est
# cette difference qu'on mesure, et ces deux temoins la tiennent dans les deux sens.

# ⚠ LE STUB `stat` RENDAIT `lcars-admin` POUR TOUT, ET C'EST CE QUI A LAISSE PASSER LE DEFAUT.
# Les deux objets sont gardes par DEUX groupes differents (mesure du 2026-08-22 sur un poste :
# `/home/private` est `root:fleet`, le jeton `root:lcars-admin`), et `stat` sur le FICHIER exige
# deja la traversee du REPERTOIRE. Un stub qui repond toujours ne peut donc pas voir le cas ou la
# mesure fine echoue — c'est-a-dire le cas nominal qu'elle existe pour diagnostiquer.
#
# La doublure modelise les deux objets ET la traversee : le fichier ne se stat que si le PROCESS
# porte le groupe du repertoire.
_install_stubs() { # <groupes du PROCESS> [groupes de la BASE]
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  # Le jeton EXISTE et n'est PAS lisible — l'etat exact ou la commande doit choisir son message.
  MASTER="$BATS_TEST_TMPDIR/forge-master.token"; echo tok > "$MASTER"; chmod 000 "$MASTER"
  local db="${2:-lcars fleet lcars-admin}"

  cat > "$STUBS/stat" <<EOF
#!/usr/bin/env bash
target="\${@: -1}"
if [[ "\$target" == *forge-master.token ]]; then
  # La traversee d'abord : sans le groupe du repertoire, ce stat-la ECHOUE, comme sur un vrai poste.
  printf '%s\\n' "$1" | tr ' ' '\\n' | grep -qx fleet || { echo "stat: cannot statx" >&2; exit 1; }
  echo lcars-admin
else
  echo fleet
fi
EOF
  # Avec un argument (`id -nG lcars`) : la BASE, ou le compte est admin.
  # Sans argument (`id -nG`) : le PROCESS, dont les groupes sont ceux du test.
  cat > "$STUBS/id" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-un")    echo lcars ;;
  "-nG lcars") echo "$db" ;;
  "-nG")    echo "$1" ;;
  *)        exec /usr/bin/id "\$@" ;;
esac
EOF
  chmod +x "$STUBS/stat" "$STUBS/id"
  GESTURES="$BATS_TEST_TMPDIR/gestures.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$GESTURES"
  chmod +x "$GESTURES"
}

@test "catalogue install: compte promu, SESSION antérieure — le refus nomme la session, pas la forge" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : le gate ne se joue pas"
  _install_stubs "lcars fleet"

  run env PATH="$STUBS:$PATH" LCARS_MASTER_TOKEN_FILE="$MASTER" \
      LCARS_FORGE_GESTURES="$GESTURES" "$SUT" catalogue install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"SESSION est anterieure"* ]]
  # LE MENSONGE INTERDIT #1 : prescrire une promotion deja faite.
  [[ "$output" != *"proprietaire de la forge te promeut"* ]]

  # LE MENSONGE INTERDIT #2, et il a vecu un jour : « deconnecte-toi et reconnecte-toi ». La console
  # du deck survit au rechargement de l'onglet ; on retombe sur le meme process, ne avant la
  # promotion. L'operateur a suivi ce conseil, rien n'a change, et c'est `newgrp` qui a debloque.
  [[ "$output" != *"Deconnecte-toi et reconnecte-toi"* ]]

  # LE MENSONGE INTERDIT #3, ET IL A REMPLACE LE #2 PENDANT UN JOUR : « tmux kill-server ». Le
  # serveur tmux n'est pas le porteur du cache, il en est l'HERITIER — le set de groupes est fige
  # dans TTYD par `setpriv --init-groups`, et le serveur suivant nait sous ce meme ttyd avec
  # exactement les memes groupes. Corriger un geste faux par un autre geste faux a coute une heure
  # a l'operateur, parti chercher une sortie ssh du conteneur.
  [[ "$output" != *"kill-server"* ]]

  # LE SEUL GESTE QUI MARCHE, et il est nomme.
  [[ "$output" == *"newgrp lcars-admin"* ]]
}

@test "catalogue install: compte NON promu — le message general revient, inchange" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : le gate ne se joue pas"
  # Le process ET la base sont d'accord : le compte n'est pas dans le groupe. Le stub `id -nG lcars`
  # ne repond plus admin.
  _install_stubs "lcars fleet"
  cat > "$STUBS/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-un")       echo lcars ;;
  "-nG lcars") echo "lcars fleet" ;;
  "-nG")       echo "lcars fleet" ;;
  *)           exec /usr/bin/id "$@" ;;
esac
EOF
  chmod +x "$STUBS/id"

  run env PATH="$STUBS:$PATH" LCARS_MASTER_TOKEN_FILE="$MASTER" \
      LCARS_FORGE_GESTURES="$GESTURES" "$SUT" catalogue install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'administre pas ce runtime"* ]]
  [[ "$output" != *"SESSION est anterieure"* ]]
}

# ─── `catalogue install` lit l'env de la BOITE, pas celui du shell ───────────────────────────────
# ELLE ETAIT LA SEULE DES CINQ PORTES FORGE A NE PAS LE FAIRE (`cat_states`, `project migrate`,
# `project reconcile`, `approve` le font). Consequence mesuree le 2026-08-20 : sous `sudo`, qui
# reinitialise l'environnement et deplace $HOME, la commande accusait la boite de n'avoir pas de
# `FORGE_BASE_URL` — un manque qui etait celui de l'appelant.
# ─── LE TROISIEME ETAT, ET LE REFUS N'EN CONNAISSAIT QUE DEUX ────────────────────────────────────
# « admin sur la forge » et « humain de cette flotte » sont DEUX faits distincts. Le convergeur
# ITERE sur `fleet:humans` et n'appelle `forge_is_admin` que dans cette boucle : hors de la team,
# personne ne lit ton `is_admin`, donc aucun groupe n'est projete — si admin sois-tu.
#
# ⚠ MESURE DU 2026-08-22, EN VOL. Un operateur ADMIN de sa forge, absent de `fleet:humans`, s'est vu
# prescrire sa propre promotion. Meme forme que la cicatrice du dessus, un cran plus haut : le refus
# nommait la mauvaise cause, donc il envoyait chercher au bon endroit pour un probleme qui etait
# ailleurs.

@test "catalogue install: ni groupe ni base — le refus nomme fleet:humans, pas is_admin" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : le gate ne se joue pas"
  # Le process ET la base sont d'accord : ce compte n'a jamais ete converge.
  _install_stubs "lcars" "lcars"

  run env PATH="$STUBS:$PATH" LCARS_MASTER_TOKEN_FILE="$MASTER" \
      LCARS_FORGE_GESTURES="$GESTURES" "$SUT" catalogue install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"humain de cette flotte"* ]]
  [[ "$output" == *"humans"* ]]
  # LE MENSONGE INTERDIT #4 : accuser is_admin quand la promotion est faite et la team absente.
  [[ "$output" != *"n'administre pas ce runtime"* ]]
  [[ "$output" != *"y porte is_admin"* ]]
  [[ "$output" != *"SESSION est anterieure"* ]]
}

@test "catalogue install: session anterieure a la CONVERGENCE — mesuree sur le repertoire" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : le gate ne se joue pas"
  # ⚠ LE CAS QUI ETAIT INATTEIGNABLE. La base porte les deux groupes, le process aucun — l'etat
  # exact d'un shell ouvert avant le tour du convergeur. La mesure fine partait de
  # `stat -c %G <jeton>`, qui exige la traversee du repertoire : elle echouait ici, et le refus
  # retombait sur « ton compte n'administre pas ce runtime ». Le repli etait ecrit comme un cas
  # rare ; il etait le cas nominal, parce que les deux objets n'ont pas le meme groupe.
  _install_stubs "lcars" "lcars fleet lcars-admin"

  run env PATH="$STUBS:$PATH" LCARS_MASTER_TOKEN_FILE="$MASTER" \
      LCARS_FORGE_GESTURES="$GESTURES" "$SUT" catalogue install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"SESSION est anterieure"* ]]
  [[ "$output" == *"newgrp fleet"* ]]
  [[ "$output" != *"n'administre pas ce runtime"* ]]
  [[ "$output" != *"humain de cette flotte"* ]]
}

@test "catalogue install: la configuration vient de fleet_v2.env, pas du shell" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout : le gate ne se joue pas"
  T="$BATS_TEST_TMPDIR"
  echo tok > "$T/tok"; chmod 0644 "$T/tok"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/gestures.sh"; chmod +x "$T/gestures.sh"
  cat > "$T/fleet_v2.env" <<EOF
LCARS_MASTER_TOKEN_FILE=$T/tok
LCARS_FORGE_GESTURES=$T/gestures.sh
EOF

  # RIEN dans l'environnement : tout doit venir du fichier de la boite.
  run env -u LCARS_MASTER_TOKEN_FILE -u LCARS_FORGE_GESTURES \
      LCARS_FLEET_V2_ENV="$T/fleet_v2.env" "$SUT" catalogue install web-demo
  [ "$status" -eq 0 ]
}
