#!/usr/bin/env bats
# SOURCE: runtime/test/services/box/boot_humans.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for entrypoint.sh — le premier tour synchrone, et le verdict de population
#
# CE QUE CES TEMOINS FERMENT. La boite rendait la main sans savoir si quelqu'un pouvait lancer une
# fleet. Le convergeur d'humains tourne en boucle detachee (`setsid`, poll 30 s) : entre le
# `exec sshd` et sa premiere passe, la boite se declare *healthy* — son healthcheck ne sonde que des ports : ssh + le deck
# — et n'a personne. `box up` lit `/run/lcars-provision.rc`, qui vaut 0 parce qu'il mesure les
# MODULES, pas la population. Il n'avait aucune raison de douter.
#
# ⚠ LE RAIL POSTE AVAIT FERME EXACTEMENT CA LE 2026-08-25, ET PAS CELUI-CI. `64-services` tire le
# convergeur en `--once` synchrone puis mesure la population avant/apres. La boite, elle, lancait la
# boucle et passait a la suite. Le rail qui compte le moins etait donc le mieux verifie des deux.
#
# ⚠ LE FAIT SE LIT SUR LA MACHINE (lot 6, 2026-09-04). L'entrypoint appelait
# `provision doctor --only 64-services` pour lire le fait `fleet_humans=` — l'installeur ne joue plus
# au boot (⚖ user, Q1 : l'image est le produit, le conteneur une instance). La regle est celle de
# `is_fleet_human` du protocole des modules : membre de `fleet`, uid au-dessus du plancher, pas le
# siege — et le bloc APPELLE ce predicat (dans un sous-shell qui source `human-protocol.sh`), il ne
# le recopie pas. Relecture hostile 2026-09-04 (S4) : il en portait une copie, plancher 1000 en
# dur, la ou le protocole lit `UID_MIN` dans login.defs — deux reponses a la meme question des que
# la machine pose un autre plancher. Le decor pose donc un `login.defs` (`PASSWD_DEFS`), et un
# temoin le fait varier.
#
# ⚠ CES TEMOINS EXECUTENT LE BLOC REEL, extrait du fichier. Un temoin de texte epinglerait
# l'orthographe d'un appel ; ce qui compte est ce que le bloc FAIT quand le convergeur echoue,
# quand la sonde derive, et ce qu'il ECRIT pour son lecteur.

load ../../support/refute

setup() {
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  SRC="$BATS_TEST_DIRNAME/../../../services/box/boot.sh"
  [ -f "$SRC" ]

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export LCARS_HUMANS_RC_FILE="$BATS_TEST_TMPDIR/humans.rc"
  export LCARS_HUMAN_CONVERGER="$BATS_TEST_TMPDIR/converger.sh"
  # ⚠ TROISIEME CHEMIN ABSOLU DU BLOC, ET IL A FAIT ECHOUER DEUX TEMOINS AVANT D'ETRE VU. La
  # redirection `>>/var/log/lcars-converger.log` echoue hors conteneur, donc la commande ne tourne
  # meme pas et `first_rc` prend le 1 de la REDIRECTION — le bloc annoncait « NON CONCLUANT (rc=1) »
  # sur un convergeur qui avait rendu 0. Un chemin en dur ne rend pas seulement un bloc intestable :
  # il fabrique un faux verdict des qu'on sort de l'endroit ou il existe.
  export LCARS_CONVERGER_LOG="$BATS_TEST_TMPDIR/converger.log"
  JOURNAL="$BATS_TEST_TMPDIR/journal"

  export LCARS_PROV_RC_FILE="$BATS_TEST_TMPDIR/provision.rc"

  # Le predicat du protocole, et ce qu'il lit : le plancher de la machine (`login.defs` de decor,
  # 1000 par defaut — un temoin le change) et le siege (`LCARS_SYSADMIN_UID`, le fichier est absent).
  export LCARS_HUMAN_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/human-protocol.sh"
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  [ -f "$LCARS_HUMAN_PROTOCOL" ] && [ -f "$LCARS_MODULE_PROTOCOL" ]
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  export LCARS_SYSADMIN_UID=1000

  # ⚠ DEUX MORCEAUX REELS, ET C'EST LEUR CONTRAT QU'ON MESURE. Le bloc de convergence POSE
  # `humans_rc` ; `publier_verdicts` l'ECRIT. Les deux vivaient ensemble jusqu'au 2026-08-26, ou la
  # publication est descendue apres le bloc pour fermer une course avec `box up`. Extraire le seul
  # bloc laisserait le temoin vert sur une publication cassee — et c'est justement la moitie qui
  # avait un defaut.
  BLOC="$BATS_TEST_TMPDIR/bloc.sh"
  {
    sed -n '/^publier_verdicts() {/,/^}/p' "$SRC"
    sed -n '/^CONVERGER_BIN=/,/^# ─── 3bis/p' "$SRC" | sed '$d'
    # Le site d'appel reel est juste apres le bloc, hors des deux plages.
    printf '%s\n' 'publier_verdicts'
  } > "$BLOC"
}

