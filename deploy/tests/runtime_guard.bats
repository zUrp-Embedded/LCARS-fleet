#!/usr/bin/env bats
# SOURCE: deploy/tests/runtime_guard.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for R-no-root-runtime — la reservation du siege cote BEAM (B9)
#
# `00` §6.1 : GUARD B (bin/fleet) refuse une fleet sous l'uid du siege, mais la release est sur
# le PATH d'admiral et `config/runtime.exs` ne refusait que "0" — le contournement etait a une
# commande. Ces temoins rejouent la VRAIE config (mix run, pas un grep) : la garde doit lever pour
# l'uid du siege, et laisser passer un uid worker. `LCARS_SYSADMIN_UID` est la couture — la meme
# cle que GUARD A/B, jamais un login.
#
# ⚠ Ces temoins exigent mix + le projet compile (comme la suite ExUnit) — ils vivent ici parce que
# la garde est HORS de portee d'ExUnit (`config_env() != :test` la desarme en test, et c'est voulu :
# elle vise les lancements manuels).
# ⚠ COUT ASSUME (audit) : MIX_ENV=dev — sur un checkout CI froid c'est une compilation dev
# complete en plus du budget. Pas de contournement propre : la garde n'existe qu'en dev/prod, et
# un skip conditionnel serait un temoin qui ne mesure rien exactement la ou la CI passe.

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2005 — `echo $(...)` garde la sortie sur UNE ligne, ce que le motif attend
# shellcheck disable=SC2005

setup() {
  FLEET_DIR="$BATS_TEST_DIRNAME/../../runtime"
  command -v mix >/dev/null 2>&1 || skip "mix absent de ce poste"
  # ⚠ LA COUTURE EST LE CHEMIN, PAS LA VALEUR — ET SANS ELLE CES TEMOINS MESURERAIENT LA MACHINE.
  # GUARD B lit `/etc/lcars/seat.uid` et n'a AUCUN repli : le fichier est la seule source. Chaque
  # temoin pose donc le sien, et la couture le deplace hors du poste — sans elle, le vrai fichier
  # d'une machine provisionnee ecraserait le decor de tous les tests ci-dessous.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
}

@test "R-no-root: l'uid du SIEGE est refuse au boot, avec la phrase GUARD B" {
  echo "$(id -u)" > "$LCARS_SEAT_UID_FILE"
  run bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSADMIN seat"* ]]
  [[ "$output" == *"GUARD B"* ]]
}

@test "R-no-root: un uid worker passe (la garde vise le siege, pas les humains de fleet)" {
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  run bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -eq 0 ]]
}

@test "R-no-root: un compte SYSTEME (uid < UID_MIN) est refuse — le miroir de GUARD B est ENTIER" {
  # fleet porte DEUX regles (siege + frontiere systeme/humain) ; la v1 du miroir n'en portait
  # qu'une et demie (audit). `id` est double en tete de PATH : la config lit uid=999.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho 999\n' > "$BIN/id"; chmod +x "$BIN/id"
  echo "1000" > "$LCARS_SEAT_UID_FILE"
  run env PATH="$BIN:$PATH" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSTEM account"* ]]
}

@test "aucun fichier de siege : la garde REFUSE au lieu de deviner, et la variable ne la sauve pas" {
  # Le siege est l'uid de qui a installe LCARS : sur une machine provisionnee il ne peut pas etre
  # vide. Son absence n'est donc pas « siege inconnu » mais « machine non provisionnee » — un etat
  # qu'on nomme. Un defaut y repondrait par un nombre, et `1000` accuserait le lecteur le plus
  # probable : le premier uid humain de toute distro.
  [[ ! -e "$LCARS_SEAT_UID_FILE" ]]
  run env LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"R-no-seat"* ]]
}

# ─── LA CLEF DE LA GARDE N'EST PLUS DANS L'ENVIRONNEMENT DU GARDE ──────────────────────────────
#
# ⚠ MESURE DU 2026-08-27 : `LCARS_SYSADMIN_UID=99999 fleet start` desarmait GUARD B, des DEUX
# cotes. Une garde qui lit sa politique dans l'environnement du processus qu'elle garde ne garde
# rien : cet environnement appartient au garde. Le fichier `root:root` la lui retire — encore
# faut-il qu'il GAGNE, sinon il suffit de reposer la variable.

