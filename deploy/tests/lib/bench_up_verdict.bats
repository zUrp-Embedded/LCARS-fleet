#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/bench_up_verdict.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du banc — forge, conteneur, amorçage, humain, semis, runner, fleet, verdict
#
# bench-up.sh est copié dans un arbre factice avec les libs réelles ; docker, curl, git,
# enroll-catalogue.sh et forge-runner.sh sont des doublures qui notent leurs appels. Trois ports
# libres sont pris à chaque cas pour que la sonde de ports réelle ne voie rien de tenu.

load ../refute

free_ports() { # free_ports <n> — n ports libres distincts, sur une ligne
  python3 -c 'import socket,sys; ss=[socket.socket() for _ in range(int(sys.argv[1]))]; [s.bind(("127.0.0.1",0)) for s in ss]; print(" ".join(str(s.getsockname()[1]) for s in ss))' "$1"
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/fake"
  BENCH="$ROOT/deploy/docker/bench"
  DOCKER_D="$ROOT/deploy/docker"
  mkdir -p "$BENCH" "$ROOT/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../../docker/bench/bench-up.sh" "$BENCH/bench-up.sh"
  REAL="$BENCH/bench-up.sh"
  local f
  for f in provision-lib.sh docker-endpoint.sh store.sh forge-bootstrap.sh; do cp "$BATS_TEST_DIRNAME/../../lib/$f" "$ROOT/deploy/lib/"; done
  : > "$DOCKER_D/docker-compose.yml"; : > "$DOCKER_D/docker-compose.bench.yml"; : > "$DOCKER_D/forge-compose.yml"
  read -r BF BD BS < <(free_ports 3)
  export BF BD BS
  SRC="$BATS_TEST_TMPDIR/bench-up"
  printf '#!/usr/bin/env bash\nexec bash "%s" --port-forge %s --port-deck %s --port-ssh %s "$@" < /dev/null\n' "$REAL" "$BF" "$BD" "$BS" > "$SRC"
  chmod +x "$SRC"

  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export CALLS
  # ce que les doublures rendent : un fichier par fait, modifiable par cas
  export IMAGE_REV_OUT="$BATS_TEST_TMPDIR/image_rev";   echo "deadbeef1" > "$IMAGE_REV_OUT"
  export MASTER_TOKEN_OUT="$BATS_TEST_TMPDIR/master";   echo "MASTER" > "$MASTER_TOKEN_OUT"
  export SYS_TOKEN_OUT="$BATS_TEST_TMPDIR/sys";         echo "SYS-TOKEN" > "$SYS_TOKEN_OUT"
  export PROV_RC_OUT="$BATS_TEST_TMPDIR/prov_rc";       echo "0" > "$PROV_RC_OUT"
  export HUMAN_RC="$BATS_TEST_TMPDIR/human_rc";         echo "0" > "$HUMAN_RC"
  export CREATE_RC="$BATS_TEST_TMPDIR/create_rc";       echo "0" > "$CREATE_RC"
  export FLEET_RC="$BATS_TEST_TMPDIR/fleet_rc";         echo "0" > "$FLEET_RC"
  export RUNNER_RC="$BATS_TEST_TMPDIR/runner_rc";       echo "0" > "$RUNNER_RC"
  export RUNNERS_JSON="$BATS_TEST_TMPDIR/runners";      printf '{"runners":[{"id":1}]}\n' > "$RUNNERS_JSON"
  export REV_OK="$BATS_TEST_TMPDIR/rev_ok";             echo "0" > "$REV_OK"
  export REMOTE_MAIN="$BATS_TEST_TMPDIR/remote_main";   : > "$REMOTE_MAIN"
  export ANCESTOR_RC="$BATS_TEST_TMPDIR/ancestor";      echo "0" > "$ANCESTOR_RC"
  export PATCH_CODE="$BATS_TEST_TMPDIR/patch";          echo "200" > "$PATCH_CODE"
  export PORT_HOLDER="$BATS_TEST_TMPDIR/port_holder"
  export CREDS_POSED="$BATS_TEST_TMPDIR/creds_posed"

  cat > "$DOCKER_D/forge-runner.sh" <<'FAKE'
#!/usr/bin/env bash
echo "RUNNER:$*" >> "$CALLS"
rc="$(cat "$RUNNER_RC")"
[[ "$rc" -eq 0 ]] || echo "REFUS-TEMOIN: image(s) introuvable(s) sur ce daemon: alpine:3.20" >&2
exit "$rc"
FAKE
  cat > "$ROOT/deploy/lib/enroll-catalogue.sh" <<'FAKE'
#!/usr/bin/env bash
echo "ENROLL:$*" >> "$CALLS"
dir=""; while [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done
echo '{"roles":[]}' > "$dir/roles.auto.tfvars.json"
printf 'PROV_ROLES="system_architect fleet_engineer"\nPROV_FORGE_ORG="fleet"\n'
FAKE
  chmod 0755 "$DOCKER_D/forge-runner.sh" "$ROOT/deploy/lib/enroll-catalogue.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  cat > "$BINDIR/dockerstub" <<'FAKE'
#!/usr/bin/env bash
argv="$*"
stdin=""; [[ -p /dev/stdin || -f /dev/stdin ]] && stdin="$(cat)"
echo "DOCKER:$argv${stdin:+ <<< $stdin}" >> "$CALLS"
case "$argv" in
  *" create lcars"*|*" up -d")   env | grep '^LCARS_\|^FORGE_' | sort >> "$CALLS"; exit 0 ;;
  *"ps --filter publish="*)      [[ -f "$PORT_HOLDER" ]] && cat "$PORT_HOLDER"; exit 0 ;;
  *"com.docker.compose.project"*) echo "un-autre-projet"; exit 0 ;;
  version*)                      echo "29.0.0"; exit 0 ;;
  "run --rm"*)                   echo flux-ok; exit 0 ;;
  "ps -a"*)                      exit 0 ;;
  "inspect -f {{.State.Health.Status}}"*) echo healthy; exit 0 ;;
  "image inspect -f"*)           cat "$IMAGE_REV_OUT"; exit 0 ;;
  "image inspect"*)              exit 0 ;;
  "inspect "*"Config.Image"*)    echo "gitea/runner:test"; exit 0 ;;
  *"user create"*)               rc="$(cat "$CREATE_RC")"; [[ "$rc" -eq 0 ]] || echo "user already exists" >&2; exit "$rc" ;;
  *"generate-access-token"*)     cat "$MASTER_TOKEN_OUT"; exit 0 ;;
  *"forge-seed.pass"*)           exit 1 ;;
  *"id -u "*)                    exit "$(cat "$HUMAN_RC")" ;;
  *"system_starfleet.gitea_token"*) cat "$SYS_TOKEN_OUT"; exit 0 ;;
  *"*.gitea_token"*)             echo 9; exit 0 ;;
  *"credentials.json"*)          [[ "$argv" == *"mkdir"* ]] && { touch "$CREDS_POSED"; exit 0; }; [[ -e "$CREDS_POSED" ]] && echo oui || echo non; exit 0 ;;
  *"lcars-provision.rc"*)        cat "$PROV_RC_OUT"; exit 0 ;;
  *"forge-gestures.sh runner-token"*) echo REG-TOKEN-TEMOIN; exit 0 ;;
  *"gitea-runner --version"*)    echo "v1"; exit 0 ;;
  *" env "*"fleet start")        exit "$(cat "$FLEET_RC")" ;;
