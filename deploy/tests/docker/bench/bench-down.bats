#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench/bench-down.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: témoins de bench-down.sh — ce dont un banc est fait, l'ordre de sa destruction, et ce qui n'est pas un banc

load ../../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../docker/bench/bench-down.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"
  export CALLS

  # DAEMON_OBJETS : « <nom>:<type>:<marqueur> » des conteneurs (c) et volumes (v) du daemon, rangés dans le
  # projet que leur nom porte ; VOLUMES_HORS : les volumes sans projet compose (le magasin) ; DOCKER_KO :
  # la requête qui échoue ; RETRAIT_KO=1 : chaque down et chaque volume rm échouent, et rien ne part
  export DAEMON_OBJETS="" VOLUMES_HORS="" DOCKER_KO="" RETRAIT_KO=""
  # un down émis est relu par compose lui-même, sans daemon : ses fichiers, ses constantes et son environnement suffisent-ils ?
  REAL_DOCKER="$(command -v docker)"
  export REAL_DOCKER NO_DAEMON="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock"

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
touch "$CALLS.descendus" "$CALLS.retires"
if [[ "$1" == compose && "$*" == *" down -v --remove-orphans" ]]; then
  if err="$(DOCKER_HOST="$NO_DAEMON" "$REAL_DOCKER" "${@:1:$#-3}" config --format json 2>&1 > "$CALLS.modele-${*: -4:1}")"; then echo "LU:${*: -4:1}" >> "$CALLS"
  else echo "ILLISIBLE:${*: -4:1}: $err" >> "$CALLS"
  fi
  [[ -z "$RETRAIT_KO" ]] || { echo "Error response from daemon: remove ${*: -4:1}_data: volume is in use" >&2; exit 1; }
  echo "${*: -4:1}" >> "$CALLS.descendus"
  exit 0
fi
parti() { # parti <nom> — l'objet appartient à un projet descendu, ou c'est un volume retiré
  local p
  grep -qxF "$1" "$CALLS.retires" && return 0
  while read -r p; do [[ -n "$p" && "$1" == "$p"[-_]* ]] && return 0; done < "$CALLS.descendus"
  return 1
}
objets() { # objets <projet> <c|v> <format> — le format reçu, rendu pour chaque objet du projet encore là
  local o nom type marque ligne
  for o in $DAEMON_OBJETS; do
    IFS=: read -r nom type marque <<<"$o"
    [[ "$type" == "$2" && "$nom" == "$1"[-_]* ]] || continue
    parti "$nom" && continue
    ligne="${3//\{\{.Names\}\}/$nom}"; ligne="${ligne//\{\{.Name\}\}/$nom}"
    printf '%s\n' "${ligne//\{\{.Label \"lcars.bench\"\}\}/$marque}"
  done
}
case "$*" in
  "ps -a --filter label=com.docker.compose.project="*)
    [[ "$DOCKER_KO" != ps ]] || exit 1
    objets "${4#label=com.docker.compose.project=}" c "$6" ;;
  "volume ls --filter label=com.docker.compose.project="*)
    objets "${4#label=com.docker.compose.project=}" v "$6" ;;
  "volume ls --format"*)
    for o in $DAEMON_OBJETS; do [[ "$o" == *:v:* ]] && ! parti "${o%%:*}" && echo "${o%%:*}"; done
    for o in $VOLUMES_HORS; do parti "$o" || echo "$o"; done ;;
  "volume rm -f "*)
    [[ -z "$RETRAIT_KO" ]] || { echo "Error response from daemon: remove $4: volume is in use" >&2; exit 1; }
    echo "$4" >> "$CALLS.retires" ;;
esac
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
}

run_down() {
  run bash "$SRC" --project bt --yes
}

# l'index du premier appel qui porte un motif, ou "" : cette suite lit l'ordre
idx_of() {
  grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1
}

BANC="bt-fleet-lcars-1:c:bt bt-runner-act-1:c:bt bt-forge-gitea-1:c:bt"

