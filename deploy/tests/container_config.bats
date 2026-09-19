#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/container_config.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for deploy/container config|status|up|forge-check|forge-apply — la conf de l'instance vit COTE HOTE, le verdict et la forge se lisent de l'hote

load refute
load support/decor

setup() {
  decor_pose
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # un arbre dont les constantes portent des ports et des noms de secrets que rien d'autre n'écrit
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/docker" "$ARBRE/deploy/lib"
  cp "$REPO/deploy/container" "$ARBRE/deploy/"
  cp "$REPO/deploy/lib/provision-lib.sh" "$REPO/deploy/lib/docker-endpoint.sh" "$REPO/deploy/lib/store.sh" \
     "$REPO/deploy/lib/bench.sh" "$REPO/deploy/lib/forge-bootstrap.sh" "$ARBRE/deploy/lib/"
  # ⚖ décision 3 : les faits du produit ne sont pas dans cet arbre — on les lui NOMME.
  export PROV_PRODUCT_FACTS_FILE="$REPO/runtime/etc/facts.env"
  cp "$REPO/deploy/docker/docker-compose.yml" "$REPO/deploy/docker/docker-compose.secrets.yml" "$ARBRE/deploy/docker/"
  CONSTANTES="$ARBRE/deploy/installer-constants.env"
  { grep -vE '^(PROV_SSH_PORT_DEFAULT|PROV_DECK_PORT_DEFAULT|PROV_MASTER_TOKEN_FILE|PROV_FORGE_SEED_FILE)=' "$REPO/deploy/installer-constants.env"
    printf '%s\n' PROV_SSH_PORT_DEFAULT=4222 PROV_DECK_PORT_DEFAULT=4999 \
      PROV_MASTER_TOKEN_FILE=/opt/lcars/var/tokens/maitre-temoin.token PROV_FORGE_SEED_FILE=/opt/lcars/var/tokens/graine-temoin.pass
  } > "$CONSTANTES"
  SRC="$ARBRE/deploy/container"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"; : > "$CALLS"
  # le up émis est relu par compose lui-même, sans daemon : son rendu JSON est gardé
  local real_docker; real_docker="$(command -v docker)"
  cat > "$BINDIR/docker" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
env | grep -E '^FORGE_(ADMIN_TOKEN|SEED_PASSWORD)=' >> "$BATS_TEST_TMPDIR/env-docker" || true
case "\$1 \$2" in
  "compose version") exit 0 ;;
esac
if [[ "\$*" == *" config --images" ]]; then DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" exec "$real_docker" "\$@"; fi
if [[ "\$*" == *" ps -q lcars"* ]]; then printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0; fi
if [[ "\$*" == *" up -d"* ]]; then
  printf '%s\n' "\${LCARS_DECK_ORIGINS-<absent>}" > "$BATS_TEST_TMPDIR/origins.seen"
  printf '%s %s\n' "\${FORGE_BASE_URL-}" "\${LCARS_ADMIRAL-}" > "$BATS_TEST_TMPDIR/env.seen"
  env | grep -E '^(LCARS_SSH_PORT|LCARS_LANDING_PORT_BIND)=' | sort > "$BATS_TEST_TMPDIR/binds.seen"
  a=("\$@"); n=0; while [[ "\${a[\$n]}" != up ]]; do n=\$((n + 1)); done
  DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" "$real_docker" "\${a[@]:0:\$n}" config --format json > "$BATS_TEST_TMPDIR/rendu.json" 2>&1
  exit 0
fi
if [[ "\$1 \$2" == "ps -aq" ]]; then printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0; fi
# les conteneurs lcars du daemon, « <projet> <fichiers compose> » par ligne ; le journal du démarrage en cours
if [[ "\$1 \$2 \$3" == "ps -a --filter" ]]; then printf '%b' "\${STUB_LCARS_DAEMON:-}"; exit 0; fi
if [[ "\$1 \$2" == "logs --since" ]]; then [[ "\$3" == 2026-09-14T22:45:50.339480853Z ]] || exit 1; printf '%b' "\${STUB_JOURNAL:-}"; exit 0; fi
if [[ "\$1 \$3" == "inspect --format" ]]; then echo "\${STUB_CONFIG_FILES:-}"; exit 0; fi
if [[ "\$1" == inspect ]]; then
  case "\$3" in
    "{{.Config.Image}}") echo "lcars-fleet:banc" ;;
    *State.Status*)   echo "\${STUB_STATE:-running}" ;;
    *Health*)         echo "\${STUB_HEALTH:-healthy}" ;;
    *revision*)       echo "\${STUB_REV:-}" ;;
    "{{.Image}}")     echo "sha256:image-temoin" ;;
    *Config.Env*)     [[ -z "\${STUB_ORIGINES:-}" ]] || echo "LCARS_DECK_ORIGINS=\$STUB_ORIGINES" ;;
    *PortBindings*)   printf "%b" "\${STUB_PUBLIES:-}" ;;
    *StartedAt*)      echo "2026-09-14T22:45:50.339480853Z" ;;
  esac; exit 0
