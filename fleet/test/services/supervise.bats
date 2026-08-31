#!/usr/bin/env bats
# SOURCE: fleet/test/services/supervise.bats
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
#                `box restart`, sur une boite qui reste *healthy* (healthcheck = des ports, ssh + le deck).
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

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2034 — variable posee pour un sous-processus ou lue par un helper, pas par ce fichier
#   SC2086 — eclatement VOULU d'une liste separee par des espaces
# shellcheck disable=SC2034,SC2086

load ../support/refute

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
  refute grep -q 'ABANDON' "$LOG"
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

@test "un reglage qui DESARME la borne est refuse a l'entree" {
  # ⚠ `--interval 0` RENDAIT LA BORNE INOPERANTE, et la boucle tournait sans fin. La purge de la
  # fenetre teste `(( now - t < INTERVAL ))` : avec 0, toujours faux, donc `starts` reste VIDE, donc
  # `>= BURST` n'arrive jamais. Le fichier atteignait par son propre reglage le mode de panne qu'il
  # existe pour empecher. `--delay abc` avait la meme forme en plus doux : `sleep` refusait et la
  # boucle continuait SANS delai.
  local bad
  for bad in "--interval 0" "--burst 0" "--delay abc" "--interval -1" "--grace x"; do
    run timeout 5 "$SUT" --name essai $bad -- true
    [ "$status" -eq 2 ] || { echo "accepte a tort : $bad (status $status)"; return 1; }
  done
}

@test "--grace est LU — un drapeau qui se parse sans effet est pire qu'un drapeau absent" {
  # ⚠ IL ETAIT INERTE. `GRACE` etait pose a cote de la trap qui s'en sert, donc APRES la boucle qui
  # lit `--grace` : le parseur affectait, la ligne suivante ecrasait. On mesure donc l'EFFET, pas la
  # presence du drapeau — un enfant qui ignore TERM doit mourir apres la grace DEMANDEE, pas apres
  # les cinq secondes du defaut.
  "$SUT" --name essai --log "$LOG" --burst 9 --grace 1 -- \
    bash -c "trap '' TERM; echo \$\$ > '$MARQUE'; sleep 30" &
  local sup=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MARQUE" ] && break; sleep 0.3; done
  [ -s "$MARQUE" ] || { echo "TEMOIN INVALIDE : l'enfant n'a jamais demarre"; return 1; }
  local enfant; enfant="$(cat "$MARQUE")"
  local t0="$SECONDS"
  kill -TERM "$sup" 2>/dev/null || true
  wait "$sup" 2>/dev/null || true
  local dt=$(( SECONDS - t0 ))
  if kill -0 "$enfant" 2>/dev/null; then kill -9 "$enfant" 2>/dev/null; echo "ORPHELIN survivant"; return 1; fi
  # Avec le defaut (5 s) inerte, l'arret prendrait ~5 s : on exige la grace DEMANDEE.
  [ "$dt" -le 3 ] || { echo "arret en ${dt}s — la grace demandee (1s) n'a pas ete lue"; return 1; }
  grep -q 'ignore TERM' "$LOG"
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
  # ⚠ `refute`, PAS `! kill`. Mutation du 2026-08-26 : le `kill` retire de `relay()` laissait ce
  # temoin VERT avec l'orphelin bien vivant — bash exempte d'`errexit` toute commande niee par `!`,
  # et l'assertion suivante rattrapait le code. Le detail est dans `refute.bash`.
  refute kill -0 "$enfant"
  # ⚠ ET LE CODE DE SORTIE COMPTE. Ce temoin finissait sur `wait "$sup" || true` : le `|| true`
  # avalait N'IMPORTE QUEL code, et une mutation `exit 0` → `exit 99` sur l'arret propre le laissait
  # VERT. Un arret demande qui rend non-zero fait echouer l'appelant (`box down` sous `set -e`) sur
  # un geste parfaitement reussi.
  local rc=0; wait "$sup" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { echo "arret PROPRE rendu en $rc — un TERM demande n'est pas une panne"; return 1; }
}

@test "l'attente entre deux relances est INTERRUPTIBLE — un box down ne paie pas le delai" {
  # ⚠ `sleep "$DELAY"` NU RETARDE LE SIGNAL DE TOUT SON DELAI : bash n'execute une trap qu'entre
  # deux commandes, donc un TERM recu pendant un `sleep` externe attend sa fin naturelle. Mesure :
  # `--delay 5` faisait mourir le superviseur en 4 s. Avec le defaut de 10 s et trois services
  # supervises, chaque `box down` payait ca.
  "$SUT" --name essai --log "$LOG" --burst 9 --interval 60 --delay 8 -- bash -c 'exit 1' &
  local sup=$! i
  # On attend d'etre DANS l'attente : la premiere ligne « relance dans » le dit.
  for i in 1 2 3 4 5 6 7 8 9 10; do grep -q 'relance dans' "$LOG" 2>/dev/null && break; sleep 0.3; done
  grep -q 'relance dans' "$LOG" || { kill "$sup" 2>/dev/null; echo "TEMOIN INVALIDE : jamais entre en attente"; return 1; }
  local t0="$SECONDS"
  kill -TERM "$sup" 2>/dev/null || true
  wait "$sup" 2>/dev/null || true
  local dt=$(( SECONDS - t0 ))
  [ "$dt" -le 2 ] || { echo "mort en ${dt}s — le signal a attendu la fin du sleep (delai : 8s)"; return 1; }
}
