#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench/bench-up.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du banc — forge, conteneur, amorçage, humain, semis, runner, fleet, verdict

load ../../refute
load ../../support/decor

free_ports() { # free_ports <n> — n ports libres distincts, sur une ligne
  python3 -c 'import socket,sys; ss=[socket.socket() for _ in range(int(sys.argv[1]))]; [s.bind(("127.0.0.1",0)) for s in ss]; print(" ".join(str(s.getsockname()[1]) for s in ss))' "$1"
}

sans_outil() { # sans_outil <outil> — un dossier qui porte tout le PATH de la machine sauf <outil>
  local d="$BATS_FILE_TMPDIR/sans-$1" dir f n
  local -A vu=()
  local -a dirs liens=()
  mkdir -p "$d"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      [[ -f "$f" && -x "$f" && -z "${vu[$n]:-}" ]] || continue
      case "$n" in "$1"|"$1".*) continue ;; esac
      vu[$n]=1; liens+=("$f")
    done
  done
  ln -s -t "$d" "${liens[@]}"
  printf '%s\n' "$d"
}

setup_file() {
  SANS_PYTHON3="$(sans_outil python3)"
  SANS_JQ="$(sans_outil jq)"
  export SANS_PYTHON3 SANS_JQ
}

setup() {
  decor_pose
  ROOT="$BATS_TEST_TMPDIR/fake"
  BENCH="$ROOT/deploy/docker/bench"
  DOCKER_D="$ROOT/deploy/docker"
  mkdir -p "$BENCH" "$ROOT/deploy/lib" "$ROOT/.git"
  cp "$BATS_TEST_DIRNAME/../../../docker/bench/bench-up.sh" "$BENCH/bench-up.sh"
  REAL="$BENCH/bench-up.sh"
  local f
  for f in provision-lib.sh docker-endpoint.sh store.sh forge-bootstrap.sh bench.sh; do cp "$BATS_TEST_DIRNAME/../../../lib/$f" "$ROOT/deploy/lib/"; done
  : > "$DOCKER_D/docker-compose.yml"; : > "$DOCKER_D/docker-compose.bench.yml"; : > "$DOCKER_D/forge-compose.yml"
  read -r BF BD BS DF DD DS < <(free_ports 6)
  export BF BD BS DF DD DS
  # les constantes de l'arbre portent des valeurs que rien d'autre n'écrit : le banc qui les rend les a lues
  CONSTANTES="$ROOT/deploy/installer-constants.env"
  { grep -vE '^(PROV_FORGE_BASE_DEFAULT|PROV_FORGE_HOST_PORT_DEFAULT|PROV_DECK_PORT_DEFAULT|PROV_SSH_PORT_DEFAULT|PROV_FORGE_INTERNAL_URL|PROV_RUNNER_LABELS)=' \
      "$BATS_TEST_DIRNAME/../../../installer-constants.env"
    printf '%s\n' PROV_FORGE_BASE_DEFAULT=banc-temoin "PROV_FORGE_HOST_PORT_DEFAULT=$DF" "PROV_DECK_PORT_DEFAULT=$DD" "PROV_SSH_PORT_DEFAULT=$DS" \
      PROV_FORGE_INTERNAL_URL=http://forge-temoin:3000 PROV_RUNNER_LABELS=shell:docker://alpine:temoin,dood:docker://docker:temoin
  } > "$CONSTANTES"
  SRC="$BATS_TEST_TMPDIR/bench-up"
  printf '#!/usr/bin/env bash\nexec bash "%s" --port-forge %s --port-deck %s --port-ssh %s "$@" < /dev/null\n' "$REAL" "$BF" "$BD" "$BS" > "$SRC"
  chmod +x "$SRC"

  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export CALLS
  # ce que les doublures rendent : un fichier par fait, modifiable par cas
  export IMAGE_REV_OUT="$BATS_TEST_TMPDIR/image_rev";   echo "deadbeef1" > "$IMAGE_REV_OUT"
  export MASTER_TOKEN_OUT="$BATS_TEST_TMPDIR/master";   echo "MASTER" > "$MASTER_TOKEN_OUT"
  export ACCEPTED_TOKEN="$BATS_TEST_TMPDIR/accepte";    echo "MASTER" > "$ACCEPTED_TOKEN"
  export SYS_TOKEN_OUT="$BATS_TEST_TMPDIR/sys";         echo "SYS-TOKEN" > "$SYS_TOKEN_OUT"
  export PROV_RC_OUT="$BATS_TEST_TMPDIR/prov_rc";       echo "0" > "$PROV_RC_OUT"
  export PROV_ANCIEN_OUT="$BATS_TEST_TMPDIR/prov_ancien"; : > "$PROV_ANCIEN_OUT"
  export HUMAN_RC="$BATS_TEST_TMPDIR/human_rc";         echo "0" > "$HUMAN_RC"
  export CREATE_RC="$BATS_TEST_TMPDIR/create_rc";       echo "0" > "$CREATE_RC"
  export FLEET_RC="$BATS_TEST_TMPDIR/fleet_rc";         echo "0" > "$FLEET_RC"
  export RUNNER_RC="$BATS_TEST_TMPDIR/runner_rc";       echo "0" > "$RUNNER_RC"
  export REV_OK="$BATS_TEST_TMPDIR/rev_ok";             echo "0" > "$REV_OK"
  export REMOTE_MAIN="$BATS_TEST_TMPDIR/remote_main";   : > "$REMOTE_MAIN"
  export ANCESTOR_RC="$BATS_TEST_TMPDIR/ancestor";      echo "0" > "$ANCESTOR_RC"
  export PATCH_CODE="$BATS_TEST_TMPDIR/patch";          echo "200" > "$PATCH_CODE"
  export DAEMON_MORT="$BATS_TEST_TMPDIR/daemon-mort"
  export PS_RC="$BATS_TEST_TMPDIR/ps_rc";               echo "0" > "$PS_RC"
  # les objets des projets du banc, « <nom>:<c|v>:<marqueur> », rangés dans le projet que leur nom porte
  export OBJETS=""
  export SOURCE_OWNER_OUT="$BATS_TEST_TMPDIR/owner";    echo "admiral" > "$SOURCE_OWNER_OUT"
  export PORT_HOLDER="$BATS_TEST_TMPDIR/port_holder"
  export CREDS_POSED="$BATS_TEST_TMPDIR/creds_posed"

  cat > "$DOCKER_D/forge-runner.sh" <<'FAKE'
#!/usr/bin/env bash
echo "RUNNER:$*" >> "$CALLS"
while [[ $# -gt 0 ]]; do
  case "$1" in *-file) echo "RUNNER-FILE:$1=$(cat "$2") mode=$(stat -c %a "$2") dossier=$(stat -c %a "$(dirname "$2")") $2" >> "$CALLS"; shift ;; esac
  shift
done
rc="$(cat "$RUNNER_RC")"
[[ "$rc" -eq 0 ]] || echo "REFUS-TEMOIN: image(s) introuvable(s) sur ce daemon: alpine:3.20" >&2
exit "$rc"
FAKE
  cat > "$ROOT/deploy/lib/enroll-catalogue.sh" <<'FAKE'
#!/usr/bin/env bash
echo "ENROLL:$*" >> "$CALLS"
dir=""; while [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done
echo '{"roles":[]}' > "$dir/roles.auto.tfvars.json"
printf '[enroll-catalogue] rôles     : system_architect fleet_engineer\n[enroll-catalogue] org       : %s\n' "${ORG_ROSTER:-fleet}"
FAKE
  chmod 0755 "$DOCKER_D/forge-runner.sh" "$ROOT/deploy/lib/enroll-catalogue.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  cat > "$BINDIR/dockerstub" <<'FAKE'
#!/usr/bin/env bash
argv="$*"
stdin=""; [[ -p /dev/stdin || -f /dev/stdin ]] && stdin="$(cat)"
echo "DOCKER:$argv${stdin:+ <<< $stdin}" >> "$CALLS"
objets() {
  local o nom type marque ligne
  for o in $OBJETS; do
    IFS=: read -r nom type marque <<<"$o"
    [[ "$type" == "$2" && "$nom" == "$1"[-_]* ]] || continue
    ligne="${3//\{\{.Names\}\}/$nom}"; ligne="${ligne//\{\{.Name\}\}/$nom}"
    printf '%s\n' "${ligne//\{\{.Label \"lcars.bench\"\}\}/$marque}"
  done
}
case "$argv" in
  "ps -a --filter label=com.docker.compose.project="*)
    [[ "$(cat "$PS_RC")" -eq 0 ]] || exit 1
    objets "${4#label=com.docker.compose.project=}" c "$6"; exit 0 ;;
  "volume ls --filter label=com.docker.compose.project="*)
    objets "${4#label=com.docker.compose.project=}" v "$6"; exit 0 ;;
  *" up -d"*)                    env | grep '^LCARS_\|^FORGE_' | sort >> "$CALLS"; exit 0 ;;
  *"ps --filter publish="*)      [[ -f "$PORT_HOLDER" ]] && cat "$PORT_HOLDER"; exit 0 ;;
  *"com.docker.compose.project"*) echo "un-autre-projet"; exit 0 ;;
  version*)                      [[ -e "$DAEMON_MORT" ]] && exit 1; echo "29.0.0"; exit 0 ;;
  *"stat -c %U "*)               cat "$SOURCE_OWNER_OUT"; exit 0 ;;
  "inspect -f {{.State.Health.Status}}"*) echo healthy; exit 0 ;;
  "image inspect -f"*)           cat "$IMAGE_REV_OUT"; exit 0 ;;
  "image inspect"*)              exit 0 ;;
  *"user create"*)               rc="$(cat "$CREATE_RC")"; [[ "$rc" -eq 0 ]] || echo "user already exists" >&2; exit "$rc" ;;
  *"generate-access-token"*)     cat "$MASTER_TOKEN_OUT"; exit 0 ;;
  *"forge-seed.pass"*)           exit 1 ;;
  *"id -u "*)                    exit "$(cat "$HUMAN_RC")" ;;
  *"system_starfleet.gitea_token"*) cat "$SYS_TOKEN_OUT"; exit 0 ;;
  *"*.gitea_token"*)             echo 9; exit 0 ;;
  *"credentials.json"*)          [[ "$argv" == *"mkdir"* ]] && { touch "$CREDS_POSED"; exit 0; }; [[ -e "$CREDS_POSED" ]] && echo oui || echo non; exit 0 ;;
  *"lcars-forge.rc"*)        cat "$PROV_RC_OUT"; exit 0 ;;
  *"lcars-provision.rc"*)    [[ -s "$PROV_ANCIEN_OUT" ]] || exit 1; cat "$PROV_ANCIEN_OUT"; exit 0 ;;
  *"forge-gestures.sh runner-token"*) echo REG-TOKEN-TEMOIN; exit 0 ;;
  *" env "*"fleet start")        exit "$(cat "$FLEET_RC")" ;;