# `say` journalise, `setsid` ne detache RIEN (sinon un daemon survit au temoin), et `$PROVISION`
# est une doublure dont on pilote le verdict.
bloc() { # bloc <rc du convergeur> <sonde : 0 = un humain (zoe, 1001), 1 = personne, 2 = le siege seul (admiral, 1000)>
  # ⚠ LE FAIT SE LIT SUR LA MACHINE (lot 6, 2026-09-04) : un humain de fleet est un membre du groupe
  # `fleet` dont l'uid est au-dessus du plancher et qui n'est pas le siege. Le bloc lisait le fait
  # `fleet_humans=` depose par le doctor de l'INSTALLEUR ; l'installeur ne joue plus au boot. Le
  # decor double donc `getent` (le groupe et ses membres) et `id` (leurs uid) — c'est la mesure.
  local conv_rc="$1" sonde="$2" members="zoe"
  case "$sonde" in 1) members="" ;; 2) members="admiral" ;; esac
  printf '%s\n' '#!/usr/bin/env bash' "exit $conv_rc" > "$LCARS_HUMAN_CONVERGER"
  chmod 0755 "$LCARS_HUMAN_CONVERGER"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == group ]] && { printf "fleet:x:2000:%s\\n" "'"$members"'"; exit 0; }' \
    'exit 2' > "$BIN/getent"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *zoe*) echo 1001 ;; *) echo 1000 ;; esac' > "$BIN/id"
  chmod 0755 "$BIN/getent" "$BIN/id"
  run bash -c "
    set -euo pipefail
    export PATH='$BIN:$PATH'
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    launch() { local n=\"\$1\"; shift 2; printf '%s ACTIF (double)\n' \"\$n\" >> '$JOURNAL'; }
    setsid() { :; }
    LCARS_UID=1000
    LCARS_ADMIRAL=admiral
    MODULE_PROTOCOL='$LCARS_MODULE_PROTOCOL'
    RC_FILE='$LCARS_PROV_RC_FILE'
    prov_rc=0
    source '$BLOC'"
}

@test "le bloc s'extrait, et il n'est pas vide — sinon les temoins suivants ne mesurent rien" {
  # ⚠ GARDE D'INSTRUMENT. Un `sed` qui ne trouve plus ses bornes rend un fichier VIDE, et un bloc
  # vide ne fait rien de mal : les cinq temoins ci-dessous passeraient au vert en n'ayant rien joue.
  [ -s "$BLOC" ]
  grep -q 'CONVERGER_BIN=' "$BLOC"
  grep -q -- '--once' "$BLOC"
  grep -q 'getent group' "$BLOC"
  [ "$(wc -l < "$BLOC")" -ge 20 ]
}

@test "le premier tour est SYNCHRONE — la boucle ne part qu'apres" {
  # C'est toute la correction : `--once` d'abord, `launch` (setsid) ensuite. Un lancement seul rendait la main
  # avant que quiconque existe.
  local once_at loop_at
  once_at="$(grep -n -- '--once' "$BLOC" | head -1 | cut -d: -f1)"
  loop_at="$(grep -n 'launch "convergence des humains"' "$BLOC" | head -1 | cut -d: -f1)"
  [ -n "$once_at" ]
  [ -n "$loop_at" ]
  [ "$once_at" -lt "$loop_at" ]
}

@test "premier tour OK et sonde OK : le verdict publie 0, et il le DIT" {
  bloc 0 0
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = "0" ]
  grep -q 'premier tour fait' "$JOURNAL"
  grep -q 'présent' "$JOURNAL"
}

@test "doctor VERT et PERSONNE : le verdict publie non-zero, et il nomme GUARD B" {
  # Le cas d'une boite de production ou personne ne s'est encore enrole. Ce n'est pas une panne —
  # mais ca doit se LIRE, sinon l'operateur cherche pourquoi `fleet start` refuse.
  # Mesure du 2026-09-04, banc bob_2 : le doctor rendait 0 (l'absence est un WARN), le bloc lisait
  # ce 0 comme « present(s) », et la boite l'annoncait avec le seul siege a bord.
  bloc 0 1
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = "1" ]
  grep -q 'AUCUN humain de fleet' "$JOURNAL"
  grep -q 'GUARD B' "$JOURNAL"
  grep -q 'humans' "$JOURNAL"
}

