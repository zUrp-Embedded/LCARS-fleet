#!/usr/bin/env bats
# SOURCE: deploy/tests/install_door.bats
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

# ⚠ SC2016 AU NIVEAU DU FICHIER : ce temoin LIT `install.sh`. Ses motifs portent des `$s`, `$SRC`,
# `$RAIL` qui doivent atteindre `grep`/`sed` TELS QUELS — les developper chercherait la valeur de
# CE shell au lieu du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

load ../refute

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
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"

  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SRC="$REPO/install.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  # Un docker qui repond a tout par 0 : la sonde d'endpoint n'a besoin que de ca.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/docker"
  chmod 0755 "$BINDIR/docker"
  # ⚠ LA SONDE WSL1 MESURE LE NOYAU DE LA MACHINE QUI JOUE LE TEST. `install.sh` refuse un
  # `--substrate wsl` sans user-namespaces (`unshare -Ur true`), et Ubuntu >= 24.04 les refuse aux
  # binaires sans profil AppArmor (`kernel.apparmor_restrict_unprivileged_userns=1`) : bwrap passe,
  # `unshare` non. Le temoin du bandeau force `--substrate wsl` — sur un desktop Ubuntu il
  # rougissait sur la sonde, jamais sur le bandeau (mesure du 2026-08-30, gate de 60-deploy sur un
  # poste neuf). Le decor declare la premisse : des namespaces disponibles.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/unshare"
  chmod 0755 "$BINDIR/unshare"
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
  # Le rail poste ecrit sous /opt/lcars : le garde de cible du provisionnement l'interdit
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
# /local, /opt/lcars/var/tokens, aucun désinstalleur) — pas parce qu'il ne saurait pas y tourner. Sur une
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

@test "le bandeau ne PROMET aucun humain — ce rail n'en cree pas, il pose les autorites" {
  # ⚠ CE TEMOIN A CHANGE DE SENS, ET C'EST LA PREMISSE QUI EST TOMBEE (⚖ user 2026-08-30). Il
  # exigeait que le bandeau annonce « créera l'utilisateur « lcars » » SANS CONDITION, parce que la
  # recette semait ce compte sur tout deploiement — l'arbitrage du 26/08 le justifiait par « le
  # poste/bench c'est pour la DEMO ». Le poste n'est plus un banc : c'est un deploiement de travail,
  # il pose les AUTORITES et les personnes s'inscrivent sur la forge sous leur nom.
  #
  # Ce que le bandeau doit dire reste ce qu'il a toujours du dire : LA VERITE SUR CE QUI VA ARRIVER.
  # Promettre un compte que rien ne creera est la premiere ligne que lit l'operateur, et la premiere
  # qui serait fausse.
  run env LCARS_ALLOW_ANY_HOST=1 bash "$SRC" --substrate linux --workstation --check < /dev/null
  [[ "$output" != *"créera l'utilisateur"* ]]
  [[ "$output" == *"ne crée aucun humain"* ]]
  # ET IL DIT PAR OU ILS ARRIVENT : un refus sans chemin laisse l'operateur devant une fleet muette.
  [[ "$output" == *"inscrivent sur la forge"* ]]
}

@test "AUCUN nom d'humain n'est ecrit dans la porte — elle n'en connait plus" {
  # ⚠ CE TEMOIN EXIGEAIT L'INVERSE, ET SON MOTIF SURVIT INTACT (⚖ user 2026-08-30). Il demandait que
  # le bandeau nomme le compte en INTERROGEANT l'autorite (`builtin-human`) plutot qu'en recopiant un
  # litteral — « celui qu'on ne relit pas gagne le jour ou l'un des deux bouge ». La porte ne nomme
  # plus personne du tout : elle ne cree pas d'humain, et a l'instant ou elle parle il n'y en a
  # peut-etre aucun. Ne rien ecrire satisfait le motif d'origine par le haut.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  # ⚠ `refute`, PAS `!` : la premiere de ces deux assertions n'est pas la derniere ligne du bloc,
  # et POSIX exempte d'`errexit` toute commande niee par `!` — elle etait donc verte au moment
  # precis ou le litteral qu'elle interdit serait revenu.
  refute grep -qE '(^|[^.[:alnum:]_/-])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  # ET ELLE N'INTERROGE PLUS L'AUTORITE : il n'y a plus de nom a demander.
  refute grep -q 'builtin-human' <<<"$code"
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

# ⚠ CE TEMOIN S'APPELAIT « REFUS avant tout build » ET NE FORCAIT JAMAIS L'ABSENCE D'IMAGE.
#
# Il lancait `install.sh --box` sur la machine qui joue la suite. Si `lcars-fleet:2` y est presente
# — le cas sur tout poste de dev — la branche de build n'est jamais prise, et le temoin passait sans
# exercer la propriete qu'il nomme. Mesure du corpus : le controle `FORGE_BASE_URL` etait APRES
# l'`image inspect`, donc sur une machine NEUVE sans image et sans forge, la porte construisait
# plusieurs minutes avant d'annoncer qu'elle ne pouvait rien en faire.
#
# L'arbre factice existait deja dans ce fichier (`_fake_tree <rc-inspect> <rc-delegue>`), et le
# premier argument est exactement ce qu'il fallait : image ABSENTE. Le temoin le prend maintenant.

@test "--box sans forge : REFUS avant tout build, IMAGE ABSENTE — les deux voies sont nommees" {
  local fake; fake="$(_fake_tree 1 0)"
  run bash "$fake/install.sh" --box < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
  [[ "$output" == *"--bench"* ]]
  # LA PROPRIETE : rien n'a ete construit, alors que l'image etait absente.
  refute_out 'DOCKERSH:build' <<<"$output"
}

@test "--box --bench sans forge : PAS de refus — le drapeau dit « fabrique-la moi »" {
  # La seule exception, et elle doit rester : sans elle, `--bench` deviendrait inutilisable.
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench -- --project bt < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"BENCHUP:"* ]]
  refute_out 'FORGE_BASE_URL' <<<"$output"
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
  grep -qE 'exec "\$SCRIPT_DIR/deploy/box" up' "$SRC"
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


