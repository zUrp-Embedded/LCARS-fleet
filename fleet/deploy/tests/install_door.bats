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

load refute

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
  # Le rail poste annonce ce qu'il possede, et que la convergence ne sait pas le retirer.
  [[ "$output" == *"la convergence ajoute et ne retire pas"* ]]
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
  [[ "$output" == *"provision uninstall"* ]]
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
# un UTILISATEUR sur la machine de quelqu'un. L'annoncer dans le bandeau du cout est ce qui la rend
# consentie, et la taire la rendrait subie.
#
# ⚠ ET CE BANDEAU A EU UNE BRANCHE QUI MENTAIT. Tant que `--fleet-human` existait, il annoncait sans
# le drapeau que RIEN ne serait cree — alors que la recette posait quand meme le compte integre sous
# le defaut de `forge-gestures.sh`, et que le convergeur le materialisait vingt rangs plus loin. Le
# bandeau du COUT taisait donc exactement la mutation qu'il existe pour annoncer. Le pre-semis est la
# raison d'etre de ce rail (⚖ USER 2026-08-25 : « livrer out of the box un user fleet enabled »), et
# il se dit maintenant sans condition.

@test "le bandeau annonce le compte SANS CONDITION — il n'y a plus de cas « rien ne sera cree »" {
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"créera l'utilisateur"* ]]
  [[ "$output" != *"Aucun humain de fleet nommé"* ]]
  [[ "$output" != *"rien ne sera créé"* ]]
}

@test "le nom annonce est celui de l'AUTORITE, pas un litteral de ce fichier" {
  # Le bandeau doit nommer le compte que la recette creera vraiment. La seule facon de le savoir est
  # de le DEMANDER : un litteral ici resterait d'accord avec l'autorite jusqu'au jour ou l'un des
  # deux bouge, et c'est celui qu'on ne relit pas qui gagne ce jour-la.
  local attendu
  attendu="$(bash "$REPO/fleet/services/forge-gestures.sh" builtin-human)"
  [ -n "$attendu" ]
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"créera l'utilisateur « $attendu »"* ]]
  # ET LE NOM N'EST PAS GRAVE ICI : la porte interroge le verbe, elle ne recopie pas sa reponse.
  run grep -c 'builtin-human' "$SRC"
  [ "$status" -eq 0 ]
}

@test "VERROU : « --fleet-human » est REFUSE, il ne revient pas en passe-plat muet" {
  # Un drapeau retire doit RATER, pas etre accepte et ignore. La branche BOITE de cette porte le
  # montrait deja : elle parsait `--fleet-human` et n'utilisait jamais `PASSTHRU`, donc l'operateur
  # nommait un compte et repartait sans un mot. Un drapeau mort qu'on accepte est pire que pas de
  # drapeau du tout — il documente une capacite qui n'existe pas.
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --fleet-human vanille --check < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Option inconnue : --fleet-human"* ]]
}

