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
  echo "tok" > "$PROV_TOKENS_DIR/system_starfleet.gitea_token"
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

# ─── L'ADRESSE QU'UN TIERS COMPOSE ──────────────────────────────────────────────────────────────
#
# MEME LECON QUE LA FORGE, UN CRAN PLUS LOIN — et ici c'est pire qu'un lien faux : OAuth2 compare le
# `redirect_uri` en CHAINE EXACTE, donc une entree non declaree est un REFUS, pas une degradation.
#
# Mesure du 2026-08-21, poste natif installe a froid, operateur venant d'une autre machine :
#   « CETTE ENTREE N'EST PAS DECLAREE — tu es arrive par http://10.42.0.63:20999/auth/callback.
#     Entrees declarees : http://127.0.0.1:20999/…, http://localhost:20999/… »
# Le levier existait (`PROV_DECK_ORIGINS`) ; c'est le DEFAUT qui etait faux.

head_uris() { # <bind> — les URIs derivees, l'en-tete du module seule
  local head="$BATS_TEST_TMPDIR/deck-head.sh"
  sed '/^check() {/,$d' "$SUT" > "$head"
  PROV_DECK_BIND="$1" PROV_DECK_ORIGINS="" PROV_DECK_PORT=20999 \
    bash -c "set -euo pipefail; source '$head' >/dev/null 2>&1; callback_uris"
}

@test "le deck declare l'adresse ANNONCEE, pas seulement la loopback" {
  # `advertise_addr` rend l'adresse de sortie quand le bind est un joker ; on force une adresse
  # explicite pour que le temoin ne depende pas du reseau de la machine qui le joue.
  run head_uris "192.0.2.7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://192.0.2.7:20999/auth/callback"* ]]
  # et la loopback reste, sous ses DEUX ecritures — OAuth2 compare des chaines
  [[ "$output" == *"http://127.0.0.1:20999/auth/callback"* ]]
  [[ "$output" == *"http://localhost:20999/auth/callback"* ]]
}

@test "une adresse qui ne vaut RIEN n'est pas declaree — la lib dit ce qu'elle rend" {
  # Sous WSL en NAT, `advertise_addr` rend `localhost` AVEC un motif : la VM n'est routee depuis
  # aucune autre machine. Declarer une entree la-dessus ajouterait une chaine que personne ne peut
  # taper. Le temoin epingle que le module LIT `PROV_ADVERTISE_WHY` au lieu de l'ignorer.
  grep -q 'PROV_ADVERTISE_WHY' "$SUT"
  run head_uris "127.0.0.1"
  [ "$status" -eq 0 ]
  # bind loopback : rien d'autre que les deux ecritures de la loopback
  [ "$(echo "$output" | tr ' ' '\n' | grep -c 'auth/callback')" -eq 2 ]
}

@test "pas de doublon quand l'operateur NOMME deja l'adresse annoncee" {
  local head="$BATS_TEST_TMPDIR/deck-head2.sh"
  sed '/^check() {/,$d' "$SUT" > "$head"
  run bash -c "set -euo pipefail
    PROV_DECK_BIND=192.0.2.7 PROV_DECK_PORT=20999 PROV_DECK_ORIGINS='http://192.0.2.7:20999'
    export PROV_DECK_BIND PROV_DECK_PORT PROV_DECK_ORIGINS
    source '$head' >/dev/null 2>&1; callback_uris"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr ' ' '\n' | grep -c '192.0.2.7')" -eq 1 ]
}