esac
exit 0
FAKE
  # curl reçoit l'en-tête d'authentification sur son entrée et le corps JSON dans un fichier
  cat > "$BINDIR/curl" <<'FAKE'
#!/usr/bin/env bash
echo "CURL-ARGV:$*" >> "$CALLS"
hdr="$(cat)"; out=/dev/null; fmt=""; method=GET; body=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$(cat "${2#@}")"; shift 2 ;;
    -m|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "CURL:$method $url | $hdr | $body" >> "$CALLS"
code=200; rep=""
case "$method $url" in
  "GET "*/api/v1/user)              [[ "$hdr" == "Authorization: token $(cat "$ACCEPTED_TOKEN")" || "$hdr" == "Authorization: Basic "* ]] || code=401 ;;
  "PATCH "*/api/v1/admin/users/*)   code="$(cat "$PATCH_CODE")" ;;
  "POST "*/api/v1/users/*/tokens)   code=201; rep='{"sha1":"OP-TOKEN"}' ;;
  "GET "*/api/v1/users/*)           rep='{"is_admin":true}' ;;
esac
printf '%s' "$rep" > "$out"
[[ -z "$fmt" ]] || printf '%s' "$code"
FAKE
  # git note son argv et son environnement ; un fichier inclus par -c include.path est noté avec son mode
  cat > "$BINDIR/git" <<'FAKE'
#!/usr/bin/env bash
echo "GIT:$*" >> "$CALLS"
env | sed 's/^/GIT-ENV:/' >> "$CALLS"
[[ "$1 $2" != "-c include.path="* ]] || { f="${2#include.path=}"; echo "GIT-INCLUDE:$(stat -c %a "$f") $f"; sed 's/^/GIT-INCLUDE-LIGNE:/' "$f"; } >> "$CALLS"
case "$*" in
  *"rev-parse -q --verify"*) exit "$(cat "$REV_OK")" ;;
  *"rev-parse HEAD"*)        echo "kitcommit1"; exit 0 ;;
  *"ls-remote"*)           r="$(cat "$REMOTE_MAIN")"; [[ -z "$r" ]] || echo "$r	refs/heads/main"; exit 0 ;;
  *"merge-base --is-ancestor"*) exit "$(cat "$ANCESTOR_RC")" ;;
esac
exit 0
FAKE
  chmod 0755 "$BINDIR/dockerstub" "$BINDIR/curl" "$BINDIR/git"
  # python3 n'est pas sur ce PATH : le banc lit la forge par jq
  export PATH="$BINDIR:$DECOR_BIN:$SANS_PYTHON3"
  export DOCKER_BIN=dockerstub DOCKER_HOST=unix:///dev/null
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

run_bench() { run bash "$SRC" --forge-project bt --image lcars-fleet:9 "$@"; }


@test "runner demandé et servi, conteneur convergé, fleet démarrée : banc PRÊT, sortie 0" {
  run_bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"[bench-up] banc PRÊT"* ]]
  [[ "$output" != *"PAS PRÊT"* ]]
  [[ "$output" == *"fleet     : démarrée sous lcars (sans credentials claude"*"converge  : convergé"* ]]
  [[ "$output" == *"forge     : "*"(admiral / toto123456 · lcars / toto32toto32)"* ]]
}

@test "le conteneur publie un échec de convergence : PAS PRÊT, sortie 6, même avec un runner servi, et la fleet n'est pas lancée" {
  echo "1" > "$PROV_RC_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRÊT — le conteneur s'est déclaré en échec"*"rc=1"*"provision doctor"* ]]
  [[ "$output" != *"le runner était demandé"* ]]
  refute grep -q 'lcars-1 env.* fleet start' "$CALLS"
}

@test "un drift résiduel (rc 2) n'est pas un échec : le banc reste PRÊT et le drift se dit" {
  echo "2" > "$PROV_RC_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRÊT"*"drift résiduel"* ]]
}

@test "un verdict de conteneur illisible est une non-mesure, dite, pas un échec" {
  printf 'cat: /run/lcars-forge.rc: No such file or directory\n' > "$PROV_RC_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRÊT"*"non mesuré"* ]]
}

@test "une image qui publie son verdict dans lcars-provision.rc : un échec y est lu, un 0 est dit sans distinction du drift, jamais « convergé »" {
  : > "$PROV_RC_OUT"
  echo 0 > "$PROV_ANCIEN_OUT"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"converge  : aucun geste en échec — cette image publie son verdict sans distinguer un drift"* ]]
  [[ "$output" != *"converge  : convergé"* ]]
  echo 1 > "$PROV_ANCIEN_OUT"
  run_bench --no-runner
  [ "$status" -eq 6 ]
  [[ "$output" == *"converge  : en échec (rc=1)"* ]]
}

@test "l'org du roster nomme le dépôt semé ; un roster sans org sème dans l'org par défaut des constantes" {
  ORG_ROSTER=escadre run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "push -q http://127.0.0.1:$BF/escadre/lcars.git " "$CALLS"
  [[ "$output" == *"roster dérivé du catalogue de l'image (system_architect fleet_engineer) · org escadre"* ]]
  : > "$CALLS"
  ORG_ROSTER="<non déclarée>" run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "push -q http://127.0.0.1:$BF/fleet/lcars.git " "$CALLS"
}

@test "le jeton système absent du conteneur après la relance : arrêt en 6, aucun push" {
  : > "$SYS_TOKEN_OUT"
  run_bench --no-runner
  [ "$status" -eq 6 ]
  [[ "$output" == *"jeton système absent après la relance"* ]]
  refute grep -q 'GIT:.*push' "$CALLS"
}

@test "--no-runner porte son propre verdict, jamais celui du banc complet" {
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRÊT sans CI"* ]]
  [[ "$output" != *"PAS PRÊT"* ]]
  refute grep -q '^RUNNER:' "$CALLS"
}


@test "le runner reçoit la forge, les deux jetons par fichier, le réseau, le projet, les labels des constantes et la base du banc" {
  run_bench
  [ "$status" -eq 0 ]
  local ligne; ligne="$(grep '^RUNNER:' "$CALLS")"
  [[ "$ligne" == *"--forge-api http://127.0.0.1:$BF/api/v1 --admin-token-file "*" --reg-token-file "*"--network bt-forge_default"*"--project bt-runner"* ]]
  [[ "$ligne" == *" --instance-url http://"*":$BF --network "* ]]
  [[ "$ligne" != *"--instance-url http://127.0.0.1:"* ]]
  [[ "$ligne" != *MASTER* && "$ligne" != *REG-TOKEN-TEMOIN* ]]
  grep -qE '^RUNNER-FILE:--admin-token-file=MASTER mode=600 dossier=700 ' "$CALLS"
  grep -qE '^RUNNER-FILE:--reg-token-file=REG-TOKEN-TEMOIN mode=600 dossier=700 ' "$CALLS"
  [[ "$ligne" == *" --labels shell:docker://alpine:temoin,dood:docker://docker:temoin --bench bt" ]]
  [[ "$output" == *"runner    : enregistré — labels : shell:docker://alpine:temoin,dood:docker://docker:temoin"* ]]
}

@test "le jeton master se vérifie par son en-tête : la forge qui en attend un autre arrête le banc en 4" {
  echo AUTRE > "$ACCEPTED_TOKEN"
  run_bench --no-runner
  [ "$status" -eq 4 ]
  [[ "$output" == *"le jeton master ne s'authentifie pas"* ]]
  grep -qx "CURL:GET http://127.0.0.1:$BF/api/v1/user | Authorization: token MASTER | " "$CALLS"
}

@test "forge-runner.sh en échec : PAS PRÊT, sortie 6, son refus mot pour mot, le journal conservé et nommé, les détails avant le refus" {
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  echo 1 > "$RUNNER_RC"
  TMPDIR="$T" run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"banc PAS PRÊT — le runner était demandé et ne sert pas"*"runner    : absent"*"REFUS-TEMOIN"*"alpine:3.20"*"sortie complète conservée : $T/forge-runner-"*"détruire  :"*"banc incomplet"* ]]
  [ "$(find "$T" -name 'forge-runner-*' | wc -l)" -eq 1 ]
}

@test "un banc réussi ne laisse aucun journal de sous-script et ne déverse pas sa sortie" {
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  TMPDIR="$T" run_bench
  [ "$status" -eq 0 ]
  [ "$(find "$T" -name 'forge-runner-*' | wc -l)" -eq 0 ]
  [[ "$output" != *"REFUS-TEMOIN"* ]]
}


@test "une image sans révision, ou « unknown », est refusée en 7 avant toute forge ; une image estampillée montre sa révision" {
  : > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  [[ "$output" == *"ne porte pas de révision"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
  echo unknown > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  echo deadbeef1 > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"révision  : deadbeef1"* ]]
}


@test "l'adresse annoncée n'est jamais le joker d'écoute, et seule l'entrée annoncée est déclarée au deck" {
  run_bench --no-runner --bind 0.0.0.0 --advertise 10.0.0.9
  [ "$status" -eq 0 ]
  [[ "$output" != *"http://0.0.0.0:"* ]]
  [[ "$output" == *"http://10.0.0.9:$BF"*"http://10.0.0.9:$BD"* ]]
  grep -qx "LCARS_DECK_ORIGINS=http://10.0.0.9:$BD" "$CALLS"
  grep -qx "LCARS_DEVFORGE_ROOT_URL=http://10.0.0.9:$BF/" "$CALLS"
}

@test "un bind précis rend les deux adresses égales et referme le banc sur cette machine" {
  run_bench --no-runner --bind 127.0.0.5
  [[ "$output" == *"http://127.0.0.5:$BF"*"cette machine seulement"* ]]
  [[ "$output" == *"ssh lcars@127.0.0.5 -p $BS"* ]]
}

@test "ouvert sur le réseau, le banc dit ce que ça coûte" {
  run_bench --no-runner --bind 0.0.0.0 --advertise 10.0.0.9
  [[ "$output" == *"ouvert sur le réseau"*"--bind 127.0.0.1"* ]]
}

@test "un port déjà tenu par un autre banc est refusé avant de créer quoi que ce soit" {
  echo "un-autre-banc" > "$PORT_HOLDER"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"refus : un autre conteneur"*"un-autre-banc (projet un-autre-projet)"*"bench-down.sh"*"--port-forge"* ]]
  refute grep -qE 'compose .* (up|create)' "$CALLS"
}


@test "la forge monte avec port, bind et URL racine, puis admiral est créé sans mot de passe dans la CLI de la forge, et reçoit celui du contrat par l'API au jeton master" {
  run_bench --no-runner --advertise 10.0.0.9
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "DOCKER:compose -f .*forge-compose.yml -f .*forge-compose.bench.yml -p bt-forge up -d" "$CALLS"
  grep -qx "LCARS_DEVFORGE_PORT=$BF" "$CALLS"
  grep -q "DOCKER:exec -i -u root bt-fleet-lcars-1 chpasswd <<< admiral:toto123456" "$CALLS"
  grep -qx 'DOCKER:exec -u git bt-forge-gitea-1 gitea admin user create --username admiral --random-password --email admiral@lcars.local --admin --must-change-password=false' "$CALLS"
  local patch; patch="$(grep "^CURL:PATCH http://127.0.0.1:$BF/api/v1/admin/users/admiral | Authorization: token MASTER | " "$CALLS")"
  [ "$(jq -c '{password, admin}' <<<"${patch##* | }")" = '{"password":"toto123456","admin":true}' ]
  grep -E '^(DOCKER|CURL-ARGV):' "$CALLS" | grep -v '<<<' | refute_out 'toto123456'
  [[ "$output" == *"compte admiral créé"*"mot de passe de banc posé sur admiral"* ]]
}

@test "admiral déjà présent : le mot de passe du contrat est reposé par l'API, et l'amorçage continue" {
  echo 1 > "$CREATE_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^CURL:PATCH http://127.0.0.1:$BF/api/v1/admin/users/admiral | Authorization: token MASTER | " "$CALLS"
  [[ "$output" == *"compte admiral déjà présent"*"mot de passe de banc posé sur admiral"* ]]
}

@test "la forge refuse le mot de passe d'admiral : arrêt en 4 qui le nomme, avant le conteneur" {
  echo 403 > "$PATCH_CODE"
  run_bench --no-runner
  [ "$status" -eq 4 ]
  [[ "$output" == *"la forge refuse le compte « admiral » (HTTP 403)"*"mot de passe de banc de admiral non posé"* ]]
  refute grep -q 'config-token' "$CALLS"
}

@test "sans jeton master rendu par la forge, le banc s'arrête en 4 et le dit" {
  : > "$MASTER_TOKEN_OUT"
  run_bench --no-runner
  [ "$status" -eq 4 ]
  [[ "$output" == *"jeton master"* ]]
  refute grep -q 'config-token' "$CALLS"
}

@test "le jeton et le seed entrent dans le conteneur par stdin, le roster vient de l'image, la structure s'applique avec l'humain nommé" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "forge-gestures.sh config-token <<< MASTER" "$CALLS"
  grep -qE "forge-gestures.sh config-seed <<< [A-Za-z0-9]{20}" "$CALLS"
  grep -q "ENROLL:--tofu-dir .* --image lcars-fleet:9" "$CALLS"
  refute grep -q 'ENROLL:.*--repo' "$CALLS"
  local depot; depot="$(grep -F 'DOCKER:exec -i -u root bt-fleet-lcars-1 sh -c ' "$CALLS" | grep -F 'roles.auto.tfvars.json')"
  [[ "$depot" == *" sh /opt/lcars/services/forge-recipe/roles.auto.tfvars.json <<< {\"roles\":[]}" ]]
  grep -q "DOCKER:exec -i -u root -e LCARS_BUILTIN_HUMAN=lcars -e LCARS_BUILTIN_EMAIL=lcars@lcars.local bt-fleet-lcars-1 /opt/lcars/forge-gestures.sh apply" "$CALLS"
  refute grep -qE 'DOCKER:[^<]*MASTER' "$CALLS"
}

@test "l'humain du banc : mot de passe et site-admin par l'API avec le jeton master en en-tête, jeton opérateur posé après la relance, mot de passe unix" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local patch; patch="$(grep "^CURL:PATCH http://127.0.0.1:$BF/api/v1/admin/users/lcars | Authorization: token MASTER | " "$CALLS")"
  [ "$(jq -c '{password, admin}' <<<"${patch##* | }")" = '{"password":"toto32toto32","admin":true}' ]
  grep '^CURL-ARGV:' "$CALLS" | refute_out 'MASTER|toto32toto32'
  local relance jeton; relance="$(grep -n '^DOCKER:restart' "$CALLS" | cut -d: -f1)"; jeton="$(grep -n 'gitea_token <<< OP-TOKEN' "$CALLS" | cut -d: -f1)"
  [ -n "$relance" ]
  [ -n "$jeton" ]
  [ "$relance" -lt "$jeton" ]
  grep -q "chpasswd <<< lcars:toto32toto32" "$CALLS"
}

@test "l'humain absent du conteneur après la relance est un arrêt en 5 qui nomme le convergeur" {
  echo 1 > "$HUMAN_RC"
  run_bench --no-runner
  [ "$status" -eq 5 ]
  [[ "$output" == *"n'existe pas dans le conteneur après la relance"*"convergeur"* ]]
}

@test "credentials claude : absentes, dites et le banc continue ; présentes, posées chez l'humain par stdin" {
  run_bench --no-runner --creds-from "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creds claude absentes"*"le banc continue"*"creds     : non"* ]]
  printf 'CREDS-DE-DECOR\n' > "$BATS_TEST_TMPDIR/creds.json"
  run_bench --no-runner --creds-from "$BATS_TEST_TMPDIR/creds.json"
  [ "$status" -eq 0 ]
  grep -q "credentials.json <<< CREDS-DE-DECOR" "$CALLS"
  [[ "$output" == *"creds claude posées chez lcars"* ]]
}

@test "--no-creds est un choix, dit comme tel, et rien n'est lu ni posé" {
  printf 'CREDS-DE-DECOR\n' > "$BATS_TEST_TMPDIR/creds.json"
  run_bench --no-runner --no-creds --creds-from "$BATS_TEST_TMPDIR/creds.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creds claude non posées (--no-creds)"*"par choix"*"creds     : non"* ]]
  refute grep -q 'CREDS-DE-DECOR' "$CALLS"
}

# ─── le semis des dépôts ────────────────────────────────────────────────────────────────────────

@test "le semis pousse la révision de l'image sur main, le jeton système dans un fichier de configuration 0600 inclus par git, ni dans son argv ni dans son environnement, et sans --force" {
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  TMPDIR="$T" run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE "^GIT:-c include.path=$T/bench-up-jetons\.[^/]+/git-forge -C $ROOT push -q http://127.0.0.1:$BF/fleet/lcars.git deadbeef1:refs/heads/main$" "$CALLS"
  grep -qE "^GIT-INCLUDE:600 $T/bench-up-jetons\." "$CALLS"
  [ "$(grep '^GIT-INCLUDE-LIGNE:' "$CALLS" | sort -u)" = "$(printf 'GIT-INCLUDE-LIGNE:\textraHeader = Authorization: token SYS-TOKEN\nGIT-INCLUDE-LIGNE:[http "http://127.0.0.1:%s/"]' "$BF" | sort)" ]
  grep -E '^(GIT|GIT-ENV|DOCKER|CURL-ARGV):' "$CALLS" | refute_out 'SYS-TOKEN'
  [ "$(find "$T" -name 'bench-up-jetons.*' | wc -l)" -eq 0 ]
  refute grep -q 'push -q --force' "$CALLS"
  [[ "$output" == *"main poussé (révision de l'image : deadbeef1)"* ]]
  refute grep -q 'GIT:.* ops:ops' "$CALLS"
  refute grep -q '^CURL:POST .*/repos' "$CALLS"
}

