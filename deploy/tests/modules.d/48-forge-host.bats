#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/48-forge-host.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de la forge du poste — montée ou fournie, adresses, refus, admin, jeton, seed, siège

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/48-forge-host.sh"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=48-forge-host
  # le module écrit des fichiers root:fleet : il se joue sous unshare -Ur, où root est ce compte ; le
  # décor fait appartenir tout ce qu'il pose à ce compte
  decor_pose
  TOKENS="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  MAP="$TOKENS/forge-uid.map"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  # l'admin de la forge est un compte unix réel : le siège s'enregistre avec son uid
  ME="$(id -un)"
  forge_double_start
  # la forge du poste écoute sur 127.0.0.1:<port choisi> : le port choisi est celui de la forge locale
  PORT="${FORGE_DOUBLE_URL##*:}"
  POSTE="http://127.0.0.1:$PORT"
  export PROV_SUBSTRATE=linux PROV_FORGE_ADVERTISE=10.9.9.9 PROV_HUMAN="$ME" PROV_FORGE_BASE=bob_9 PROV_FORGE_HOST_PORT="$PORT"
  export DOCKER_HOST=unix:///dev/null
  export STUB_PORTS="0.0.0.0:$PORT->3000/tcp"   # notre projet publie le port : la forge qui répond est la nôtre
  routes
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$DECOR_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "DOCKER:\$*" >> "$CALLS"
env | grep '^LCARS_DEVFORGE_\|^PW=' | sort >> "$CALLS"
case "\$*" in
  version*)                       echo "29.0.0"; exit 0 ;;
  "compose version"*)             echo "v2"; exit 0 ;;
  compose*" up -d"*)              echo 'GET /api/v1/version 200 {"version":"1.24.0"}' >> "$FORGE_DOUBLE_DIR/routes"; exit 0 ;;
  ps*"--format {{.Ports}}")       [[ -z "\${STUB_PORTS:-}" ]] || echo "\$STUB_PORTS"; exit 0 ;;
  ps*publish=*)                   [[ -z "\${STUB_PUBLISH:-}" ]] || echo "\$STUB_PUBLISH"; exit 0 ;;
  ps*"--format {{.Names}}")       echo "\${STUB_NAME-bob_9-forge-gitea-1}"; exit 0 ;;
  inspect*)                       echo "\${STUB_INSPECT_PROJECT:-autre}"; exit 0 ;;
  "exec "*"printf lcars-stream-ok") printf 'lcars-stream-ok'; exit 0 ;;
  *"user create"*)                [[ -z "\${STUB_CREATE_ERR:-}" ]] || echo "\$STUB_CREATE_ERR" >&2; exit "\${STUB_CREATE_RC:-0}" ;;
  *"generate-access-token"*)      printf '%s\n' "\${STUB_TOKEN-tok-master}"; exit 0 ;;
esac
exit 0
EOF
  # le vrai curl, argv noté : aucun secret ne doit y passer
  cat > "$DECOR_BIN/curl" <<EOF
#!/usr/bin/env bash
echo "CURL:\$*" >> "$CALLS"
exec "$(command -v curl)" "\$@"
EOF
  printf '#!/usr/bin/env bash\necho "${STUB_WSL_NET:-nat}"\n' > "$DECOR_BIN/wslinfo"
  chmod 0755 "$DECOR_BIN/docker" "$DECOR_BIN/curl" "$DECOR_BIN/wslinfo"
  export PROV_DOCKER_BIN="$DECOR_BIN/docker"
}

teardown() { forge_double_stop; }

# routes — la table de la forge locale, relue à chaque requête ; UP=0 la rend muette sur /version,
# USER_CODE et IS_ADMIN disent le compte, PATCH_CODE la promotion, SEAT le #1 de la forge
routes() {
  : > "$FORGE_DOUBLE_DIR/routes"
  [[ "${UP:-1}" == 0 ]] || forge_route GET /api/v1/version 200 '{"version":"1.24.0"}'
  forge_route GET "/api/v1/users/$ME" "${USER_CODE:-200}" "{\"login\":\"$ME\",\"is_admin\":${IS_ADMIN:-true}}"
  forge_route GET '/api/v1/admin/users?limit=*' 200 "[{\"id\":1,\"login\":\"${SEAT:-$ME}\"}]"
  forge_route PATCH "/api/v1/admin/users/$ME" "${PATCH_CODE:-200}" '{}'
}

