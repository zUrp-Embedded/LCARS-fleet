#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/install_door.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for install.sh — LA porte : ce qu'elle detecte, ce qu'elle demande, ce qu'elle refuse
#
# CE QUI EST EN JEU. Cette porte choisit entre deux rails dont les erreurs sont GRAVES ET
# ASYMETRIQUES : deviner « poste », c'est posseder `/etc` de quelqu'un sans son accord ; deviner
# « boite », c'est batir 3 Go que personne n'a demandes. Une question dont aucune reponse n'est
# sure ne doit donc pas avoir de defaut — et c'est exactement ce que ces temoins epinglent.
#
# ⚠ AUCUN TEMOIN ICI NE DECLENCHE UNE MUTATION. Tous s'arretent sur un refus ou une question. Le
# chemin poste finit par `provision apply` en root et le chemin boite par un build de 15 min : un
# temoin qui les traverserait provisionnerait la machine qui joue la suite. Ce qui est mesure est
# la DECISION, jamais son execution.
#
# LE SUBSTRAT SE PILOTE PAR `LCARS_DOCKER=1` — `detect_substrate` rend alors `docker`, c'est-a-dire
# « pas wsl », ce qui donne le chemin natif de facon deterministe sur n'importe quelle machine.
# Sans lui, on est sur le substrat reel de la machine qui joue les tests.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SRC="$REPO/install.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  # Un docker qui repond a tout par 0 : la sonde d'endpoint n'a besoin que de ca.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/docker"
  chmod 0755 "$BINDIR/docker"
  export PATH="$BINDIR:$PATH"
  # La sonde prend la branche « DOCKER_HOST est pose » et interroge la doublure — sinon ces temoins
  # dependraient d'une socket sur la machine qui les joue.
  export DOCKER_HOST="unix:///dev/null"
  unset FORGE_BASE_URL
}

@test "l'aide marche SANS docker — un --help qui exige l'outil qu'il documente est une porte fermee" {
  run env -i PATH=/usr/bin:/bin bash "$SRC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--workstation"* ]]
  [[ "$output" == *"--box"* ]]
  [[ "$output" == *"--bench"* ]]
}

@test "PAS DE DEFAUT sans TTY : le refus NOMME les deux drapeaux" {
  # Le coeur du dessin. Un defaut silencieux ici choisit a la place de quelqu'un entre « on te prend
  # /etc » et « on te construit 3 Go » — les deux erreurs qu'aucune valeur par defaut ne repare.
  run bash "$SRC" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas de défaut sûr"* ]]
  [[ "$output" == *"--workstation"* ]]
  [[ "$output" == *"--box"* ]]
}

@test "la question DIT ce que chaque branche PREND — le cout est dans la question, pas apres" {
  run bash "$SRC" < /dev/null
  # Le rail poste annonce ce qu'il possede, et qu'on ne revient pas en arriere.
  [[ "$output" == *"AUCUN désinstalleur"* ]]
  [[ "$output" == *"/etc/wsl.conf"* ]]
  # Le rail boite annonce son prix et sa reversibilite.
  [[ "$output" == *"rien dans /etc ni /usr"* ]]
  [[ "$output" == *"reset"* ]]
}

@test "hors WSL : aucune question — une seule option est permise, et on le DIT" {
  # Le rail poste ecrit /local et /home/private : le garde de cible du provisionnement l'interdit
  # hors WSL. Poser la question la-bas offrirait un choix qui n'existe pas.
  run env LCARS_DOCKER=1 bash "$SRC" --box < /dev/null
  [[ "$output" == *"une seule option"* ]] || [[ "$output" != *"1 ou 2"* ]]
  [[ "$output" != *"pas de défaut sûr"* ]]
}

@test "--workstation hors WSL est REFUSE, et le refus donne la voie qui marche" {
  run env LCARS_DOCKER=1 bash "$SRC" --workstation < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"réservé à WSL2"* ]]
  [[ "$output" == *"--box"* ]]
}

@test "--box sans forge : REFUS avant tout build, et les deux voies sont nommees" {
  # La boite ne fabrique pas la forge, elle la consomme. Sans ce refus, 15 min de build finissaient
  # sur une boite qui ne peut rien produire — et le diagnostic arrivait apres la depense.
  run bash "$SRC" --box < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
  [[ "$output" == *"--bench"* ]]
  [[ "$output" != *"étiquetage du jumeau"* ]]   # rien n'a ete construit
}

@test "le preflight de branche vient APRES la question, jamais avant" {
  # ⚠ PROPRIETE D'ORDRE, ET ELLE EST STRUCTURELLE. Sur la branche boite la distro n'est PAS la
  # cible : on n'y pose ni /local, ni groupe, ni wsl.conf. Exiger une distro vierge dans le
  # preflight COMMUN refuserait la machine de travail de quelqu'un qui voulait juste lancer une
  # boite depuis elle — c'est le cas de la machine ou ce rail a ete ecrit.
  local q pf
  q="$(grep -n 'PRÉFLIGHT COMMUN' "$SRC" | head -1 | cut -d: -f1)"
  pf="$(grep -n 'PRÉFLIGHT DE LA BRANCHE' "$SRC" | head -1 | cut -d: -f1)"
  local choice; choice="$(grep -n '─── LE CHOIX' "$SRC" | head -1 | cut -d: -f1)"
  [ "$q" -lt "$choice" ]
  [ "$choice" -lt "$pf" ]
}

@test "la branche BOITE n'escalade JAMAIS en root — c'est la promesse auditee du rail" {
  # « rien hors de ton clone et de docker » : un sudo sur ce chemin la casserait sans rien acheter.
  local box_line sudo_line
  box_line="$(grep -n 'RAIL" == "box"' "$SRC" | head -1 | cut -d: -f1)"
  sudo_line="$(grep -n '^  exec sudo' "$SRC" | head -1 | cut -d: -f1)"
  [ "$box_line" -lt "$sudo_line" ]
  # Et le chemin boite se termine par un exec : il ne retombe pas dans la suite du script.
  grep -q 'exec "$SCRIPT_DIR/docker.sh" up' "$SRC"
}

@test "stdin reste REFUSE — l'arbitrage de l'user, pas une commodite" {
  # ⚖ « si on refuse stdin c'est que ça nous a emmerdé, je paye pas une 2e fois. » Le drapeau sert
  # le cas sans TTY sur un fichier POSE, jamais un pipe.
  run bash -c "cat '$SRC' | bash -s -- --box"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas pipé depuis stdin"* ]]
  [[ "$output" == *"wget -O"* ]]
}