fi
if [[ "\$*" == *"cat /run/lcars-boot.state"* ]];   then [[ -n "\${STUB_BOOT:-}" ]]   || exit 1; echo "\$STUB_BOOT"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-forge.rc"* ]]; then [[ -n "\${STUB_PROV:-}" ]]   || exit 1; echo "\$STUB_PROV"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-provision.rc"* ]]; then [[ -n "\${STUB_PROV_ANCIEN:-}" ]] || exit 1; echo "\$STUB_PROV_ANCIEN"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-humans.rc"* ]];    then [[ -n "\${STUB_HUM:-}" ]]    || exit 1; echo "\$STUB_HUM"; exit 0; fi
if [[ "\$*" == *"cat /opt/lcars/.verified"* ]];    then [[ -n "\${STUB_TAMPON:-}" ]] || exit 1; echo "\$STUB_TAMPON"; exit 0; fi
if [[ "\$*" == *"cat /run/lcars-seat.login"* ]];   then [[ -n "\${STUB_SEAT:-}" ]]   || exit 1; echo "\$STUB_SEAT"; exit 0; fi
if [[ "\$*" == *" exec -it -u "* ]]; then echo "SHELL \$*"; exit 0; fi
all="\$*"   # \${*##…} s'appliquerait a CHAQUE parametre, pas a la ligne
if [[ "\$all" == *"forge-gestures.sh config-"* ]]; then cat > "$BATS_TEST_TMPDIR/pushed.\${all##* config-}"; exit 0; fi
if [[ "\$all" == *"forge-gestures.sh apply" ]]; then cat > "$BATS_TEST_TMPDIR/pushed.apply"; exit 0; fi
if [[ "\$all" == *" sh -c "*"forge-recipe/roles.auto.tfvars.json" ]]; then cat > "$BATS_TEST_TMPDIR/roster.seen"; exit 0; fi
# source-push : le script bash du conteneur est joué, contre des outils doublés qui notent leur argv
if [[ "\$all" == *" exec -T lcars bash -c "* ]]; then
  a=("\$@"); n=0; while [[ "\${a[\$n]}" != -c ]]; do n=\$((n + 1)); done
  PATH="$BATS_TEST_TMPDIR/conteneur-bin:\$PATH" bash "\${a[@]:\$n}"; exit \$?
fi
exit 0
EOS
  chmod 0755 "$BINDIR/docker"
  # curl (la sonde du deck de « status ») : STUB_DECK_HTTP, 000 par defaut ; forge-check parle a la vraie forge doublee
  # comme le vrai : rien ne répond, il écrit 000 et sort non nul
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\${@: -1}\" >> '$BATS_TEST_TMPDIR/curl.urls'" \
    'printf "%s" "${STUB_DECK_HTTP:-000}"; [[ "${STUB_DECK_HTTP:-000}" != 000 ]] || exit 7' > "$BINDIR/curl"; chmod 0755 "$BINDIR/curl"
  # l'attente du verdict de up tourne sans dormir
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/sleep"; chmod 0755 "$BINDIR/sleep"
  export PATH="$BINDIR:$PATH"
  export DOCKER_HOST="unix:///dev/null" PROV_DOCKER_BIN="$BINDIR/docker"
  export LCARS_CONTAINER_CONF_DIR="$BATS_TEST_TMPDIR/conf"
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_ORIGINES STUB_PUBLIES STUB_STATE STUB_HEALTH STUB_REV STUB_BOOT STUB_PROV STUB_PROV_ANCIEN STUB_HUM STUB_TAMPON STUB_DECK_HTTP STUB_SEAT STUB_LCARS_DAEMON STUB_JOURNAL LCARS_DECK_ORIGINS LCARS_LANDING_PORT_BIND LCARS_IMAGE LCARS_HUMAN
  unset FORGE_BASE_URL FORGE_PUBLIC_URL LCARS_ADMIRAL LCARS_UID FORGE_ADMIN_TOKEN FORGE_SEED_PASSWORD
  ENV_FILE="$LCARS_CONTAINER_CONF_DIR/lcars-fleet.env"
  SECRETS="$LCARS_CONTAINER_CONF_DIR/lcars-fleet.secrets"
}

teardown() { forge_double_stop; }

# une instance saine vue par les doublures : conteneur, verdicts, deck et tampon
sain() { export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=0 STUB_DECK_HTTP=302 STUB_TAMPON=436f94cd STUB_REV=436f94cd; }

@test "chaque appel compose de container lit les constantes de l'installeur" {
  sain
  FORGE_ADMIN_TOKEN=tok LCARS_ADMIRAL=zoe run bash "$SRC" config
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SRC" status
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SRC" down
  [ "$status" -eq 0 ]
  local ligne f n=0
  while IFS= read -r ligne; do
    n=$((n + 1))
    [[ "$ligne" == "compose --env-file "* ]] || { echo "sans --env-file : $ligne"; return 1; }
    f="${ligne#compose --env-file }"
    [ "$(readlink -f "${f%% *}")" = "$CONSTANTES" ]
  done < <(grep '^compose ' "$CALLS" | grep -vx 'compose version')
  [ "$n" -gt 0 ]
}

@test "up : sans bind donné, ssh et deck se publient sur la loopback aux ports des constantes, exportés à compose" {
  sain
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/binds.seen")" = $'LCARS_LANDING_PORT_BIND=127.0.0.1:4999\nLCARS_SSH_PORT=127.0.0.1:4222' ]
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://127.0.0.1:4999,http://localhost:4999" ]
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

