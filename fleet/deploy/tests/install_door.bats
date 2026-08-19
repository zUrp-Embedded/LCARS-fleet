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
  # ⚠ LA DOUBLURE SE DÉCLARE, elle ne se glisse plus dans le PATH en espérant être prise. Sur WSL la
  # sonde préfère DÉLIBÉRÉMENT la CLI du montage Docker Desktop : il n'y a pas de « binaire docker »
  # dans une distro, seulement un montage, et un `docker` du PATH y est une copie que quelqu'un a
  # posée. Un test qui compte sur l'ordre du PATH mesure donc la machine qui le joue.
  # `PROV_DOCKER_BIN` est le choix de l'appelant et il l'emporte sur tout — c'est la couture prévue.
  export PROV_DOCKER_BIN="$BINDIR/docker"
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
  # ⚠ CE TEMOIN NE PEUT PAS TOURNER HORS WSL, ET IL LE DIT AU LIEU DE ROUGIR. La question n'existe
  # que la ou les DEUX rails sont possibles — c'est-a-dire WSL. Dans le conteneur du gate CI, le
  # substrat est `docker` : aucune question n'est posee, donc rien a mesurer. Un `skip` bats est
  # BRUYANT (« ok N # skip … ») : il dit ce qui n'a pas tourne, ce qu'un rouge ne dirait pas mieux
  # et qu'un vert cacherait. Mesure du 2026-08-19 : ces deux temoins passaient sur trois machines
  # WSL et rougissaient en CI, pour une raison qui n'a rien a voir avec ce qu'ils epinglent.
  [[ "$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo autre)" == "wsl" ]] \
    || skip "la question n'est posee que sur WSL — ce substrat n'a qu'un rail possible"
  # Le coeur du dessin. Un defaut silencieux ici choisit a la place de quelqu'un entre « on te prend
  # /etc » et « on te construit 3 Go » — les deux erreurs qu'aucune valeur par defaut ne repare.
  run bash "$SRC" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas de défaut sûr"* ]]
  [[ "$output" == *"--workstation"* ]]
  [[ "$output" == *"--box"* ]]
}

