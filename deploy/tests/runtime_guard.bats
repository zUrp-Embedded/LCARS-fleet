#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/runtime_guard.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for R-no-root-runtime — la reservation du siege cote BEAM (B9)

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2005 — `echo $(...)` garde la sortie sur UNE ligne, ce que le motif attend
# shellcheck disable=SC2005

setup() {
  FLEET_DIR="$BATS_TEST_DIRNAME/../../runtime"
  command -v mix >/dev/null 2>&1 || skip "mix absent de ce poste"
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
  [[ ! -e "$LCARS_SEAT_UID_FILE" ]]
  run env LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"R-no-seat"* ]]
}


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
  printf 'pasunuid\n' > "$LCARS_SEAT_UID_FILE"
  run env LCARS_SEAT_UID_FILE="$LCARS_SEAT_UID_FILE" LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"R-no-seat"* ]]
}



@test "GUARD B borne: la molette d'environnement ne desarme PLUS la frontiere systeme/humain" {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho 999\n' > "$BIN/id"; chmod +x "$BIN/id"
  echo "1000" > "$LCARS_SEAT_UID_FILE"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"
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
  printf 'UID_MIN\t2000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"
  run env PATH="$BIN:$PATH" PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSTEM account"* ]]
  [[ "$output" == *"2000"* ]]
}

@test "GUARD B borne: login.defs ILLISIBLE se REFUSE, il ne se remplace pas par 1000" {
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  run env PASSWD_DEFS="$BATS_TEST_TMPDIR/aucun-login-defs" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"UID_MIN"* ]]
  [[ "$output" == *"aucun-login-defs"* ]]
}