@test "un premier tour EN ECHEC ne tue pas le boot — la boite doit rester joignable" {
  # Meme regle que tout ce fichier : un echec de convergence n'est jamais fatal, sinon une boite
  # cassee devient une boite qu'on ne peut pas reparer.
  bloc 3 1
  [ "$status" -eq 0 ]
  grep -q 'NON CONCLUANT (rc=3)' "$JOURNAL"
  # Et la boucle part quand meme : le tour suivant reprendra ce qui manque.
  grep -q 'convergence des humains ACTIF' "$JOURNAL"
}

@test "L'ORDRE DE PUBLICATION FERME LA COURSE : provision.rc est ecrit APRES humans.rc" {
  # ⚠ LA VERIFICATION ETAIT INERTE DE L'AUTRE COTE DU TUYAU. `box up` poll `lcars-provision.rc`
  # toutes les 5 s, le trouve, puis lit `lcars-humans.rc` UNE SEULE FOIS. Tant que `provision.rc`
  # s'ecrivait AVANT la passe de convergence — qui dure des dizaines de secondes — `box up` lisait
  # un fichier pas encore ecrit, et affichait « population NON MESUREE » A TOUS LES COUPS, quelle
  # que soit la population reelle. Le lot precedent avait donc ajoute une mesure que son unique
  # lecteur ne pouvait jamais voir.
  #
  # On mesure l'ORDRE, pas la presence : c'est l'ordre qui porte la garantie. `provision.rc` present
  # DOIT impliquer `humans.rc` present.
  bloc 0 0
  [ "$status" -eq 0 ]
  [ -f "$LCARS_HUMANS_RC_FILE" ]
  [ -f "$LCARS_PROV_RC_FILE" ]
  # ⚠ ON NE COMPARE PAS LES MTIME, ET LA PREMIERE VERSION LES CALCULAIT POUR RIEN. Les deux
  # ecritures tombent dans la meme milliseconde : `-nt` ne les separe pas, et `stat %N` n'existe pas
  # partout. L'ordre se lit dans le CORPS de la fonction, qui est la source de la garantie.
  local fn; fn="$(sed -n '/^publier_verdicts() {/,/^}/p' "$SRC")"
  local l_h l_p
  l_h="$(grep -n 'HUMANS_RC_FILE' <<<"$fn" | head -1 | cut -d: -f1)"
  # `RC_FILE` seul : `HUMANS_RC_FILE` le contient — un grep nu prendrait la ligne des humains pour
  # celle du provisionnement et lirait l'ordre a l'envers (vu au lot 8, apres le renommage)
  l_p="$(grep -nE '(^|[^A-Z_])RC_FILE' <<<"$fn" | head -1 | cut -d: -f1)"
  [ -n "$l_h" ] && [ -n "$l_p" ] || { echo "publier_verdicts n'ecrit plus les deux"; return 1; }
  [ "$l_h" -lt "$l_p" ] || { echo "provision.rc ecrit AVANT humans.rc — la course est rouverte"; return 1; }
}