@test "GUARD B miroir: le FICHIER gagne sur la variable — la dispense ne se pose plus en prefixe" {
  echo "$(id -u)" > "$LCARS_SEAT_UID_FILE"
  run env LCARS_SEAT_UID_FILE="$LCARS_SEAT_UID_FILE" LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSADMIN seat"* ]]
}

@test "GUARD B miroir: le fichier fait AUTORITE aussi quand il innocente — pas seulement quand il accuse" {
  # LE PENDANT, ET SANS LUI LE PRECEDENT NE PROUVE PAS LA PRECEDENCE : une garde qui refuserait
  # TOUJOURS passerait le temoin d'a cote sans lire quoi que ce soit.
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  run env LCARS_SEAT_UID_FILE="$LCARS_SEAT_UID_FILE" LCARS_SYSADMIN_UID="$(id -u)" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -eq 0 ]]
}

@test "GUARD B miroir: un fichier ILLISIBLE se REFUSE, il ne se remplace pas" {
  # Un contenu non numerique est la meme chose qu'une absence : la garde n'a pas etabli le siege.
  # Retomber sur la variable rendrait au garde la clef qu'on vient de lui retirer, et le ferait
  # garder un uid que rien ne designe.
  printf 'pasunuid\n' > "$LCARS_SEAT_UID_FILE"
  run env LCARS_SEAT_UID_FILE="$LCARS_SEAT_UID_FILE" LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"R-no-seat"* ]]
}


# ─── LA BORNE SYSTEME/HUMAIN — MEME REGLE QUE LE SIEGE, ET ELLE N'Y ETAIT PAS ────────────────────
#
# ⚠ GUARD B PORTE DEUX REGLES, ET LA SECONDE LISAIT SA BORNE DANS L'ENVIRONNEMENT DU PROCESSUS
# QU'ELLE GARDE. `config/runtime.exs` faisait `System.get_env("LCARS_UID_MIN", "1000")` : le seul
# site de cette variable dans tout le depot etait sa PROPRE LECTURE — personne ne la posait. Une
# molette qui n'existe que pour etre tournee contre la garde.
#
# C'est exactement le trou ferme le matin meme sur l'autre moitie (`LCARS_SYSADMIN_UID=99999
# fleet start` desarmait la reservation du siege), et la reponse est la meme : la borne est un
# FAIT DE MACHINE — `/etc/login.defs` la DECLARE, `useradd` la lit, et quatre autres lecteurs de ce
# depot la lisent la. Le BEAM etait le cinquieme, et le seul a ne pas la lire.
#
# `PASSWD_DEFS` est la couture des quatre autres : elle deplace le CHEMIN, jamais la valeur.

@test "GUARD B borne: la molette d'environnement ne desarme PLUS la frontiere systeme/humain" {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho 999\n' > "$BIN/id"; chmod +x "$BIN/id"
  echo "1000" > "$LCARS_SEAT_UID_FILE"
  printf 'UID_MIN\t1000\n' > "$BATS_TEST_TMPDIR/login.defs"
  # uid 999 = compte SYSTEME. `LCARS_UID_MIN=0` etait la dispense : elle ne doit plus rien pouvoir.
  run env PATH="$BIN:$PATH" LCARS_UID_MIN=0 PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSTEM account"* ]]
}

@test "GUARD B borne: elle se LIT dans login.defs — un plancher deplace deplace la frontiere" {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho 1500\n' > "$BIN/id"; chmod +x "$BIN/id"
  echo "1000" > "$LCARS_SEAT_UID_FILE"
  # Un administrateur qui pose la frontiere a 2000 fait de l'uid 1500 un compte SYSTEME. La garde
  # doit suivre le systeme, pas une convention gravee.
  printf 'UID_MIN\t2000\n' > "$BATS_TEST_TMPDIR/login.defs"
  run env PATH="$BIN:$PATH" PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSTEM account"* ]]
  [[ "$output" == *"2000"* ]]
}

@test "GUARD B borne: login.defs ILLISIBLE se REFUSE, il ne se remplace pas par 1000" {
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  # Meme doctrine que le fichier de siege : une borne qu'on ne peut pas etablir n'est pas une borne
  # qu'on invente. Un repli sur 1000 rendrait la garde verte sur une machine dont on ignore la
  # frontiere — un succes ambigu la ou un echec explicite est disponible.
  run env PASSWD_DEFS="$BATS_TEST_TMPDIR/aucun-login-defs" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"UID_MIN"* ]]
  [[ "$output" == *"aucun-login-defs"* ]]
}