@test "une forge qui porte déjà un main étranger : le hook est levé et le push forcé, dit" {
  echo "0123456789abcdef" > "$REMOTE_MAIN"; echo 1 > "$ANCESTOR_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE "^GIT:-c include.path=[^ ]+ -C $ROOT -c core.hooksPath=/dev/null push -q --force " "$CALLS"
  [[ "$output" == *"main existe déjà sur la forge de banc (012345678)"*"poussé de force"* ]]
}

@test "une révision d'image absente du clone est refusée : le banc ne sème pas un autre code" {
  echo 1 > "$REV_OK"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  [[ "$output" == *"n'est pas dans ce clone"* ]]
  refute grep -q 'GIT:.*push' "$CALLS"
}

@test "depuis un kit (sans .git) : la révision vient de .source-revision, et main est un commit unique bâti de l'arbre du kit" {
  rm -rf "$ROOT/.git"
  echo "deadbeef1" > "$ROOT/.source-revision"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE "GIT:--git-dir=[^ ]+/\.git --work-tree=$ROOT add -A" "$CALLS"
  grep -q "commit -q -m kit deadbeef1" "$CALLS"
  grep -q "push -q http://127.0.0.1:$BF/fleet/lcars.git kitcommit1:refs/heads/main" "$CALLS"
  refute grep -q "rev-parse -q --verify" "$CALLS"
  [[ "$output" == *"main poussé (kit deadbeef1, un commit sans historique)"* ]]
}