@test "config : les secrets sont des FICHIERS 0600 de l'hote, nommes comme les constantes nomment ceux du conteneur" {
  FORGE_ADMIN_TOKEN=tok-master FORGE_SEED_PASSWORD=s33d run bash "$SRC" config
  [ "$status" -eq 0 ]
  [ "$(cat "$SECRETS/maitre-temoin.token")" = tok-master ]
  [ "$(cat "$SECRETS/graine-temoin.pass")" = s33d ]
  [ "$(stat -c %a "$SECRETS/maitre-temoin.token")" = 600 ]
  [ "$(stat -c %a "$SECRETS")" = 700 ]
  # le secret ne va PAS dans le fichier d'env, ni dans la sortie
  [ ! -e "$ENV_FILE" ] || refute grep -q 'tok-master' "$ENV_FILE"
  [[ "$output" != *"tok-master"* ]]
  # conteneur eteint : rien n'est pousse dans un conteneur
  [ ! -e "$BATS_TEST_TMPDIR/pushed.token" ]
}

@test "config : le conteneur qui TOURNE recoit le secret tout de suite (rotation), l'env attend un up" {
  export STUB_IDS=c0ffee
  FORGE_ADMIN_TOKEN=tok-2 LCARS_ADMIRAL=zoe run bash "$SRC" config
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/pushed.token" ] || { echo "$output"; cat "$CALLS"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/pushed.token")" = tok-2 ]
  [ "$(cat "$SECRETS/maitre-temoin.token")" = tok-2 ]
  [[ "$output" == *"up --force-recreate"* ]]
}

@test "config : une valeur multi-ligne est REFUSEE, elle ne tient pas dans un fichier d'env" {
  LCARS_SSH_AUTHORIZED_KEYS=$'ssh-ed25519 AAA a\nssh-ed25519 BBB b' run bash "$SRC" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"retour"*"ligne"* ]]
  [ ! -e "$ENV_FILE" ]
}

@test "up : le fichier d'env est LU, et l'env explicite de l'appelant PRIME (le modele compose)" {
  mkdir -p "$LCARS_CONTAINER_CONF_DIR"
  printf 'FORGE_BASE_URL=http://fichier:3000\nLCARS_ADMIRAL=zoe\nLCARS_IMAGE=depuis-fichier:1\n' > "$ENV_FILE"
  # `docker image inspect` rend 0 sur la doublure : up passe jusqu'au compose, qui note son env
  sain
  FORGE_BASE_URL=http://appelant:3000 run bash "$SRC" up
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/env.seen")" = "http://appelant:3000 zoe" ]
  [[ "$output" == *"image depuis-fichier:1"* ]]
}

@test "status et down ne préparent rien sur l'hôte" {
  run bash "$SRC" status
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
  run bash "$SRC" down
  [ "$status" -eq 0 ]
  refute grep -q 'docker-compose.secrets.yml' "$CALLS"
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
}

@test "up : compose lit l'override des secrets et monte les deux fichiers de l'hôte, posés vides (vide = rien)" {
  sain
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.secrets.forge_master_token.file, .secrets.forge_seed_password.file]' "$BATS_TEST_TMPDIR/rendu.json")" \
    = "[\"$SECRETS/maitre-temoin.token\",\"$SECRETS/graine-temoin.pass\"]" ] || { cat "$BATS_TEST_TMPDIR/rendu.json"; return 1; }
  [ -e "$SECRETS/maitre-temoin.token" ]
  [ ! -s "$SECRETS/maitre-temoin.token" ]
  [ -e "$SECRETS/graine-temoin.pass" ]
}

@test "status : sans conteneur, rc 2 et le geste nomme" {
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"aucun conteneur"*"container up"* ]]
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
  [[ "$output" == *"en attente de configuration"*"config"*"up --force-recreate"* ]]
}

@test "status : drift de forge ou aucun humain = degrade (1) ; init en echec ou conteneur mort = panne (2)" {
  export STUB_IDS=c0ffee STUB_PROV=2 STUB_HUM=0
  run bash "$SRC" status; [ "$status" -eq 1 ]; [[ "$output" == *"drift résiduel"* ]]
  export STUB_PROV=0 STUB_HUM=1
  run bash "$SRC" status; [ "$status" -eq 1 ]; [[ "$output" == *"aucun humain"* ]]
  export STUB_HUM=0 STUB_BOOT=init-failed
  run bash "$SRC" status; [ "$status" -eq 2 ]; [[ "$output" == *"init en échec"* ]]
  unset STUB_BOOT; export STUB_STATE=exited
  run bash "$SRC" status; [ "$status" -eq 2 ]
}