@test "la DERNIERE instruction lue est vraie sur CE terrain — pas celle d'un autre" {
  # Le bandeau de cloture disait « WSL : wsl --shutdown » sur une machine dediee sans WSL, et
  # « fleet_v2 start — ta fleet, sous ton uid » alors que le rail poste fait tourner la fleet sous
  # l'humain de fleet que la forge seme (48) et que le convergeur materialise (64), pas sous
  # l'operateur : GUARD B refuse l'uid du siege, qui est justement le sien sur une machine standard.
  # Un operateur qui suit cette ligne se fait refuser par un garde, sans savoir pourquoi.
  #
  # ⚠ ON MESURE LE TEXTE DU SCRIPT, PAS UNE EXECUTION : atteindre ce bandeau demande un
  # provisionnement complet (paquets, /local, une forge), ce qu'un temoin ne joue pas. Ce qui se
  # garde ici est que les deux formes EXISTENT et sont choisies par le terrain — un bandeau qui
  # redeviendrait inconditionnel le perdrait sans que rien ne rougisse.
  run grep -c 'sudo -u \$_step3_human fleet_v2 start' "$SRC"
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
  refute grep -qE 'apt-get|apt |useradd|usermod|groupadd|chgrp|>[[:space:]]*/etc/|>[[:space:]]*/usr/' <<< "$branche"
  # Et le chemin boite se termine par un exec : il ne retombe pas dans la branche poste.
  # ⚠ CE TEMOIN EPINGLAIT UN NOM DE FICHIER, PAS UNE PROPRIETE. Il cherchait le litteral
  # un litteral d'exec vers un chemin precis — donc il rougissait au renommage du delegue sans qu'aucune
  # regle ne soit cassee, et il serait passe au vert sur un `exec` vers n'importe quoi d'autre. Ce
  # qui se tient est : LA BRANCHE BOITE SE TERMINE PAR UN EXEC VERS LE DELEGUE DU RAIL, donc elle
  # ne retombe jamais dans la branche poste.
  grep -qE 'exec "\$SCRIPT_DIR/fleet/deploy/box" up' "$SRC"
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
  mkdir -p "$fake/fleet/deploy"; touch "$fake/fleet/deploy/box"; chmod 0755 "$fake/fleet/deploy/box"

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
# image, le seul rail qui promet « en un geste » mourait en dictant `fleet/deploy/box build`.
#
# Le defaut a survecu a quatre rejeux sur trois machines : sous WSL le daemon est partage par toute
# la VM, donc une distro vierge n'est PAS un docker vierge, et l'image etait toujours deja la.
#
# CE QU'ILS MESURENT EST L'APPEL, JAMAIS LE BUILD : le delegue est un espion. Un temoin qui
# batirait vraiment provisionnerait la machine qui joue la suite.

# Un arbre factice complet : la porte, la sonde reelle, et deux espions a la place des delegues.
# `$1` = code de sortie de `image inspect` (0 presente, 1 absente) · `$2` = celui du delegue.
_fake_tree() {
  local inspect_rc="${1:-0}" dockersh_rc="${2:-0}" fake="$BATS_TEST_TMPDIR/arbre-img"
  rm -rf "$fake"; mkdir -p "$fake/fleet/deploy/docker/bench" "$fake/fleet/deploy/lib"
  cp "$SRC" "$fake/install.sh"
  cp "$REPO/fleet/deploy/lib/docker-endpoint.sh" "$fake/fleet/deploy/lib/"
  cat > "$fake/fleet/deploy/box" <<SPY
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
  chmod 0755 "$fake/fleet/deploy/box" "$fake/fleet/deploy/docker/bench/bench-up.sh" "$BINDIR/docker"
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
# n'existe pas sur une machine sans Windows — et le module capable de le poser (`10-packages`, le
# depot upstream sur le substrat linux) n'etait JAMAIS atteint.
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

@test "le rail BOITE ne pose JAMAIS docker, meme sur une machine declaree (loi 5)" {
  # Loi 5 (fleet/deploy/README.md) : poser un paquet est reserve au rail qui a RECU la machine.
  # La boite est invitee, et aucun drapeau ne change ca.
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    RAIL=box
    FORCED_SUBSTRATE=linux
    detect_substrate() { echo linux; }
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}

@test "rail POSTE explicite sur machine declaree : la porte laisse toujours passer" {
  # Le garde ci-dessus ne doit pas fermer le rail qui, lui, a le droit de poser docker.
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    RAIL=workstation
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

@test "le rail POSTE ne batit AUCUNE image — le seul build de la porte est celui de la BOITE" {
  # ⚖ USER 2026-08-22 : « tu build une image complete de 1,2 Go juste pour executer 100 ko de
  # recette tofu ? ». La porte bâtissait `lcars-fleet:2` sur le rail poste sous le motif « la forge
  # du poste en a besoin (tofu, recette, gestes) » — dix minutes pour en extraire 124 Mo d'outil
  # dans un conteneur jetable, sur un rail qui ne DEMARRE jamais cette image.
  #
  # ⚠ CE TEMOIN A GRAVE LA VALEUR CONTRAIRE, et c'est pour ca qu'il est reecrit et pas supprime. Il
  # verifiait « les paquets sont joues AVANT le build quand c'est le rail qui pose docker » — une
  # regle d'ordre reelle, mais adossee a un build qui n'existe plus. La dependance qu'elle denouait
  # (docker avant ce qui en a besoin) est desormais portee par la NUMEROTATION des modules :
  # `10-packages` pose docker, `48-forge-host` monte la Gitea, et 10 < 48 par construction.
  #
  # Ce qui reste a verrouiller est donc l'inverse : qu'aucun build ne reapparaisse sur ce rail.
  local box ws
  # le build de la BOITE survit — la, l'image EST le produit livre
  box="$(grep -c 'SCRIPT_DIR/fleet/deploy/box" build' "$SRC")"
  [ "$box" -ge 1 ]
  # celui du rail poste, non : ni son invocation, ni la racine qu'il derivait
  ws="$(grep -c '_wroot/fleet/deploy/box" build' "$SRC" || true)"
  [ "$ws" -eq 0 ]
  refute grep -q '_wimg' "$SRC"
  # et le motif mort n'est pas reste en prose : un lecteur le lirait comme vrai au present
  ! grep -q 'la forge du poste en a besoin' "$SRC"
}

@test "la tranche paquets ne se joue QUE si docker manque ET que le rail peut le poser" {
  # Sur une machine qui a deja docker, rejouer trois modules avant le build serait du bruit ; sur
  # une machine non declaree, ce serait une promesse que 00-preflight refusera.
  run bash -c "sed -n '/LES PAQUETS AVANT LE BUILD/,/^fi$/p' '$SRC'"
  [[ "$output" == *"command -v"* ]]
  [[ "$output" == *"docker_installable_here"* ]]
}

@test "la sonde docker est REJOUEE apres l'installation — sinon le build lit une reponse perimee" {
  run bash -c "sed -n '/LES PAQUETS AVANT LE BUILD/,/^fi$/p' '$SRC'"
  [[ "$output" == *"docker_endpoint"* ]]
}

# ─── LE DELEGUE DU RAIL BOITE FAIT PARTIE DU CHECKOUT ───────────────────────────────────────────
#
# ⚠ CETTE PROPRIETE A CHANGE DE MAISON, PAS DE VALEUR. Elle etait tenue par le shim racine, qui
# refusait en nommant le CHECKOUT plutot que docker — « un arbre incomplet, et le dire evite une
# enquete sur docker qui n'y est pour rien ». Le shim a disparu ; la porte porte la garde, donc le
# temoin vit ici. Sans ce deplacement, la propriete serait morte avec le fichier qui la portait.

@test "rail boite : un delegue absent nomme le CHECKOUT, jamais docker" {
  local l_garde l_exec
  l_garde="$(grep -n 'fleet/deploy/box" \]\] ||' "$SRC" | head -1 | cut -d: -f1)"
  l_exec="$(grep -n 'exec "\$SCRIPT_DIR/fleet/deploy/box" doctor' "$SRC" | head -1 | cut -d: -f1)"
  [ -n "$l_garde" ] && [ -n "$l_exec" ]
  # La garde vient AVANT tout exec : refuser apres avoir tente est un diagnostic sur le mauvais objet.
  [ "$l_garde" -lt "$l_exec" ]
  # Et elle nomme l'arbre, pas le daemon.
  local msg; msg="$(sed -n "$((l_garde+1))p" "$SRC")"
  [[ "$msg" == *"checkout complet"* ]]
  [[ "$msg" != *"daemon"* ]]
}

@test "le bandeau dit COMMENT on revient en arriere, et ce n'est pas le meme geste des deux cotes" {
  # La convergence ajoute et ne retire pas : le bandeau nomme le point de restauration que ça
  # suppose. Il existe par construction sous WSL, l'opérateur l'apporte ailleurs — une ligne unique
  # dirait donc le mauvais geste sur l'un des deux terrains.
  run bash "$SRC" --substrate wsl --workstation --check < /dev/null
  [[ "$output" == *"la convergence AJOUTE, elle ne retire pas"* ]]
  [[ "$output" == *"wsl --unregister"* ]]
  [[ "$output" != *"Aucun désinstalleur n'existe"* ]]

  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"la convergence AJOUTE, elle ne retire pas"* ]]
  [[ "$output" == *"snapshot ou image"* ]]
  [[ "$output" != *"wsl --unregister"* ]]
}