esac
exit 0
FAKE
  cat > "$BINDIR/curl" <<'FAKE'
#!/usr/bin/env bash
cfg=""; for a in "$@"; do [[ "$a" == "-K" ]] && cfg="$(cat)"; done
url="${@: -1}"
echo "CURL:$* | $(tr '\n' ' ' <<<"$cfg")" >> "$CALLS"
case "$url" in
  */actions/runners)        cat "$RUNNERS_JSON"; exit 0 ;;
  */api/v1/admin/users/*)   [[ " $* " == *" -w "* ]] && cat "$PATCH_CODE"; exit 0 ;;
  */api/v1/users/*/tokens)  printf '{"sha1":"OP-TOKEN"}'; exit 0 ;;
  */api/v1/users/*)         printf '{"is_admin":true}'; exit 0 ;;
esac
exit 0
FAKE
  cat > "$BINDIR/git" <<'FAKE'
#!/usr/bin/env bash
echo "GIT:$* | ${GIT_CONFIG_KEY_0:-}=${GIT_CONFIG_VALUE_0:-}" >> "$CALLS"
case "$*" in
  *"rev-parse -q --verify"*) exit "$(cat "$REV_OK")" ;;
  *"ls-remote"*)             r="$(cat "$REMOTE_MAIN")"; [[ -z "$r" ]] || echo "$r	refs/heads/main"; exit 0 ;;
  *"merge-base --is-ancestor"*) exit "$(cat "$ANCESTOR_RC")" ;;
esac
exit 0
FAKE
  chmod 0755 "$BINDIR/dockerstub" "$BINDIR/curl" "$BINDIR/git"
  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub DOCKER_HOST=unix:///dev/null
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  unset LCARS_WORK_TREE LCARS_BENCH_ADMIRAL_PW LCARS_BENCH_HUMAN_PW
}

run_bench() { run bash "$SRC" --forge-project bt --image lcars-fleet:9 "$@"; }

# ─── le verdict ─────────────────────────────────────────────────────────────────────────────────

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
  printf 'cat: /run/lcars-provision.rc: No such file or directory\n' > "$PROV_RC_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRÊT"*"non mesuré"* ]]
}

@test "--no-runner porte son propre verdict, jamais celui du banc complet" {
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRÊT sans CI"* ]]
  [[ "$output" != *"PAS PRÊT"* ]]
  refute grep -q '^RUNNER:' "$CALLS"
}

# ─── le runner ──────────────────────────────────────────────────────────────────────────────────

@test "le runner reçoit la forge, le jeton d'enregistrement, le réseau, le projet et les trois labels, sans le label elixir" {
  run_bench
  [ "$status" -eq 0 ]
  local ligne; ligne="$(grep '^RUNNER:' "$CALLS")"
  [[ "$ligne" == *"--forge-api http://127.0.0.1:$BF/api/v1"*"--reg-token REG-TOKEN-TEMOIN"*"--network bt-forge_default"*"--project bt-runner"* ]]
  [[ "$ligne" == *"shell:docker://alpine:3.20"*"dood:docker://docker:cli"*"ubuntu-latest:docker://catthehacker/ubuntu:act-latest"* ]]
  [[ "$ligne" != *"elixir:"* ]]
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

@test "runner démarré mais aucun vu par la forge : PAS PRÊT, sortie 6" {
  printf '{"runners":[]}\n' > "$RUNNERS_JSON"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"banc PAS PRÊT — le runner était demandé"*"démarré mais aucun runner vu par la forge"* ]]
}

# ─── l'image ────────────────────────────────────────────────────────────────────────────────────

@test "une image sans révision, ou « unknown », est annoncée inconnue ; une image estampillée montre sa révision" {
  : > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  [[ "$output" == *"ne porte pas de révision"* ]]
  echo unknown > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  echo deadbeef1 > "$IMAGE_REV_OUT"
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"révision  : deadbeef1"* ]]
}

# ─── les adresses et les ports ──────────────────────────────────────────────────────────────────

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

# ─── l'amorçage ─────────────────────────────────────────────────────────────────────────────────

@test "la forge monte avec port, bind et URL racine, puis admiral est créé avec le mot de passe du contrat, unix et forge" {
  run_bench --no-runner --advertise 10.0.0.9
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "DOCKER:compose -f .*forge-compose.yml -p bt-forge up -d" "$CALLS"
  grep -qx "LCARS_DEVFORGE_PORT=$BF" "$CALLS"
  grep -q "DOCKER:exec -i -u root bt-fleet-lcars-1 chpasswd <<< admiral:toto123456" "$CALLS"
  grep -q "gitea admin user create --username admiral --password toto123456" "$CALLS"
  [[ "$output" == *"compte admiral créé"* ]]
}

@test "admiral déjà présent : mot de passe de banc reposé, et l'amorçage continue" {
  echo 1 > "$CREATE_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "user change-password --username admiral --password toto123456" "$CALLS"
  [[ "$output" == *"compte admiral déjà présent — mot de passe de banc reposé"* ]]
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
  grep -q "DOCKER:cp .*/roles.auto.tfvars.json bt-fleet-lcars-1:/opt/lcars/services/forge-recipe/roles.auto.tfvars.json" "$CALLS"
  grep -q "DOCKER:exec -i -u root -e LCARS_BUILTIN_HUMAN=lcars -e LCARS_BUILTIN_EMAIL=lcars@lcars.local bt-fleet-lcars-1 /opt/lcars/forge-gestures.sh apply" "$CALLS"
  refute grep -qE 'DOCKER:[^<]*MASTER' "$CALLS"
}