@test "status : le geste en drift ou en échec se nomme lui-même, lu dans le journal du démarrage en cours seul" {
  # le journal d'un banc relancé (mesuré sur .63) : le boot d'avant la relance a d'autres drifts, que --since écarte
  export STUB_IDS=c0ffee STUB_PROV=2 STUB_HUM=0 STUB_DECK_HTTP=302
  export STUB_JOURNAL='[container-init] OK    container-init: siege\n[forge.d] WARN  tokens: pas grave\n[forge.d] DRIFT tokens: AUCUN runner CI enregistré sur cette forge — tout job reste en attente, aucune PR ne fusionne\n[container-boot] geste de forge « tokens » : drift residuel — il se reposera au boot suivant\n[container-init] DRIFT container-init: CLONAGE ECHOUE (http://gitea:3000/fleet/lcars.git) — le conteneur demarre sans source\n'
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"forge       : drift résiduel — un geste manque, rien n'est cassé :"$'\n'"                tokens : AUCUN runner CI enregistré sur cette forge"$'\n'"                container-init : CLONAGE ECHOUE (http://gitea:3000/fleet/lcars.git)"$'\n'"                (le détail et son remède : « deploy/container -p lcars-fleet logs »)"* ]] || { echo "$output"; return 1; }
  grep -qx 'logs --since 2026-09-14T22:45:50.339480853Z c0ffee' "$CALLS"
  refute_out 'pas grave|tout job reste' <<<"$output"
  export STUB_PROV=1 STUB_JOURNAL='[forge.d] FAIL  deck-oidc: client OAuth2 refusé par la forge — HTTP 422\n'
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"échec d'un geste (rc=1) — le conteneur tourne et ne produira rien :"$'\n'"                deck-oidc : client OAuth2 refusé par la forge"* ]]
  # un journal muet : le renvoi aux logs, qui rendent la main
  export STUB_PROV=2 STUB_JOURNAL=''
  run bash "$SRC" status
  [[ "$output" == *"drift résiduel — un geste manque ; « deploy/container -p lcars-fleet logs » nomme lequel"* ]]
  # convergé : le journal n'est pas lu
  : > "$CALLS"
  export STUB_PROV=0
  run bash "$SRC" status
  refute grep -q '^logs' "$CALLS"
}

@test "status sans conteneur dans le projet visé nomme les projets lcars du daemon et la commande exacte ; aucun, le geste d'installation" {
  export STUB_LCARS_DAEMON="z5-fleet $BATS_TEST_TMPDIR/kit/deploy/docker/docker-compose.yml,$BATS_TEST_TMPDIR/kit/deploy/docker/docker-compose.bench.yml\nbob63-forge $BATS_TEST_TMPDIR/kit/deploy/docker/forge-compose.yml\nautre /srv/autre/docker-compose.yml\n"
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"container status (lcars-fleet) : aucun conteneur lcars dans ce projet — projets lcars sur ce daemon : z5-fleet ; « deploy/container -p <projet> status »"* ]]
  refute_out 'bob63-forge|autre' <<<"$output"
  grep -qF 'ps -a --filter label=com.docker.compose.service=lcars' "$CALLS"
  unset STUB_LCARS_DAEMON
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"aucun conteneur lcars — « deploy/container up »"* ]]
}

@test "logs rend la main ; -f le suit, explicitement" {
  run bash "$SRC" -p lcars-fleet logs --tail 20
  [ "$status" -eq 0 ]
  grep -qE -- "-p lcars-fleet logs --tail 20$" "$CALLS"
  refute grep -qE -- " logs -f --tail" "$CALLS"
  run bash "$SRC" -p lcars-fleet logs -f
  grep -qE -- "-p lcars-fleet logs -f$" "$CALLS"
}

@test "pull sur une installation neuve ne dit pas de suite — l'installeur enchaîne ; sur une instance posée, la suite exacte, banc compris" {
  LCARS_IMAGE=registre/lcars:v2 run bash "$SRC" pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"container pull: « registre/lcars:v2 » tirée"* ]]
  refute_out 'Puis' <<<"$output"
  export STUB_IDS=c0ffee
  LCARS_IMAGE=registre/lcars:v2 run bash "$SRC" -p prod-fleet pull
  [[ "$output" == *"Puis :  LCARS_IMAGE=registre/lcars:v2 deploy/container -p prod-fleet up"* ]]
  export STUB_CONFIG_FILES="$ARBRE/deploy/docker/docker-compose.yml,$ARBRE/deploy/docker/docker-compose.bench.yml"
  LCARS_IMAGE=registre/lcars:v2 run bash "$SRC" -p z5-fleet pull
  [[ "$output" == *"Puis :  deploy/docker/bench/bench-swap-image.sh --forge-project z5 --image registre/lcars:v2"* ]]
}

@test "status : population d'humains non mesurée — dite comme telle, jamais « aucun humain »" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=2
  run bash "$SRC" status
  [[ "$output" == *"humains     : population non mesurée"* ]]
  [[ "$output" != *"aucun humain"* ]]
}

@test "up sur un conteneur en attente de configuration : rc 1 dès l'état lu, le geste de config et la recréation sont dits" {
  export STUB_IDS=c0ffee STUB_BOOT=awaiting-config
  run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"en attente de configuration"*"config"*"up --force-recreate"* ]]
  [ "$(grep -c 'cat /run/lcars-boot.state' "$CALLS")" -eq 2 ]
}

@test "up sur un init en échec : panne (2) dès l'état lu, sans attendre le verdict des gestes" {
  export STUB_IDS=c0ffee STUB_BOOT=init-failed
  run bash "$SRC" up
  [ "$status" -eq 2 ]
  [[ "$output" == *"init en échec"*"logs"* ]]
  # l'attente lit l'état une fois, status une fois
  [ "$(grep -c 'cat /run/lcars-boot.state' "$CALLS")" -eq 2 ]
}