@test "REGRESSION — tout ce qui suit « -- » atteint le delegue, VERBATIM" {
  # ⚠ SANS CA, `--bench` ETAIT UNE IMPASSE. Il delegue a `bench-up.sh`, qui a ses propres options
  # (`--project`, `--ssh-port`, `--image`), et le parseur de cette porte refuse ce qu'il ne connait
  # pas : aucune d'elles ne pouvait l'atteindre, donc le delegue n'etait utilisable que dans son cas
  # par defaut — c'est-a-dire une fois par machine. Trouve en rejouant sur une vraie machine, pas en
  # relisant : un trou qui ne se voit qu'a l'usage.
  local fake="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$fake/deploy/docker/bench" "$fake/deploy/lib"
  cp "$SRC" "$fake/install.sh"
  cp "$REPO/deploy/lib/docker-endpoint.sh" "$fake/deploy/lib/"
  cat > "$fake/deploy/docker/bench/bench-up.sh" <<'SPY'
#!/usr/bin/env bash
printf '%s\n' "$#"; printf '[%s]' "$@"; echo
SPY
  chmod 0755 "$fake/deploy/docker/bench/bench-up.sh"
  mkdir -p "$fake/deploy"; touch "$fake/deploy/box"; chmod 0755 "$fake/deploy/box"
  _faux_provision "$fake" "${_faits_sains[@]}"

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
# image, le seul rail qui promet « en un geste » mourait en dictant `deploy/box build`.
#
# Le defaut a survecu a quatre rejeux sur trois machines : sous WSL le daemon est partage par toute
# la VM, donc une distro vierge n'est PAS un docker vierge, et l'image etait toujours deja la.
#
# CE QU'ILS MESURENT EST L'APPEL, JAMAIS LE BUILD : le delegue est un espion. Un temoin qui
# batirait vraiment provisionnerait la machine qui joue la suite.

# ─── LE DECOR POSE LES FAITS, IL NE FABRIQUE PLUS UNE MACHINE ───────────────────────────────────
#
# La porte ne sonde plus rien : elle appelle `deploy/provision doctor --only 00-preflight` et
# lit les faits `nom=valeur` que le module depose. Ces temoins doivent donc fournir ce `provision`.
#
# ⚠ ET C'EST UN GAIN, PAS UNE CONTRAINTE. Pour obtenir « docker absent », il fallait jusqu'ici
# contrefaire une machine — une doublure de CLI, un `DOCKER_HOST` vers /dev/null, une liste de
# sockets vide — et le temoin mesurait alors la fidelite de sa contrefacon autant que la porte. Il
# DECLARE maintenant le fait. Ce qui reste a contrefaire ne l'est plus que pour ce qu'on mesure
# vraiment.
_faux_provision() { # _faux_provision <arbre> [nom=valeur…]
  local arbre="$1"; shift
  mkdir -p "$arbre/deploy"
  { echo '#!/usr/bin/env bash'
    # Sans `PROV_FACTS_FILE` il ne fait rien : c'est la porte qui pose le canal, et un decor qui
    # ecrirait quand meme masquerait une porte qui aurait oublie de le poser.
    echo '[[ -n "${PROV_FACTS_FILE:-}" ]] || exit 0'
    echo 'cat > "$PROV_FACTS_FILE" <<'"'"'FACTS'"'"''
    printf '%s\n' "$@"
    echo 'FACTS'
  } > "$arbre/deploy/provision"
  chmod 0755 "$arbre/deploy/provision"
}

# Les faits d'une machine SAINE — ce qu'un decor pose quand le sujet du temoin est ailleurs.
_faits_sains=(git=oui curl=oui docker=oui docker_bin=/usr/bin/docker substrat=wsl wsl2=oui
              consent=sans-objet wslconf=absent compose=oui sudo=oui)

# Un arbre factice complet : la porte, la sonde reelle, et deux espions a la place des delegues.
# `$1` = code de sortie de `image inspect` (0 presente, 1 absente) · `$2` = celui du delegue.
_fake_tree() {
  local inspect_rc="${1:-0}" dockersh_rc="${2:-0}" fake="$BATS_TEST_TMPDIR/arbre-img"
  rm -rf "$fake"; mkdir -p "$fake/deploy/docker/bench" "$fake/deploy/lib"
  cp "$SRC" "$fake/install.sh"
  cp "$REPO/deploy/lib/docker-endpoint.sh" "$fake/deploy/lib/"
  cat > "$fake/deploy/box" <<SPY
#!/usr/bin/env bash
echo "DOCKERSH:\$*"
exit $dockersh_rc
SPY
  cat > "$fake/deploy/docker/bench/bench-up.sh" <<'SPY'
#!/usr/bin/env bash
echo "BENCHUP:$*"
SPY
  cat > "$BINDIR/docker" <<SPY
#!/usr/bin/env bash
[[ "\$1 \$2" == "image inspect" ]] && exit $inspect_rc
exit 0
SPY
  _faux_provision "$fake" "${_faits_sains[@]}"
  chmod 0755 "$fake/deploy/box" "$fake/deploy/docker/bench/bench-up.sh" "$BINDIR/docker"
  printf '%s' "$fake"
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
  # ⚠ CE TEMOIN LISAIT L'ORTHOGRAPHE DE LA FONCTION (`"$s" == "linux"`), et il est tombe le jour ou
  # la variable a change de nom — sur un comportement rigoureusement identique. C'est une
  # prose-lock : elle epingle la facon d'ecrire, pas la regle. Les trois voisins, eux, EXECUTENT la
  # fonction dans un decor pose ; celui-ci fait pareil desormais, et la double condition se mesure
  # par ses deux moities plutot que par deux motifs de texte.
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    SUBSTRATE=linux
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "oui" ]
  # ET LA DECLARATION EST NECESSAIRE : le meme substrat sans elle ne passe pas.
  run bash -c "
    SUBSTRATE=linux
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}

