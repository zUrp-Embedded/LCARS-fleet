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
  # ⚠ LE DECOR POSSEDE L'ENVIRONNEMENT, PAS SEULEMENT LE PATH — ET CE FICHIER L'A APPRIS EN SE
  # TROMPANT LUI-MEME. Le 2026-08-21, le temoin « SANS le drapeau, linux natif refuse » est tombe
  # ROUGE pendant une install a froid : le gate tourne DANS `provision apply`, qui tourne DANS
  # `install.sh`, qui exporte `LCARS_ALLOW_ANY_HOST=1` a travers son escalade sudo. La porte
  # acceptait donc, correctement, et le temoin mesurait l'intention de l'operateur au lieu du code.
  #
  # C'est la meme faute que celle corrigee le matin meme dans `provision_runner.bats`, re-ecrite le
  # soir dans un fichier voisin. La regle qui la ferme : un temoin qui juge ce qu'un script fait
  # d'un environnement DONNE doit POSER cet environnement, jamais l'heriter — et il efface la
  # FAMILLE, pas les noms qu'il connait, sinon le prochain drapeau rouvre le trou en silence.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

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

# ─── LA MACHINE DÉDIÉE — LE REFUS EST UN GARDE-FOU, PAS UNE INCAPACITÉ ──────────────────────────
# Le rail poste est refusé hors WSL parce qu'il POSSÈDE la machine (paquets, groupe système,
# /local, /home/private, aucun désinstalleur) — pas parce qu'il ne saurait pas y tourner. Sur une
# machine DÉDIÉE, c'est exactement l'installation qu'on veut.
#
# ⚠ CE DRAPEAU EXISTAIT DÉJÀ, ET IL ÉTAIT INATTEIGNABLE PAR LA PORTE. `00-preflight` lit
# `LCARS_ALLOW_ANY_HOST` depuis toujours ; la porte, elle, refusait AVANT que le rail n'ait la
# chance de le lire. Il ne servait donc qu'à qui appelait `provision` à la main — et c'est ce qui
# s'est passé le 2026-08-20 : une install native jouée geste par geste à côté du rail, parce que la
# porte disait non. Un drapeau qu'on ne peut pas atteindre par la porte est un drapeau qui n'existe
# pas.

@test "machine dédiée: SANS le drapeau, linux natif refuse ET NOMME le drapeau" {
  # Le refus doit rester le défaut — c'est lui qui protège la machine de quelqu'un. Ce qu'il ne
  # doit plus faire, c'est laisser croire que le natif est hors d'atteinte.
  run bash "$SRC" --substrate linux --workstation < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"réservé à WSL2"* ]]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST=1"* ]]
  [[ "$output" == *"DÉDIÉE"* ]]
}

@test "machine dédiée: AVEC le drapeau, la porte laisse passer et DIT ce que ça prend" {
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"déclaré DÉDIÉ"* ]]
  [[ "$output" == *"AUCUN désinstalleur"* ]]
  # Elle est passée : le bandeau du rail poste est imprimé, donc le garde de substrat est franchi.
  [[ "$output" == *"RAIL POSTE"* ]]
  [[ "$output" != *"réservé à WSL2"* ]]
}

@test "machine dédiée: le drapeau SURVIT à l'escalade sudo" {
  # `sudo` remet l'environnement à zéro. Sans ce drapeau dans la liste nommée, la porte le lit,
  # décide de laisser passer, escalade — et la SECONDE instance ne le voit plus, donc se refuse
  # elle-même en invitant à poser le drapeau qu'on vient de poser. Refus parfaitement circulaire, et
  # rien dans la sortie ne dit que sudo est passé entre les deux.
  run grep -n 'for _v in ' "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST"* ]]
}

@test "machine dédiée: le drapeau n'ouvre PAS le rail poste dans un conteneur" {
  # Installer le rail poste DANS une boîte n'a pas de sens : c'est le rail boîte qui fait ça, au
  # build de l'image. Aucun drapeau ne rend ça vrai, et un drapeau qui ouvrirait tout serait un
  # interrupteur général déguisé en garde-fou.
  run env LCARS_ALLOW_ANY_HOST=1 LCARS_DOCKER=1 bash "$SRC" --workstation < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"réservé à WSL2"* ]]
}

# ─── LE COMPTE SE DIT AVANT D'EXISTER ───────────────────────────────────────────────────────────
# ⚖ USER 2026-08-21 : « on cree pas un user sur une machine nue. dans docker c'est sans gravite, la
# ca demande au moins une validation user. » C'est la SEULE mutation de ce rail qui fait apparaitre
# un UTILISATEUR sur la machine de quelqu'un. Nommer le compte EST la validation ; l'annoncer dans
# le bandeau du cout est ce qui la rend consentie, et la taire la rendrait subie.

