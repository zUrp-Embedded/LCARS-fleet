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

setup() {
  FLEET_DIR="$BATS_TEST_DIRNAME/../.."
  command -v mix >/dev/null 2>&1 || skip "mix absent de ce poste"
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