@test "sans la DECLARATION, docker reste un prerequis — sinon la porte promet ce que 00-preflight refusera" {
  # `LCARS_ALLOW_ANY_HOST` absent : ce provisionnement n'a pas le droit de toucher la machine, donc
  # annoncer qu'il y installera docker serait une promesse non tenue trois lignes plus loin.
  run bash -c "
    SUBSTRATE=linux
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}

@test "declaree ET linux : la porte laisse passer" {
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    SUBSTRATE=linux
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "oui" ]
}

@test "le rail BOITE ne pose JAMAIS docker, meme sur une machine declaree (loi 5)" {
  # Loi 5 (deploy/README.md) : poser un paquet est reserve au rail qui a RECU la machine.
  # La boite est invitee, et aucun drapeau ne change ca.
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    RAIL=box
    SUBSTRATE=linux
    $(sed -n '/^docker_installable_here()/,/^}/p' "$SRC")
    docker_installable_here && echo oui || echo non"
  [ "$output" = "non" ]
}

@test "rail POSTE explicite sur machine declaree : la porte laisse toujours passer" {
  # Le garde ci-dessus ne doit pas fermer le rail qui, lui, a le droit de poser docker.
  run bash -c "
    export LCARS_ALLOW_ANY_HOST=1
    RAIL=workstation
    SUBSTRATE=linux
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




# ─── LE DELEGUE DU RAIL BOITE FAIT PARTIE DU CHECKOUT ───────────────────────────────────────────
#
# ⚠ CETTE PROPRIETE A CHANGE DE MAISON, PAS DE VALEUR. Elle etait tenue par le shim racine, qui
# refusait en nommant le CHECKOUT plutot que docker — « un arbre incomplet, et le dire evite une
# enquete sur docker qui n'y est pour rien ». Le shim a disparu ; la porte porte la garde, donc le
# temoin vit ici. Sans ce deplacement, la propriete serait morte avec le fichier qui la portait.

@test "rail boite : un delegue absent nomme le CHECKOUT, jamais docker" {
  local l_garde l_exec
  l_garde="$(grep -n 'deploy/box" \]\] ||' "$SRC" | head -1 | cut -d: -f1)"
  l_exec="$(grep -n 'exec "\$SCRIPT_DIR/deploy/box" doctor' "$SRC" | head -1 | cut -d: -f1)"
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

# ============ LES DRAPEAUX DE LA PORTE ATTEIGNENT LE RAIL BOITE, OU SONT REFUSES ================
#
# ⚠ CES TEMOINS FERMENT UN AVALEMENT SILENCIEUX, MESURE SUR UNE INSTALL REELLE (2026-08-28).
# `--forge-project`, `--port-forge` et `--port-deck` partent dans `PASSTHRU`, qui n'est lu QUE par
# le rail POSTE — le re-exec sudo et les appels a `provision`. Sur `--box` ils n'atteignaient
# personne : la porte les acceptait, n'imprimait rien, et le delegue tournait sur ses defauts.
#
# `--box --bench --forge-project alice4 --port-forge 21090` a monte un banc sur le projet
# `lcars-nuit` et le port 21000, puis a refuse sur une collision avec un banc de la veille.
# L'operateur decouvre cinq minutes plus tard qu'aucune de ses trois valeurs n'a ete lue.
#
# ET `--help` PROMETTAIT LE GESTE. Il decrit `--forge-project` comme « le geste qui en monte une
# SECONDE au lieu de deplacer celle qui tourne », sans le qualifier de rail. Une porte qui documente
# une option et ne la lit pas ment plus surement qu'une porte qui la refuse.
#
# LA REGLE TENUE ICI : traduire ce qui a un sens pour le delegue, REFUSER le reste, ne jamais avaler.