mod() { run unshare -Ur bash "$SRC" "$@"; }


@test "publiée sur toutes les adresses par défaut, l'adresse annoncée compose l'URL publique" {
  mod check
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge du poste vivante ($POSTE) — ouverte sur 0.0.0.0, composable en http://10.9.9.9:$PORT"* ]]
}

@test "un bind sur la loopback ferme la forge à cette machine, et le verdict le dit" {
  PROV_FORGE_BIND=127.0.0.1 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"cette machine seule"* ]]
  [[ "$output" != *"ouverte sur"* ]]
}

@test "sous WSL en NAT sans adresse donnée, l'annonce est localhost et le motif remonte ; hors WSL non" {
  unset PROV_FORGE_ADVERTISE
  PROV_SUBSTRATE=wsl STUB_WSL_NET=nat mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"composable en http://localhost:$PORT (WSL2 en mode NAT"* ]]
  PROV_SUBSTRATE=linux STUB_WSL_NET=nat mod check
  [ "$status" -eq 1 ]
  [[ "$output" != *"http://localhost:$PORT"* ]]
}

@test "avec --bench (PROV_FORGE_MONTEE=1), un FORGE_BASE_URL résiduel ne détourne pas le module : la forge est celle du poste" {
  PROV_FORGE_MONTEE=1 FORGE_BASE_URL=http://ailleurs:9 mod check
  [[ "$output" == *"forge du poste vivante ($POSTE)"* ]]
  refute_out "forge fournie" <<<"$output"
  refute_out "ailleurs" <<<"$output"
}

@test "sans FORGE_BASE_URL hors conteneur, la forge est celle du poste : son adresse est la loopback au port choisi" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$TOKENS/forge.url")" = "$POSTE" ]
  [ "$(cat "$TOKENS/forge.mode")" = poste ]
  refute_out "forge fournie" <<<"$output"
}

@test "une forge fournie s'annonce à FORGE_PUBLIC_URL quand elle est donnée, jamais à l'adresse du poste" {
  rm -f "$DECOR_BIN/docker"
  FORGE_BASE_URL="$FORGE_DOUBLE_URL" FORGE_PUBLIC_URL="https://forge.lan/" mod apply
  [ "$(cat "$TOKENS/forge.public.url")" = "https://forge.lan" ]
  [ "$(cat "$TOKENS/forge.url")" = "$FORGE_DOUBLE_URL" ]
  [ "$(cat "$TOKENS/forge.mode")" = fournie ]
}

@test "une forge fournie est consommée : son URL sans slash final, docker non requis, rien monté" {
  rm -f "$DECOR_BIN/docker"
  FORGE_BASE_URL="$FORGE_DOUBLE_URL/" mod apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge fournie ($FORGE_DOUBLE_URL) — rien à monter"*"DRIFT"*"forge fournie sans autorité"* ]]
  refute grep -q 'compose .* up\|user create' "$CALLS"
  [ "$(cat "$TOKENS/forge.url")" = "$FORGE_DOUBLE_URL" ]
  [ "$(cat "$TOKENS/forge.public.url")" = "$FORGE_DOUBLE_URL" ]
  printf 'tok-donne\n' > "$TOKENS/forge-master.token"
  FORGE_BASE_URL="$FORGE_DOUBLE_URL/" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"autorité de création déjà posée"*"administre la forge"* ]]
  [ "$(forge_requests "select(.path == \"/api/v1/users/$ME\") | .auth" | sort -u)" = '"token tok-donne"' ]
}

@test "une forge fournie muette est un drift au check et un échec à l'apply" {
  FORGE_BASE_URL=http://127.0.0.1:9 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"forge fournie muette (http://127.0.0.1:9)"* ]]
  FORGE_BASE_URL=http://127.0.0.1:9 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"forge fournie muette (http://127.0.0.1:9)"* ]]
}


@test "sans daemon docker, le check refuse : la forge du poste est un conteneur, aucune autre forme" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DECOR_BIN/docker"
  PROV_SUBSTRATE=wsl mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"*"aucun daemon"*"aucune autre forme"* ]]
}

@test "une forge qui répond sans que notre projet publie le port est étrangère : refus nommé, avant tout compose" {
  STUB_PORTS="" mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"une forge répond sur $POSTE, mais aucun conteneur du projet « bob_9-forge » ne publie $PORT"*"--port-forge"* ]]
  STUB_PORTS="" mod apply
  [ "$status" -eq 1 ]
  refute grep -q 'compose .* up' "$CALLS"
}