@test "un convergeur PRESENT mais NON EXECUTABLE compte comme absent — pas comme lancable" {
  # ⚠ TEMOIN MUET DEMASQUE PAR MUTATION : remplacer `-x` par `-f` dans la garde laissait tout le
  # corpus VERT. Le decor creait toujours le fichier en 0755, et le seul cas « absent » le
  # SUPPRIMAIT — les deux tests etaient donc faux ensemble, et rien ne distinguait les conditions.
  #
  # En production le cas existe : un `cp` sans `-p`, un montage `noexec`, une archive depliee sans
  # les modes. Avec `-f`, le bloc partirait, `timeout` rendrait 126 (permission denied), et la
  # boucle relancerait indefiniment un fichier qu'elle ne peut pas executer.
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$LCARS_HUMAN_CONVERGER"
  chmod 0644 "$LCARS_HUMAN_CONVERGER"
  run bash -c "
    set -euo pipefail
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    launch() { local n=\"\$1\"; shift 2; printf '%s ACTIF (double)\n' \"\$n\" >> '$JOURNAL'; }
    setsid() { :; }
    PROVISION=/bin/true
    RC_FILE='$LCARS_PROV_RC_FILE'
    prov_rc=0
    source '$BLOC'"
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_HUMANS_RC_FILE" ]
  grep -q 'DÉSACTIVÉE' "$JOURNAL"
  # Et surtout : la passe n'a PAS ete tentee.
  refute grep -q 'premier tour' "$JOURNAL"
}

@test "le convergeur ABSENT : rien n'est publie, et le bloc le dit — pas de verdict invente" {
  # Sans convergeur, la question « qui peut lancer une fleet » n'a pas ete posee. Ecrire 0 ferait
  # dire au fichier « tout va bien » pour une mesure qui n'a pas eu lieu — et son lecteur
  # (`box up`) distingue justement « absent » de « zero ».
  rm -f "$LCARS_HUMAN_CONVERGER"
  run bash -c "
    set -euo pipefail
    say() { printf '%s\n' \"\$*\" >> '$JOURNAL'; }
    # \`launch\` est definie plus haut dans l'entrypoint, hors du bloc extrait — et c'est le sujet
    # d'un AUTRE corpus (\`supervise.bats\`). Ici on double, sinon ces temoins mesureraient deux
    # choses a la fois et rougiraient pour la mauvaise.
    launch() { local n=\"\$1\"; shift 2; printf '%s ACTIF (double)\n' \"\$n\" >> '$JOURNAL'; }
    setsid() { :; }
    PROVISION=/bin/true
    RC_FILE='$LCARS_PROV_RC_FILE'
    prov_rc=0
    source '$BLOC'"
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_HUMANS_RC_FILE" ]
  grep -q 'DÉSACTIVÉE' "$JOURNAL"
}

@test "le SIEGE seul dans le groupe fleet n'est PAS un humain de fleet — humans.rc=1, et le bloc le dit" {
  # Relecture hostile 2026-09-04 : la clause `_u != LCARS_UID` (le correctif d'un defaut mesure sur
  # le banc) n'etait atteinte par aucun cas — la retirer laissait ce fichier vert.
  bloc 0 2
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = 1 ]
  grep -q "AUCUN humain" "$JOURNAL"
}

@test "le plancher est celui de la MACHINE (UID_MIN de login.defs), pas un 1000 en dur" {
  # S4 (relecture hostile 2026-09-04). zoe est a l'uid 1001 : humaine de fleet sur une machine dont
  # login.defs pose UID_MIN 1000, compte SYSTEME sur une machine qui pose 2000. Le bloc recopiait
  # `>= 1000` ; le convergeur lisait login.defs — et les deux repondaient differemment. Ce temoin
  # rougit sur la copie : avec 1000 en dur, zoe passe quel que soit login.defs.
  printf 'UID_MIN\t2000\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  bloc 0 0
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = 1 ]
  grep -q 'AUCUN humain de fleet' "$JOURNAL"
  # Et l'inverse, pour que le temoin ne mesure pas un predicat qui refuse tout : a 1001, zoe passe.
  printf 'UID_MIN\t1001\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  rm -f "$JOURNAL" "$LCARS_HUMANS_RC_FILE"
  bloc 0 0
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = 0 ]
  grep -q 'présent' "$JOURNAL"
}

@test "le bloc APPELLE le predicat du protocole — il ne porte aucune copie de la regle d'uid" {
  # Le mur de S4 : `is_fleet_human` est la seule definition. Un plancher numerique dans ce bloc est
  # un troisieme exemplaire, celui qu'on ne relit pas.
  grep -q 'is_fleet_human' "$BLOC"
  grep -q 'human-protocol.sh' "$BLOC"
  refute grep -qE '(>=|-ge) *[0-9]{3,}' "$BLOC"
}

@test "protocole ABSENT : la population n'est PAS mesuree, humans.rc dit 1, et le bloc nomme le fichier" {
  # Un 0 invente dirait « quelqu'un peut lancer une fleet » sans avoir regarde ; un 1 muet ferait
  # chercher un humain manquant la ou c'est l'image qui est incomplete.
  export LCARS_HUMAN_PROTOCOL="$BATS_TEST_TMPDIR/absent/human-protocol.sh"
  bloc 0 0
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HUMANS_RC_FILE")" = 1 ]
  grep -q 'protocole des humains introuvable' "$JOURNAL"
}

@test "console-humans.sh, le convergeur et le protocole lisent la MEME source pour le plancher (PASSWD_DEFS → login.defs)" {
  # Trois lecteurs, une source : `console-humans.sh` decide qui recoit une console, le protocole qui
  # est humain de fleet, le convergeur qui il cree. Chacun garde sa politique (la console refuse
  # sans bornes lisibles, les deux autres retombent sur 1000), mais le fichier lu — et le nom qui
  # le deplace — est le meme.
  local services="$BATS_TEST_DIRNAME/../../../services"
  grep -q 'PASSWD_DEFS:-/etc/login.defs' "$services/console-humans.sh"
  grep -q 'PASSWD_DEFS:-/etc/login.defs' "$services/lib/human-protocol.sh"
  grep -q 'PASSWD_DEFS:-/etc/login.defs' "$services/human-converger.sh"
}
