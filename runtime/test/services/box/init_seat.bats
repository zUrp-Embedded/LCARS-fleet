#!/usr/bin/env bats
# SOURCE: runtime/test/services/box/init_seat.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for box/init.sh seat — le siege se DERIVE, il ne s'invente pas
#
# Ces temoins vivaient dans `deploy/tests/docker/entrypoint_seat.bats` et jouaient `resolve_admiral`,
# une fonction de l'entrypoint qui sourcait la lib de l'installeur. Lot 6 (⚖ user 2026-09-04, Q1) :
# l'init de l'instance est du PRODUIT, `runtime/services/box/init.sh`, et le siege est son premier
# geste. Les regles n'ont pas bouge : la table fait foi, sinon le #1 de la forge par son ID, sinon
# la semence de l'appelant ; une divergence se REFUSE ; sans rien, on ne fabrique pas de nom.
#
# ⚠ `curl` est une doublure posee en tete de PATH : aucune forge n'est appelee.

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/box/init.sh"
  [ -f "$SUT" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  MAP="$BATS_TEST_TMPDIR/forge-uid.map";  export LCARS_UID_MAP_FILE="$MAP"
  TOKF="$BATS_TEST_TMPDIR/forge-master.token"; export LCARS_MASTER_TOKEN_FILE="$TOKF"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  export LCARS_SEAT_LOGIN_FILE="$BATS_TEST_TMPDIR/run/lcars-seat.login"
  unset LCARS_ADMIRAL FORGE_BASE_URL FORGE_BASE_URL LCARS_UID
  # curl par defaut : un appel est une FAUTE, il se voit
  printf '%s\n' '#!/usr/bin/env bash' 'echo "CURL NE DOIT PAS ETRE APPELE" >&2; exit 99' > "$BIN/curl"
  chmod 0755 "$BIN/curl"
}

forge_answers() { # forge_answers <json> — la forge repond ce json a tout GET
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s' '$1'" > "$BIN/curl"; chmod 0755 "$BIN/curl"
}
seat() { run bash "$SUT" seat; }
seat_login() { cat "$LCARS_SEAT_LOGIN_FILE" 2>/dev/null || true; }

@test "siege : la TABLE du convergeur fait foi — aucune forge n'est interrogee" {
  printf '1\t1000\tzoe\n2\t1001\tbob\n' > "$MAP"
  seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = zoe ]
  [[ "$output" != *"CURL NE DOIT PAS ETRE APPELE"* ]]
}

@test "siege : c'est la ligne forge_id=1, pas la premiere ligne du fichier" {
  printf '7\t1007\tautre\n1\t1000\tzoe\n' > "$MAP"
  seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = zoe ]
}

@test "siege : sans table, il se DERIVE du #1 de la forge — et s'enregistre au format du convergeur" {
  printf 'jeton\n' > "$TOKF"
  export FORGE_BASE_URL="http://forge:3000"
  forge_answers '[{"id":2,"login":"bob"},{"id":1,"login":"lordzurp"}]'
  seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = lordzurp ]
  [ "$(cat "$MAP")" = "$(printf '1\t1000\tlordzurp')" ]
}

@test "siege : le #1 est resolu par son ID, jamais par son rang ni par son nom" {
  printf 'jeton\n' > "$TOKF"
  export FORGE_BASE_URL="http://forge:3000"
  forge_answers '[{"id":7,"login":"admiral"},{"id":1,"login":"renomme"}]'
  seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = renomme ]
}

@test "siege : l'uid part dans un FICHIER, parce que l'export ne traverse pas « exec sshd »" {
  printf '1\t1000\tzoe\n' > "$MAP"
  LCARS_UID=1005 seat
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_SEAT_UID_FILE")" = 1005 ]
}

@test "siege : ni semence, ni table, ni forge → rc 3, jamais un nom invente" {
  seat
  [ "$status" -eq 3 ]
  [[ "$output" == *"IMPOSSIBLE a determiner"* ]]
  [ ! -s "$MAP" ]
  [ ! -e "$LCARS_SEAT_LOGIN_FILE" ]
}

@test "siege : une forge MUETTE refuse aussi — elle ne fabrique pas un nom" {
  printf 'jeton\n' > "$TOKF"
  export FORGE_BASE_URL="http://forge:3000"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 7' > "$BIN/curl"; chmod 0755 "$BIN/curl"
  seat
  [ "$status" -eq 3 ]
  [[ "$output" == *"forge muette"* ]]
  [ ! -e "$LCARS_SEAT_LOGIN_FILE" ]
}

@test "siege : LCARS_ADMIRAL est la SEMENCE du cas from-scratch, et elle s'enregistre" {
  LCARS_ADMIRAL=admiral seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = admiral ]
  [[ "$output" == *"seme par l'appelant"* ]]
  [[ "$output" != *"CURL NE DOIT PAS ETRE APPELE"* ]]
  [ "$(cat "$MAP")" = "$(printf '1\t1000\tadmiral')" ]
}

@test "siege : un nom ENREGISTRE n'est jamais re-ecrit — le home sur le disque fait foi" {
  printf '1\t1000\tancien\n' > "$MAP"
  seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = ancien ]
  [ "$(cat "$MAP")" = "$(printf '1\t1000\tancien')" ]
}

@test "siege : la semence et la TABLE divergent -> REFUS, et le refus nomme les DEUX noms" {
  printf '1\t1000\tzoe\n' > "$MAP"
  LCARS_ADMIRAL=amiral seat
  [ "$status" -eq 1 ]
  [[ "$output" == *"DIVERGENCE"* ]]
  [[ "$output" == *"amiral"* ]]
  [[ "$output" == *"zoe"* ]]
  [ "$(awk -F"\t" '$1 == 1 { print $3 }' "$MAP")" = zoe ]
}

@test "siege : la semence et la table qui S ACCORDENT ne refusent pas" {
  printf '1\t1000\tzoe\n' > "$MAP"
  LCARS_ADMIRAL=zoe seat
  [ "$status" -eq 0 ]
  [ "$(seat_login)" = zoe ]
  [[ "$output" != *"DIVERGENCE"* ]]
}
