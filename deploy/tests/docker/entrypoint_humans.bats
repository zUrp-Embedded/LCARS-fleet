#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/entrypoint_humans.bats
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
# siege — et le bloc la lit lui-meme sur `getent group`.
#
# ⚠ CES TEMOINS EXECUTENT LE BLOC REEL, extrait du fichier. Un temoin de texte epinglerait
# l'orthographe d'un appel ; ce qui compte est ce que le bloc FAIT quand le convergeur echoue,
# quand la sonde derive, et ce qu'il ECRIT pour son lecteur.

load ../refute

setup() {
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  SRC="$BATS_TEST_DIRNAME/../../docker/entrypoint.sh"
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
bloc() { # bloc <rc du convergeur> <sonde : 0 = un humain, 1 = personne>
  # ⚠ LE FAIT SE LIT SUR LA MACHINE (lot 6, 2026-09-04) : un humain de fleet est un membre du groupe
  # `fleet` dont l'uid est au-dessus du plancher et qui n'est pas le siege. Le bloc lisait le fait
  # `fleet_humans=` depose par le doctor de l'INSTALLEUR ; l'installeur ne joue plus au boot. Le
  # decor double donc `getent` (le groupe et ses membres) et `id` (leurs uid) — c'est la mesure.
  local conv_rc="$1" sonde="$2" members="zoe"
  [ "$sonde" -eq 0 ] || members=""
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
    PROV_RC_FILE='$LCARS_PROV_RC_FILE'
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
  # mais ca doit se LIRE, sinon l'operateur cherche pourquoi `fleet_v2 start` refuse.
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
  l_p="$(grep -n 'PROV_RC_FILE'   <<<"$fn" | head -1 | cut -d: -f1)"
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
    PROV_RC_FILE='$LCARS_PROV_RC_FILE'
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
    PROV_RC_FILE='$LCARS_PROV_RC_FILE'
    prov_rc=0
    source '$BLOC'"
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_HUMANS_RC_FILE" ]
  grep -q 'DÉSACTIVÉE' "$JOURNAL"
}