@test "le projet qui tourne sur un autre port n'est pas déplacé : refus qui nomme les deux issues" {
  UP=0 routes
  STUB_PORTS="0.0.0.0:21005->3000/tcp" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"tourne déjà sur le port 21005, et cette passe en demande $PORT"*"--forge-project"*"compose -p bob_9-forge down"* ]]
  refute grep -q 'compose .* up' "$CALLS"
}

@test "forge éteinte et port tenu par un autre : l'apply refuse avant de monter, et nomme le port" {
  UP=0 routes
  STUB_PORTS="" STUB_PUBLISH=autre-forge-gitea-1 STUB_INSPECT_PROJECT=autre-forge mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"port $PORT déjà pris par autre-forge-gitea-1"* ]]
  refute grep -q 'compose .* up' "$CALLS"
}


@test "forge muette sur un port que notre projet tient : l'apply la monte avec port, bind et URL publique, l'attend, et pose ses deux adresses en 0644" {
  UP=0 routes
  STUB_PORTS="" STUB_PUBLISH=bob_9-forge-gitea-1 STUB_INSPECT_PROJECT=bob_9-forge mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'DOCKER:compose -f .*forge-compose.yml -p bob_9-forge up -d' "$CALLS"
  grep -qx "LCARS_DEVFORGE_PORT=$PORT" "$CALLS"
  grep -qx 'LCARS_DEVFORGE_BIND=0.0.0.0' "$CALLS"
  grep -qx "LCARS_DEVFORGE_ROOT_URL=http://10.9.9.9:$PORT/" "$CALLS"
  [[ "$output" == *"forge du poste montée ($POSTE)"* ]]
  [ "$(cat "$TOKENS/forge.url")" = "$POSTE" ]
  [ "$(cat "$TOKENS/forge.public.url")" = "http://10.9.9.9:$PORT" ]
  [ "$(stat -c %a "$TOKENS/forge.url")" = "644" ]
  [ "$(stat -c %a "$TOKENS/forge.public.url")" = "644" ]
}

@test "forge vivante et à nous : l'apply reconverge le compose et dit « vivante et convergée »" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'compose .* up -d' "$CALLS"
  [[ "$output" == *"forge du poste vivante et convergée"* ]]
}


