#!/usr/bin/env bats
# SOURCE: test/provision_role_tokens/provision_role_tokens.bats
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: bats tests for etc/provision-role-tokens.sh (A4) — usage, check, idempotent provisioning, failures
#
# The forge is stubbed by a curl SHIM (prepended to PATH): the validity probe (`-w %{http_code}`) reads
# $MOCK/probe_code; the mint POST returns $MOCK/post_response and is COUNTED in $MOCK/calls.log — so
# idempotence is asserted on "zero POST on the second run", not on a printed line. jq is the real one.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/provision-role-tokens.sh"
  TMP="$(mktemp -d)"
  MOCK="$TMP/mock"; mkdir -p "$MOCK"
  TOKDIR="$TMP/tokens"; mkdir -p "$TOKDIR"

  # curl shim: dispatched by call SHAPE (probe -w / DELETE / POST), not by URL — the URL assembly is
  # tested elsewhere; here we test the script's LOGIC. Every call is logged.
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

@test "LCARS header present (SOURCE/AUTHOR/STARDATE/STATUS)" {
  head -5 "$SCRIPT" | grep -q "SOURCE: etc/provision-role-tokens.sh"
  head -5 "$SCRIPT" | grep -q "STATUS:"
}

@test "--help → exit 0 + usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "no --forge and no FORGE_BASE_URL → exit 1 fail-loud" {
  run env -u FORGE_BASE_URL "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"--forge"* ]]
}

@test "provisioning mode WITHOUT --passwords-file → exit 1, never a blind mint" {
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"droit de mint"* ]]
  [ ! -f "$MOCK/calls.log" ]
}

@test "--admin-token-file REMOVED (stillborn mode: Gitea refuses minting by admin token)" {
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --admin-token-file /whatever --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue"* ]]
}

@test "unreadable passwords-file → exit 1 (the missing right is STATED, not worked around)" {
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --passwords-file "$TMP/inexistant.json" --roles engineer
  [ "$status" -eq 1 ]
  [[ "$output" == *"illisible"* ]]
}

@test "--check: valid local token (probe 200) → OK, exit 0" {
  printf 'tok-ok\n' > "$TOKDIR/engineer.gitea_token"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
}

@test "--check: invalid token (probe 401) → FAIL, exit 2, file INTACT (--check never writes)" {
  printf 'tok-mort\n' > "$TOKDIR/engineer.gitea_token"
  printf '401' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --roles engineer --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-mort" ]
}

@test "le compte est le LOGIN, le fichier reste le ROLE" {
  # `<catalogue>_<role>` est la forme du compte forge, parce qu'un username Gitea est unique a
  # l'INSTANCE : sans prefixe, deux catalogues nommant chacun un `dev` se partagent un compte et un
  # jeton. Le FICHIER, lui, ne bouge pas — c'est la cle que le runtime connait (`as_role/2` indexe
  # `<role>.gitea_token`, jamais le login). La projection est inversible par construction : `_` est
  # interdit dans les deux moities, donc la premiere separe exactement.
  printf 'tok-ok\n' > "$TOKDIR/engineer.gitea_token"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --roles fleet_engineer --check
  [ "$status" -eq 0 ]
  # Le rapport nomme les DEUX : le compte sonde et le fichier qui le porte.
  [[ "$output" == *"OK    fleet_engineer"* ]]
  [[ "$output" == *"engineer.gitea_token)"* ]]

  # Un role compose garde son tiret : seul le PREMIER souligne separe.
  printf 'tok-ok\n' > "$TOKDIR/code-reviewer.gitea_token"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --roles web_code-reviewer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-reviewer.gitea_token)"* ]]
}

@test "local readability is load-bearing: a token whose group != GROUP FAILS (unreadable by runtime)" {
  # Forge-valid but group-wrong = the runtime BEAM cannot read it. Announcing POSE + exit 0 there
  # hid a broken deploy behind a WARN. A group the runner cannot chgrp to → the stat verify FAILS
  # the account: the file is written (mint was real), but it is not counted as posed and exit != 0.
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group nonexistent-group-zzz --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [[ "$output" == *"ILLISIBLE"* ]]
  # The token IS on disk (the forge mint cost was real; --check will confirm), just flagged unreadable.
  [ -f "$TOKDIR/engineer.gitea_token" ]
}

@test "happy path: mint (sha1) + probe 200 → file written 0640, exit 0" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSE  engineer"* ]]
  [ "$(cat "$TOKDIR/engineer.gitea_token")" = "tok-frais" ]
  [ "$(stat -c %a "$TOKDIR/engineer.gitea_token")" = "640" ]
  grep -q "POST" "$MOCK/calls.log"
}

@test "idempotence: second run on an already-valid token → OK skip, ZERO new POST" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  posts_before="$(grep -c POST "$MOCK/calls.log")"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    engineer"* ]]
  [ "$(grep -c POST "$MOCK/calls.log")" = "$posts_before" ]
}

@test "password missing from the file for a role → FAIL that role, exit 2 (the others' mint is not masked)" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "architect engineer"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  architect"* ]]
  [[ "$output" == *"POSE  engineer"* ]]
}

@test "mint refused (POST without sha1) → FAIL, exit 2, no file written" {
  printf '{"message":"forbidden"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles engineer
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  engineer"* ]]
  [ ! -f "$TOKDIR/engineer.gitea_token" ]
}

@test "passwords-file: BOTH JSON shapes accepted (bare string and {password:...})" {
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --roles "engineer qualifier"
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/qualifier.gitea_token" ]
}

@test "passwords-file: a CAPITALIZED key matches the lowercase role (Gitea is case-insensitive)" {
  # A human writes the accounts as they see them on the forge (`Architect`); the internal role is
  # `architect`. The lookup must match — otherwise it FAILs while the password EXISTS.
  printf '{"Architect":"pw-arch"}' > "$TMP/caps.json"
  printf '{"sha1":"tok-frais"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/caps.json" --roles architect
  [ "$status" -eq 0 ]
  [ "$(cat "$TOKDIR/architect.gitea_token")" = "tok-frais" ]
}

@test "--extra-token ACCOUNT:FILE: mints the system account, writes the file (account is not file)" {
  printf '{"lcars-system":"pw-sys"}' > "$TMP/syspw.json"
  printf '{"sha1":"tok-sys"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/syspw.json" \
      --roles "" --extra-token lcars-system:system.gitea_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSE  lcars-system"* ]]
  [ "$(cat "$TOKDIR/system.gitea_token")" = "tok-sys" ]
  [ ! -f "$TOKDIR/lcars-system.gitea_token" ]
}

@test "--extra-token without ':' → exit 1 fail-loud (account:file format required)" {
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$PWDFILE" --extra-token bidon
  [ "$status" -eq 1 ]
  [[ "$output" == *"compte>:<fichier"* ]]
}

@test "A4 complete: 1 role + the system account in ONE gesture (the canonical call)" {
  printf '{"engineer":"pw-eng","lcars-system":"pw-sys"}' > "$TMP/full.json"
  printf '{"sha1":"tok-x"}' > "$MOCK/post_response"
  printf '200' > "$MOCK/probe_code"
  run "$SCRIPT" --forge http://f --group "$(id -gn)" --tokens-dir "$TOKDIR" --passwords-file "$TMP/full.json" \
      --roles engineer --extra-token lcars-system:system.gitea_token
  [ "$status" -eq 0 ]
  [ -f "$TOKDIR/engineer.gitea_token" ]
  [ -f "$TOKDIR/system.gitea_token" ]
}
