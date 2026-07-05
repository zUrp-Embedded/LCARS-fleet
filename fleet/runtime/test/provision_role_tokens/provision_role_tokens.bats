#!/usr/bin/env bats
# SOURCE: test/provision_role_tokens/provision_role_tokens.bats
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: tests bats etc/provision-role-tokens.sh (fix A4) — usage, check, pose idempotente, échecs
#
# La forge est stubée par un SHIM curl (PATH prepended) : la sonde de validité (`-w %{http_code}`)
# lit $MOCK/probe_code ; le POST de mint rend $MOCK/post_response et se COMPTE dans $MOCK/calls.log
# (l'idempotence s'asserte sur « zéro POST au 2e run », pas sur une impression). jq = le vrai.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/provision-role-tokens.sh"
  TMP="$(mktemp -d)"
  MOCK="$TMP/mock"; mkdir -p "$MOCK"
  TOKDIR="$TMP/tokens"; mkdir -p "$TOKDIR"

  # Shim curl : trié par forme d'appel (sonde -w / DELETE / POST), pas par URL (assemblage testé
  # ailleurs ; ici on teste la LOGIQUE du script). Chaque appel est journalisé.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$MOCK/calls.log"
case " \$* " in
  *" -w "*) cat "$MOCK/probe_code" 2>/dev/null || printf '401' ;;
  *" DELETE "*) exit 0 ;;
  *" POST "*) cat "$MOCK/post_response" 2>/dev/null || printf '{}' ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"

  PWDFILE="$TMP/passwords.json"
  printf '{"engineer":"pw-eng","qualifier":{"password":"pw-qual"}}' > "$PWDFILE"
}

teardown() { rm -rf "$TMP"; }

@test "header LCARS présent (SOURCE/AUTHOR/STARDATE/STATUS)" {
  head -5 "$SCRIPT" | grep -q "SOURCE: etc/provision-role-tokens.sh"
  head -5 "$SCRIPT" | grep -q "STATUS:"
}

@test "--help → exit 0 + usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "sans --forge ni FORGE_BASE_URL → exit 1 fail-loud" {
  run env -u FORGE_BASE_URL "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"--forge"* ]]
}

@test "mode pose SANS --passwords-file → exit 1, jamais un mint aveugle" {
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"autorité"* ]]
  [ ! -f "$MOCK/calls.log" ]
}

@test "--admin-token-file RETIRÉ (mode mort-né : Gitea refuse le mint par token admin)" {
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --admin-token-file /whatever --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue"* ]]
}

@test "passwords-file illisible → exit 1 (le privilège manquant est DIT, pas contourné)" {
  run "$SCRIPT" --forge http://f --passwords-file "$TMP/inexistant.json" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"illisible"* ]]
}

@test "--check : token local valide (sonde 200) → OK, exit 0" {
  printf 'tok-ok\n' > "$TOKDIR/engineer.gitea_token"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
}

@test "--check : token invalide (sonde 401) → FAIL, exit 2, fichier INTACT (check n'écrit jamais)" {
  printf 'tok-mort\n' > "$TOKDIR/engineer.gitea_token"
  printf '401' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-mort" ]
}

@test "pose happy-path : mint (sha1) + sonde 200 → fichier écrit 0640, exit 0" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-frais" ]
  [ "$(stat -c %a "$TOKDIR/engineer.gitea_token")" = "640" ]
  grep -q "POST" "$MOCK/calls.log"
}

@test "idempotence : 2e run sur token déjà valide → OK skip, ZÉRO nouveau POST" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  posts_avant="$(grep -c POST "$MOCK/calls.log")"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
  [ "$(grep -c POST "$MOCK/calls.log")" = "$posts_avant" ]
}

@test "password absent du fichier pour le rôle → FAIL ce rôle, exit 2 (pas de mint des autres masqué)" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "architect engineer"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  architect"* ]]
  [[ "$output" == *"POSÉ  engineer"* ]]
}

@test "mint refusé (POST sans sha1) → FAIL, exit 2, aucun fichier écrit" {
  printf '{"message":"forbidden"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ ! -f "$TOKDIR/engineer.gitea_token" ]
}

@test "passwords-file : les DEUX formes JSON acceptées (string nue et {password:...})" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "engineer qualifier"
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/qualifier.gitea_token" ]
}

@test "passwords-file : clé CAPITALISÉE matche le rôle minuscule (Gitea case-insensitive, finding starfleet)" {
  # Un humain écrit les comptes comme il les voit sur la forge (`Architect`) ; le rôle interne est
  # `architect`. Le lookup doit matcher — sinon FAIL alors que le password EXISTE (le format-piège vécu).
  printf '{"Architect":"pw-arch"}' > "$TMP/caps.json"
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$TMP/caps.json" --roles architect
  [ "$status" -eq 0 ]
  [ "$(cat "$TOKDIR/architect.gitea_token")" = "tok-frais" ]
}

@test "--extra-token COMPTE:FICHIER : mint le compte système, écrit le fichier (compte ≠ fichier)" {
  printf '{"lcars-system":"pw-sys"}' > "$TMP/syspw.json"
  printf '{"sha1":"tok-sys"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$TMP/syspw.json" \
      --roles "" --extra-token lcars-system:system.gitea_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  lcars-system"* ]]
  [ "$(cat "$TOKDIR/system.gitea_token")" = "tok-sys" ]
  [ ! -f "$TOKDIR/lcars-system.gitea_token" ]
}

@test "--extra-token sans ':' → exit 1 fail-loud (format compte:fichier requis)" {
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --extra-token bidon
  [ "$status" -eq 1 ]
  [[ "$output" == *"compte>:<fichier"* ]]
}

@test "A4 complet : 1 rôle + le système en UN geste (l'appel canonique)" {
  printf '{"engineer":"pw-eng","lcars-system":"pw-sys"}' > "$TMP/full.json"
  printf '{"sha1":"tok-x"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --tokens-dir "$TOKDIR" --passwords-file "$TMP/full.json" \
      --roles engineer --extra-token lcars-system:system.gitea_token
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/system.gitea_token" ]
}