@test "l'humain du banc : mot de passe et site-admin par l'API avec le jeton en stdin, jeton opérateur posé après la relance, mot de passe unix" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'admin/users/lcars | header = "Authorization: token MASTER".*"password\\":\\"toto32toto32\\".*"admin\\":true' "$CALLS"
  refute grep -qE 'CURL:[^|]*(MASTER|toto32toto32)' "$CALLS"
  local relance jeton; relance="$(grep -n '^DOCKER:restart' "$CALLS" | cut -d: -f1)"; jeton="$(grep -n 'gitea_token <<< OP-TOKEN' "$CALLS" | cut -d: -f1)"
  [ -n "$relance" ] && [ -n "$jeton" ] && [ "$relance" -lt "$jeton" ]
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

# ─── le semis des dépôts ────────────────────────────────────────────────────────────────────────

@test "le semis pousse la révision de l'image sur main, avec le jeton système dans l'environnement de git, jamais dans l'argv, et sans --force" {
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "GIT:-C $ROOT push -q http://127.0.0.1:$BF/fleet/lcars.git deadbeef1:refs/heads/main | http.http://127.0.0.1:$BF/.extraheader=Authorization: token SYS-TOKEN" "$CALLS"
  refute grep -qE 'GIT:[^|]*SYS-TOKEN' "$CALLS"
  refute grep -q 'push -q --force' "$CALLS"
  [[ "$output" == *"main poussé (révision de l'image : deadbeef1)"*"ops non poussé (LCARS_WORK_TREE non posé"* ]]
}

