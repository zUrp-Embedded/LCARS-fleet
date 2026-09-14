#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lcars_catalogue.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-12
# STATUS: bats tests for bin/lcars — l'etat d'un catalogue vient de la FORGE, et de nulle part ailleurs

# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SUT="$BATS_TEST_DIRNAME/../../runtime/bin/lcars"
  [ -x "$SUT" ]
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  export LCARS_CATALOGUES_SHIPPED="$BATS_TEST_TMPDIR/shipped"
  mkdir -p "$LCARS_CATALOGUES_DIR" "$LCARS_CATALOGUES_SHIPPED/web"
}


@test "list: SANS release, il REFUSE de deviner et nomme la raison" {
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

@test "list: la porte CHARGE fleet.env — l'adresse forge ne vit que la (D3)" {
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
' > "$BATS_TEST_TMPDIR/fleet.env"

  run env LCARS_FLEET_BIN="$bin" ENV_PROBE="$BATS_TEST_TMPDIR/env.probe"     LCARS_FLEET_ENV="$BATS_TEST_TMPDIR/fleet.env" "$SUT" catalogue list
  [ "$status" -eq 0 ]
  grep -q 'ENV http://forge-du-fichier:3000' "$BATS_TEST_TMPDIR/env.probe"
}

@test "list: SANS fichier env, la porte part quand meme — le fichier est un apport, pas un prerequis" {
  # Un conteneur dont l'env est deja cable (le conteneur exporte FORGE_BASE_URL) n'a pas ce fichier
  # sous ce HOME ; la porte ne doit pas refuser pour autant.
  bin="$BATS_TEST_TMPDIR/fake_noenv_release"
  printf '#!/usr/bin/env bash
printf "INSTALLED fleet -\n"
' > "$bin"
  chmod +x "$bin"

  run env LCARS_FLEET_BIN="$bin" LCARS_FLEET_ENV="$BATS_TEST_TMPDIR/inexistant.env"     "$SUT" catalogue list
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
  bin="$BATS_TEST_TMPDIR/fake_release_activite"
  printf '#!/usr/bin/env bash\nprintf "INSTALLED fleet -\\n"\n' > "$bin"
  chmod +x "$bin"

  run -0 env LCARS_FLEET_BIN="$bin" LCARS_FLEET_ENV="$BATS_TEST_TMPDIR/inexistant.env" \
    "$SUT" catalogue list
  [ ! -e "$HOME/.lcars/catalogues.active" ]
  [ ! -e "$BATS_TEST_TMPDIR/catalogues.active" ]
}


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

# bats test_tags=structure
@test "catalogue install: la CLI ne lit AUCUN secret et n'appelle AUCUN geste" {
  local body
  body="$(sed -n '/^cmd_catalogue_install()/,/^}/p' "$SUT" | sed 's/#.*//')"
  [ -n "${body//[[:space:]]/}" ]   # une extraction cassee rendrait du vide, donc un sans-faute
  [[ "$body" != *"MASTER_TOKEN"* ]]
  [[ "$body" != *"forge-gestures"* ]]
  [[ "$body" != *"id -nG"* ]]
  run bash -c "sed 's/#.*//' '$SUT' | grep -c 'lcars-admin' || true"
  [ "$output" -eq 0 ]
}


# bats test_tags=structure
@test "catalogue install: le defaut de la socket est l'adresse REELLE du service" {
  local defaut manifeste
  defaut="$(sed -n 's/^_CATALOGUE_SOCKET="${LCARS_CATALOGUE_SOCKET:-\(.*\)}"$/\1/p' "$SUT")"
  [ -n "$defaut" ]
  manifeste="$(awk '{c=$1;sub(/:.*/,"",c)} c == "runtime" && $2 ~ /catalogue\.sock$/ { print $2 }' \
                 "$BATS_TEST_DIRNAME/../system.manifest")"
  [ -n "$manifeste" ]
  [ "$defaut" = "$manifeste" ]
}