@test "l'administrateur est l'humain de la passe, sauf si la table des uid nomme déjà le siège" {
  mod apply
  grep -q "user create .* _ $ME\$" "$CALLS"
  : > "$CALLS"; rm -f "$TOKENS"/*
  printf '1\t0\troot\n' > "$MAP"
  SEAT=root routes
  mod apply
  grep -q 'user create .* _ root$' "$CALLS"
}

@test "premier apply : compte créé avec un mot de passe de dix lettres annoncé, jeton master et seed posés en 0600" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local pw; pw="$(sed -n 's/^PW=//p' "$CALLS" | head -1)"
  refute grep -q "DOCKER:.*$pw" "$CALLS"
  [[ "$pw" =~ ^[A-Za-z]{10}$ ]]
  grep -q "forge du poste — compte d'administration	$ME	$pw" "$PROV_ANNOUNCE_FILE"
  [[ "$output" != *"$pw"* ]]
  [ "$(cat "$TOKENS/forge-master.token")" = "tok-master" ]
  [ "$(stat -c %a "$TOKENS/forge-master.token")" = "600" ]
  [[ "$(cat "$TOKENS/forge-seed.pass")" =~ ^[A-Za-z0-9]{20}$ ]]
  [ "$(stat -c %a "$TOKENS/forge-seed.pass")" = "600" ]
  [[ "$output" == *"autorité de création posée"*"seed des comptes posé ($TOKENS/forge-seed.pass"* ]]
}

@test "sans canal d'annonce, le mot de passe créé s'imprime sur place : se taire serait pire" {
  unset PROV_ANNOUNCE_FILE
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local pw; pw="$(sed -n 's/^PW=//p' "$CALLS" | head -1)"
  [[ "$output" == *"IDENTIFIANTS"*"$ME"*"$pw"* ]]
}

@test "second apply : jeton et seed déjà posés restent, aucun compte recréé, rien annoncé" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  printf 'seed-deja-pose\n' > "$TOKENS/forge-seed.pass"
  mod apply
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  mod apply
  [ "$status" -eq 0 ]
  refute grep -q 'user create' "$CALLS"
  [ ! -e "$PROV_ANNOUNCE_FILE" ]
  [ "$(cat "$TOKENS/forge-seed.pass")" = "seed-deja-pose" ]
  [[ "$output" == *"autorité de création déjà posée"*"seed des comptes déjà posé ($TOKENS/forge-seed.pass)"* ]]
}

@test "compte déjà présent hors banc : dit, la porte de repose nommée, et l'apply continue" {
  STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists [name: $ME]" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"compte « $ME » déjà présent"*"PROV_FORGE_ADMIN_RESET=1"* ]]
  refute grep -q 'user change-password' "$CALLS"
  [ -s "$TOKENS/forge-master.token" ]
}

@test "un refus de création qui n'est pas « déjà présent » est un échec qui cite la forge" {
  STUB_CREATE_RC=1 STUB_CREATE_ERR="database is locked" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"création du compte « $ME » refusée par la forge : database is locked"* ]]
  [ ! -s "$TOKENS/forge-master.token" ]
}

@test "en banc, le mot de passe de l'amiral est celui du contrat, posé même sur un compte déjà présent, et annoncé" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  LCARS_BENCH=1 mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "user create .* _ $ME\$" "$CALLS"
  grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
  : > "$CALLS"; rm -f "$TOKENS"/* "$PROV_ANNOUNCE_FILE"
  LCARS_BENCH=1 STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists" mod apply
  [ "$status" -eq 0 ]
  grep -q "user change-password .* _ $ME\$" "$CALLS"
  grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  LCARS_BENCH=1 mod apply
  [ "$status" -eq 0 ]
  refute grep -q 'user create' "$CALLS"
  grep -q "user change-password .* _ $ME\$" "$CALLS"
  grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
}

@test "PROV_FORGE_ADMIN_RESET pose un mot de passe neuf et l'annonce, jamais sur un compte tout juste créé" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  PROV_FORGE_ADMIN_RESET=1 mod apply
  refute grep -q 'user change-password' "$CALLS"
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  PROV_FORGE_ADMIN_RESET=1 mod apply
  [ "$status" -eq 0 ]
  grep -q "user change-password .* _ $ME\$" "$CALLS"
  grep -qE '^PW=[A-Za-z]{10}$' "$CALLS"
  grep -q "$ME	" "$PROV_ANNOUNCE_FILE"
}


@test "PROV_FORGE_ADMIN_RESET sur une forge fournie : aucun conteneur visé, rien n'échoue — le mot de passe est à qui la tient" {
  rm -f "$DECOR_BIN/docker"
  printf 'tok-donne\n' > "$TOKENS/forge-master.token"
  FORGE_BASE_URL="$FORGE_DOUBLE_URL" PROV_FORGE_ADMIN_RESET=1 mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out '^FAIL|repose du mot de passe' <<<"$output"
}

@test "le conteneur de la forge se lit par son projet, pas par un nom de service recopié" {
  UP=0 routes
  STUB_PORTS="" STUB_PUBLISH=bob_9-forge-gitea-1 STUB_INSPECT_PROJECT=bob_9-forge STUB_NAME=forge-renommee-1 mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^DOCKER:exec -e PW -u git forge-renommee-1 ' "$CALLS"
  grep -q '^DOCKER:exec -u git forge-renommee-1 gitea admin user generate-access-token' "$CALLS"
}

@test "check : seed perdu et adresses absentes sont des drifts, avant qu'un apply ne régénère le seed" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm -f "$TOKENS/forge-seed.pass" "$TOKENS/forge.url"
  printf 'http://ailleurs:1\n' > "$TOKENS/forge.public.url"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 48-forge-host: $TOKENS/forge-seed.pass absent (seed des comptes)"* ]]
  [[ "$output" == *"DRIFT 48-forge-host: $TOKENS/forge.url absent (adresse de la forge)"* ]]
  [[ "$output" == *"DRIFT 48-forge-host: $TOKENS/forge.public.url porte « http://ailleurs:1 », attendu « http://10.9.9.9:$PORT » (adresse publique de la forge)"* ]]
}

@test "sans jq pour lire la réponse, l'adminité est non mesurable : un administrateur n'est pas repromu à chaque passe" {
  mod apply; [ "$status" -eq 0 ]
  printf '#!/bin/sh\nexit 127\n' > "$DECOR_BIN/jq"; chmod 0755 "$DECOR_BIN/jq"
  : > "$FORGE_DOUBLE_DIR/requests.jsonl"
  mod apply
  [[ "$output" == *"WARN"*"adminité de « $ME » non mesurable"* ]]
  [ -z "$(forge_requests 'select(.method == "PATCH")')" ]
}

@test "l'adminité se lit avec le jeton : un compte admin est dit, rien n'est promu" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"« $ME » administre la forge"* ]]
  [ "$(forge_requests "select(.path == \"/api/v1/users/$ME\") | .auth" | sort -u)" = '"token tok-master"' ]
  [ -z "$(forge_requests 'select(.method == "PATCH")')" ]
}

@test "un simple compte est promu par un PATCH JSON (admin, login_name, source_id), jeton en en-tête et jamais en argv" {
  mod apply; [ "$status" -eq 0 ]
  : > "$CALLS"
  IS_ADMIN=false routes
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"« $ME » promu administrateur"* ]]
  local patch; patch="$(forge_requests 'select(.method == "PATCH")')"
  [ "$(jq -r .path <<<"$patch")" = "/api/v1/admin/users/$ME" ]
  [ "$(jq -r .auth <<<"$patch")" = "token tok-master" ]
  [ "$(jq -r .ctype <<<"$patch")" = "application/json" ]
  [ "$(jq -c '.body | fromjson' <<<"$patch")" = "{\"admin\":true,\"login_name\":\"$ME\",\"source_id\":0}" ]
  grep -q '^CURL:' "$CALLS"
  refute grep -q 'tok-master' "$CALLS"
}

@test "un compte absent de la forge est un avertissement au check ; une promotion refusée est un échec nommé" {
  mod apply; [ "$status" -eq 0 ]
  USER_CODE=404 routes
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $ME » n'a pas de compte sur cette forge"* ]]
  IS_ADMIN=false PATCH_CODE=403 routes
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"« $ME » n'a pas pu être promu administrateur"* ]]
}

@test "une forge qui répond 500 sur le compte laisse l'adminité inconnue : dit, rien n'est tenté" {
  mod apply; [ "$status" -eq 0 ]
  USER_CODE=500 IS_ADMIN=false routes
  : > "$FORGE_DOUBLE_DIR/requests.jsonl"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"WARN"*"adminité de « $ME » non mesurable"* ]]
  [ -z "$(forge_requests 'select(.method == "PATCH")')" ]
}

@test "sans jeton, l'adminité est inconnue et rien n'est tenté" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune autorité"*"adminité de « $ME » non mesurable"* ]]
  [ -z "$(forge_requests "select(.path == \"/api/v1/users/$ME\" or .method == \"PATCH\")")" ]
}

@test "le siège s'enregistre à l'apply dans la table des uid, le check le voit ensuite et n'écrit rien" {
  mod check
  [ "$status" -eq 1 ]
  [ ! -e "$MAP" ]
  mod apply
  [ "$(awk -F'\t' '$1 == 1 { print $3 }' "$MAP")" = "$ME" ]
  [[ "$output" == *"siège : « $ME » enregistré"* ]]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"siège : « $ME » enregistré"* ]]
}

@test "un siège sans compte sur la machine ne s'enregistre pas : la carte reste sans ligne, le drift le nomme au check comme à l'apply" {
  local seul=amiral-hors-machine
  refute id -u "$seul"
  ME="$seul" routes
  PROV_FORGE_ADMIN="$seul" mod apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"DRIFT"*"siège : « $seul » n'a pas de compte sur cette machine"*"PROV_FORGE_ADMIN"* ]]
  [ ! -e "$MAP" ]
  PROV_FORGE_ADMIN="$seul" mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"siège : « $seul » n'a pas de compte sur cette machine"* ]]
  refute_out "l'apply pose la ligne" <<<"$output"
}

@test "deux acteurs pour un rôle : la divergence est un drift, et la table garde son occupant" {
  printf '1\t0\troot\n' > "$MAP"
  SEAT=root routes
  PROV_FORGE_ADMIN="$ME" mod apply
  [[ "$output" == *"DRIFT"*"deux acteurs pour un rôle"* ]]
  [ "$(awk -F'\t' '$1 == 1 { print $3 }' "$MAP")" = "root" ]
}