@test "up attend le verdict des gestes de forge et montre status : un drift se dit et rend 0, un geste en échec rend 2" {
  sain
  export STUB_PROV=2
  run bash "$SRC" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"container up (lcars-fleet)"*"container status (lcars-fleet)"*"drift résiduel"* ]]
  export STUB_PROV=1
  run bash "$SRC" up
  [ "$status" -eq 2 ]
  [[ "$output" == *"échec d'un geste (rc=1)"*"le conteneur tourne et ne produira rien"* ]]
  export STUB_PROV=0
  run bash "$SRC" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"gestes convergés"* ]]
}

@test "up d'une instance neuve : personne d'inscrit, santé en période de grâce, deck pas encore publié — up rend 0, status dégradé" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=1 STUB_HEALTH=starting
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"santé : starting"*"aucun humain de fleet"*"deck        : rien ne répond"* ]]
  run bash "$SRC" status
  [ "$status" -eq 1 ]
}

@test "up sur un conteneur qui ne tourne plus : l'attente s'arrête dès l'état lu, panne (2)" {
  sain
  unset STUB_PROV
  export STUB_STATE=exited
  run bash "$SRC" up
  [ "$status" -eq 2 ]
  [[ "$output" == *"conteneur   : exited"* ]]
  # status lit le verdict une fois ; l'attente ne l'a pas lu
  [ "$(grep -c 'cat /run/lcars-forge.rc' "$CALLS")" -eq 1 ]
}

@test "up sans verdict dans le délai : le conteneur tourne, status le dit en cours, up rend 1 — rien ne confirme l'installation" {
  sain
  unset STUB_PROV
  run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"boot        : en cours (aucun verdict encore)"* ]]
  [ "$(grep -c 'cat /run/lcars-forge.rc' "$CALLS")" -gt 2 ]
  # l'attente se dit chaque minute
  [[ "$output" == *"container up : boot en cours depuis 60 s, sans verdict — « deploy/container -p lcars-fleet logs -f » le suit"* ]]
  [ "$(grep -c 'boot en cours depuis' <<<"$output")" -eq 15 ]
}

@test "une image qui publie son verdict dans lcars-provision.rc : l'attente s'arrête, un 0 n'est jamais « gestes convergés » et status reste dégradé" {
  sain
  unset STUB_PROV
  export STUB_PROV_ANCIEN=0
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"forge       : aucun geste en échec — cette image publie son verdict sans distinguer un drift"* ]]
  [[ "$output" != *"gestes convergés"* ]]
  [[ "$output" != *"boot en cours depuis"* ]]
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  export STUB_PROV_ANCIEN=1
  run bash "$SRC" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"échec d'un geste (rc=1)"* ]]
}

@test "up avec des clés ssh multi-lignes : le conteneur les reçoit, up rend status, et la conf ne les retient pas" {
  sain
  LCARS_SSH_AUTHORIZED_KEYS=$'ssh-ed25519 AAA a\nssh-ed25519 BBB b' LCARS_ADMIRAL=zoe run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"LCARS_SSH_AUTHORIZED_KEYS porte un retour à la ligne — prise pour ce démarrage, non retenue"* ]]
  grep -qx 'LCARS_ADMIRAL=zoe' "$ENV_FILE"
  refute grep -q 'LCARS_SSH_AUTHORIZED_KEYS' "$ENV_FILE"
}

@test "status : sans verdict encore, le boot est en cours — dégradé (1), jamais sain" {
  export STUB_IDS=c0ffee STUB_HUM=0 STUB_DECK_HTTP=302
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"en cours (aucun verdict encore)"* ]]
}

@test "config de secrets seuls sur un conteneur qui tourne : rc 0" {
  export STUB_IDS=c0ffee
  FORGE_ADMIN_TOKEN=tok-3 FORGE_SEED_PASSWORD=graine run bash "$SRC" config
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/pushed.token")" = tok-3 ]
}

@test "up retient ce qu'on lui a donné : l'image et la forge valent pour les gestes suivants" {
  sain
  LCARS_IMAGE=registre/lcars:v1 FORGE_BASE_URL=https://forge.exemple run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'LCARS_IMAGE=registre/lcars:v1' "$ENV_FILE"
  grep -qx 'FORGE_BASE_URL=https://forge.exemple' "$ENV_FILE"
  run bash "$SRC" pull
  grep -q '^pull registre/lcars:v1$' "$CALLS"
}

@test "shell entre sous le siège de l'instance quand LCARS_HUMAN n'est pas donné" {
  export STUB_IDS=c0ffee STUB_SEAT=zoe
  run bash "$SRC" shell
  [[ "$output" == *"exec -it -u zoe lcars bash"* ]]
  LCARS_HUMAN=ana run bash "$SRC" shell
  [[ "$output" == *"exec -it -u ana lcars bash"* ]]
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
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
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
  sain
  LCARS_LANDING_PORT_BIND=127.0.0.1:22021 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://127.0.0.1:22021,http://localhost:22021" ]
  # un bind sur toutes les interfaces devient la loopback pour le navigateur local
  LCARS_LANDING_PORT_BIND=0.0.0.0:22021 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://127.0.0.1:22021,http://localhost:22021" ]
  # l'operateur qui pose LCARS_DECK_ORIGINS garde la main
  LCARS_DECK_ORIGINS=http://deck.example LCARS_LANDING_PORT_BIND=127.0.0.1:22021 run bash "$SRC" up
  [ "$(cat "$BATS_TEST_TMPDIR/origins.seen")" = "http://deck.example" ]
}