@test "PORTE->BANC : \`--forge-project\` devient le \`--project\` du delegue" {
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench --forge-project alice4 < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"BENCHUP:--project alice4"* ]]
}

@test "PORTE->BANC : les deux ports aussi, sous les noms du delegue" {
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench --port-forge 21090 --port-deck 21091 < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"--forge-port 21090"* ]]
  [[ "$output" == *"--deck-port 21091"* ]]
}

# ─── L ARITE : UN SEUL DRAPEAU IMPAIR, ET IL DECALAIT TOUT CE QUI SUIT ──────────────────────────
#
# ⚠ LA BOUCLE DE TRADUCTION AVANCAIT DE DEUX EN DEUX. `--disposable` pousse UN seul jeton dans
# `PASSTHRU` — c est le seul —, donc des qu il est present, tous les drapeaux suivants tombent sur
# des index impairs et AUCUN `case` ne les voit. Mesure du 2026-09-01 : `--box --bench --disposable
# --port-ssh 2223 --forge-project alice4` faisait partir `bench-up` avec ZERO argument.
#
# ⚠ ET LE SECOND EFFET EST PIRE QUE LE PREMIER : `--box --disposable --human alice` sortait 0.
# `--human` est un drapeau du rail POSTE que cette boucle doit REFUSER ; decale, il etait avale sans
# un mot. Un drapeau non traduit fait tourner le delegue sur ses defauts ; un drapeau non REFUSE
# fait croire a un geste qui ne se produit pas.

@test "ARITE : \`--disposable\` est IMPAIR, et ce qui le suit est traduit quand meme" {
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench --disposable --port-ssh 2223 --forge-project alice4 < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--ssh-port 2223"* ]] \
    || { echo "le port SSH n a pas ete traduit — la boucle est decalee : $output"; return 1; }
  [[ "$output" == *"--project alice4"* ]] \
    || { echo "le projet n a pas ete traduit — la boucle est decalee : $output"; return 1; }
}

@test "ARITE : un drapeau du rail POSTE reste REFUSE meme derriere \`--disposable\`" {
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --disposable --human alice < /dev/null
  [ "$status" -ne 0 ] \
    || { echo "un drapeau du rail POSTE a ete avale en silence : $output"; return 1; }
  [[ "$output" == *"--human"* ]]
}

@test "ARITE : un drapeau dont l arite n est pas declaree fait RATER la porte, il ne se devine pas" {
  # ⚠ C EST LA MOITIE QUI EMPECHE LE DEFAUT DE REVENIR. Deviner « c est surement une paire » est
  # exactement ce qui l a produit : le prochain drapeau solo ajoute a `PASSTHRU` le reproduirait en
  # silence. On simule cet ajout futur en poussant un drapeau que la table d arite ignore.
  local fake; fake="$(_fake_tree 0 0)"
  # `--substrate` a une arite declaree ; on la retire de la table pour jouer l oubli.
  sed -i 's/    --substrate|--port-forge/    --port-forge/' "$fake/install.sh"
  run bash "$fake/install.sh" --box --bench --substrate docker --forge-project alice4 < /dev/null
  [ "$status" -ne 0 ] \
    || { echo "un drapeau d arite inconnue a ete traverse en silence : $output"; return 1; }
  [[ "$output" == *"arité non déclarée"* ]]
}

@test "PRECEDENCE : ce que l'operateur ecrit APRES \`--\` gagne sur la traduction" {
  # Le delegue lit en dernier-gagne ; la traduction est donc PREPOSEE. Celui qui nomme les deux
  # obtient celui qu'il a ecrit pour le delegue — sinon la porte deciderait a sa place.
  local fake; fake="$(_fake_tree 0 0)"
  run bash "$fake/install.sh" --box --bench --forge-project traduit -- --project explicite < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"--project traduit"* ]]
  [[ "$output" == *"--project explicite"* ]]
  [[ "${output##*--project }" == "explicite"* ]]
}

@test "SANS BANC : \`--forge-project\` passe par l'environnement — l'autre delegue n'a pas de drapeaux" {
  local fake; fake="$(_fake_tree 0 0)"
  cat > "$fake/deploy/box" <<'SPY'
#!/usr/bin/env bash
echo "DOCKERSH:$* LCARS_PROJECT=${LCARS_PROJECT:-<vide>}"
SPY
  chmod 0755 "$fake/deploy/box"
  run env FORGE_BASE_URL=http://forge.test bash "$fake/install.sh" --box --forge-project alice4 < /dev/null
  [[ "$output" == *"LCARS_PROJECT=alice4"* ]]
}

@test "REFUS : un port sans banc est REFUSE, il n'est pas avale" {
  # Sans `--bench`, les ports de la boite sont ceux du compose : il n'y a rien a fixer. Le refus
  # coute une seconde ; l'avalement coutait cinq minutes et une collision.
  local fake; fake="$(_fake_tree 0 0)"
  run env FORGE_BASE_URL=http://forge.test bash "$fake/install.sh" --box --port-forge 21090 < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--port-forge"* ]]
  [[ "$output" == *"compose"* ]]
  # ⚠ `<<<"$output"` : `refute_out` lit STDIN. Sans redirection il herite de celui du test —
  # vide — et passe au vert en n'ayant rien compare. Un mur d'absence prive de sa source felicite.
  refute_out 'DOCKERSH' <<<"$output"
}

