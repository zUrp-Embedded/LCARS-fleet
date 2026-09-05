#!/usr/bin/env bats
# SOURCE: deploy/tests/container_config.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for deploy/container config|status — la conf de l'instance vit COTE HOTE, le verdict se lit de l'hote
#
# ⚖ user 2026-09-04 (Q1, chantier deploy-independance) : le modele Docker. « container config » ecrit l'env
# et les secrets de l'instance sur l'hote (par projet) ; « container up » les donne au conteneur ; « container
# status » lit l'instance de l'hote et remplace le doctor. `docker` est une doublure : rien ne tourne.

load refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/deploy/container"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"; : > "$CALLS"
  cat > "$BINDIR/docker" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1 \$2" in
  "compose version") exit 0 ;;
esac
if [[ "\$*" == *" ps -q lcars"* ]]; then printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0; fi
if [[ "\$*" == *" up -d"* ]]; then printf '%s\n' "\${LCARS_DECK_ORIGINS-<absent>}" > "$BATS_TEST_TMPDIR/origins.seen"; exit 0; fi
if [[ "\$1" == inspect ]]; then
  case "\$3" in
    *State.Status*)   echo "\${STUB_STATE:-running}" ;;
    *Health*)         echo "\${STUB_HEALTH:-healthy}" ;;
    *revision*)       echo "\${STUB_REV:-}" ;;
  esac; exit 0
fi
if [[ "\$*" == *"cat /run/lcars-boot.state"* ]];   then [[ -n "\${STUB_BOOT:-}" ]]   || exit 1; echo "\$STUB_BOOT"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-provision.rc"* ]]; then [[ -n "\${STUB_PROV:-}" ]]   || exit 1; echo "\$STUB_PROV"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-humans.rc"* ]];    then [[ -n "\${STUB_HUM:-}" ]]    || exit 1; echo "\$STUB_HUM"; exit 0; fi
if [[ "\$*" == *"cat /opt/lcars/.verified"* ]];    then [[ -n "\${STUB_TAMPON:-}" ]] || exit 1; echo "\$STUB_TAMPON"; exit 0; fi
all="\$*"   # \${*##…} s'appliquerait a CHAQUE parametre, pas a la ligne
if [[ "\$all" == *"forge-gestures.sh config-"* ]]; then cat > "$BATS_TEST_TMPDIR/pushed.\${all##* config-}"; exit 0; fi
exit 0
EOS
  chmod 0755 "$BINDIR/docker"
  # curl (la sonde du deck de « status ») : STUB_DECK_HTTP, 000 par defaut
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "${STUB_DECK_HTTP:-000}"' > "$BINDIR/curl"; chmod 0755 "$BINDIR/curl"
  export PATH="$BINDIR:$PATH"
  export DOCKER_HOST="unix:///dev/null" PROV_DOCKER_BIN="$BINDIR/docker"
  export LCARS_CONTAINER_CONF_DIR="$BATS_TEST_TMPDIR/conf"
  unset LCARS_PROJECT STUB_IDS STUB_STATE STUB_HEALTH STUB_REV STUB_BOOT STUB_PROV STUB_HUM STUB_TAMPON STUB_DECK_HTTP LCARS_DECK_ORIGINS LCARS_LANDING_PORT_BIND
  unset FORGE_BASE_URL FORGE_PUBLIC_URL LCARS_ADMIRAL LCARS_UID FORGE_ADMIN_TOKEN FORGE_SEED_PASSWORD
  ENV_FILE="$LCARS_CONTAINER_CONF_DIR/lcars-fleet.env"
  SECRETS="$LCARS_CONTAINER_CONF_DIR/lcars-fleet.secrets"
}

@test "config : sans variable, montre ce qui est pose et ne touche rien" {
  run bash "$SRC" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun env pos"* ]]
  [[ "$output" == *"FORGE_ADMIN_TOKEN=<absent>"* ]]
  [ ! -s "$ENV_FILE" ]
}

@test "config : l'env se pose COTE HOTE, par projet, en 0600 — et un second config FUSIONNE" {
  FORGE_BASE_URL=http://forge:3000 LCARS_ADMIRAL=zoe run bash "$SRC" config
  [ "$status" -eq 0 ]
  grep -qx 'FORGE_BASE_URL=http://forge:3000' "$ENV_FILE"
  grep -qx 'LCARS_ADMIRAL=zoe' "$ENV_FILE"
  [ "$(stat -c %a "$ENV_FILE")" = 600 ]
  LCARS_UID=1005 run bash "$SRC" config
  [ "$status" -eq 0 ]
  grep -qx 'LCARS_ADMIRAL=zoe' "$ENV_FILE"
  grep -qx 'LCARS_UID=1005' "$ENV_FILE"
  # un autre projet a SA conf
  FORGE_BASE_URL=http://autre:3000 run bash "$SRC" -p autre config
  grep -qx 'FORGE_BASE_URL=http://autre:3000' "$LCARS_CONTAINER_CONF_DIR/autre.env"
  grep -qx 'FORGE_BASE_URL=http://forge:3000' "$ENV_FILE"
}