@test "status : un deck qui rend 409 (entree non declaree) est DEGRADE, pas vert" {
  export STUB_IDS=c0ffee STUB_PROV=0 STUB_HUM=0 STUB_TAMPON=436f94cd STUB_REV=436f94cd STUB_DECK_HTTP=409
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"409"*"non déclarée"* ]]
}

# bats test_tags=structure
@test "aide : chaque variable d'env ANNONCEE est LUE — par container, par un compose qu'il pilote, ou par une lib qu'il source" {
  local names
  names="$(sed -n '/^# ENV (optionnels)/,/^# EXIT :/p' "$SRC" | grep -oE '^#   [A-Z][A-Z0-9_]+' | sed 's/^#   //')"
  [ "$(grep -c . <<<"$names")" -ge 8 ] || { echo "moins de 8 variables lues dans l'aide — l'instrument ne lit plus le bloc ENV" >&2; return 1; }
  # la liste des clés de conf et l'aide ne lisent rien : elles ne comptent pas comme lecture
  local code
  code="$(sed '/^CONF_KEYS=(/,/)/d' "$SRC" | cat - "$REPO/deploy/docker/docker-compose.yml" "$REPO/deploy/docker/docker-compose.secrets.yml" \
              "$REPO/deploy/lib/store.sh" "$REPO/deploy/lib/docker-endpoint.sh" | grep -vE '^\s*#')"
  local n bad=0
  while read -r n; do
    [ -n "$n" ] || continue
    grep -qE "(^|[^A-Z0-9_])$n([^A-Z0-9_]|$)" <<<"$code" || { echo "$n : annoncee par l'aide de container, lue nulle part" >&2; bad=1; }
  done <<<"$names"
  [ "$bad" -eq 0 ]
}

# ─── forge-check : la forge fournie, vérifiée depuis l'hôte avec la conf du projet ─────────────

# forge_fournie <adresse publique> — la conf d'un projet complet : deux adresses, jeton et seed posés ; curl est le vrai
forge_fournie() {
  rm -f "$BINDIR/curl"
  mkdir -p "$SECRETS"
  printf 'FORGE_BASE_URL=http://host.docker.internal:3000\nFORGE_PUBLIC_URL=%s\n' "$1" > "$ENV_FILE"
  printf 'JETON-MAITRE\n' > "$SECRETS/maitre-temoin.token"
  printf 'graine\n' > "$SECRETS/graine-temoin.pass"
}

@test "forge-check : une forge qui tient le contrat rend 0, sans appeler docker, et le jeton voyage en en-tête" {
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  forge_route GET '/api/v1/admin/users*' 200 '[]'
  forge_fournie "$FORGE_DOUBLE_URL"
  run bash "$SRC" forge-check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ok       la forge répond sur $FORGE_DOUBLE_URL"*"ok       jeton master accepté, site-admin"*"ok       seed posé"*"la forge tient le contrat"* ]]
  [[ "$output" != *"manque"* ]]
  [ "$(forge_requests 'select(.path | startswith("/api/v1/admin/users")) | .auth')" = '"token JETON-MAITRE"' ]
  [ ! -s "$CALLS" ]
}

@test "forge-check : une conf vide rend 1, et chaque manque vient avec son geste" {
  run bash "$SRC" forge-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL=http://<hôte>:<port> deploy/container -p lcars-fleet config"* ]]
  [[ "$output" == *"FORGE_PUBLIC_URL=http://<adresse tapée dans le navigateur>:<port> deploy/container -p lcars-fleet config"* ]]
  [[ "$output" == *"FORGE_ADMIN_TOKEN=<jeton> deploy/container -p lcars-fleet config"*"scope « all »"* ]]
  [[ "$output" == *"FORGE_SEED_PASSWORD=<mot de passe> deploy/container -p lcars-fleet config"* ]]
  [[ "$output" == *"4 manque(s)"*"deploy/README.md"* ]]
}

@test "forge-check : une forge qui ne répond pas est un manque, et le jeton posé n'est pas déclaré valide" {
  local port; port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  forge_fournie "http://127.0.0.1:$port"
  run bash "$SRC" forge-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manque   rien ne répond sur http://127.0.0.1:$port/api/v1/version depuis cet hôte"* ]]
  [[ "$output" == *"jeton master posé — non vérifié, la forge ne répond pas"* ]]
  [[ "$output" == *"1 manque(s)"* ]]
}

@test "forge-check : un jeton que la forge refuse, ou qui n'est pas site-admin, est un manque qui le dit" {
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  forge_route GET '/api/v1/admin/users*' 403 x1 '{"message":"forbidden"}'
  forge_route GET '/api/v1/admin/users*' 401 '{"message":"unauthorized"}'
  forge_fournie "$FORGE_DOUBLE_URL"
  run bash "$SRC" forge-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manque   le jeton master n'a pas la portée admin, ou son compte n'est pas site-admin (HTTP 403)"* ]]
  run bash "$SRC" forge-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manque   la forge refuse le jeton master (HTTP 401)"* ]]
}