@test "depuis un kit dont la révision n'est pas celle de l'image : refus qui nomme les deux, rien n'est poussé" {
  rm -rf "$ROOT/.git"
  echo "cafe0001" > "$ROOT/.source-revision"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  [[ "$output" == *"ce kit atteste « cafe0001 » et l'image lcars-fleet:9 porte deadbeef1"* ]]
  refute grep -q 'GIT:.*push' "$CALLS"
}

# ─── la fleet ───────────────────────────────────────────────────────────────────────────────────

@test "la fleet démarre sous l'humain : sans credentials avec LCARS_START_WITHOUT_CLAUDE=1, avec credentials sans lui" {
  run_bench --no-runner
  grep -q "DOCKER:exec -u lcars bt-fleet-lcars-1 env LCARS_START_WITHOUT_CLAUDE=1 fleet start" "$CALLS"
  printf 'CREDS\n' > "$BATS_TEST_TMPDIR/creds.json"; : > "$CALLS"
  run_bench --no-runner --creds-from "$BATS_TEST_TMPDIR/creds.json"
  grep -q "DOCKER:exec -u lcars bt-fleet-lcars-1 env fleet start" "$CALLS"
}

@test "une fleet qui ne démarre pas : banc PAS PRÊT, sortie 6, l'échec nommé — avec ou sans runner" {
  echo 1 > "$FLEET_RC"
  run_bench --no-runner
  [ "$status" -eq 6 ]
  [[ "$output" == *"banc PAS PRÊT — la fleet ne démarre pas sous lcars"*"fleet     : « fleet start » a échoué sous lcars"*"détruire  :"*"banc incomplet"* ]]
  [[ "$output" != *"banc PRÊT sans CI"* ]]
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"banc PAS PRÊT — la fleet ne démarre pas sous lcars"* ]]
  [[ "$output" != *"[bench-up] banc PRÊT"$'\n'* ]]
}

