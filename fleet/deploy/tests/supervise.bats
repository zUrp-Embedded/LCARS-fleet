#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/supervise.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for services/supervise.sh — la relance, et surtout SA BORNE
#
# CE QUE CE CORPUS FERME. Mesure du 2026-08-26, comparaison des deux rails :
#
#   rail poste   `64-services` pose des unites systemd : `Restart=always`, `RestartSec=10`,
#                `StartLimitBurst=5`, `StartLimitIntervalSec=60`. Un service qui tombe revient.
#   rail boite   `entrypoint.sh` lancait `setsid <cmd> &`. tini est PID 1 et RECOLTE les orphelins ;
#                il n'en relance aucun. Un convergeur mort restait mort jusqu'au prochain
#                `box restart`, sur une boite qui reste *healthy* (healthcheck = port 22).
#
# Le rail poste testait donc des politiques de redemarrage que la PRODUCTION n'avait pas, et la
# production avait un mode de panne que rien ne testait.
#
# ⚠ LA BORNE EST LA MOITIE QUI COMPTE. Relancer est facile ; relancer SANS BORNE transforme un
# service qui echoue instantanement (fichier absent, port pris) en boucle a 100 % d'un coeur qui
# remplit le disque de journaux. C'est ce que `StartLimitBurst` existe pour empecher, et c'est la
# moitie qu'une premiere version oublie toujours.
#
# ⚠ ET CES TEMOINS EXECUTENT LE VRAI SCRIPT, avec de vraies commandes qui meurent. Un temoin de
# texte epinglerait la presence d'une boucle `while` ; ce qui compte est ce qui se passe au
# cinquieme echec, et si le processus s'arrete VRAIMENT.

setup() {
  SUT="$BATS_TEST_DIRNAME/../../services/supervise.sh"
  [ -f "$SUT" ]
  [ -x "$SUT" ]
  LOG="$BATS_TEST_TMPDIR/sup.log"
  MARQUE="$BATS_TEST_TMPDIR/marque"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -6 "$SUT"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "sans --name ou sans commande : refus TYPE, pas une boucle qui tourne dans le vide" {
  run "$SUT" -- true
  [ "$status" -eq 2 ]
  run "$SUT" --name x --
  [ "$status" -eq 2 ]
}

@test "IL RELANCE — c'est le fait que le rail boite n'avait pas" {
  # La commande compte ses propres passages. Trois lignes = elle a bien ete rejouee.
  run timeout 20 "$SUT" --name essai --log "$LOG" --burst 3 --interval 60 --delay 0 -- \
    bash -c "echo passage >> '$MARQUE'; exit 1"
  [ -f "$MARQUE" ]
  [ "$(wc -l < "$MARQUE")" -eq 3 ]
}

@test "IL S'ARRETE — la borne mord, et le processus SORT (il ne boucle pas en silence)" {
  # ⚠ LE TEMOIN QUI COMPTE. Sans borne, ce `timeout 20` serait la seule chose qui arrete le script,
  # et le temoin serait vert en ayant mesure... le timeout. On exige donc que le script sorte de
  # LUI-MEME, avec un code non nul, bien avant la limite.
  run timeout 20 "$SUT" --name essai --log "$LOG" --burst 3 --interval 60 --delay 0 -- \
    bash -c 'exit 1'
  [ "$status" -eq 1 ]         # 124 serait le timeout : ce serait un ABANDON qui n'a pas eu lieu
  grep -q 'ABANDON' "$LOG"
  grep -q 'borne : 3' "$LOG"
}

@test "la borne est une FENETRE GLISSANTE, pas un compteur qui n'oublie jamais" {
  # ⚠ UN COMPTEUR NU EST LA MAUVAISE IMPLEMENTATION EVIDENTE. Un service qui tombe une fois par jour
  # finirait par atteindre la borne au bout d'une semaine — donc par abandonner sur une machine
  # parfaitement saine, et de la maniere la plus difficile a diagnostiquer qui soit.
  #
  # Fenetre d'UNE seconde et delai d'une seconde : chaque relance sort de la fenetre precedente,
  # donc la borne n'est jamais atteinte et c'est le `timeout` qui arrete — 124, ici ATTENDU.
  run timeout 8 "$SUT" --name essai --log "$LOG" --burst 2 --interval 1 --delay 1 -- \
    bash -c "echo passage >> '$MARQUE'; exit 1"
  [ "$status" -eq 124 ]
  ! grep -q 'ABANDON' "$LOG"
  # Et il a bien relance plus que la borne : c'est ce que « glissante » veut dire.
  [ "$(wc -l < "$MARQUE")" -gt 2 ]
}

@test "les arguments de la commande TRAVERSENT — un service se lance avec ses drapeaux" {
  # `human-converger.sh` est lance nu, mais l'executeur de catalogue passe par `setpriv --reuid …`,
  # donc la commande supervisee porte des arguments. Les perdre lancerait le mauvais processus.
  run timeout 20 "$SUT" --name essai --log "$LOG" --burst 1 --interval 60 --delay 0 -- \
    bash -c "printf '%s\n' \"\$@\" >> '$MARQUE'; exit 0" _ un deux trois
  grep -qx 'un' "$MARQUE"
  grep -qx 'deux' "$MARQUE"
  grep -qx 'trois' "$MARQUE"
}

@test "un rc 0 est une mort comme une autre — ces services sont des BOUCLES" {
  # `Restart=always` de systemd dit la meme chose : un convergeur qui « se termine proprement » a
  # quand meme cesse de converger. Distinguer 0 des autres ferait taire exactement le cas ou un
  # service sort en 0 sur une erreur qu'il a mal classee.
  run timeout 20 "$SUT" --name essai --log "$LOG" --burst 2 --interval 60 --delay 0 -- true
  [ "$status" -eq 1 ]
  grep -q 'sorti (rc=0)' "$LOG"
  grep -q 'ABANDON' "$LOG"
}

@test "TERM se propage a l'enfant — sinon un « box down » laisse un orphelin" {
  # Le superviseur est le PARENT. Sans propagation, il meurt et son enfant reste, rattache a PID 1,
  # hors de portee de tout ce qui pourrait l'arreter ensuite.
  "$SUT" --name essai --log "$LOG" --burst 9 --interval 60 --delay 0 -- \
    bash -c "echo \$\$ > '$MARQUE'; sleep 30" &
  local sup=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MARQUE" ] && break; sleep 0.3; done
  [ -s "$MARQUE" ]
  local enfant; enfant="$(cat "$MARQUE")"
  kill -TERM "$sup" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$enfant" 2>/dev/null || break; sleep 0.3; done
  ! kill -0 "$enfant" 2>/dev/null
  wait "$sup" 2>/dev/null || true
}
