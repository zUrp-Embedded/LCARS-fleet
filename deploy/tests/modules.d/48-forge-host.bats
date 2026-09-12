#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/48-forge-host.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de la forge du poste — montée ou fournie, adresses, refus, admin, jeton, seed, siège
#
# Le module est joué entier (check ou apply) sous des doublures docker et curl qui notent leurs
# appels dans CALLS ; la forge « répond » ou non selon STUB_FORGE_UP, docker publie ou non le
# port du projet selon STUB_PORTS.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/48-forge-host.sh"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=48-forge-host
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"; mkdir -p "$PROV_TOKENS_DIR"
  export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/uid.map"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
  # le module écrit des fichiers root:fleet : il se joue sous unshare -Ur, où root est ce compte et
  # seul le gid 0 existe — le groupe de fleet et l'autorité y sont root
  export PROV_FLEET_GROUP=root PROV_AUTHORITY_USER=root
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  # l'admin de la forge est un compte unix réel : le siège s'enregistre avec son uid
  ME="$(id -un)"
  export PROV_SUBSTRATE=linux PROV_FORGE_ADVERTISE=10.9.9.9 PROV_HUMAN="$ME" PROV_FORGE_PROJECT=bob_9-forge
  export DOCKER_HOST=unix:///dev/null
  export STUB_PORTS="0.0.0.0:21000->3000/tcp"   # notre projet publie le port : la forge qui répond est la nôtre
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$BIN/docker" <<EOF
#!/usr/bin/env bash
echo "DOCKER:\$*" >> "$CALLS"
env | grep '^LCARS_DEVFORGE_\|^PW=' | sort >> "$CALLS"
case "\$*" in
  version*)                       echo "29.0.0"; exit 0 ;;
  "compose version"*)             echo "v2"; exit 0 ;;
  "ps --format {{.ID}}")          echo abc123; exit 0 ;;
  ps*"--format {{.Ports}}")       [[ -z "\${STUB_PORTS:-}" ]] || echo "\$STUB_PORTS"; exit 0 ;;
  ps*publish=*)                   [[ -z "\${STUB_PUBLISH:-}" ]] || echo "\$STUB_PUBLISH"; exit 0 ;;
  inspect*)                       echo "\${STUB_INSPECT_PROJECT:-autre}"; exit 0 ;;
  "exec "*"printf lcars-stream-ok") printf 'lcars-stream-ok'; exit 0 ;;
  *"user create"*)                [[ -z "\${STUB_CREATE_ERR:-}" ]] || echo "\$STUB_CREATE_ERR" >&2; exit "\${STUB_CREATE_RC:-0}" ;;
  *"generate-access-token"*)      printf '%s\n' "\${STUB_TOKEN-tok-master}"; exit 0 ;;
