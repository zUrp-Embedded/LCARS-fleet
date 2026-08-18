#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/deck_origins.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for modules.d/55-deck-oidc — la LISTE DES ENTREES doit converger
#
# CE QUE CES TEMOINS TIENNENT. La porte du deck refuse une entree non declaree et imprime le geste
# qui repare : « ajouter celle-ci a LCARS_DECK_ORIGINS et rejouer le provisioning ». Mesure du
# 2026-08-18 : ce geste ne faisait RIEN. `apply` sortait des que le fichier nommait un client encore
# connu de la forge, sans jamais comparer les retours enregistres a ceux qu'on voulait — la liste
# etait posee une fois, a la creation, et plus jamais. Le runtime prescrivait un geste qu'il
# n'honorait pas : un mensonge operationnel, pas une lacune de confort.
#
# Second fait tenu ici : NOTRE PROPRE CLIENT N'EST PAS UN ETRANGER. L'appartenance se prouvait par
# les `redirect_uris` — or ce sont precisement eux qui changent. Une boite qui change ses entrees
# voyait donc son ancien client comme celui d'une autre boite : elle le laissait vivre en le
# denoncant, et en creait un second. L'ancrage est le `client_id` de NOTRE fichier.
#
# Aucune socket : `curl` est une doublure en tete de PATH, et ce qui est mesure est la decision du
# module (ce qu'il DELETE, ce qu'il POST, ce qu'il ecrit).

setup() {
  SUT="$BATS_TEST_DIRNAME/../modules.d/55-deck-oidc.sh"
  [ -f "$SUT" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export APPS_JSON="$BATS_TEST_TMPDIR/apps.json"
  export TRACE="$BATS_TEST_TMPDIR/trace"
  : > "$TRACE"

  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in */api/v1/version) exit 0 ;; esac
method=GET; prev=""
for a in "$@"; do [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done
printf '%s %s\n' "$method" "$url" >> "$TRACE"
case "$method" in
  GET)    cat "$APPS_JSON" ;;
  DELETE) echo '{}' ;;
  POST)   echo '{"client_id":"NEWCID","client_secret":"NEWSECRET"}' ;;
esac
SH
  chmod +x "$BIN/curl"

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=55-deck-oidc
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$PROV_TOKENS_DIR"
  echo "tok" > "$PROV_TOKENS_DIR/system.gitea_token"
  export PROV_FORGE_URL="http://forge.test"
  export PROV_FORGE_PUBLIC_URL="http://10.0.0.5:21000"
  export PROV_DECK_PORT=20999
  export PROV_DECK_OIDC_FILE="$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  mkdir -p "$BATS_TEST_TMPDIR/etc"
  # L'entree ANNONCEE. Les deux ecritures de la loopback sont semees par le module lui-meme.
  export PROV_DECK_ORIGINS="http://10.0.0.5:20999"
  echo '{"client_id":"CID"}' > "$PROV_DECK_OIDC_FILE"
}

# Les retours que le module DOIT vouloir : la loopback dans ses DEUX ecritures, plus l'annoncee.
apps_with() { # apps_with <uris...>
  local uris=("$@") j=""
  for u in "${uris[@]}"; do j="$j\"$u\","; done
  printf '[{"id":7,"name":"lcars-deck","client_id":"CID","redirect_uris":[%s]}]\n' "${j%,}" > "$APPS_JSON"
}

@test "check : la liste enregistree EGALE la voulue — aucune derive" {
  apps_with "http://127.0.0.1:20999/auth/callback" \
            "http://localhost:20999/auth/callback" \
            "http://10.0.0.5:20999/auth/callback"
  run bash "$SUT" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"posé et connu de la forge"* ]]
}

@test "check : localhost absent des retours = DERIVE, et les deux listes sont nommees" {
  # LE CAS EXACT DU 2026-08-18. `localhost` et `127.0.0.1` designent le meme point d'ecoute et sont
  # deux ORIGINES distinctes pour la comparaison exacte d'OAuth2. Le navigateur arrive en
  # `localhost` — sous WSL c'est meme la seule adresse qui marche depuis l'hote.
  apps_with "http://127.0.0.1:20999/auth/callback" \
            "http://10.0.0.5:20999/auth/callback"
  run bash "$SUT" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"non convergées"* ]]
  [[ "$output" == *"http://localhost:20999/auth/callback"* ]]
  [[ "$output" == *"enregistrées"* ]]
}

@test "apply : une liste qui a change REPOSE le client — et c'est le NOTRE qui part" {
  apps_with "http://127.0.0.1:20999/auth/callback"
  run bash "$SUT" apply
  [ "$status" -eq 0 ]
  # notre client, designe par l'id de l'app que NOTRE client_id nomme
  grep -q "DELETE http://forge.test/api/v1/user/applications/oauth2/7" "$TRACE"
  grep -q "POST http://forge.test/api/v1/user/applications/oauth2" "$TRACE"
  # et le fichier repose est celui du client neuf, avec la liste complete
  run jq -r '.client_id, (.redirect_uris|join(" "))' "$PROV_DECK_OIDC_FILE"
  [[ "$output" == *"NEWCID"* ]]
  [[ "$output" == *"http://localhost:20999/auth/callback"* ]]
  [[ "$output" == *"http://10.0.0.5:20999/auth/callback"* ]]
}

@test "apply : notre ancien client n'est jamais denonce comme etranger" {
  # SANS le filtre par client_id, l'ancienne app (meme nom, autres retours) tombait dans
  # `foreign_apps` : laissee vivante et denoncee, pendant qu'on en creait une seconde. Deux clients
  # homonymes sous le meme compte, dont un mort.
  apps_with "http://127.0.0.1:20999/auth/callback"
  run bash "$SUT" apply
  [[ "$output" != *"homonyme"* ]]
}

@test "apply : liste deja convergee = AUCUN geste (ni DELETE ni POST)" {
  apps_with "http://127.0.0.1:20999/auth/callback" \
            "http://localhost:20999/auth/callback" \
            "http://10.0.0.5:20999/auth/callback"
  run bash "$SUT" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà posé et vivant"* ]]
  ! grep -q "DELETE" "$TRACE"
  ! grep -q "POST" "$TRACE"
}