# ─── la source du conteneur, le daemon, les substitutions ──────────────────────────────────────

@test "après le semis, le clone du conteneur se réaligne sur le main poussé, sous son propriétaire, et après le push" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local push fetch reset
  push="$(grep -n 'GIT:.* push -q ' "$CALLS" | head -1 | cut -d: -f1)"
  fetch="$(grep -n 'DOCKER:exec -i -u admiral bt-fleet-lcars-1 git -C /home/projects/LCARS fetch -q --depth 1 http://forge-temoin:3000/fleet/lcars.git main' "$CALLS" | cut -d: -f1)"
  reset="$(grep -n 'DOCKER:exec -i -u admiral bt-fleet-lcars-1 git -C /home/projects/LCARS reset -q --hard FETCH_HEAD' "$CALLS" | cut -d: -f1)"
  [ -n "$push" ]
  [ -n "$fetch" ]
  [ -n "$reset" ]
  [ "$push" -lt "$fetch" ]
  [ "$fetch" -lt "$reset" ]
  [[ "$output" == *"source du conteneur alignée sur main (/home/projects/LCARS)"* ]]
}

@test "sans clone dans le conteneur, la source y est clonée depuis main par admiral" {
  : > "$SOURCE_OWNER_OUT"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'DOCKER:exec -i -u admiral bt-fleet-lcars-1 git clone -q --depth 1 http://forge-temoin:3000/fleet/lcars.git /home/projects/LCARS' "$CALLS"
  [[ "$output" == *"source du conteneur clonée depuis main"* ]]
}