@test "forge-check : un appel admin redirigé est un manque qui mène à l'adresse servie" {
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  forge_route GET '/api/v1/admin/users*' 301 -
  forge_fournie "$FORGE_DOUBLE_URL"
  run bash "$SRC" forge-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manque   l'appel admin est redirigé (HTTP 301)"*"FORGE_PUBLIC_URL=<adresse> deploy/container -p lcars-fleet config"* ]]
}

@test "forge-check : le jeton qui part en http hors de la loopback le dit ; sur la loopback, rien" {
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  forge_route GET '/api/v1/admin/users*' 200 '[]'
  forge_fournie "$FORGE_DOUBLE_URL"
  run bash "$SRC" forge-check
  [ "$status" -eq 0 ]
  [[ "$output" != *"en clair"* ]]
  # la forge doublée répond sous un nom qui n'est pas la loopback
  local port="${FORGE_DOUBLE_URL##*:}" vrai_curl; vrai_curl="$(command -v curl)"
  printf '#!/usr/bin/env bash\nexec %q --resolve forge.exemple:%s:127.0.0.1 "$@"\n' "$vrai_curl" "$port" > "$BINDIR/curl"; chmod 0755 "$BINDIR/curl"
  printf 'FORGE_BASE_URL=http://forge.exemple:%s\nFORGE_PUBLIC_URL=http://forge.exemple:%s\n' "$port" "$port" > "$ENV_FILE"
  run bash "$SRC" forge-check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"note     le jeton master part en clair vers http://forge.exemple:$port"*"ok       jeton master accepté, site-admin"* ]]
}

@test "forge-apply : le roster se dérive de l'image du conteneur et se pose root 0644 dans la recette, avant la recette" {
  run bash "$SRC" forge-apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun conteneur lcars"*"deploy/container -p lcars-fleet up"* ]]
  cat > "$ARBRE/deploy/lib/enroll-catalogue.sh" <<FAKE
#!/usr/bin/env bash
echo "ENROLL \$*" >> "$CALLS"
[[ -z "\${ENROLL_REFUS:-}" ]] || { echo "refus-temoin" >&2; exit 2; }
while [[ \$# -gt 0 ]]; do [[ "\$1" == --tofu-dir ]] && dir="\$2"; shift; done
echo '{"roles":["temoin"]}' > "\$dir/roles.auto.tfvars.json"
FAKE
  chmod +x "$ARBRE/deploy/lib/enroll-catalogue.sh"
  export STUB_IDS=c0ffee
  run bash "$SRC" forge-apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^ENROLL --tofu-dir .* --image sha256:image-temoin$" "$CALLS"
  [ "$(cat "$BATS_TEST_TMPDIR/roster.seen")" = '{"roles":["temoin"]}' ]
  local pose recette
  pose="$(grep -n "exec -T -u root lcars sh -c .* sh /opt/lcars/services/forge-recipe/roles.auto.tfvars.json$" "$CALLS" | cut -d: -f1)"
  recette="$(grep -n "exec -T -u root lcars /opt/lcars/forge-gestures.sh apply" "$CALLS" | cut -d: -f1)"
  [ -n "$pose" ]
  [ -n "$recette" ]
  [ "$pose" -lt "$recette" ]
  : > "$CALLS"
  ENROLL_REFUS=1 run bash "$SRC" forge-apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"refus-temoin"*"roster des rôles non posé"* ]]
  refute grep -q "forge-gestures.sh apply" "$CALLS"
}

@test "forge-apply : le jeton master part par l'entrée de la recette, jamais dans l'environnement de docker ni de la dérivation" {
  printf '#!/usr/bin/env bash\nenv | grep -E "^FORGE_(ADMIN_TOKEN|SEED_PASSWORD)=" >> "%s/env-docker"\nwhile [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done\necho "{}" > "$dir/roles.auto.tfvars.json"\n' \
    "$BATS_TEST_TMPDIR" > "$ARBRE/deploy/lib/enroll-catalogue.sh"
  chmod +x "$ARBRE/deploy/lib/enroll-catalogue.sh"
  export STUB_IDS=c0ffee
  FORGE_ADMIN_TOKEN=tok-secret FORGE_SEED_PASSWORD=graine-secrete run bash "$SRC" forge-apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/pushed.apply")" = tok-secret ]
  [ ! -s "$BATS_TEST_TMPDIR/env-docker" ]
}

@test "forge-apply : sans jq sur l'hôte, le refus nomme jq avant de demander le roster à l'image" {
  cp "$REPO/deploy/lib/enroll-catalogue.sh" "$ARBRE/deploy/lib/"
  local sans="$BATS_TEST_TMPDIR/sans-jq" dir f n
  mkdir -p "$sans"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      [[ -f "$f" && -x "$f" && "$n" != jq && ! -e "$sans/$n" ]] || continue
      ln -s "$f" "$sans/$n"
    done
  done
  export STUB_IDS=c0ffee
  PATH="$sans" run bash "$SRC" forge-apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq requis sur cette machine"*"roster des rôles non posé"* ]]
  refute grep -q ' run --rm ' "$CALLS"
  refute grep -q "forge-gestures.sh apply" "$CALLS"
}

