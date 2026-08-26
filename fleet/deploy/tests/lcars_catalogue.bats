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

# ─── `catalogue install` : LA CLI NE DETIENT RIEN, ELLE DEMANDE ─────────────────────────────────
#
# CE QUI EST EPINGLE ICI EST LE CLIENT, PAS L'AUTORITE. La decision — « la forge dit-elle que ce
# pair est admin ? » — vit dans `catalogue-executor.py`, dont le banc est
# `fleet/test/test_catalogue_executor.py`. Ce fichier-ci tient l'autre moitie du contrat : que
# CHAQUE cause rendue par le service devienne la BONNE phrase, et qu'aucune ne se traduise en une
# autre.
#
# ⚠ POURQUOI C'EST LA MOITIE QUI COMPTE POUR L'OPERATEUR. Un refus qui nomme la mauvaise cause
# envoie chercher au bon endroit pour un probleme qui est ailleurs, avec la certitude d'avoir
# compris — c'est ce qui a coute le plus cher sur cette porte, plusieurs fois. « Le service ne
# tourne pas » et « tu n'es pas admin » demandent des gestes opposes ; les confondre est le defaut,
# pas l'imprecision.
#
# Le TRANSPORT est double, parce que c'est le sujet : `bin/lcars` ecrit une ligne et lit un verdict.
_ask_stubs() { # <ce que le service repond, ligne a ligne>
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/reponse"
  cat > "$STUBS/socat" <<EOF
#!/usr/bin/env bash
cat >/dev/null            # la demande part, on ne la relit pas ici
cat "$BATS_TEST_TMPDIR/reponse"
EOF
  chmod +x "$STUBS/socat"
  # Une VRAIE socket : la commande teste \`-S\`, et un fichier ordinaire ne repondrait pas la meme
  # chose. On la cree avec python plutot que de relacher la garde pour le confort du test.
  SOCK="$BATS_TEST_TMPDIR/catalogue.sock"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"
}

_ask() { # <reponse du service> [nom de catalogue]
  _ask_stubs "$1"
  run env PATH="$STUBS:$PATH" LCARS_CATALOGUE_SOCKET="$SOCK" "$SUT" catalogue install "${2:-web-demo}"
}

@test "catalogue install: la forge dit NON — le refus nomme la forge, et rien d'autre" {
  _ask "FAIL:not_admin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"la forge dit"* ]]
  # ⚠ LES TROIS MENSONGES QUE CETTE PORTE A DEJA PRESCRITS, et qui ne peuvent plus etre vrais : il
  # n'y a plus de groupe a rejoindre, donc plus de session a rouvrir, donc plus rien a rattraper.
  [[ "$output" != *"newgrp"* ]]
  [[ "$output" != *"prochaine session"* ]]
  [[ "$output" != *"kill-server"* ]]
  # La promotion est effective A LA COMMANDE SUIVANTE : plus aucune projection entre les deux.
  [[ "$output" == *"SUIVANTE"* ]]
}

@test "catalogue install: forge MUETTE — « je n'ai pas pu demander », JAMAIS « tu n'es pas admin »" {
  _ask "FAIL:forge_unreachable"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pas pu DEMANDER"* ]]
  # Le mensonge de cette cause-ci : lire une absence de reponse comme un refus. Les deux gestes de
  # sortie sont opposes — reessayer, ou se faire promouvoir.
  [[ "$output" != *"n'est pas admin"* ]]
}

@test "catalogue install: NOM refuse — la phrase nomme la forme, pas l'adminite" {
  _ask "FAIL:bad_name" "../../etc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un nom"* ]]
  [[ "$output" != *"admin"* ]]
}

@test "catalogue install: un autre geste EN COURS — rien n'a ete tente, et ce n'est pas un refus" {
  _ask "FAIL:busy"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RIEN n'a ete tente"* ]]
  [[ "$output" != *"admin"* ]]
}

@test "catalogue install: pair INCONNU — c'est l'enrolement qui manque, pas l'adminite" {
  _ask "FAIL:unknown_peer"
  [ "$status" -eq 1 ]
  [[ "$output" == *"humans"* ]]
  [[ "$output" != *"n'est pas admin"* ]]
}

@test "catalogue install: le service ACCEPTE — la sortie du geste arrive, sans le protocole" {
  _ask "> forge-gestures: web-demo <- fleet/web-demo
> forge-gestures: recette appliquee
OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recette appliquee"* ]]
  # Le cadrage du fil ne fuit PAS jusqu'a l'operateur : ni le prefixe, ni le verdict brut.
  [[ "$output" != *"> forge-gestures"* ]]
  [[ "$output" != *"OK"* ]]
}

@test "catalogue install: le geste ECHOUE — son code remonte, et ce n'est pas un refus d'autorite" {
  _ask "> forge-gestures: clone impossible
FAIL:gesture_failed:3"
  [ "$status" -eq 3 ]
  [[ "$output" == *"clone impossible"* ]]
  [[ "$output" != *"admin"* ]]
}

