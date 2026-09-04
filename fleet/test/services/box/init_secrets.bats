#!/usr/bin/env bats
# SOURCE: fleet/test/services/box/init_secrets.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for box/init.sh secrets — ce que le compose monte sous /run/secrets entre dans le prive de la boite
#
# ⚖ user 2026-09-04 (Q1) : « box config » pose les secrets cote hote ; l'instance les importe au
# boot. Une fois — et a nouveau seulement s'ils changent. Un montage vide n'est pas une faute.

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/box/init.sh"
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  export LCARS_SECRETS_DIR="$BATS_TEST_TMPDIR/run-secrets"; mkdir -p "$LCARS_SECRETS_DIR"
  export PROV_MODULE_TAG=box-init
  # hors root, le proprietaire demande ne peut pas etre pose : le protocole le dit et continue
  export PROV_AUTHORITY_USER="$(id -un)" PROV_FLEET_GROUP="$(id -gn)"
}

@test "secrets : un montage VIDE ne pose rien et ne se plaint pas" {
  run bash "$SUT" secrets
  [ "$status" -eq 0 ]
  [ ! -e "$PROV_TOKENS_DIR/forge-master.token" ]
  [[ "$output" != *"FAIL"* ]]
}

@test "secrets : le jeton master et le seed entrent dans le prive, en 0600" {
  printf 'tok-master\n' > "$LCARS_SECRETS_DIR/forge_master_token"
  printf 's33d\n' > "$LCARS_SECRETS_DIR/forge_seed_password"
  run bash "$SUT" secrets
  [ "$status" -eq 0 ]
  [ "$(cat "$PROV_TOKENS_DIR/forge-master.token")" = tok-master ]
  [ "$(cat "$PROV_TOKENS_DIR/forge-seed.pass")" = s33d ]
  [ "$(stat -c %a "$PROV_TOKENS_DIR/forge-master.token")" = 600 ]
  [[ "$output" == *"POSÉ"*"forge_master_token"* ]]
}

@test "secrets : deja en place = OK, pas de reecriture ; un secret CHANGE se reimporte (rotation)" {
  printf 'tok-1\n' > "$LCARS_SECRETS_DIR/forge_master_token"
  bash "$SUT" secrets >/dev/null
  local before; before="$(stat -c %Y "$PROV_TOKENS_DIR/forge-master.token")"
  run bash "$SUT" secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"deja en place"* ]]
  [[ "$output" != *"POSÉ"* ]]
  printf 'tok-2\n' > "$LCARS_SECRETS_DIR/forge_master_token"
  run bash "$SUT" secrets
  [ "$(cat "$PROV_TOKENS_DIR/forge-master.token")" = tok-2 ]
  [[ "$output" == *"POSÉ"* ]]
}

@test "secrets : l'import precede le siege dans apply — le #1 de la forge se derive du jeton importe" {
  grep -qE '^\s*secrets_import\s*$' <(sed -n '/^cmd_apply()/,/^}/p' "$SUT")
  local order; order="$(sed -n '/^cmd_apply()/,/^}/p' "$SUT" | grep -nE 'secrets_import|seat_resolve' | cut -d: -f1 | tr '\n' ' ')"
  [[ "$order" =~ ^([0-9]+)\ ([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt "${BASH_REMATCH[2]}" ]
}
