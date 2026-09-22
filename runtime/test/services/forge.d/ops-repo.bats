#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/ops-repo.bats
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: temoins de forge.d/ops-repo.sh — l'APPELANT MINCE de la porte du release
#
# CE QUE CES TEMOINS TIENNENT. La MESURE vit desormais dans le release
# (`Fleet.Application.OpsRepo`, temoins en ExUnit) ; ce fichier n'en tient plus la logique, il tient
# ce qui reste au shell et que rien d'autre ne tiendrait :
#   · les gardes AVANT la porte — sans elles, l'appelant paierait un eval pour rien et rendrait une
#     plainte du BEAM la ou l'operateur attend une phrase ;
#   · le RELAI de chaque gravite dans le dialecte du protocole, et le verdict qui en decoule ;
#   · les deux refus d'une porte qui ne mesure pas : muette, ou en echec ;
#   · le jeton qui part par l'ENVIRONNEMENT et jamais par l'argv.

# shellcheck disable=SC2016,SC2030,SC2031

load ../../support/refute

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../../services/forge.d/ops-repo.sh"
  [ -f "$MODULE" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=65-ops-repo
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$LCARS_PRIVATE_DIR"
  export LCARS_SYSTEM_TOKEN_FILE="$LCARS_PRIVATE_DIR/system_starfleet.gitea_token"
  printf 'SYS-TOKEN\n' > "$LCARS_SYSTEM_TOKEN_FILE"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export LCARS_CLI="$BATS_TEST_TMPDIR/lcars"
  unset LCARS_OPS_REPO
}

# stub_porte <code de sortie> <ce que la porte imprime sur stdout> [plainte sur stderr]
# Note l'argv complet et la presence du jeton dans l'environnement, pour que les temoins mesurent
# COMMENT la porte est appelee et pas seulement ce qu'elle rend.
stub_porte() {
  cat > "$LCARS_CLI" <<EOF
#!/usr/bin/env bash
printf 'ARGV:%s\n' "\$*" >> "$CALLS"
printf 'ENVTOK:%s\n' "\${FORGE_TOKEN:-}" >> "$CALLS"
printf 'ENVURL:%s\n' "\${FORGE_BASE_URL:-}" >> "$CALLS"
printf '%s' '${3:-}' >&2
printf '%s' '$2'
exit ${1}
EOF
  chmod +x "$LCARS_CLI"
}

CONFORME='ok	lcars/_ops : dépôt, branches tool_request et incidents, protection de tool_request'

@test "conforme : la phrase de la porte est relayée en OK, et les deux verbes rendent 0" {
  stub_porte 0 "$CONFORME"
  run bash "$MODULE" check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    65-ops-repo: lcars/_ops : dépôt, branches tool_request et incidents"* ]]

  run bash "$MODULE" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    65-ops-repo: lcars/_ops : dépôt"* ]]
}

@test "un DRIFT : check rend 1, apply rend 2 — les deux dialectes du meme constat" {
  stub_porte 0 'drift	lcars/_ops:tool_request ABSENTE — ; la recette le pose'
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 65-ops-repo: lcars/_ops:tool_request ABSENTE"* ]]

  run bash "$MODULE" apply
  [ "$status" -eq 2 ]
}

@test "un ECHEC : check rend 2, apply rend 1" {
  stub_porte 0 'fail	lcars/_ops : la forge ne dit pas s'"'"'il existe — rien n'"'"'est conclu'
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  65-ops-repo: lcars/_ops : la forge ne dit pas"* ]]

  run bash "$MODULE" apply
  [ "$status" -eq 1 ]
}

@test "plusieurs constats : chacun est relayé, et l'ECHEC gagne sur le DRIFT" {
  stub_porte 0 'drift	une branche manque
fail	une protection est illisible'
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 65-ops-repo: une branche manque"* ]]
  [[ "$output" == *"FAIL  65-ops-repo: une protection est illisible"* ]]
}

# ⚠ LE SILENCE SE LIRAIT COMME UNE CONFORMITE : une porte qui ne rend rien n'a rien mesuré.
@test "porte MUETTE : ECHEC nommé, jamais un vert" {
  stub_porte 0 ''
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"AUCUNE mesure rendue"* ]]
}

@test "porte en ECHEC : le code et sa plainte sont dits, et rien n'est conclu" {
  stub_porte 3 '' 'Authority: jeton refusé par la forge'
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"porte ops-repo en échec (code 3)"* ]]
  [[ "$output" == *"jeton refusé par la forge"* ]]
  [[ "$output" == *"rien n'est conclu"* ]]
}

@test "ligne ILLISIBLE : ECHEC qui la montre — une gravité inconnue ne se relaie pas en silence" {
  stub_porte 0 'peut-etre	ça dépend'
  run bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ligne illisible"* ]]
}

# Les gardes : ce qui manque AVANT la porte se dit ici, et la porte n'est PAS jouée — sinon
# l'opérateur reçoit une plainte du BEAM là où il attend une phrase, et on paie un eval pour rien.
@test "FORGE_BASE_URL absent : drift, et la porte n'est pas ouverte" {
  stub_porte 0 "$CONFORME"
  unset FORGE_BASE_URL
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL non posé"* ]]
  refute grep -q '^ARGV:' "$CALLS"
}

@test "CLI illisible : drift qui nomme la release, et la porte n'est pas ouverte" {
  export LCARS_CLI="$BATS_TEST_TMPDIR/pas-de-cli"
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"porte ops-repo injouable"* ]]
  [[ "$output" == *"release n'est pas posée"* ]]
}

@test "jeton système ABSENT : drift qui nomme le geste des jetons, porte non ouverte" {
  stub_porte 0 "$CONFORME"
  rm -f "$LCARS_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"jeton système absent"* ]]
  refute grep -q '^ARGV:' "$CALLS"
}

@test "jeton système VIDE : drift distinct de l'absence, porte non ouverte" {
  stub_porte 0 "$CONFORME"
  : > "$LCARS_SYSTEM_TOKEN_FILE"
  run bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"jeton système VIDE"* ]]
  refute grep -q '^ARGV:' "$CALLS"
}

# ⚠ `/proc/<pid>/environ` n'est lisible que par le propriétaire et root ; un argv l'est par tout le
# monde. Ce témoin est la seule chose qui tienne cette règle sur ce chemin.
@test "le jeton part par l'ENVIRONNEMENT, jamais par l'argv" {
  stub_porte 0 "$CONFORME"
  run bash "$MODULE" check
  [ "$status" -eq 0 ]
  grep -q '^ENVTOK:SYS-TOKEN$' "$CALLS"
  grep -q '^ENVURL:http://forge.test$' "$CALLS"
  refute grep -q '^ARGV:.*SYS-TOKEN' "$CALLS"
}

@test "UN SEUL eval par passe : la porte est ouverte une fois, et elle reçoit le verbe attendu" {
  stub_porte 0 "$CONFORME"
  run bash "$MODULE" check
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ARGV:' "$CALLS")" -eq 1 ]
  grep -q '^ARGV:tool ops-repo$' "$CALLS"
}

@test "mode inconnu : FATAL avant toute mesure, jamais un verdict" {
  stub_porte 0 "$CONFORME"
  run bash "$MODULE" reconcile
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode inconnu"* ]]
  refute grep -q '^ARGV:' "$CALLS"
}