@test "catalogue install: geste INTERROMPU — se rejoue, il ne se diagnostique pas" {
  # ⚠ MESURE : `Popen.wait()` rend `-15` quand l'enfant est tue par SIGTERM, et `exit -15` cote bash
  # rend 241 — un nombre qui ne designe rien. Le service nomme donc cette nature a part, et la CLI
  # rend une PHRASE : un geste interrompu se rejoue, un geste en echec se diagnostique. La cause la
  # plus banale est un `systemctl restart lcars-catalogue` pendant une install.
  _ask "> forge-gestures: web-demo <- fleet/web-demo
FAIL:gesture_signalled:15"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTERROMPU"* ]]
  [[ "$output" == *"signal 15"* ]]
  [[ "$output" == *"rejoue"* ]]
  # Ni un echec du geste, ni un refus d'autorite.
  [[ "$output" != *"admin"* ]]
  [[ "$output" != *"241"* ]]
}

@test "catalogue install: AUCUN verdict — echec nomme, JAMAIS un succes par defaut" {
  # ⚠ MESURE DU 2026-08-23, ET C'EST LE PIEGE QUI JUSTIFIE CE TEMOIN. `socat` ferme la connexion
  # 0,5 s apres l'EOF de stdin par defaut, alors que le geste dure des MINUTES : il rendait une
  # sortie VIDE et un code de retour ZERO. Sans ce garde, un install jamais joue se lisait comme un
  # install reussi — la pire forme d'echec, celle qui ne se voit pas.
  _ask ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"AUCUN verdict"* ]]
  [[ "$output" == *"INCONNU"* ]]
}

@test "catalogue install: une cause INCONNUE ne se traduit pas en refus d'autorite" {
  # Un service d'un autre lot rendrait une cause que cette CLI ne connait pas. La ranger dans
  # « pas admin » serait inventer un diagnostic ; on nomme le desaccord de version.
  _ask "FAIL:cause_dun_autre_lot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non interprete"* ]]
  [[ "$output" != *"n'est pas admin"* ]]
}

@test "catalogue install: SOCKET absente — porte fermee, pas porte gardee" {
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/socat"; chmod +x "$STUBS/socat"
  run env PATH="$STUBS:$PATH" LCARS_CATALOGUE_SOCKET="$BATS_TEST_TMPDIR/absente.sock" \
      "$SUT" catalogue install web-demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne tourne pas"* ]]
  # LE MENSONGE INTERDIT : accuser l'adminite de l'operateur quand c'est le service qui manque.
  [[ "$output" != *"pas admin"* ]]
  # Et le geste prescrit est SYSTEME, pas une promotion sur la forge.
  [[ "$output" == *"systemctl"* ]]
}

@test "catalogue install: le catalogue LIVRE est refuse avant meme de toucher la socket" {
  run env LCARS_CATALOGUE_SOCKET="$BATS_TEST_TMPDIR/nexiste.pas" "$SUT" catalogue install fleet
  [ "$status" -eq 1 ]
  [[ "$output" == *"livre DANS le release"* ]]
}

@test "catalogue install: la CLI ne lit AUCUN secret et n'appelle AUCUN geste" {
  # Le fond du chantier, tenu par une mesure sur la source : cette commande ne detient plus rien.
  # Detenir le jeton ETAIT la preuve du droit — c'est de la que venaient le groupe unix, sa
  # projection, son cache et son rattrapage de derive.
  # ⚠ ON MESURE LE CODE, PAS LA PROSE. Une premiere ecriture testait le corps BRUT et rougissait sur
  # un COMMENTAIRE qui raconte, a juste titre, pourquoi l'ancien chemin a disparu. Un instrument qui
  # attrape l'EXPLICATION d'un defaut au lieu du defaut interdit de l'expliquer.
  local body
  body="$(sed -n '/^cmd_catalogue_install()/,/^}/p' "$SUT" | sed 's/#.*//')"
  [ -n "${body//[[:space:]]/}" ]   # une extraction cassee rendrait du vide, donc un sans-faute
  [[ "$body" != *"MASTER_TOKEN"* ]]
  [[ "$body" != *"forge-gestures"* ]]
  [[ "$body" != *"id -nG"* ]]
  # Et plus aucun nom de groupe unix ne decide d'une adminite dans tout le fichier — mesure sur le
  # CODE, comme les trois assertions ci-dessus. Sur le fichier BRUT, une cicatrice future qui
  # expliquerait ce retrait ferait rougir ce temoin a tort : le mur qui interdit le groupe
  # interdirait de dire pourquoi il est interdit.
  run bash -c "sed 's/#.*//' '$SUT' | grep -c 'lcars-admin' || true"
  [ "$output" -eq 0 ]
}


@test "catalogue install: le defaut de la socket est l'adresse REELLE du service" {
  # Tous les temoins qui touchent la socket posent `LCARS_CATALOGUE_SOCKET` : le defaut n'est
  # exerce nulle part. Il a derive quand le service a cesse d'etre root et est passe sous
  # `/run/lcars/authority/` — la porte frappait alors une adresse morte et rendait « le service ne
  # tourne pas », c'est-a-dire la cause fausse que ce geste existe pour ne jamais dire.
  local defaut manifeste
  defaut="$(sed -n 's/^_CATALOGUE_SOCKET="${LCARS_CATALOGUE_SOCKET:-\(.*\)}"$/\1/p' "$SUT")"
  [ -n "$defaut" ]
  manifeste="$(awk '$1 == "runtime" && $2 ~ /catalogue\.sock$/ { print $2 }' \
                 "$BATS_TEST_DIRNAME/../system.manifest")"
  [ -n "$manifeste" ]
  [ "$defaut" = "$manifeste" ]
}