@test "sans drapeau, projet et ports du banc viennent des constantes" {
  run bash "$REAL" --image lcars-fleet:9 --no-runner < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "DOCKER:compose -f $DOCKER_D/forge-compose.yml -f $DOCKER_D/forge-compose.bench.yml -p banc-temoin-forge up -d" "$CALLS"
  grep -qx "LCARS_DEVFORGE_PORT=$DF" "$CALLS"
  grep -qx "LCARS_SSH_PORT=0.0.0.0:$DS" "$CALLS"
  grep -qx "LCARS_LANDING_PORT_BIND=0.0.0.0:$DD" "$CALLS"
}

@test "le conteneur se crée et démarre par un compose qui lit les constantes de l'arbre, et reçoit la base du banc" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE "^DOCKER:compose --env-file [^ ]+ -f $DOCKER_D/docker-compose.yml -f $DOCKER_D/docker-compose.bench.yml -p bt-fleet up -d --no-build lcars$" "$CALLS"
  grep -qx 'LCARS_BENCH_BASE=bt' "$CALLS"
  # compose refuse un volume externe absent : le magasin du projet du conteneur existe avant le up
  local magasin up
  magasin="$(grep -n '^DOCKER:volume create bt-fleet-cache$' "$CALLS" | cut -d: -f1)"
  up="$(grep -n -- '-p bt-fleet up -d' "$CALLS" | cut -d: -f1)"
  [ -n "$magasin" ]
  [ "$magasin" -lt "$up" ]
  local f
  for f in $(grep -oE '^DOCKER:compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$CONSTANTES" ]
  done
}