@test "REFUS : un drapeau du rail POSTE est REFUSE sur la boite, en le nommant" {
  local fake; fake="$(_fake_tree 0 0)"
  run env FORGE_BASE_URL=http://forge.test bash "$fake/install.sh" --box --only 60-deploy < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--only"* ]]
  [[ "$output" == *"provision"* ]]
  # ⚠ `<<<"$output"` : `refute_out` lit STDIN. Sans redirection il herite de celui du test —
  # vide — et passe au vert en n'ayant rien compare. Un mur d'absence prive de sa source felicite.
  refute_out 'DOCKERSH' <<<"$output"
}

# ─── E2 : LA PORTE DELEGUE LES DEUX RAILS, ELLE N EN EXECUTE AUCUN ──────────────────────────────

@test "VERROU : « --consented » est REFUSE, il ne revient pas en passe-plat muet" {
  # ⚠ MEME REGLE QUE `--fleet-human`, MEME MOTIF. Un drapeau retire doit RATER : accepte et sans
  # effet, il ferait croire a un geste qui ne se produit plus. Celui-ci disait « saute l'accueil et
  # la pause, c'est mon second passage » — une notion qui n'existe QUE si la porte se rejoue
  # elle-meme sous sudo, ce qu'elle ne fait plus depuis que le rail poste a son propre script.
  run bash "$SRC" --consented
  [ "$status" -eq 1 ]
  [[ "$output" == *"--consented"* ]]
  [[ "$output" == *"workstation"* ]]
}

@test "la porte n ESCALADE PLUS, et ne provisionne plus : les deux rails SORTENT par un exec" {
  # ⚠ LE POINT D'E2. Elle faisait DEUX metiers — choisir un rail, et en executer un : escalade sudo,
  # clone sous l'humain, tranche paquets, `provision apply`, verdict, acceptation, identifiants,
  # bandeau de fin. Cent quarante lignes, et le re-exec `--consented` avec.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -q 'exec sudo' <<<"$code"
  refute grep -q 'runuser' <<<"$code"
  refute grep -qE '"\$PROVISION" apply|provision" apply' <<<"$code"
  refute grep -q 'PROV_ANNOUNCE_FILE' <<<"$code"
  # Et les deux sorties ont la MEME forme : un exec vers un delegue du clone.
  grep -q 'exec "$WORKSTATION" up' <<<"$code"
  grep -qE 'exec "\$SCRIPT_DIR/deploy/box"' <<<"$code"
}

@test "le delegue du rail POSTE fait partie du checkout — un absent nomme le CHECKOUT" {
  # Meme propriete que pour la boite : l'erreur nomme sa cause. Un « workstation: command not found »
  # enverrait chercher un binaire, alors que c'est l'arbre qui est incomplet.
  local fake="$BATS_TEST_TMPDIR/sans-delegue"
  rm -rf "$fake"; mkdir -p "$fake/deploy"
  cp "$SRC" "$fake/install.sh"
  _faux_provision "$fake" "${_faits_sains[@]}"
  run bash "$fake/install.sh" --workstation --substrate wsl < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"workstation introuvable"* ]]
  [[ "$output" == *"checkout"* ]]
}

# ─── E3 : LA PORTE EST PIPEABLE, ET C'EST MESURE ────────────────────────────────────────────────
#
# ⚠ DEUX TEMOINS SONT MORTS ICI, ET ILS DISAIENT L'INVERSE DE CEUX-CI. « la porte refuse d'etre
# pipee » et « stdin reste REFUSE » gardaient un arbitrage devenu faux (⚖ user 2026-08-31 : « c'est
# une question technique, pas un choix dogmatique »). Le refus n'achetait que DEUX des cinq griefs du
# pipe — la troncature et la localisation — et les deux ont un meilleur remede. Ce qui suit les
# mesure au lieu de les eviter.

@test "TRONCATURE : une porte pipee et COUPEE ne fait RIEN" {
  # `curl | bash` fait lire le script AU FIL DE L'EAU : un flux coupe laisse bash executer ce qu'il
  # a deja lu. C'etait le grief REEL du pipe, et le seul que le refus achetait vraiment.
  local n; n="$(wc -c < "$SRC")"
  local p c out
  for p in 10 25 50 75 90 95 98 99; do
    c=$(( n * p / 100 ))
    out="$(head -c "$c" "$SRC" | bash -s -- --box 2>&1 | grep -c 'Préflight\|RAIL BOÎTE\|Provisionnement' || true)"
    [ "$out" -eq 0 ] || { echo "FUITE a $p% : $out ligne(s) executee(s)" >&2; return 1; }
  done
}

@test "TRONCATURE : l accolade ferme le trou que « main » seul laisse ouvert" {
  # ⚠ DEUX OCTETS, ET TOUT S'EXECUTE. Une troncature qui tombe exactement sur `main` ou `main ` donne
  # a bash une commande VALIDE sans arguments : il APPELLE la fonction. `curl_bash_2026.md` ecrit
  # « Resolu : la troncature (main(){…} en derniere ligne) » — c'est vrai a ces deux octets pres.
  # `{ main` non fermee, elle, est une erreur de syntaxe, jamais une commande.
  run tail -1 "$SRC"
  [ "$output" = '{ main "$@"; }' ]
  # ET RIEN NE SUIT : une ligne de plus apres l'appel s'executerait sur un flux tronque plus loin.
  local dernier; dernier="$(grep -n '^{ main "\$@"; }$' "$SRC" | cut -d: -f1)"
  local total; total="$(wc -l < "$SRC")"
  [ "$dernier" -eq "$total" ]
}