@test "la question DIT ce que chaque branche PREND — le cout est dans la question, pas apres" {
  # ⚠ CE TEMOIN NE PEUT PAS TOURNER HORS WSL, ET IL LE DIT AU LIEU DE ROUGIR. La question n'existe
  # que la ou les DEUX rails sont possibles — c'est-a-dire WSL. Dans le conteneur du gate CI, le
  # substrat est `docker` : aucune question n'est posee, donc rien a mesurer. Un `skip` bats est
  # BRUYANT (« ok N # skip … ») : il dit ce qui n'a pas tourne, ce qu'un rouge ne dirait pas mieux
  # et qu'un vert cacherait. Mesure du 2026-08-19 : ces deux temoins passaient sur trois machines
  # WSL et rougissaient en CI, pour une raison qui n'a rien a voir avec ce qu'ils epinglent.
  [[ "$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo autre)" == "wsl" ]] \
    || skip "la question n'est posee que sur WSL — ce substrat n'a qu'un rail possible"
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

@test "la branche BOITE ne POSE rien sur le systeme — c'est ca, la promesse auditee" {
  # ⚠ CE TEMOIN EPINGLAIT « n'escalade JAMAIS en root », ET C'ETAIT LE MAUVAIS INVARIANT. L'audit de
  # Mintie (11 h) porte sur ce que le rail MODIFIE — « rien hors de ton clone et de docker » — pas
  # sur l'uid qui appelle. Les confondre a fait pire que de se tromper de mot : le rail ne pouvait
  # pas joindre une socket appartenant a root, donc la demo ne tenait que par un `sudo` pose A LA
  # MAIN, hors du code, par celui qui l'ecrivait. Un temoin qui interdit le correctif protege le
  # contournement.
  #
  # ⚖ USER : « si l'installeur promet "jamais sudo" et ne peut pas faire son job parce qu'il faut
  # sudo, la seule conclusion logique c'est que l'installeur a besoin de sudo. »
  #
  # Ce qui est epingle desormais est ce qui est reellement promis, et c'est verifiable : aucune
  # commande de pose systeme sur le chemin boite.
  local box_start ws_start branche
  box_start="$(grep -n 'RAIL" == "box"' "$SRC" | head -1 | cut -d: -f1)"
  ws_start="$(grep -n 'LA BRANCHE POSTE' "$SRC" | head -1 | cut -d: -f1)"
  branche="$(sed -n "${box_start},${ws_start}p" "$SRC")"
  # Ni paquet, ni utilisateur, ni groupe, ni ecriture dans /etc ou /usr.
  ! grep -qE 'apt-get|apt |useradd|usermod|groupadd|chgrp|>[[:space:]]*/etc/|>[[:space:]]*/usr/' <<< "$branche"
  # Et le chemin boite se termine par un exec : il ne retombe pas dans la branche poste.
  grep -q 'exec "$SCRIPT_DIR/docker.sh" up' "$SRC"
}

@test "l'escalade pour JOINDRE le daemon est ANNONCEE avant la pause, jamais decouverte" {
  # Le cout s'annonce, il ne se decouvre pas — meme regle que le reste du bandeau. Un sudo qui
  # surgit apres le consentement transforme une promesse bornee en surprise.
  grep -q 'sudo sera demandé pour PARLER au daemon docker' "$SRC"
  local annonce pause
  annonce="$(grep -n 'sudo sera demandé' "$SRC" | head -1 | cut -d: -f1)"
  pause="$(grep -n 'read -r _ < /dev/tty' "$SRC" | head -1 | cut -d: -f1)"
  [ "$annonce" -lt "$pause" ]
}

@test "stdin reste REFUSE — l'arbitrage de l'user, pas une commodite" {
  # ⚖ « si on refuse stdin c'est que ça nous a emmerdé, je paye pas une 2e fois. » Le drapeau sert
  # le cas sans TTY sur un fichier POSE, jamais un pipe.
  run bash -c "cat '$SRC' | bash -s -- --box"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas pipé depuis stdin"* ]]
  [[ "$output" == *"wget -O"* ]]
}

@test "REGRESSION — tout ce qui suit « -- » atteint le delegue, VERBATIM" {
  # ⚠ SANS CA, `--bench` ETAIT UNE IMPASSE. Il delegue a `bench-up.sh`, qui a ses propres options
  # (`--project`, `--ssh-port`, `--image`), et le parseur de cette porte refuse ce qu'il ne connait
  # pas : aucune d'elles ne pouvait l'atteindre, donc le delegue n'etait utilisable que dans son cas
  # par defaut — c'est-a-dire une fois par machine. Trouve en rejouant sur une vraie machine, pas en
  # relisant : un trou qui ne se voit qu'a l'usage.
  local fake="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$fake/fleet/deploy/docker/bench" "$fake/fleet/deploy/lib"
  cp "$SRC" "$fake/install.sh"
  cp "$REPO/fleet/deploy/lib/docker-endpoint.sh" "$fake/fleet/deploy/lib/"
  cat > "$fake/fleet/deploy/docker/bench/bench-up.sh" <<'SPY'
#!/usr/bin/env bash
printf '%s\n' "$#"; printf '[%s]' "$@"; echo
SPY
  chmod 0755 "$fake/fleet/deploy/docker/bench/bench-up.sh"
  touch "$fake/docker.sh"; chmod 0755 "$fake/docker.sh"

  run bash "$fake/install.sh" --box --bench -- --project bt --ssh-port 2299 < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"4"* ]]
  [[ "$output" == *'[--project][bt][--ssh-port][2299]'* ]]
}

@test "sans « -- », une option inconnue est REFUSEE — jamais avalee en silence" {
  # Le pendant du temoin precedent : la porte ne doit pas gober une option qu'elle ne comprend pas
  # en esperant qu'un delegue s'en arrange. Un drapeau mal orthographie doit se voir tout de suite.
  run bash "$SRC" --box --projet-avec-une-faute < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Option inconnue"* ]]
}

@test "un drapeau sans objet sur sa branche est REFUSE, jamais avale en silence" {
  # ⚠ `--bench` FOURNIT les annexes a une BOITE. Le rail poste monte sa propre forge par
  # `48-forge-host`, dans son cycle de convergence : le drapeau n'y a aucun objet. Il etait accepte
  # par le parseur et lu NULLE PART sur cette branche — donc silencieusement avale, ce qui laisse
  # quelqu'un croire qu'il a demande quelque chose. C'est la meme classe que tout ce que ce fichier
  # epingle : un vert, ou un depart, qui ne dit pas ce qui n'a pas eu lieu.
  run env LCARS_DOCKER=1 bash "$SRC" --workstation --bench < /dev/null
  [ "$status" -ne 0 ]
  # Hors WSL c'est le garde de substrat qui parle en premier ; l'un ou l'autre refuse, jamais aucun.
  [[ "$output" == *"n'a pas d'objet sur le rail poste"* ]] || [[ "$output" == *"réservé à WSL2"* ]]
}