@test "jq manque : le banc le nomme et s'arrête en 1, avant toute forge" {
  export PATH="$BINDIR:$DECOR_BIN:$SANS_JQ"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq requis sur ce poste"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
}

@test "sous un décor, les jetons lus dans le conteneur gardent leurs chemins canoniques" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'DOCKER:exec -i -u root bt-fleet-lcars-1 cat /opt/lcars/var/tokens/system_starfleet.gitea_token$' "$CALLS"
  grep -q 'DOCKER:exec -i -u root bt-fleet-lcars-1 cat /opt/lcars/var/tokens/forge-seed.pass$' "$CALLS"
  [[ "$output" == *"jetons    : 9 fichiers dans /opt/lcars/var/tokens"$'\n'* ]]
}

@test "aucun daemon joignable : le refus de la sonde commune, en 1, avant toute forge" {
  touch "$DAEMON_MORT"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun daemon docker joignable"*"$LCARS_DECOR_ROOT/var/run/docker.sock[absent]"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
}

@test "un « docker ps » en échec est un arrêt en 1 qui le dit, avant toute forge" {
  echo 1 > "$PS_RC"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker ne rend pas les objets des projets bt-fleet, bt-forge, bt-runner"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
}

@test "la forge d'un poste homonyme (projet sans marqueur) est refusée en 1 : ni montée, ni admiral reposé" {
  export OBJETS="bt-forge-gitea-1:c: bt-forge_data:v:"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"sans son marqueur"*"conteneur bt-forge-gitea-1 (projet bt-forge)"*"volume bt-forge_data (projet bt-forge)"*"docker compose -p bt-forge down -v"* ]]
  [[ "$output" != *"reset"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
  refute grep -q 'change-password' "$CALLS"
}

@test "un runner de poste homonyme est refusé aussi : forge-runner le détruirait" {
  export OBJETS="bt-runner-act-1:c:"
  run_bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"conteneur bt-runner-act-1 (projet bt-runner)"*"docker compose -p bt-runner down -v"* ]]
  [[ "$output" != *"-p bt-forge"* && "$output" != *"reset"* ]]
  refute grep -q '^RUNNER:' "$CALLS"
}