@test "la version s affiche, et elle marche PIPEE" {
  # Celui qui rapporte un probleme sur une porte qu'il a pipee doit pouvoir dire LAQUELLE. Donc
  # `--version` ne lit pas son propre fichier : il n'y en a pas.
  run bash "$SRC" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  local v="$output"
  run bash -c "cat '$SRC' | bash -s -- --version"
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
}

@test "l aide marche PIPEE aussi — une aide qui exige un fichier est une porte fermee" {
  run bash -c "cat '$SRC' | bash -s -- --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--workstation"* ]]
  [[ "$output" == *"--box"* ]]
}

@test "LA PORTE REFUSE ROOT — « curl | sudo bash » ne peut pas exister" {
  # ⚠ LE REFUSER PAR CONSTRUCTION VAUT MIEUX QUE LE DECONSEILLER. Elle mesure, elle propose, elle
  # delegue : rien de tout cela n'a besoin de privileges. Le sudo est demande par le delegue du rail
  # poste, a SON debut, apres la validation.
  #
  # On ne joue pas la porte en root (ces temoins ne montent jamais) : on mesure la garde et sa
  # position — avant toute mesure, avant tout parsing d'option.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  grep -q 'EUID" -eq 0' <<<"$code"
  local l_garde l_parse
  l_garde="$(grep -n 'EUID" -eq 0' "$SRC" | head -1 | cut -d: -f1)"
  l_parse="$(grep -n '^while \[\[ \$# -gt 0 \]\]' "$SRC" | head -1 | cut -d: -f1)"
  [ "$l_garde" -lt "$l_parse" ]
}