@test "sans --fleet-human : la porte annonce que RIEN ne sera cree, et donne le geste" {
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"Aucun humain de fleet nommé"* ]]
  [[ "$output" == *"rien ne sera créé"* ]]
  [[ "$output" == *"--fleet-human"* ]]
}

@test "avec --fleet-human : le compte est NOMME dans le bandeau, avant d'exister" {
  # Le nom n'est pas un detail : sur ce parc les humains s'appellent `vanille`, `bob`, `alice`.
  # Un defaut cable (`lcars`) ferait apparaitre un utilisateur que personne n'a demande.
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --fleet-human vanille --check < /dev/null
  [[ "$output" == *"créera l'utilisateur « vanille »"* ]]
  [[ "$output" != *"Aucun humain de fleet nommé"* ]]
}

@test "le nom voyage jusqu'au rail — la porte le lit ET le transmet" {
  # Lu ici pour le bandeau, transmis au rail pour l'acte. Le lire sans le transmettre annoncerait
  # une creation qui n'aurait pas lieu ; le transmettre sans le lire creerait un compte que le
  # bandeau n'a pas annonce. Les deux moities sont la meme promesse.
  run grep -c 'PASSTHRU+=("\$1" "\$2"); shift 2 ;;' "$SRC"
  [ "$status" -eq 0 ]
  run grep -A1 -- '--fleet-human) FLEET_HUMAN=' "$SRC"
  [[ "$output" == *"PASSTHRU+="* ]]
}

@test "la DERNIERE instruction lue est vraie sur CE terrain — pas celle d'un autre" {
  # Le bandeau de cloture disait « WSL : wsl --shutdown » sur une machine dediee sans WSL, et
  # « fleet_v2 start — ta fleet, sous ton uid » alors que le rail poste fait tourner la fleet sous
  # l'humain de fleet (22-fleet-human), pas sous l'operateur : GUARD B refuse l'uid du siege, qui
  # est justement le sien sur une machine standard. Un operateur qui suit cette ligne se fait
  # refuser par un garde, sans savoir pourquoi.
  #
  # ⚠ ON MESURE LE TEXTE DU SCRIPT, PAS UNE EXECUTION : atteindre ce bandeau demande un
  # provisionnement complet (paquets, /local, une forge), ce qu'un temoin ne joue pas. Ce qui se
  # garde ici est que les deux formes EXISTENT et sont choisies par le terrain — un bandeau qui
  # redeviendrait inconditionnel le perdrait sans que rien ne rougisse.
  run grep -c 'sudo -u \$FLEET_HUMAN fleet_v2 start' "$SRC"
  [ "$output" = "1" ]
  run grep -c "Rien à redémarrer : ce terrain n'a pas de WSL" "$SRC"
  [ "$output" = "1" ]
  # Et la forme « sous ton uid » n'est plus inconditionnelle : elle vit dans la branche boite.
  run grep -c 'RAIL" == "workstation" \]\]; then' "$SRC"
  [ "$status" -eq 0 ]
}

@test "machine dédiée: le bandeau n'annonce PAS /etc/wsl.conf là où rien ne le touche" {
  # `30-wsl` porte `APPLY-ON: wsl`. Promettre une destruction qui n'aura pas lieu est du même ordre
  # qu'en taire une qui aura lieu : dans les deux cas l'opérateur consent à autre chose.
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"RAIL POSTE"* ]]
  [[ "$output" != *"/etc/wsl.conf"* ]]
}

@test "--substrate vaut pour la PORTE, pas seulement pour le rail" {
  # Il était en passe-plat pur : la porte détectait son substrat, décidait dessus, puis remettait au
  # rail un `--substrate` qui pouvait dire l'inverse. Deux étages, deux terrains, un seul geste.
  run bash "$SRC" --substrate n-importe-quoi --workstation < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"inconnu"* ]]
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

# ============ L'IMAGE : LA PRECONDITION QUE LA PORTE FOURNIT, ET QUI N'ETAIT PAS COUVERTE ========
#
# ⚠ CES TROIS TEMOINS EXISTENT PARCE QUE LEUR ABSENCE A COUTE UNE JOURNEE. L'en-tete de ce fichier
# dit qu'aucun temoin ne traverse, « le chemin boite par un build de 15 min » — vrai, et c'est
# justement pour ca que le chemin `--bench` n'a jamais ete joue SANS IMAGE. Il `exec`utait son
# delegue avant d'atteindre le build, qui ne vivait que sur l'autre chemin ; sur une machine sans
# image, le seul rail qui promet « en un geste » mourait en dictant `./docker.sh build`.
#
# Le defaut a survecu a quatre rejeux sur trois machines : sous WSL le daemon est partage par toute
# la VM, donc une distro vierge n'est PAS un docker vierge, et l'image etait toujours deja la.
#
# CE QU'ILS MESURENT EST L'APPEL, JAMAIS LE BUILD : `docker.sh` est un espion. Un temoin qui
# batirait vraiment provisionnerait la machine qui joue la suite.