@test "un banc posé avant le marqueur : chaque projet refusé vient avec son geste — reset pour le conteneur, down -v pour la forge et le runner" {
  export OBJETS="bt-fleet-lcars-1:c: bt-forge-gitea-1:c: bt-runner-act-1:c:"
  run_bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"deploy/container -p bt-fleet reset"*"docker compose -p bt-forge down -v"*"docker compose -p bt-runner down -v"* ]]
  [[ "$output" != *"container -p bt-forge"* && "$output" != *"container -p bt-runner"* ]]
}

@test "un banc déjà monté sous cette base est refusé : il se détruit d'abord" {
  export OBJETS="bt-fleet-lcars-1:c:bt bt-forge-gitea-1:c:bt"
  run_bench --no-runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"le banc bt existe déjà (bt-fleet)"*"bench-down.sh --project bt --yes"* ]]
  refute grep -q 'forge-compose.yml' "$CALLS"
}

@test "le conteneur ne reçoit pas de LCARS_BIND, que le compose ne lit pas" {
  run_bench --no-runner
  [ "$status" -eq 0 ]
  refute grep -q '^LCARS_BIND=' "$CALLS"
  grep -qx "LCARS_SSH_PORT=0.0.0.0:$BS" "$CALLS"
}

@test "les fichiers de jetons du runner ont existé sous TMPDIR, en 0600, et ne survivent pas au banc" {
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  TMPDIR="$T" run_bench
  [ "$status" -eq 0 ]
  local fichiers; fichiers="$(sed -n 's/^RUNNER-FILE:[^ ]* mode=600 dossier=700 //p' "$CALLS")"
  [ "$(grep -c "^$T/bench-up-jetons\.[^/]*/" <<<"$fichiers")" -eq 2 ]
  [ "$(find "$T" -name 'bench-up-jetons.*' | wc -l)" -eq 0 ]
}

@test "hors WSL, une adresse annoncée de loopback n'enrôle aucun runner : le banc le dit PAS PRÊT, en nommant --advertise" {
  PROV_SUBSTRATE=linux run_bench --advertise 127.0.0.1
  [ "$status" -eq 6 ] || { echo "$output"; return 1; }
  [[ "$output" == *"runner    : absent — aucune adresse de cette machine ne joint la forge depuis un job CI (adresse annoncée : 127.0.0.1) ; --advertise"* ]]
  refute grep -q '^RUNNER:' "$CALLS"
}