@test "les cartouches ne portent plus de bordure comptee a la main" {
  # La bordure droite se dérive du contenu ; les seules occurrences de `│…│` sont les formats de
  # printf du rendu. On mesure la SOURCE : la longueur d'une chaîne bash compte des octets hors
  # UTF-8, donc un témoin qui compterait des colonnes rougirait selon la locale de la machine.
  run bash -c "grep -n '│.*│' '$SRC' | grep -vc printf"
  [ "$output" = "0" ]
  # Et les deux bandeaux passent bien par le rendu mesuré, pas par un heredoc.
  run grep -c '^  _box_emit ' "$SRC"
  [ "$output" = "2" ]
}

@test "le bandeau ne promet pas la fleet sous l'uid de l'operateur — GUARD B la lui refuse" {
  # GUARD B (`config/runtime.exs`, miroir de `bin/fleet_v2`) refuse uid 0, l'uid du siege
  # (`LCARS_SYSADMIN_UID`, defaut 1000) et les comptes systeme : une fleet sous le siege donnerait
  # des pods sudo-capables. Le siege pose la machine, l'humain de fleet fait tourner la fleet.
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" == *"RAIL POSTE"* ]]
  [[ "$output" == *"sous l'humain de fleet"* ]]
  [[ "$output" != *"la fleet sous TON uid"* ]]
}