@test "AUCUN code hors fonction : le corps entier vit dans main" {
  # C'est la premisse de tout ce qui precede. Une seule ligne executable au niveau top s'executerait
  # sur un flux coupe n'importe ou apres elle.
  #
  # ⚠ LE CRITERE EST LA POSITION, PAS L'ANALYSE SYNTAXIQUE. Une premiere version comptait les blocs
  # et fermait `main` au premier `}` en colonne 0 — c'est-a-dire a la fin de la PREMIERE fonction
  # definie dedans. Elle accusait du code parfaitement enferme. Le corps de `main` est simplement ce
  # qui vit entre `main() {` et la derniere accolade, celle qui precede l'appel.
  local l_main l_appel total
  l_main="$(grep -n '^main() {$' "$SRC" | head -1 | cut -d: -f1)"
  l_appel="$(grep -n '^{ main "\$@"; }$' "$SRC" | head -1 | cut -d: -f1)"
  total="$(wc -l < "$SRC")"
  [ -n "$l_main" ] && [ -n "$l_appel" ]
  [ "$l_appel" -eq "$total" ]

  # AVANT `main` : rien d'executable. Un `set -e`, une constante, des commentaires — c'est tout.
  run bash -c '
    head -n $(( $2 - 1 )) "$1" | awk "
      /^[[:space:]]*#/ { next } /^[[:space:]]*\$/ { next }
      /^set -euo pipefail\$/ { next } /^LCARS_DOOR_VERSION=/ { next }
      { print NR \": \" \$0 }"' _ "$SRC" "$l_main"
  [ -z "$output" ] || { echo "code executable AVANT main :" >&2; echo "$output" >&2; return 1; }

  # ENTRE la fin de `main` et l'appel : rien non plus.
  run bash -c '
    sed -n "$2,$3p" "$1" | awk "
      /^[[:space:]]*#/ { next } /^[[:space:]]*\$/ { next } /^\}\$/ { next }
      /^\{ main / { next }
      { print \$0 }"' _ "$SRC" "$(( l_appel - 20 ))" "$l_appel"
  [ -z "$output" ] || { echo "code executable ENTRE main et son appel :" >&2; echo "$output" >&2; return 1; }
}

# ─── E3b : L'ORDRE DU CANON, ET LE BILAN QUI EXPOSE ─────────────────────────────────────────────

@test "L ORDRE : accueil -> source -> prefligt -> bilan -> sortie" {
  # ⚠ L'ACCUEIL EST GRATUIT, LE PREFLIGHT NE L'EST PAS. Celui qui a tape la commande doit savoir
  # tout de suite ce qui va se passer, pas regarder un curseur en se demandant s'il a lance une
  # installation. Et la SOURCE precede la mesure parce que le prefligt est un module du depot :
  # pipee, cette porte n'a pas de clone, donc elle en fait un avant de pouvoir mesurer.
  local l_accueil l_source l_pf l_bilan l_sortie
  l_accueil="$(grep -n "1. L'ACCUEIL" "$SRC" | head -1 | cut -d: -f1)"
  l_source="$( grep -n "1b. LA SOURCE" "$SRC" | head -1 | cut -d: -f1)"
  l_pf="$(     grep -n '2. PRÉFLIGHT — UNE SEULE MESURE' "$SRC" | head -1 | cut -d: -f1)"
  l_bilan="$(  grep -n 'LE BILAN — CE QUE LA MACHINE PERMET' "$SRC" | head -1 | cut -d: -f1)"
  l_sortie="$( grep -n 'LA BRANCHE BOÎTE' "$SRC" | head -1 | cut -d: -f1)"
  [ -n "$l_accueil" ] && [ -n "$l_source" ] && [ -n "$l_pf" ] && [ -n "$l_bilan" ] && [ -n "$l_sortie" ]
  [ "$l_accueil" -lt "$l_source" ]
  [ "$l_source"  -lt "$l_pf" ]
  [ "$l_pf"      -lt "$l_bilan" ]
  [ "$l_bilan"   -lt "$l_sortie" ]
}

@test "l accueil sort AVANT la premiere mesure — il ne coute rien, il ne se fait pas attendre" {
  run bash "$SRC" --substrate docker < /dev/null
  local l_accueil l_pf
  l_accueil="$(grep -n 'porte d.entrée' <<<"$output" | head -1 | cut -d: -f1)"
  l_pf="$(grep -n 'Préflight' <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$l_accueil" ] && [ -n "$l_pf" ]
  [ "$l_accueil" -lt "$l_pf" ]
  # Et il dit les DEUX choses que le canon lui demande : le deroule, et les grands prerequis.
  [[ "$output" == *"Le déroulé"* ]]
  [[ "$output" == *"prérequis"* ]]
}

@test "LE BILAN EXPOSE l option impossible, il ne la CACHE pas" {
  # ⚠ LA VERSION D'AVANT CHOISISSAIT EN SILENCE. Sur un linux natif elle posait `RAIL=box` sans rien
  # demander, et elle masquait l'option 2 quand docker manquait : l'ecran ne portait plus la trace de
  # ce qui n'etait pas offert, ni pourquoi. Un menu qui cache une option fait croire qu'elle n'existe
  # pas ; un menu qui la barre EN NOMMANT SON FAIT apprend la machine a celui qui la lit.
  run bash "$SRC" --substrate docker < /dev/null
  [[ "$output" == *"Bilan"* ]]
  # LES DEUX options sont la, numerotees, meme celle qui est impossible.
  [[ "$output" == *"1)"* ]]
  [[ "$output" == *"2)"* ]]
  [[ "$output" == *"IMPOSSIBLE"* ]]
  # Et le bilan porte l'etat mesure, pas une devinette.
  [[ "$output" == *"substrat"* ]]
  [[ "$output" == *"docker"* ]]
}

@test "le REFUS donne la voie qui marche — les deux rails sont des sorties l un pour l autre" {
  # Un refus qui ne dit pas par ou passer laisse quelqu'un devant un mur.
  run bash "$SRC" --substrate docker --workstation < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas possible ici"* ]]
  [[ "$output" == *"wsl --install"* ]]
}

@test "--check s ARRETE au bilan : une sonde ne choisit pas de rail" {
  # Aller plus loin demanderait un rail, donc un choix, donc une mutation.
  run bash "$SRC" --check < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bilan"* ]]
  [[ "$output" == *"workstation doctor"* ]]
  [[ "$output" == *"box doctor"* ]]
}

@test "PIPEE : la porte fait sa SOURCE elle-meme, sous l humain, sans sudo" {
  # ⚠ C'EST LE GESTE VOULU (`curl … | bash`), ET IL VA JUSQU'AU BOUT. L'ancienne porte clonait EN
  # ROOT (`runuser`) apres son escalade : le clone appartenait a root, et `git` le lisait ensuite en
  # « dubious ownership ». Ici il n'y a pas d'escalade du tout.
  #
  # ⚠ PAS DE `< /dev/null` : il ecraserait le pipe, et bash lirait /dev/null comme script. Le `read`
  # de la pause va chercher /dev/tty tout seul, et retombe sur le refus sans TTY.
  local dest="$BATS_TEST_TMPDIR/clone-pipe"
  run bash -c "cat '$SRC' | LCARS_SRC='$dest' bash -s -- --box --repo '$REPO' --branch \$(git -C '$REPO' rev-parse --abbrev-ref HEAD)"
  [[ "$output" == *"source"* ]]
  [ -x "$dest/deploy/provision" ]
  # Le clone appartient a CELUI QUI A LANCE, jamais a root.
  [ -O "$dest" ]
}

# ─── E5 : LES MURS — LE SEDIMENT NE PEUT PLUS REVENIR ───────────────────────────────────────────
#
# ⚠ CES MURS SE POSENT SUR UN ETAT DEJA ATTEINT, et c'est la seule facon honnete de poser un mur.
# Un mur ecrit AVANT le travail qu'il garde est un voeu : il rougit des le premier jour, on le
# desarme « en attendant », et il ne garde plus rien. Chacune de ces proprietes a ete gagnee par E1,
# E2 ou E3 ; ce qui suit les rend irreversibles.

@test "MUR : la porte n ESCALADE pas, ne PROVISIONNE pas, ne se REJOUE pas" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -q 'exec sudo' <<<"$code"
  refute grep -q 'runuser' <<<"$code"
  refute grep -qE '"\$PROVISION" apply' <<<"$code"
  refute grep -q 'useradd' <<<"$code"
  # Et elle ne se relance pas elle-meme : c'etait la source de `--consented`.
  refute grep -qE 'exec .*(BASH_SOURCE|\$0)' <<<"$code"
}