# Un arbre factice complet : la porte, la sonde reelle, et deux espions a la place des delegues.
# `$1` = code de sortie de `image inspect` (0 presente, 1 absente) · `$2` = celui de `docker.sh`.
_fake_tree() {
  local inspect_rc="${1:-0}" dockersh_rc="${2:-0}" fake="$BATS_TEST_TMPDIR/arbre-img"
  rm -rf "$fake"; mkdir -p "$fake/fleet/deploy/docker/bench" "$fake/fleet/deploy/lib"
  cp "$SRC" "$fake/install.sh"
  cp "$REPO/fleet/deploy/lib/docker-endpoint.sh" "$fake/fleet/deploy/lib/"
  cat > "$fake/docker.sh" <<SPY
#!/usr/bin/env bash
echo "DOCKERSH:\$*"
exit $dockersh_rc
SPY
  cat > "$fake/fleet/deploy/docker/bench/bench-up.sh" <<'SPY'
#!/usr/bin/env bash
echo "BENCHUP:$*"
SPY
  cat > "$BINDIR/docker" <<SPY
#!/usr/bin/env bash
[[ "\$1 \$2" == "image inspect" ]] && exit $inspect_rc
exit 0
SPY
  chmod 0755 "$fake/docker.sh" "$fake/fleet/deploy/docker/bench/bench-up.sh" "$BINDIR/docker"
  printf '%s' "$fake"
}

@test "image ABSENTE : la porte la construit AVANT de deleguer — la promesse « en un geste » tient" {
  local fake; fake="$(_fake_tree 1 0)"
  run bash "$fake/install.sh" --box --bench -- --project bt < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKERSH:build"* ]]
  [[ "$output" == *"BENCHUP:--project bt"* ]]
  # L'ORDRE PORTE LE SENS : deleguer avant de batir, c'est le defaut qu'on ferme.
  [[ "${output%%BENCHUP*}" == *"DOCKERSH:build"* ]]
}

@test "image PRESENTE : aucun build — un re-run reste court, sinon --check coute un quart d'heure" {
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench -- --project bt < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"DOCKERSH:build"* ]]
  [[ "$output" == *"BENCHUP:--project bt"* ]]
}

@test "build EN ECHEC : la porte s'arrete, et le delegue n'est JAMAIS atteint" {
  local fake; fake="$(_fake_tree 1 1)"
  run bash "$fake/install.sh" --box --bench -- --project bt < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"DOCKERSH:build"* ]]
  # Un banc monte sur une image qu'on n'a pas pu batir serait un vert sur du vide.
  [[ "$output" != *"BENCHUP:"* ]]
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

# ─── UN MANQUE QUE LA SUITE COMBLE N'EST PAS UN PREREQUIS ───────────────────────────────────────
#
# MESURE DU 2026-08-21, Ubuntu 26.04 fraiche, passe a froid : la porte s'arretait sur « aucune CLI
# docker : ni dans le PATH, ni dans le montage Docker Desktop » — en renvoyant vers un montage qui
# n'existe pas sur une machine sans Windows — et le module capable de le poser (`10-packages`,
# `docker.io` sur le substrat linux) n'etait JAMAIS atteint.
#
# Le motif d'origine du refus, ⚖ « ça, on refuse. docker-desktop c'est un clic », parle de WSL, ou
# Docker Desktop EST un clic et ou rien ici ne peut l'installer. Les deux regles coexistent : c'est
# le substrat qui les separe, exactement comme dans `10-packages`.

@test "la porte ne refuse plus docker sur un LINUX NATIF DECLARE — le rail le pose" {
  grep -q 'docker_installable_here' "$SRC"
  # la condition est double : substrat linux ET machine declaree dediee
  run bash -c "sed -n '/^docker_installable_here()/,/^}/p' "$SRC""
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST"* ]]
  [[ "$output" == *'"$s" == "linux"'* ]]
}

@test "sans la DECLARATION, docker reste un prerequis — sinon la porte promet ce que 00-preflight refusera" {
  # `LCARS_ALLOW_ANY_HOST` absent : ce provisionnement n'a pas le droit de toucher la machine, donc
  # annoncer qu'il y installera docker serait une promesse non tenue trois lignes plus loin.
  run bash -c "
    FORCED_SUBSTRATE=linux
    detect_substrate() { echo linux; }
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}

@test "declaree ET linux : la porte laisse passer" {
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    FORCED_SUBSTRATE=linux
    detect_substrate() { echo linux; }
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "oui" ]
}

@test "declaree mais WSL : docker reste un prerequis — rien ici n'installe Docker Desktop" {
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    FORCED_SUBSTRATE=wsl
    detect_substrate() { echo wsl; }
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}
