#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/sudoers_toolchain.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for 45-sudoers-toolchain — le cablage systeme du rail toolchain
#
# CE QUE CES TEMOINS TIENNENT, en trois familles :
#   - le SUDOERS : un binaire nomme, pose par write_atomic, REFUSE si visudo dit non — un
#     sudoers.d invalide casse TOUT sudo, pas seulement celui-ci ;
#   - la PROJECTION du siege : keyee sur l'UID (jamais un nom), inconditionnelle (un login qui
#     change ecrase l'ancien), gardee sur le magasin (var vide => AUCUNE ecriture — sinon
#     `/state/pilot.assignee` naitrait a la racine, jamais lu) ;
#   - le module est charge SANS son dispatch, patron `human_git_identity.bats`.

setup() {
  SRC="$BATS_TEST_DIRNAME/../modules.d/45-sudoers-toolchain.sh"
  [ -f "$SRC" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=45-sudoers-toolchain
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"   # un chgrp qui marche sous l'uid des tests

  export LCARS_SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"; mkdir -p "$LCARS_SUDOERS_DIR"
  export LCARS_TOOLCHAIN_RUN_STATE="$BATS_TEST_TMPDIR/run-state"
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store"; mkdir -p "$LCARS_STORE_ROOT"
  # Le siege des tests, c'est NOUS : la cle est l'uid, on la fait coincider.
  export LCARS_SYSADMIN_UID="$(id -u)"

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

run_apply() { run bash -c ". '$MOD'; apply"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SRC"; grep -q "^# AUTHOR:" "$SRC"
  grep -q "^# STARDATE:" "$SRC"; grep -q "^# STATUS:" "$SRC"
}

@test "sudoers: pose, contenu exact, mode 0440" {
  run_apply
  [[ "$status" -eq 0 ]]
  local f="$LCARS_SUDOERS_DIR/lcars-toolchain"
  [[ -f "$f" ]]
  grep -qx "%$PROV_FLEET_GROUP ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge" "$f"
  [[ "$(stat -c %a "$f")" == "440" ]]
}

@test "sudoers: un contenu refuse par visudo N'EST PAS pose" {
  # visudo double en tete de PATH : refuse tout. Si le module posait quand meme, sudo entier
  # serait casse en prod — c'est le temoin de l'ordre valide-PUIS-pose.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/visudo"; chmod +x "$BIN/visudo"
  run_apply
  [[ "$status" -ne 0 ]]
  [[ ! -f "$LCARS_SUDOERS_DIR/lcars-toolchain" ]]
}

@test "sudoers: PAS de redirection en place — le fichier ne transite jamais par un etat partiel" {
  # write_atomic = tmp + rename. Le temoin : AUCUN artefact temporaire ne survit dans sudoers.d.
  run_apply
  [[ "$status" -eq 0 ]]
  [[ -z "$(find "$LCARS_SUDOERS_DIR" -name '.prov.*' -o -name '*.tmp' | head -1)" ]]
}

@test "etat conteneur: le repertoire du marqueur existe en 2775" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ -d "$LCARS_TOOLCHAIN_RUN_STATE" ]]
  [[ "$(stat -c %a "$LCARS_TOOLCHAIN_RUN_STATE")" == "2775" ]]
}

@test "projection: le login du siege atterrit dans pilot.assignee" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/pilot.assignee")" == "$PROV_HUMAN" ]]
}

@test "projection: REECRITURE inconditionnelle — un login mort ne survit pas au boot suivant" {
  mkdir -p "$LCARS_STORE_ROOT/state"
  printf 'ancien-login\n' > "$LCARS_STORE_ROOT/state/pilot.assignee"
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/pilot.assignee")" == "$PROV_HUMAN" ]]
}

@test "projection: KEYEE SUR L'UID — un humain qui n'est pas le siege n'ecrit RIEN" {
  export LCARS_SYSADMIN_UID="99999"   # personne
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/pilot.assignee" ]]
}

@test "projection: LCARS_STORE_ROOT vide => AUCUNE ecriture, nulle part" {
  # Sans la garde, bash etend en /state/pilot.assignee : cree a la racine par root en prod,
  # jamais lu par personne — le mode de panne de 02 §3.1.
  export LCARS_STORE_ROOT=""
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "/state/pilot.assignee" ]]
  [[ "$output" == *"inerte"* ]]
}

@test "projection: magasin non monte (var posee, dossier absent) => inerte, dit, rc 0" {
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/nulle-part"
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"inerte"* ]]
}

@test "check: drift quand le sudoers manque, OK quand tout est pose" {
  run bash -c ". '$MOD'; check"
  [[ "$output" == *"DRIFT"* ]]
  run_apply
  run bash -c ". '$MOD'; check"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"sudoers etroit absent"* ]]
}