@test "config : les secrets sont des FICHIERS 0600 de l'hote, montes par l'override compose" {
  FORGE_ADMIN_TOKEN=tok-master FORGE_SEED_PASSWORD=s33d run bash "$SRC" config
  [ "$status" -eq 0 ]
  [ "$(cat "$SECRETS/forge-master.token")" = tok-master ]
  [ "$(cat "$SECRETS/forge-seed.pass")" = s33d ]
  [ "$(stat -c %a "$SECRETS/forge-master.token")" = 600 ]
  [ "$(stat -c %a "$SECRETS")" = 700 ]
  # le secret ne va PAS dans le fichier d'env, ni dans la sortie
  [ ! -e "$ENV_FILE" ] || refute grep -q 'tok-master' "$ENV_FILE"
  [[ "$output" != *"tok-master"* ]]
  # boite eteinte : rien n'est pousse dans un conteneur
  [ ! -e "$BATS_TEST_TMPDIR/pushed.token" ]
}

@test "config : la boite qui TOURNE recoit le secret tout de suite (rotation), l'env attend un up" {
  export STUB_IDS=c0ffee
  FORGE_ADMIN_TOKEN=tok-2 LCARS_ADMIRAL=zoe run bash "$SRC" config
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/pushed.token" ] || { echo "$output"; cat "$CALLS"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/pushed.token")" = tok-2 ]
  [ "$(cat "$SECRETS/forge-master.token")" = tok-2 ]
  [[ "$output" == *"prochain"*"up"* ]]
}

@test "config : une valeur multi-ligne est REFUSEE, elle ne tient pas dans un fichier d'env" {
  LCARS_SSH_AUTHORIZED_KEYS=$'ssh-ed25519 AAA a\nssh-ed25519 BBB b' run bash "$SRC" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"retour"*"ligne"* ]]
  [ ! -e "$ENV_FILE" ]
}

@test "up : le fichier d'env est LU, et l'env explicite de l'appelant PRIME (le modele compose)" {
  mkdir -p "$LCARS_CONTAINER_CONF_DIR"
  printf 'FORGE_BASE_URL=http://fichier:3000\nLCARS_ADMIRAL=zoe\n' > "$ENV_FILE"
  # `docker image inspect` rend 0 sur la doublure : up passe jusqu'au compose
  FORGE_BASE_URL=http://appelant:3000 LCARS_UP_VERDICT_TIMEOUT=0 run bash "$SRC" up
  # ce que compose a vu : l'env du PROCESSUS container — on le lit par une commande qui l'imprime
  run env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="$DOCKER_HOST" PROV_DOCKER_BIN="$PROV_DOCKER_BIN" \
      LCARS_CONTAINER_CONF_DIR="$LCARS_CONTAINER_CONF_DIR" FORGE_BASE_URL=http://appelant:3000 \
      bash -c 'PROJECT=lcars-fleet; source <(sed -n "/^CONTAINER_CONF_DIR=/,/^ensure_secrets$/p" "$0"); echo "$FORGE_BASE_URL $LCARS_ADMIRAL $LCARS_CONTAINER_SECRETS"' "$SRC"
  [ "$status" -eq 0 ]
  [[ "$output" == "http://appelant:3000 zoe $SECRETS" ]]
}

@test "compose : l'override des secrets est passe a CHAQUE compose, et les fichiers existent (vides = rien)" {
  run bash "$SRC" down
  [ "$status" -eq 0 ]
  grep -q -- '-f .*docker-compose.secrets.yml -p lcars-fleet down' "$CALLS"
  [ -e "$SECRETS/forge-master.token" ] && [ ! -s "$SECRETS/forge-master.token" ]
  [ -e "$SECRETS/forge-seed.pass" ]
  grep -q 'LCARS_CONTAINER_SECRETS' "$REPO/deploy/docker/docker-compose.secrets.yml"
  grep -q '/run/secrets\|forge_master_token' "$REPO/deploy/docker/docker-compose.secrets.yml"
}

@test "status : sans conteneur, rc 2 et le geste nomme" {
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"AUCUN conteneur"*"container up"* ]]
}

@test "status : sain — tout converge, le tampon est la revision qui tourne, rc 0" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=0 STUB_TAMPON=436f94cd STUB_REV=436f94cd STUB_DECK_HTTP=302
  run bash "$SRC" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"*"healthy"* ]]
  [[ "$output" == *"boot        : services démarrés"* ]]
  [[ "$output" != *"démarrés0"* ]]
  [[ "$output" == *"gestes converg"* ]]
  [[ "$output" == *"humains     : pr"* ]]
  [[ "$output" == *"la révision qui tourne est celle du build"* ]]
}

