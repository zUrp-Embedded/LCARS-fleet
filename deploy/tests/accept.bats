#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/accept.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de deploy/accept, joué entier — la connexion à la forge, la mesure des runners, le démarrage de la fleet, le verdict et son code

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  unset SUDO_USER NO_COLOR
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le démarrage sous un humain se joue en root de namespace"
  SANDBOX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$SANDBOX/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../accept" "$SANDBOX/deploy/"
  cp "$BATS_TEST_DIRNAME/../lib/provision-lib.sh" "$BATS_TEST_DIRNAME/../lib/docker-endpoint.sh" "$SANDBOX/deploy/lib/"
  cp "$BATS_TEST_DIRNAME/../installer-constants.env" "$BATS_TEST_DIRNAME/../system.manifest" "$SANDBOX/deploy/"
  # ⚖ décision 3 : la lib refuse au sourcing sans les faits du produit, que ce bac à sable ne copie
  # pas (il n'a que `deploy/`). On les lui NOMME, comme un opérateur le ferait.
  export PROV_PRODUCT_FACTS_FILE="$BATS_TEST_DIRNAME/../../runtime/etc/facts.env"
  # ⚖ phase 6 : la lib SOURCE les primitives du produit, que ce bac à sable ne copie pas
  export PROV_PRIMITIVES_SH="$BATS_TEST_DIRNAME/../../runtime/services/lib/primitives.sh"
  MOD="$SANDBOX/deploy/accept"
  decor_pose
  TOKENS="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  ANNOUNCE="$BATS_TEST_TMPDIR/annonce"; : > "$ANNOUNCE"
  # la population de la machine : le siège (uid 1000, seat.uid) et un humain de fleet, lcars
  HOME_DIR="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME_DIR"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  printf 'root:x:0:0::/root:/bin/bash\nsiege:x:1000:1000::/home/siege:/bin/bash\nlcars:x:1001:1001::%s:/bin/bash\n' "$HOME_DIR" > "$LCARS_DECOR_ROOT/etc/passwd"
  printf '1000\n' > "$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  printf '%s\n' '#!/usr/bin/env bash' \
    "[[ \"\$1\" == passwd && -n \"\$2\" ]] || exit 2" \
    "printf '%s:x:1001:1001::%s:/bin/bash\\n' \"\$2\" '$HOME_DIR'" > "$BINDIR/getent"
  printf '%s\n' '#!/usr/bin/env bash' 'shift 2; [[ "$1" == "--" ]] && shift; exec "$@"' > "$BINDIR/runuser"
  # les groupes d'un compte : membre de fleet s'il est nommé dans MEMBRES_FLEET ; le reste va au vrai id
  export MEMBRES_FLEET="$BATS_TEST_TMPDIR/membres-fleet"; printf 'lcars\n' > "$MEMBRES_FLEET"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "$1" == -nG ]]; then if grep -qx -- "$2" "$MEMBRES_FLEET"; then echo "$2 fleet"; else echo "$2"; fi; exit 0; fi' \
    'exec /usr/bin/id "$@"' > "$BINDIR/id"
  chmod 0755 "$BINDIR"/*
  # fleet n'est que dans le PATH de la session de l'humain : le lanceur ne le voit pas
  FLEET_BIN="$BATS_TEST_TMPDIR/fleet-bin"; mkdir -p "$FLEET_BIN"
  printf 'export PATH="%s:/usr/bin:/bin"\n' "$FLEET_BIN" > "$HOME_DIR/.bash_profile"
}

teardown() { forge_double_stop; }

# la doublure de fleet écrit encore après « BEAM vivant » : c'est la fenêtre où un grep -q sous pipefail tuait le producteur
fleet_stub() { # fleet_stub <vivant|mort|start-casse>
  local etat="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "ETAT='$etat'"
    printf '%s\n' 'pwd >> "$MARQUEUR.cwd"; printf "%s\n" "${USER:-}" >> "$MARQUEUR.user"'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status)'
    printf '%s\n' '    printf "fleet: build deadbeef (source=release)\n"'
    printf '%s\n' '    [[ -f "$MARQUEUR" || "$ETAT" == vivant ]] && printf "fleet: BEAM vivant. Logs : tmux -S …\n"'
    printf '%s\n' '    sleep 0.3'
    printf '%s\n' '    printf "fleet: visibilite debug : off\n"'
    printf '%s\n' '    printf "(aucun pod vivant)\n"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  start) [[ "$ETAT" == start-casse ]] && { echo "plainte-temoin du lanceur" >&2; exit 1; }; : > "$MARQUEUR"; [[ -z "${LCARS_START_WITHOUT_CLAUDE:-}" ]] || : > "$MARQUEUR.sans-claude" ;;'
    printf '%s\n' '  stop)  rm -f "$MARQUEUR" ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$FLEET_BIN/fleet"
  chmod 0755 "$FLEET_BIN/fleet"
  export MARQUEUR="$BATS_TEST_TMPDIR/beam.vivant"
  rm -f "$MARQUEUR" "$MARQUEUR.cwd" "$MARQUEUR.user"
}

accept_joue() { # accept_joue [option d'accept…] — le script entier, en root de namespace, sous le décor
  run unshare -Ur env PATH="$DECOR_BIN:$BINDIR:/usr/bin:/bin" bash "$MOD" --announce-file "$ANNOUNCE" "$@"
}

modele() { # modele <version> <label> — le modèle de projet de cette version de la release posée demande ce label
  local wf="$LCARS_DECOR_ROOT/opt/lcars/runtime/rel/lcars_fleet/lib/lcars_fleet-$1/priv/catalogue/project_template/main/.gitea/workflows"
  mkdir -p "$wf"
  printf 'jobs:\n  test:\n    runs-on: %s\n' "$2" > "$wf/ci.yml"
}

forge_runners() { # forge_runners <code http> <corps> — la forge locale sert les runners, son adresse et le jeton master sont posés
  [[ -n "${FORGE_DOUBLE_PID:-}" ]] || forge_double_start
  forge_route GET /api/v1/admin/actions/runners "$1" "$2"
  printf '%s\n' "$FORGE_DOUBLE_URL" > "$TOKENS/forge.url"
  printf 'jeton-de-decor\n' > "$TOKENS/forge-master.token"
}

UN_RUNNER_SHELL='{"total_count":1,"runners":[{"name":"r1","labels":[{"name":"shell"}]}]}'

# ─── la forge ───────────────────────────────────────────────────────────────────────────────────

@test "forge : un identifiant annoncé s'authentifie en Basic contre la forge" {
  forge_runners 200 "$UN_RUNNER_SHELL"
  forge_route GET /api/v1/user 200 '{"login":"alice"}'
  printf 'forge\talice\tmot de passe "fort"\n' > "$ANNOUNCE"
  accept_joue
  [[ "$output" == *"OUI   forge : « alice » s'authentifie avec le mot de passe annoncé"* ]]
  [ "$(forge_requests 'select(.path == "/api/v1/user") | .auth')" = '"basic alice:mot de passe \"fort\""' ]
}

@test "forge : un identifiant que la forge refuse est un échec qui nomme le code HTTP, la sortie est 1" {
  forge_runners 200 "$UN_RUNNER_SHELL"
  forge_route GET /api/v1/user 401 '{"message":"user does not exist"}'
  printf 'forge\talice\tfaux\n' > "$ANNOUNCE"
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   forge : « alice » ne s'authentifie pas (HTTP 401)"* ]]
}

@test "sans adresse de forge, une seule capacité manque : la CI n'est pas comptée une seconde fois" {
  printf 'forge\talice\tmdp\n' > "$ANNOUNCE"
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   forge : aucune adresse connue"* ]]
  [[ "$output" == *"---   CI : sans adresse de forge"* ]]
  refute_out 'NON   CI' <<<"$output"
}

@test "aucun secret dans l'argv ni l'environnement d'un enfant : ni le mot de passe annoncé, ni le jeton master" {
  espion_enfants curl base64 tr
  forge_runners 200 '{"total_count":0,"runners":[]}'
  forge_route GET /api/v1/user 200 '{"login":"alice"}'
  printf 'forge\talice\tmdp-annonce\n' > "$ANNOUNCE"
  accept_joue
  [ "$(forge_requests '.path' | wc -l)" -eq 2 ]
  [ "$(forge_requests 'select(.path == "/api/v1/user") | .auth' | jq -r .)" = "basic alice:mdp-annonce" ]
  [ "$(grep -c '^ARGV curl ' "$DECOR_ENFANTS")" -eq 2 ]
  grep -q '^ARGV base64 ' "$DECOR_ENFANTS"
  refute grep -q 'mdp-annonce' "$DECOR_ENFANTS"
  refute grep -qF "$(printf 'alice:mdp-annonce' | base64 -w0)" "$DECOR_ENFANTS"
  refute grep -q 'jeton-de-decor' "$DECOR_ENFANTS"
}

# ─── la CI ──────────────────────────────────────────────────────────────────────────────────────

@test "CI : une forge injoignable est sautée, jamais comptée comme zéro runner" {
  forge_runners 200 '{"total_count":0,"runners":[]}'
  printf 'http://127.0.0.1:1\n' > "$TOKENS/forge.url"
  accept_joue
  [[ "$output" == *"---   CI : l'API admin des runners n'a pas répondu (HTTP 000)"* ]]
  refute_out "aucun runner" <<<"$output"
}

@test "CI : l'adresse vient du fichier forge.url du décor, et l'API admin des runners est lue avec le jeton master" {
  modele 1.2.0 shell
  forge_runners 200 "$UN_RUNNER_SHELL"
  accept_joue
  [[ "$output" == *"OUI   CI : 1 runner(s) servant les labels que le modèle de projet livré demande (shell)"* ]]
  [ "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners") | .auth')" = '"token jeton-de-decor"' ]
}

@test "CI : un jeton hors portée site-admin est sauté, et le refus nomme le code HTTP" {
  forge_runners 403 '{"message":"token does not have at least one of required scope(s)"}'
  accept_joue
  [[ "$output" == *"---   CI : l'API admin des runners n'a pas répondu (HTTP 403)"* ]]
}

@test "CI : une réponse qui n'est pas du JSON est sautée" {
  forge_runners 404 '<html><body>404 Not Found</body></html>'
  accept_joue
  [[ "$output" == *"---   CI : l'API admin des runners n'a pas répondu (HTTP 404)"* ]]
}

@test "CI : un 200 sans total_count entier est sauté — forme inattendue" {
  local corps
  for corps in '{"ok":true}' '{"total_count":"3"}' '{"total_count":1.5}'; do
    [[ -z "${FORGE_DOUBLE_DIR:-}" ]] || : > "$FORGE_DOUBLE_DIR/routes"
    forge_runners 200 "$corps"
    accept_joue
    [[ "$output" == *"---   CI : réponse 200 de l'API admin sans « total_count » entier"* ]] || { echo "$corps : $output"; return 1; }
  done
}

@test "CI : zéro runner mesuré est un échec" {
  forge_runners 200 '{"total_count":0,"runners":[]}'
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   CI : aucun runner enregistré"* ]]
}

@test "CI : seule la version de la release qui démarre compte — pas une assemblée restée à côté" {
  modele 1.2.0 shell
  modele 1.1.0 vieux-label
  mkdir -p "$LCARS_DECOR_ROOT/opt/lcars/runtime/rel/lcars_fleet/releases"
  printf '27 1.2.0\n' > "$LCARS_DECOR_ROOT/opt/lcars/runtime/rel/lcars_fleet/releases/start_erl.data"
  forge_runners 200 "$UN_RUNNER_SHELL"
  accept_joue
  [[ "$output" == *"OUI   CI : 1 runner(s)"*"(shell)"* ]]
  refute_out "vieux-label" <<<"$output"
}

@test "CI : sans release posée, le contrôle des labels est un échec nommé — le modèle d'un checkout ne la remplace pas" {
  local wf="$SANDBOX/runtime/priv/catalogue/project_template/main/.gitea/workflows"
  mkdir -p "$wf"; printf 'jobs:\n  test:\n    runs-on: shell\n' > "$wf/ci.yml"
  forge_runners 200 "$UN_RUNNER_SHELL"
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   CI : aucun « runs-on » lu dans les workflows du modèle de projet de la release posée"* ]]
}

@test "CI : après un réenrôlement, seul le runner le plus récent de son nom compte, s'il est en ligne ; l'ancien n'est pas un second runner" {
  modele 1.2.0 shell
  # l'ancien enregistrement, encore « en ligne » à l'instant du réenrôlement, porte des labels que le neuf ne sert plus
  forge_runners 200 '{"total_count":3,"runners":[{"id":2,"name":"lcars-runner","status":"online","labels":[{"name":"shell"}]},{"id":3,"name":"lcars-runner","status":"online","labels":[{"name":"autre"}]},{"id":1,"name":"vieux","status":"offline","labels":[{"name":"shell"}]}]}'
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   CI : 1 runner(s), mais aucun ne sert : shell"* ]]
  : > "$FORGE_DOUBLE_DIR/routes"
  forge_runners 200 '{"total_count":2,"runners":[{"id":2,"name":"lcars-runner","status":"online","labels":[{"name":"shell"}]},{"id":3,"name":"lcars-runner","status":"online","labels":[{"name":"shell"}]}]}'
  accept_joue
  [[ "$output" == *"OUI   CI : 1 runner(s) servant"* ]]
  : > "$FORGE_DOUBLE_DIR/routes"
  forge_runners 200 '{"total_count":1,"runners":[{"id":4,"name":"lcars-runner","status":"offline","labels":[{"name":"shell"}]}]}'
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   CI : aucun runner en ligne"* ]]
}

@test "CI : un runner qui ne sert pas le label demandé est un échec qui le nomme" {
  modele 1.2.0 shell
  forge_runners 200 '{"total_count":1,"runners":[{"name":"r1","labels":[{"name":"autre"}]}]}'
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   CI : 1 runner(s), mais aucun ne sert : shell"* ]]
}

# ─── la fleet ───────────────────────────────────────────────────────────────────────────────────

@test "fleet déjà vivante : le sondage la voit, rien n'est démarré, et « elle démarre » n'est pas établi" {
  fleet_stub vivant
  accept_joue
  [[ "$output" == *"---   fleet : déjà démarrée sous « lcars »"*"n'est pas établi"* ]]
  [ ! -e "$MARQUEUR" ]
}

@test "instrument : la doublure de fleet écrit encore après « BEAM vivant » — un grep -q sous pipefail tuerait le producteur" {
  fleet_stub vivant
  run env PATH="$FLEET_BIN:$PATH" python3 -c \
    'import signal, os, sys; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash -uo pipefail -c \
    'fleet status 2>/dev/null | grep -q "BEAM vivant"; echo "rc=$? PIPESTATUS=${PIPESTATUS[*]}"'
  [[ "$output" == *"PIPESTATUS=141 0"* ]]
}

@test "fleet arrêtée : elle est démarrée sous l'humain de la machine, depuis son home et le PATH de sa session, vue vivante, puis arrêtée" {
  fleet_stub mort
  accept_joue
  [[ "$output" == *"OUI   fleet : démarre et vivante sous « lcars », arrêtée après mesure"* ]]
  [ ! -e "$MARQUEUR" ]
  [ "$(sort -u "$MARQUEUR.cwd")" = "$HOME_DIR" ]
}

@test "sur un banc, la fleet démarre sous l'humain de démonstration, sans credentials claude, et reste debout" {
  fleet_stub mort
  # un autre humain de fleet le précède dans la table : c'est l'humain de démonstration qui est retenu
  printf 'root:x:0:0::/root:/bin/bash\nsiege:x:1000:1000::/home/siege:/bin/bash\nalice:x:1001:1001::/home/alice:/bin/bash\ncaptain:x:1002:1002::%s:/bin/bash\n' "$HOME_DIR" > "$LCARS_DECOR_ROOT/etc/passwd"
  printf 'alice\ncaptain\n' > "$MEMBRES_FLEET"
  LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=captain accept_joue
  [[ "$output" == *"OUI   fleet : démarre et vivante sous « captain », laissée debout"* ]]
  [ "$(sort -u "$MARQUEUR.user")" = captain ]
  [ -e "$MARQUEUR" ]
  [ -e "$MARQUEUR.sans-claude" ]
}

@test "sur un banc, un humain de démonstration absent des humains de fleet est un manque nommé : rien ne démarre sous un autre" {
  fleet_stub mort
  LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=demo accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   fleet : l'humain de démonstration du banc « demo » n'est pas matérialisé parmi les humains de fleet de cette machine"* ]]
  refute_out '« lcars »' <<<"$output"
  [ ! -e "$MARQUEUR" ]
  [ ! -e "$MARQUEUR.user" ]
}

@test "hors banc, un compte humain hors du groupe fleet n'est pas un humain de fleet : la fleet démarre sous un membre, ou rien n'est démarré" {
  fleet_stub mort
  printf 'root:x:0:0::/root:/bin/bash\nsiege:x:1000:1000::/home/siege:/bin/bash\nalice:x:1001:1001::/home/alice:/bin/bash\nlcars:x:1002:1002::%s:/bin/bash\n' "$HOME_DIR" > "$LCARS_DECOR_ROOT/etc/passwd"
  accept_joue
  [[ "$output" == *"OUI   fleet : démarre et vivante sous « lcars »"* ]]
  [ "$(sort -u "$MARQUEUR.user")" = lcars ]
  : > "$MEMBRES_FLEET"
  accept_joue
  [[ "$output" == *"---   fleet : aucun humain de fleet sur cette machine (membre du groupe « fleet »)"* ]]
  refute_out '« alice »|« lcars »' <<<"$output"
}

@test "start en échec : refus qui cite la plainte du lanceur" {
  fleet_stub start-casse
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON   fleet : « fleet start » a échoué sous « lcars »"*"plainte-temoin du lanceur"* ]]
}

@test "fleet absent du PATH de l'humain : refus qui nomme le compte" {
  accept_joue
  [[ "$output" == *"NON   fleet : « fleet » n'est pas dans le PATH de « lcars »"* ]]
}

@test "l'humain de fleet est celui que la machine porte, jamais un nom reçu de l'environnement" {
  fleet_stub vivant
  LCARS_BUILTIN_HUMAN=bob accept_joue
  [[ "$output" == *"« lcars »"* ]]
  [[ "$output" != *"« bob »"* ]]
}

@test "aucun humain de fleet sur la machine : sauté en le disant, aucun nom inventé" {
  fleet_stub vivant
  printf 'root:x:0:0::/root:/bin/bash\nsiege:x:1000:1000::/home/siege:/bin/bash\n' > "$LCARS_DECOR_ROOT/etc/passwd"
  accept_joue
  [[ "$output" == *"---   fleet : aucun humain de fleet sur cette machine"* ]]
  [[ "$output" != *"« lcars »"* ]]
}

# ─── le verdict ─────────────────────────────────────────────────────────────────────────────────

@test "verdict : trois capacités tenues rendent 0 et le disent" {
  modele 1.2.0 shell
  forge_runners 200 "$UN_RUNNER_SHELL"
  forge_route GET /api/v1/user 200 '{"login":"alice"}'
  printf 'forge\talice\tmdp\n' > "$ANNOUNCE"
  fleet_stub mort
  accept_joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"Les trois tiennent."* ]]
}

@test "verdict : une capacité sautée sans rien de faux rend 0 et la nomme non établie" {
  modele 1.2.0 shell
  forge_runners 200 "$UN_RUNNER_SHELL"
  forge_route GET /api/v1/user 200 '{"login":"alice"}'
  printf 'forge\talice\tmdp\n' > "$ANNOUNCE"
  fleet_stub vivant
  accept_joue
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 capacité(s) sur 3 vérifiée(s) — fleet : rien à mesurer dans cette passe, donc pas établie(s)"* ]]
}

@test "verdict : une capacité manquante rend 1 et le compte ; une option inconnue rend 2" {
  forge_runners 200 '{"total_count":0,"runners":[]}'
  fleet_stub vivant
  accept_joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 capacité(s) manquante(s) — l'installation est incomplète"* ]]
  accept_joue --zzz
  [ "$status" -eq 2 ]
  [[ "$output" == *"accept: option inconnue: --zzz"* ]]
}

@test "verdict : une option sans sa valeur rend 2, comme une option inconnue — jamais le 1 d'une capacité manquante" {
  run unshare -Ur env PATH="$DECOR_BIN:$BINDIR:/usr/bin:/bin" bash "$MOD" --announce-file
  [ "$status" -eq 2 ]
  [[ "$output" == *"accept: --announce-file attend une valeur"* ]]
}

@test "la palette suit NO_COLOR, même sur un terminal" {
  fleet_stub vivant
  local cmd="unshare -Ur env PATH='$DECOR_BIN:$BINDIR:/usr/bin:/bin' bash '$MOD' --announce-file '$ANNOUNCE'"
  run script -qec "$cmd" /dev/null
  [[ "$output" == *$'\033['* ]]
  run script -qec "env NO_COLOR=1 $cmd" /dev/null
  [[ "$output" == *"ACCEPTATION"* ]]
  refute_out $'\033\\[' <<<"$output"
}
