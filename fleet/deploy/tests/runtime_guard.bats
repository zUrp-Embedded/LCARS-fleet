#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/runtime_guard.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for R-no-root-runtime — la reservation du siege cote BEAM (B9)
#
# `00` §6.1 : GUARD B (bin/fleet_v2) refuse une fleet sous l'uid du siege, mais la release est sur
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

setup() {
  FLEET_DIR="$BATS_TEST_DIRNAME/../.."
  command -v mix >/dev/null 2>&1 || skip "mix absent de ce poste"
  # ⚠ LA COUTURE EST LE CHEMIN, PAS LA VALEUR — ET SANS ELLE CES TEMOINS MESURERAIENT LA MACHINE.
  # Depuis le 2026-08-27, GUARD B lit `/etc/lcars/seat.uid` et ce FICHIER GAGNE sur la variable :
  # c'est ce qui empeche le garde de lever sa propre garde. Sur une machine provisionnee, le vrai
  # fichier ecraserait donc le decor de chaque test ci-dessous — verts ici, rouges sur un poste
  # installe, meme arbre. On pointe la couture sur un chemin qui n'existe pas : la variable
  # redevient le levier, et c'est le contrat documente du repli.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
}

@test "R-no-root: l'uid du SIEGE est refuse au boot, avec la phrase GUARD B" {
  run env LCARS_SYSADMIN_UID="$(id -u)" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSADMIN seat"* ]]
  [[ "$output" == *"GUARD B"* ]]
}

@test "R-no-root: un uid worker passe (la garde vise le siege, pas les humains de fleet)" {
  run env LCARS_SYSADMIN_UID="99999" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -eq 0 ]]
}

@test "R-no-root: un compte SYSTEME (uid < UID_MIN) est refuse — le miroir de GUARD B est ENTIER" {
  # fleet_v2 porte DEUX regles (siege + frontiere systeme/humain) ; la v1 du miroir n'en portait
  # qu'une et demie (audit). `id` est double en tete de PATH : la config lit uid=999.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho 999\n' > "$BIN/id"; chmod +x "$BIN/id"
  run env PATH="$BIN:$PATH" LCARS_SYSADMIN_UID="1000" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSTEM account"* ]]
}

@test "R-no-root: LCARS_SYSADMIN_UID posee VIDE ne desarme PAS la garde du siege" {
  run env LCARS_SYSADMIN_UID="" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1" 
  # Notre uid n'est pas 1000 ici ? Si l'uid des tests EST 1000, la garde tire (refus attendu) ;
  # sinon elle passe. Les deux etats sont legitimes — ce qu'on epingle : "" == defaut 1000, donc
  # le MEME comportement qu'avec la variable absente.
  run2=$status
  run bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$run2" -eq "$status" ]]
}

# ─── LA CLEF DE LA GARDE N'EST PLUS DANS L'ENVIRONNEMENT DU GARDE ──────────────────────────────
#
# ⚠ MESURE DU 2026-08-27 : `LCARS_SYSADMIN_UID=99999 fleet_v2 start` desarmait GUARD B, des DEUX
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

@test "GUARD B miroir: un fichier ILLISIBLE n'arme rien de faux — on retombe sur la variable" {
  printf 'pasunuid\n' > "$LCARS_SEAT_UID_FILE"
  run env LCARS_SEAT_UID_FILE="$LCARS_SEAT_UID_FILE" LCARS_SYSADMIN_UID="$(id -u)" \
    bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSADMIN seat"* ]]
}