@test "un banc complet : les trois projets compose sont descendus, aucun oublié" {
  DAEMON_OBJETS="$BANC" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
  grep -q -- "-p bt-fleet down -v" "$CALLS"
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "des retraits refusés par docker : les objets relus sont nommés, sortie 3, jamais « détruit »" {
  DAEMON_OBJETS="$BANC bt-forge_data:v:bt" VOLUMES_HORS="bt-fleet-cache" RETRAIT_KO=1 run_down

  [ "$status" -eq 3 ]
  [[ "$output" == *"banc « bt » NON détruit"*"volume bt-forge_data (projet bt-forge)"*"conteneur bt-runner-act-1 (projet bt-runner)"*"volume bt-fleet-cache (magasin)"* ]]
  [[ "$output" != *"banc « bt » détruit"* ]]
}

@test "un banc détruit est relu vide après les retraits : sortie 0" {
  DAEMON_OBJETS="$BANC bt-forge_data:v:bt" VOLUMES_HORS="bt-fleet-cache" run_down

  [ "$status" -eq 0 ]
  [[ "$output" == *"banc « bt » détruit"* ]]
  [ "$(grep -c '^ps -a --filter label=com.docker.compose.project=bt-forge ' "$CALLS")" -eq 2 ]
}

@test "le runner part en premier : il tient le réseau de la forge" {
  DAEMON_OBJETS="$BANC" run_down

  runner="$(idx_of '\-p bt-runner down')"
  forge="$(idx_of '\-p bt-forge down')"
  [ -n "$runner" ]
  [ -n "$forge" ]
  [ "$runner" -lt "$forge" ]
}

@test "le magasin du banc est détruit, volume par volume" {
  DAEMON_OBJETS="bt-fleet-lcars-1:c:bt bt-forge-gitea-1:c:bt" run_down

  [ "$status" -eq 0 ]
  local v
  for v in bt-fleet-cache bt-fleet-toolchains bt-fleet-sysroots bt-fleet-state; do
    grep -qx "volume rm -f $v" "$CALLS" || { echo "non détruit : $v"; return 1; }
  done
}

@test "un banc à moitié détruit (conteneur parti, runner debout) se termine" {
  DAEMON_OBJETS="bt-runner-act-1:c:bt" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
}

@test "plus aucun conteneur, mais les volumes marqués de la forge restent : détruits quand même" {
  DAEMON_OBJETS="bt-forge_data:v:bt bt-forge_config:v:bt" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "un magasin resté à côté de sa forge compte comme résidu, et il est détruit" {
  DAEMON_OBJETS="bt-forge_data:v:bt" VOLUMES_HORS="bt-fleet-cache bt-fleet-toolchains" run_down

  [ "$status" -eq 0 ]
  grep -qx "volume rm -f bt-fleet-cache" "$CALLS"
}

@test "un magasin resté seul est vu, refusé faute de banc, et le remède nomme ses volumes" {
  VOLUMES_HORS="bt-fleet-cache bt-fleet-toolchains bt-fleet-sysroots bt-fleet-state" run_down

  [ "$status" -eq 1 ]
  [[ "$output" != *"rien à détruire"* ]]
  [[ "$output" == *"sans aucun objet du banc « bt »"*"docker volume rm bt-fleet-cache bt-fleet-toolchains bt-fleet-sysroots bt-fleet-state"* ]]
  [[ "$output" != *"reset"* ]]
  refute grep -q -- "volume rm" "$CALLS"
}

@test "rien de ce banc n'existe : sortie 2, et pas un appel destructeur" {
  DAEMON_OBJETS="quelquun-dautre_data:v:" VOLUMES_HORS="someoneelses_data" run_down

  [ "$status" -eq 2 ]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "un conteneur <base>-fleet sans le marqueur du banc est refusé : c'est une instance posée" {
  DAEMON_OBJETS="bt-fleet-lcars-1:c: bt-fleet_lcars-home:v:" run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"sans son marqueur"*"conteneur bt-fleet-lcars-1 (projet bt-fleet)"*"deploy/container -p bt-fleet reset"* ]]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "la forge d'un poste homonyme (sans marqueur) n'est pas un banc : refusée, même à côté d'objets marqués" {
  DAEMON_OBJETS="bt-forge-gitea-1:c: bt-forge_data:v: bt-runner-act-1:c:bt" run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"conteneur bt-forge-gitea-1 (projet bt-forge)"*"volume bt-forge_data (projet bt-forge)"*"docker compose -p bt-forge down -v"* ]]
  [[ "$output" != *"reset"* ]]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "un marqueur d'un autre banc n'est pas celui-ci" {
  DAEMON_OBJETS="bt-forge-gitea-1:c:autre" run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"bt-forge-gitea-1"* ]]
  refute grep -q -- "down -v" "$CALLS"
}

@test "une requête docker en échec arrête en 1, sans rien détruire" {
  DAEMON_OBJETS="$BANC" DOCKER_KO=ps run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"docker ne rend pas les objets"* ]]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "--yes reste exigé, et son absence ne détruit rien" {
  DAEMON_OBJETS="$BANC"
  run bash "$SRC" --project bt

  [ "$status" -eq 1 ]
  refute grep -q -- "down -v" "$CALLS"
}

@test "le down du runner relit le modèle que forge-runner --bench pose : le réseau externe de la forge, les volumes marqués" {
  DAEMON_OBJETS="$BANC" run_down

  [ "$status" -eq 0 ]
  grep -qx 'LU:bt-runner' "$CALLS"
  local modele="$CALLS.modele-bt-runner"
  [ "$(jq -r '.networks.default.name' "$modele")" = bt-forge_default ]
  [ "$(jq -r '.networks.default.external' "$modele")" = true ]
  [ "$(jq -r '.volumes.data.labels["lcars.bench"]' "$modele")" = bt ]
  [ "$(jq -r '.volumes.dind.labels["lcars.bench"]' "$modele")" = bt ]
  [ "$(jq -r '.services.act.labels["lcars.bench"]' "$modele")" = bt ]
}

@test "les trois down se lisent par compose avec les constantes de l'installeur, sans valeur factice" {
  DAEMON_OBJETS="$BANC" run_down

  [ "$status" -eq 0 ]
  refute grep -q '^ILLISIBLE:' "$CALLS"
  grep -qx 'LU:bt-runner' "$CALLS"
  grep -qx 'LU:bt-fleet' "$CALLS"
  grep -qx 'LU:bt-forge' "$CALLS"
  local constantes f; constantes="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/installer-constants.env"
  [ "$(grep -c -- '^compose --env-file ' "$CALLS")" -eq 3 ]
  for f in $(grep -oE -- '^compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$constantes" ]
  done
}