@test "status : en attente de configuration — rc 1, et le remede est « container config »" {
  export STUB_IDS=c0ffee STUB_BOOT=awaiting-config STUB_HEALTH=starting
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"EN ATTENTE DE CONFIGURATION"*"container config"* ]]
}

@test "status : drift de forge ou aucun humain = degrade (1) ; init en echec ou conteneur mort = panne (2)" {
  export STUB_IDS=c0ffee STUB_PROV=2 STUB_HUM=0
  run bash "$SRC" status; [ "$status" -eq 1 ]; [[ "$output" == *"DRIFT"* ]]
  export STUB_PROV=0 STUB_HUM=1
  run bash "$SRC" status; [ "$status" -eq 1 ]; [[ "$output" == *"AUCUN humain"* ]]
  export STUB_HUM=0 STUB_BOOT=init-failed
  run bash "$SRC" status; [ "$status" -eq 2 ]; [[ "$output" == *"INIT EN"* ]]
  unset STUB_BOOT; export STUB_STATE=exited
  run bash "$SRC" status; [ "$status" -eq 2 ]
}

@test "status : une image reconstruite sans up se VOIT — tampon ≠ revision" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=0 STUB_TAMPON=436f94cd STUB_REV=deadbeef
  run bash "$SRC" status
  [[ "$output" == *"436f94cd"*"deadbeef"* ]]
  [[ "$output" == *"reconstruite"* ]]
}

@test "pull : tire l'image nommee par LCARS_IMAGE et rien d'autre — up ne tire jamais, il nomme les deux gestes" {
  LCARS_IMAGE=reg.example/fleet/lcars:2.2 run bash "$SRC" pull
  [ "$status" -eq 0 ]
  grep -qx 'pull reg.example/fleet/lcars:2.2' "$CALLS"
  refute grep -q 'build' "$CALLS"
  # `up` sur une image absente : la doublure repond 1 a `image inspect`
  cat >> "$BINDIR/docker" <<'EOS'
EOS
  sed -i 's/^exit 0$/[[ "$1 $2" == "image inspect" ]] \&\& exit 1; exit 0/' "$BINDIR/docker"
  run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"container build"* ]]
  [[ "$output" == *"container pull"* ]]
  refute grep -q ' pull ' "$CALLS"
}

@test "up : le port PUBLIE entre dans les origines du deck — sinon 409 sur le chemin nominal" {
  LCARS_LANDING_PORT_BIND=127.0.0.1:22021 LCARS_UP_VERDICT_TIMEOUT=0 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://127.0.0.1:22021,http://localhost:22021" ]
  # un bind sur toutes les interfaces devient la loopback pour le navigateur local
  LCARS_LANDING_PORT_BIND=0.0.0.0:22021 LCARS_UP_VERDICT_TIMEOUT=0 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://127.0.0.1:22021,http://localhost:22021" ]
  # l'operateur qui pose LCARS_DECK_ORIGINS garde la main
  LCARS_DECK_ORIGINS=http://deck.example LCARS_LANDING_PORT_BIND=127.0.0.1:22021 LCARS_UP_VERDICT_TIMEOUT=0 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://deck.example" ]
}

@test "status : un deck qui rend 409 (entree non declaree) est DEGRADE, pas vert" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=0 STUB_TAMPON=436f94cd STUB_REV=436f94cd STUB_DECK_HTTP=409
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"409"*"NON DÉCLARÉE"* ]]
}

@test "aide : chaque variable d'env ANNONCEE est LUE — par container, par un compose qu'il pilote, ou par une lib qu'il source" {
  # Relecture hostile 2026-09-04 (M6) : `LCARS_CONSOLE_PORT` etait documentee dans l'aide et lue
  # nulle part — une piste morte pour l'operateur qui cherche pourquoi son port ne bouge pas, dans
  # le fichier qu'il lit en premier. L'aide est un contrat : un nom qu'elle annonce a un lecteur.
  local names
  names="$(sed -n '/^# ENV (tous optionnels)/,/^# EXIT :/p' "$SRC" | grep -oE '^#   [A-Z][A-Z0-9_]+' | sed 's/^#   //')"
  [ "$(grep -c . <<<"$names")" -ge 8 ] || { echo "moins de 8 variables lues dans l'aide — l'instrument ne lit plus le bloc ENV" >&2; return 1; }
  local code
  code="$(cat "$SRC" "$REPO/deploy/docker/docker-compose.yml" "$REPO/deploy/docker/docker-compose.secrets.yml" \
              "$REPO/deploy/lib/store.sh" "$REPO/deploy/lib/docker-endpoint.sh" | grep -vE '^\s*#')"
  local n bad=0
  while read -r n; do
    [ -n "$n" ] || continue
    grep -qE "(^|[^A-Z0-9_])$n([^A-Z0-9_]|$)" <<<"$code" || { echo "$n : annoncee par l'aide de container, lue nulle part" >&2; bad=1; }
  done <<<"$names"
  [ "$bad" -eq 0 ]
}