@test "MUR : sa SEULE mesure est l appel au module" {
  # ⚠ UNE SONDE « JUSTE POUR CE CAS-LA » EST EXACTEMENT LA DUPLICATION QU'ON RETIRE. Deux sondes du
  # meme fait derivent, et celle qu'on ne relit pas est celle qui ment le jour ou l'autre change.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -q 'docker_endpoint' <<<"$code"
  refute grep -q 'detect_substrate' <<<"$code"
  # `command -v` survit pour UNE chose : verifier que `git` existe avant de cloner. Ce n'est pas une
  # sonde de l'etat de la machine, c'est la garde d'un appel — et la source precede le preflight,
  # donc aucun fait n'est encore disponible a cet instant.
  [ "$(grep -c 'command -v' <<<"$code")" -eq 1 ]
  grep -q 'command -v git' <<<"$code"
  # Et l'appel au module existe bien, sinon ce mur serait vert a vide.
  grep -q 'doctor --only 00-preflight' <<<"$code"
}

@test "MUR : la porte ne CONTREDIT pas son propre refus de root" {
  # Elle refuse `EUID 0`. Un message qui conseillerait « sudo bash install.sh » enverrait droit dans
  # ce refus — et c'est ce que deux d'entre eux faisaient, herites d'avant la garde.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE 'sudo[^"]*bash \$0' <<<"$code"
  refute grep -q 'sudo bash install' <<<"$code"
}

@test "MUR : aucun NOM d humain, nulle part" {
  # ⚠ LE MOTIF EXCLUT UN POINT DEVANT : `~/.lcars` est un REPERTOIRE, pas le nom d'un compte. Ce rail
  # ne cree aucun humain (canon du 2026-08-30) ; en nommer un serait faire taper a l'operateur une
  # commande qui echoue.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/-])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  refute grep -q 'builtin-human' <<<"$code"
}

@test "MUR : la porte reste une PORTE — plafond de code, pas de lignes" {
  # ⚠ LE PLAFOND PORTE SUR LE CODE, PAS SUR LE FICHIER. La doctrine de ce depot VEUT la prose : la
  # cicatrice vit inline, autonome, et un plafond de lignes brutes ferait choisir entre expliquer et
  # tenir sous la barre. C'est le code qui mesure ce que la porte FAIT.
  #
  # 460 : la mesure du jour est 441 (E4 vient d'en retirer 29 avec le build d'image). La marge est
  # etroite DELIBEREMENT — ce fichier a grossi jusqu'a porter deux rails entiers, et chaque etape du
  # chantier lui en retire. Un plafond large ne garderait rien.
  local n; n="$(grep -vcE '^\s*#|^\s*$' "$SRC")"
  [ "$n" -le 460 ] || {
    echo "la porte a $n lignes de code (plafond 460) — qu'est-ce qui est revenu dedans ?" >&2
    return 1
  }
}

@test "PORTS : les TROIS ports du banc sont passes au delegue, pas deux" {
  # ⚠ MESURE DU 2026-09-01, BANC 2008 : « REFUS : un autre conteneur tient deja un des ports de ce
  # banc · 2222 -> lcars-nuit-lcars-1 ». Le refus est JUSTE — les WSL d une meme machine partagent
  # un daemon docker, donc un seul banc par port — mais la sortie qu il propose (`--ssh-port`)
  # n existait pas a l entree : la porte ne traduisait que `--port-forge` et `--port-deck`.
  #
  # Un refus qui nomme un geste que la porte ne sait pas passer envoie l operateur contre un mur.
  local porte="$BATS_TEST_DIRNAME/../../../install.sh"
  # les trois entrent au parsing
  grep -qE '^\s+--port-forge\|--port-deck\|--port-ssh\)' "$porte"
  # et les trois sont TRADUITS vers les noms du delegue
  local bloc; bloc="$(sed -n '/--port-forge|--port-deck|--port-ssh)/,/esac/p' "$porte" | grep -vE '^\s*#')"
  grep -q -- '--forge-port' <<<"$bloc"
  grep -q -- '--deck-port'  <<<"$bloc"
  grep -q -- '--ssh-port'   <<<"$bloc"
  # et le delegue les connait — sinon on traduit vers un drapeau qui n existe pas
  local bench="$BATS_TEST_DIRNAME/../../docker/bench/bench-up.sh"
  grep -q -- '--ssh-port)' "$bench"
}

@test "PORTS : chacun est traduit vers SON nom, pas vers celui du voisin" {
  # Le `case` remplace un `[[ … ]] && _d=…` a deux branches : avec trois valeurs, la forme courte
  # aurait fait tomber la troisieme dans le defaut — donc `--port-ssh` aurait publie le port de la
  # FORGE, silencieusement, sur le port que l operateur voulait pour SSH.
  local porte="$BATS_TEST_DIRNAME/../../../install.sh"
  local bloc; bloc="$(sed -n '/--port-forge|--port-deck|--port-ssh)/,/esac/p' "$porte")"
  grep -qE '\-\-port-deck\)\s+_d="--deck-port"' <<<"$bloc"
  grep -qE '\-\-port-ssh\)\s+_d="--ssh-port"'   <<<"$bloc"
}