@test "forge-apply réussi nomme le geste qui pose jetons, catalogues et deck sur la structure : la recréation du conteneur" {
  printf '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do [[ "$1" == --tofu-dir ]] && dir="$2"; shift; done\necho "{}" > "$dir/roles.auto.tfvars.json"\n' > "$ARBRE/deploy/lib/enroll-catalogue.sh"
  chmod +x "$ARBRE/deploy/lib/enroll-catalogue.sh"
  export STUB_IDS=c0ffee
  run bash "$SRC" forge-apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"jetons de rôle"*"deploy/container -p lcars-fleet up --force-recreate"* ]]
  [[ "$output" != *"ce que le conteneur voit de sa forge maintenant"* ]]
}

@test "source-push : le compte et le groupe arrivent au bash du conteneur en arguments — un login qui porte un guillemet reste un login" {
  mkdir -p "$BATS_TEST_TMPDIR/conteneur-bin" "$BATS_TEST_TMPDIR/clone/.git"
  local o
  for o in chown mv rm git; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/conteneur.calls"\n' "$o" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/conteneur-bin/$o"
    chmod +x "$BATS_TEST_TMPDIR/conteneur-bin/$o"
  done
  export STUB_IDS=c0ffee
  LCARS_HUMAN="o'brien" run bash "$SRC" source-push "$BATS_TEST_TMPDIR/clone"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "chown -R o'brien:fleet /home/projects/.lcars-fleet.incoming" "$BATS_TEST_TMPDIR/conteneur.calls"
  grep -qx "mv -T /home/projects/.lcars-fleet.incoming /home/projects/lcars-fleet" "$BATS_TEST_TMPDIR/conteneur.calls"
}

@test "pull sans image nommée, depuis un kit, vise l'image que pack a inscrite au compose, même quand lcars-fleet:local est sur ce daemon" {
  sed -i 's|${LCARS_IMAGE:-lcars-fleet:local}|${LCARS_IMAGE:-registre.exemple/lcars-fleet:v7}|' "$ARBRE/deploy/docker/docker-compose.yml"
  run bash "$SRC" pull
  grep -qx 'pull registre.exemple/lcars-fleet:v7' "$CALLS" || { cat "$CALLS"; return 1; }
  refute grep -qx 'pull lcars-fleet:local' "$CALLS"
}

@test "pull sans image nommée, depuis un checkout, refuse de tirer l'image locale et nomme les deux gestes" {
  run bash "$SRC" pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"lcars-fleet:local est l'image qu'un checkout bâtit, aucun registre ne la porte"* ]]
  [[ "$output" == *"LCARS_IMAGE=<registre/image:tag> deploy/container pull"* ]]
  refute grep -q '^pull ' "$CALLS"
}

@test "up pose le magasin du projet avant de créer le conteneur : compose refuse un volume externe absent" {
  sain
  run bash "$SRC" -p mon-instance up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local v magasin up
  for v in cache toolchains sysroots state; do grep -qx "volume create mon-instance-$v" "$CALLS"; done
  magasin="$(grep -n '^volume create mon-instance-cache$' "$CALLS" | cut -d: -f1)"
  up="$(grep -n -- '-p mon-instance up -d' "$CALLS" | cut -d: -f1)"
  [ "$magasin" -lt "$up" ]
}

@test "status d'un banc : la recréation se fait par bench-swap-image sur l'image qui tourne, jamais par un up simple ni par --bench up" {
  export STUB_IDS=c0ffee STUB_BOOT=awaiting-config STUB_CONFIG_FILES="x/docker-compose.yml,x/docker-compose.bench.yml"
  run bash "$SRC" -p bt-fleet status
  [ "$status" -eq 1 ]
  [[ "$output" == *"deploy/docker/bench/bench-swap-image.sh --forge-project bt --image lcars-fleet:banc"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"--bench up"* ]]
}

@test "status : le deck se sonde par la première entrée que le conteneur a déclarée, et un deck muet se dit sans code doublé" {
  sain
  export STUB_ORIGINES="http://localhost:4321,http://192.0.2.9:4321"
  run bash "$SRC" status
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/curl.urls")" = "http://localhost:4321/auth/login" ]
  [[ "$output" == *"deck        : répond sur http://localhost:4321 (HTTP 302)"* ]]
  unset STUB_ORIGINES STUB_DECK_HTTP
  run bash "$SRC" status
  [ "$status" -eq 1 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/curl.urls")" = "http://127.0.0.1:4999/auth/login" ]
  [[ "$output" == *"deck        : rien ne répond sur http://127.0.0.1:4999"* ]]
  [[ "$output" != *"000000"* ]]
}

@test "up d'une instance qui tourne sans ports dans sa conf : elle garde les ports qu'elle publie, jamais les défauts" {
  sain
  export STUB_PUBLIES='22/tcp=127.0.0.1:20032\n4999/tcp=:20031\n'
  run bash "$SRC" up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/binds.seen")" = $'LCARS_LANDING_PORT_BIND=0.0.0.0:20031\nLCARS_SSH_PORT=127.0.0.1:20032' ]
  # un port donné à l'appel gagne sur celui que l'instance publie
  run bash "$SRC" --port-deck 20091 up
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/binds.seen")" = $'LCARS_LANDING_PORT_BIND=127.0.0.1:20091\nLCARS_SSH_PORT=127.0.0.1:20032' ]
}