esac
exit 0
EOF
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
cfg=""; for a in "\$@"; do [[ "\$a" == "-K" ]] && cfg="\$(cat)"; done
url="\${@: -1}"
echo "CURL:\$* | \$(tr '\n' ' ' <<<"\$cfg")" >> "$CALLS"
case "\$url" in
  */api/v1/version)  [[ "\${STUB_FORGE_UP:-1}" == 1 ]] && exit 0 || exit 7 ;;
  */api/v1/users/*)  code="\${STUB_USER_CODE:-200}"
                     [[ " \$* " == *" -w "* ]] && { printf '{"is_admin":%s}\n%s' "\${STUB_IS_ADMIN:-true}" "\$code"; exit 0; }
                     printf '{"is_admin":%s}' "\${STUB_IS_ADMIN:-true}"; exit 0 ;;
  *"/api/v1/admin/users?limit="*) printf '[{"id":1,"login":"%s"}]' "\${STUB_SEAT:-$ME}"; exit 0 ;;
  */api/v1/admin/users/*) exit "\${STUB_PATCH_RC:-0}" ;;
esac
exit 0
EOF
  chmod 0755 "$BIN/docker" "$BIN/curl"
  export PATH="$BIN:$PATH" PROV_DOCKER_BIN="$BIN/docker"
}

mod() {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le module ne se joue pas ici"
  run unshare -Ur bash "$SRC" "$@"
}

# ─── les adresses ───────────────────────────────────────────────────────────────────────────────

@test "publiée sur toutes les adresses par défaut, l'adresse annoncée compose l'URL publique" {
  mod check
  [ "$status" -ne 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge du poste vivante (http://127.0.0.1:21000) — OUVERTE sur 0.0.0.0, composable en http://10.9.9.9:21000"* ]]
}

@test "un bind sur la loopback ferme la forge à cette machine, et le verdict le dit" {
  PROV_FORGE_BIND=127.0.0.1 mod check
  [ "$status" -ne 2 ]
  [[ "$output" == *"cette machine SEULE"* ]]
  [[ "$output" != *"OUVERTE"* ]]
}

@test "sous WSL en NAT sans adresse donnée, l'annonce est localhost et le motif remonte ; hors WSL non" {
  unset PROV_FORGE_ADVERTISE
  PROV_SUBSTRATE=wsl LCARS_WSL_NETWORKING_MODE=nat mod check
  [ "$status" -ne 2 ]
  [[ "$output" == *"composable en http://localhost:21000 (WSL2 en mode NAT"* ]]
  PROV_SUBSTRATE=linux LCARS_WSL_NETWORKING_MODE=nat mod check
  [ "$status" -ne 2 ]
  [[ "$output" != *"http://localhost:21000"* ]]
}

@test "une forge fournie est consommée : son URL sans slash final, docker non requis, rien monté" {
  rm -f "$BIN/docker"
  FORGE_BASE_URL="http://forge.example:3000/" mod apply
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge FOURNIE (http://forge.example:3000) — rien à monter"*"DRIFT"*"forge fournie sans autorité"* ]]
  refute grep -q 'compose .* up\|user create' "$CALLS"
  [ "$(cat "$PROV_TOKENS_DIR/forge.url")" = "http://forge.example:3000" ]
  printf 'tok-donne\n' > "$PROV_TOKENS_DIR/forge-master.token"
  FORGE_BASE_URL="http://forge.example:3000/" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"autorité de création déjà posée"*"administre la forge"* ]]
}

@test "une forge fournie muette est un drift au check et un échec à l'apply" {
  STUB_FORGE_UP=0 FORGE_BASE_URL=http://forge.example:3000 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"forge FOURNIE muette"* ]]
  STUB_FORGE_UP=0 FORGE_BASE_URL=http://forge.example:3000 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"forge FOURNIE muette"* ]]
}

# ─── les refus ──────────────────────────────────────────────────────────────────────────────────

@test "sans daemon docker, le check refuse : la forge du poste est un conteneur, aucune autre forme" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"
  LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/absent.sock" PROV_SUBSTRATE=wsl mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"*"aucun daemon"*"aucune autre forme"* ]]
}

@test "une forge qui répond sans que notre projet publie le port est étrangère : refus nommé, avant tout compose" {
  STUB_PORTS="" mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"une forge répond sur http://127.0.0.1:21000, mais AUCUN conteneur du projet « bob_9-forge » ne publie 21000"*"--port-forge"* ]]
  STUB_PORTS="" mod apply
  [ "$status" -eq 1 ]
  refute grep -q 'compose .* up' "$CALLS"
}

@test "le projet qui tourne sur un autre port n'est pas déplacé : refus qui nomme les deux issues" {
  STUB_FORGE_UP=0 STUB_PORTS="0.0.0.0:21005->3000/tcp" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"tourne déjà sur le port 21005, et cette passe en demande 21000"*"--forge-project"*"compose -p bob_9-forge down"* ]]
  refute grep -q 'compose .* up' "$CALLS"
}

@test "forge éteinte et port tenu par un autre : l'apply refuse avant de monter, et nomme le port" {
  STUB_FORGE_UP=0 STUB_PUBLISH=autre-forge-gitea-1 STUB_INSPECT_PROJECT=autre-forge mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"port 21000 déjà pris par autre-forge-gitea-1"* ]]
  refute grep -q 'compose .* up' "$CALLS"
}

# ─── le montage et les adresses posées ──────────────────────────────────────────────────────────

forge_absente_puis_vivante() { # la forge ne répond pas au premier appel, puis répond
  cat > "$BIN/curl.state" <<<"0"
  sed -i 's|\*/api/v1/version)  .*|*/api/v1/version)  n=$(cat "'"$BIN"'/curl.state"); echo $((n+1)) > "'"$BIN"'/curl.state"; [[ "$n" -ge 1 ]] \&\& exit 0 \|\| exit 7 ;;|' "$BIN/curl"
}