@test "rejeu sur une forge qui porte déjà un main étranger : le hook est levé et le push forcé, dit" {
  echo "0123456789abcdef" > "$REMOTE_MAIN"; echo 1 > "$ANCESTOR_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "GIT:-C $ROOT -c core.hooksPath=/dev/null push -q --force" "$CALLS"
  [[ "$output" == *"main existe déjà sur la forge de banc (012345678)"*"poussé de force"* ]]
}

@test "une révision d'image absente du clone est refusée : le banc ne sème pas un autre code" {
  echo 1 > "$REV_OK"
  run_bench --no-runner
  [ "$status" -eq 7 ]
  [[ "$output" == *"n'est pas dans ce clone"* ]]
  refute grep -q 'GIT:.*push' "$CALLS"
}

# ─── la fleet ───────────────────────────────────────────────────────────────────────────────────

@test "la fleet démarre sous l'humain : sans credentials avec LCARS_START_WITHOUT_CLAUDE=1, avec credentials sans lui, et un échec est nommé" {
  run_bench --no-runner
  grep -q "DOCKER:exec -u lcars bt-fleet-lcars-1 env LCARS_START_WITHOUT_CLAUDE=1 fleet start" "$CALLS"
  printf 'CREDS\n' > "$BATS_TEST_TMPDIR/creds.json"; : > "$CALLS"
  run_bench --no-runner --creds-from "$BATS_TEST_TMPDIR/creds.json"
  grep -q "DOCKER:exec -u lcars bt-fleet-lcars-1 env fleet start" "$CALLS"
  echo 1 > "$FLEET_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet     : « fleet start » a échoué sous lcars"* ]]
}
