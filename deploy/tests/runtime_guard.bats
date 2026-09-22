#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/runtime_guard.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for R-no-root-runtime — le CABLAGE de GUARD B : un lancement réel refuse, et il refuse pour ce motif-là
#
# CE QUI RESTE ICI, ET POURQUOI. Le jugement de GUARD B vit dans `Fleet.BootGuard`, et ses treize
# cas sont des témoins ExUnit (`runtime/test/fleet/boot_guard_test.exs`) : chaque branche y est
# jouée sur des faits injectés, sans démarrer de VM. Ce qu'aucun d'eux ne peut prouver, c'est que
# `config/runtime.exs` APPELLE encore la garde — un module parfait que personne ne branche laisse
# la machine ouverte. Les deux cas ci-dessous lancent donc le vrai boot, et ils vont par paire :
# une garde qui refuserait TOUT passerait le premier sans rien lire.
#
# SC2005 : `echo $(...)` garde la sortie sur une ligne, ce que le motif attend
# shellcheck disable=SC2005

setup() {
  FLEET_DIR="$BATS_TEST_DIRNAME/../../runtime"
  command -v mix >/dev/null 2>&1 || skip "mix absent de ce poste"
  [[ -d "$FLEET_DIR/deps" ]] || skip "dépendances du runtime absentes ($FLEET_DIR/deps) : « cd runtime && mix deps.get »"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
}

@test "câblage : un lancement réel sous l'uid que le fichier nomme siège est REFUSÉ, avec la phrase GUARD B" {
  echo "$(id -u)" > "$LCARS_SEAT_UID_FILE"
  run bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SYSADMIN seat"* ]]
  [[ "$output" == *"GUARD B"* ]]
}

@test "câblage : le même lancement passe quand le fichier nomme un AUTRE siège — la garde lit, elle ne refuse pas par principe" {
  echo "99999" > "$LCARS_SEAT_UID_FILE"
  run bash -c "cd '$FLEET_DIR' && MIX_ENV=dev mix run --no-start -e ':ok' 2>&1"
  [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