@test "forge absente : l'apply la monte avec port, bind et URL publique, l'attend, et pose ses deux adresses en 0644" {
  forge_absente_puis_vivante
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'DOCKER:compose -f .*forge-compose.yml -p bob_9-forge up -d' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_PORT=21000' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_BIND=0.0.0.0' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_ROOT_URL=http://10.9.9.9:21000/' "$CALLS"
  [[ "$output" == *"forge du poste montée (http://127.0.0.1:21000)"* ]]
  [ "$(cat "$PROV_TOKENS_DIR/forge.url")" = "http://127.0.0.1:21000" ]
  [ "$(cat "$PROV_TOKENS_DIR/forge.public.url")" = "http://10.9.9.9:21000" ]
  [ "$(stat -c %a "$PROV_TOKENS_DIR/forge.url")" = "644" ]
  [ "$(stat -c %a "$PROV_TOKENS_DIR/forge.public.url")" = "644" ]
}

@test "forge vivante et à nous : l'apply reconverge le compose et dit « vivante et convergée »" {
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'compose .* up -d' "$CALLS"
  [[ "$output" == *"forge du poste vivante et convergée"* ]]
}

# ─── le compte d'administration, le jeton, le seed ──────────────────────────────────────────────

@test "l'administrateur est l'humain de la passe, sauf si la table des uid nomme déjà le siège" {
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  grep -q "user create .* _ $ME\$" "$CALLS"
  : > "$CALLS"; rm -f "$PROV_TOKENS_DIR"/*
  printf '1\t0\troot\n' > "$PROV_UID_MAP_FILE"
  STUB_PORTS="0.0.0.0:21000->3000/tcp" STUB_SEAT=root mod apply
  grep -q 'user create .* _ root$' "$CALLS"
}

@test "premier apply : compte créé avec un mot de passe de dix lettres annoncé, jeton master et seed posés en 0600" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local pw; pw="$(sed -n 's/^PW=//p' "$CALLS" | head -1)"
  refute grep -q "DOCKER:.*$pw" "$CALLS"
  [[ "$pw" =~ ^[A-Za-z]{10}$ ]]
  grep -q "forge du poste — compte d'administration	$ME	$pw" "$PROV_ANNOUNCE_FILE"
  [[ "$output" != *"$pw"* ]]
  [ "$(cat "$PROV_TOKENS_DIR/forge-master.token")" = "tok-master" ]
  [ "$(stat -c %a "$PROV_TOKENS_DIR/forge-master.token")" = "600" ]
  [[ "$(cat "$PROV_TOKENS_DIR/forge-seed.pass")" =~ ^[A-Za-z0-9]{20}$ ]]
  [ "$(stat -c %a "$PROV_TOKENS_DIR/forge-seed.pass")" = "600" ]
  [[ "$output" == *"autorité de création posée"*"seed des comptes posé"* ]]
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
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  local seed; seed="$(cat "$PROV_TOKENS_DIR/forge-seed.pass")"
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ]
  refute grep -q 'user create' "$CALLS"
  [ ! -e "$PROV_ANNOUNCE_FILE" ]
  [ "$(cat "$PROV_TOKENS_DIR/forge-seed.pass")" = "$seed" ]
  [[ "$output" == *"autorité de création déjà posée"*"seed des comptes déjà posé"* ]]
}

@test "compte déjà présent hors banc : dit, la porte de repose nommée, et l'apply continue" {
  STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists [name: $ME]" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"compte « $ME » déjà présent"*"PROV_FORGE_ADMIN_RESET=1"* ]]
  refute grep -q 'user change-password' "$CALLS"
  [ -s "$PROV_TOKENS_DIR/forge-master.token" ]
}

@test "un refus de création qui n'est pas « déjà présent » est un échec qui cite la forge" {
  STUB_CREATE_RC=1 STUB_CREATE_ERR="database is locked" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"création du compte « $ME » refusée par la forge : database is locked"* ]]
  [ ! -s "$PROV_TOKENS_DIR/forge-master.token" ]
}

@test "en banc, le mot de passe de l'amiral est celui du contrat, posé même sur un compte déjà présent, et annoncé" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  LCARS_BENCH=1 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "user create .* _ $ME\$" "$CALLS" && grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
  : > "$CALLS"; rm -f "$PROV_TOKENS_DIR"/* "$PROV_ANNOUNCE_FILE"
  LCARS_BENCH=1 STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ]
  grep -q "user change-password .* _ $ME\$" "$CALLS" && grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  LCARS_BENCH=1 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ]
  refute grep -q 'user create' "$CALLS"
  grep -q "user change-password .* _ $ME\$" "$CALLS" && grep -qx 'PW=toto123456' "$CALLS"
  grep -q "$ME	toto123456" "$PROV_ANNOUNCE_FILE"
}

@test "PROV_FORGE_ADMIN_RESET pose un mot de passe neuf et l'annonce, jamais sur un compte tout juste créé" {
  export PROV_ANNOUNCE_FILE="$BATS_TEST_TMPDIR/creds"
  PROV_FORGE_ADMIN_RESET=1 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  refute grep -q 'user change-password' "$CALLS"
  : > "$CALLS"; rm -f "$PROV_ANNOUNCE_FILE"
  PROV_FORGE_ADMIN_RESET=1 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 0 ]
  grep -q "user change-password .* _ $ME\$" "$CALLS" && grep -qE '^PW=[A-Za-z]{10}$' "$CALLS"
  grep -q "$ME	" "$PROV_ANNOUNCE_FILE"
}

# ─── l'adminité et le siège ─────────────────────────────────────────────────────────────────────

@test "l'adminité se lit avec le jeton : admin OK, simple compte promu par l'API sans secret en argv, absent averti" {
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [[ "$output" == *"« $ME » administre la forge"* ]]
  : > "$CALLS"
  STUB_IS_ADMIN=false STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [[ "$output" == *"« $ME » promu administrateur"* ]]
  grep -q 'CURL:-K - .*admin/users/'"$ME"' | header = "Authorization: token tok-master".*request = "PATCH"' "$CALLS"
  refute grep -qE 'CURL:[^|]*tok-master' "$CALLS"
  STUB_USER_CODE=404 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod check
  [ "$status" -ne 2 ]
  [[ "$output" == *"« $ME » n'a pas de compte sur cette forge"* ]]
  STUB_IS_ADMIN=false STUB_PATCH_RC=22 STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"« $ME » n'a pas pu être promu administrateur"* ]]
}

@test "sans jeton, l'adminité est inconnue et rien n'est tenté" {
  STUB_PORTS="0.0.0.0:21000->3000/tcp" mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"AUCUNE autorité"*"adminité de « $ME » non mesurable"* ]]
  refute grep -q 'PATCH' "$CALLS"
}

@test "le siège s'enregistre à l'apply dans la table des uid, le check le voit ensuite et n'écrit rien" {
  rm -f "$PROV_UID_MAP_FILE"
  PROV_HUMAN="$(id -un)" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod check
  [ "$status" -ne 2 ]
  [ ! -e "$PROV_UID_MAP_FILE" ]
  PROV_HUMAN="$(id -un)" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [ "$(awk -F'\t' '$1 == 1 { print $3 }' "$PROV_UID_MAP_FILE")" = "$(id -un)" ]
  [[ "$output" == *"siège : « $(id -un) » enregistré"* ]]
  PROV_HUMAN="$(id -un)" STUB_PORTS="0.0.0.0:21000->3000/tcp" mod check
  [ "$status" -ne 2 ]
  [[ "$output" == *"siège : « $(id -un) » enregistré"* ]]
}

@test "deux acteurs pour un rôle : la divergence est un drift, et la table garde son occupant" {
  printf '1\t0\troot\n' > "$PROV_UID_MAP_FILE"
  PROV_FORGE_ADMIN="$(id -un)" STUB_SEAT=root STUB_PORTS="0.0.0.0:21000->3000/tcp" mod apply
  [[ "$output" == *"DRIFT"*"deux acteurs pour un rôle"* ]]
  [ "$(awk -F'\t' '$1 == 1 { print $3 }' "$PROV_UID_MAP_FILE")" = "root" ]
}
