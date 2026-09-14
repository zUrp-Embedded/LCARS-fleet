#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/00-preflight.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-31
# STATUS: témoins de 00-preflight — les faits que l'installeur lit, et les verdicts qui ne bougent pas

load ../refute
load ../support/decor

setup() {
  # le décor possède l'environnement : toute la famille est effacée, pas les noms connus
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  unset SUDO_USER
  # la révision de l'arbre, que le runner exporte avant tout module
  export PROV_SOURCE_REV=cafe1234

  MOD="$BATS_TEST_DIRNAME/../../modules.d/00-preflight.sh"
  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  [ -f "$MOD" ]
  [ -f "$LIB" ]
  FACTS="$BATS_TEST_TMPDIR/facts"

  decor_pose
  BIN="$DECOR_BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod 0755 "$BIN/docker"
  CHANNEL="$LCARS_DECOR_ROOT/etc/lcars/channel"
  APT_HISTORY="$LCARS_DECOR_ROOT/var/log/apt/history.log"
  mkdir -p "$(dirname "$APT_HISTORY")"
  printf 'root:x:0:0::/root:/bin/bash\nbob:x:1000:1000::/home/bob:/bin/bash\n' > "$LCARS_DECOR_ROOT/etc/passwd"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  mkdir -p "$LCARS_DECOR_ROOT/proc"
  printf 'MemTotal:       8388608 kB\n' > "$LCARS_DECOR_ROOT/proc/meminfo"
}

teardown() { [[ -z "${LISTENER:-}" ]] || kill "$LISTENER" 2>/dev/null || true; }

# la garde du runner est armée : un module qui meurt rend 3, et « status -ne 3 » mesure quelque chose
preflight() { # preflight <substrat> [VAR=val…]
  local sub="$1"; shift
  run env PROV_FACTS_FILE="$FACTS" PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight PROVISION_RUN=1 \
      PROV_SUBSTRATE="$sub" PROV_DOCKER_BIN="$BIN/docker" \
      PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$@" bash "$MOD" check
}

double() { # double <outil> <corps bash> — une doublure dans le PATH du décor
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"; chmod 0755 "$BIN/$1"
}

naissance_est() { # naissance_est <valeur> — ce que « stat -c %W / » rend pour la naissance de l'instance ; le reste va au vrai stat
  double stat "[[ \"\$*\" == '-c %W /' ]] && { echo '$1'; exit 0; }
exec $(PATH=/usr/bin:/bin command -v stat) \"\$@\""
}

df_rend() { # df_rend <Mo libres> — df note son argument dans $BATS_TEST_TMPDIR/df.args
  double df "echo \"\$*\" >> '$BATS_TEST_TMPDIR/df.args'
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\\nfaux 100000 0 %s 1%% /\\n' '$1'"
}

lignes() { grep -c -- "$1" <<<"$output" || true; }

fact() { sed -n "s/^$1=//p" "$FACTS" 2>/dev/null | tail -1; }

path_sans() { # path_sans <outil> → un dossier qui porte tout le PATH système sauf l'outil
  local sans="$BATS_TEST_TMPDIR/sans-$1" d f n; mkdir -p "$sans"
  for d in /usr/sbin /usr/bin /sbin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      n="$(basename "$f")"
      [ "$n" = "$1" ] && continue
      [ -e "$sans/$n" ] || ln -sf "$f" "$sans/$n"
    done
  done
  echo "$sans"
}

docker_qui_repond() { # un docker qui répond à version et compose, publie <conteneur> (projet <projet>) sur tout port, et connaît <projet-existant>
  cat > "$BIN/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "compose version"*)       echo "Docker Compose version v2.0.0" ;;
  version*)                 echo "29.0.0|Docker Engine - Test" ;;
  "ps --filter publish="*)  [[ -n "${1:-}" ]] && echo "$1" ;;
  "inspect -f "*)           echo "${2:-}" ;;
  "ps -a --filter label=com.docker.compose.project=${3:-jamais} -q") echo abc123 ;;
esac
exit 0
EOF
  chmod 0755 "$BIN/docker"
}

ss_muet() { # un ss qui voit l'écoute sans nommer le processus
  printf '#!/usr/bin/env bash\necho "LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*"\n' "$1" > "$BIN/ss"
  chmod 0755 "$BIN/ss"
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

listen_on() { # listen_on <port> — un processus python qui écoute quelques secondes ; pid dans $LISTENER
  python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(128); time.sleep(60)' "$1" &
  LISTENER=$!
  local n=0
  until timeout 1 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null; do n=$((n + 1)); [[ "$n" -lt 10 ]] || return 1; sleep 0.2; done
  return 0
}


contrat() { # les faits que lisent install.sh et deploy/workstation, dérivés de leurs appels à fait
  local install="$BATS_TEST_DIRNAME/../../../install.sh" poste="$BATS_TEST_DIRNAME/../../workstation"
  {
    grep -hvE '^\s*#' "$install" "$poste" | grep -oE '\bfait "?[a-z0-9_]+("|\)| |$)' | sed -E 's/^fait "?//; s/("|\)| )$//'
    # les deux familles nommées par variable : fait "port_$p" sur la boucle des ports, fait "$t" sur les
    # outils requis, posés ou ajoutés selon le mode
    sed -n 's/^for p in \(.*\); do$/\1/p' "$install" | tr ' ' '\n' | sed 's/^/port_/'
    grep -ohE 'OUTILS_REQUIS\+?="[a-z ]+"' "$install" | sed 's/.*="\(.*\)"/\1/' | tr ' ' '\n' | grep -v '^$'
  } | sort -u
}

faits_poses() { # faits_poses <faits admis vides> — chaque fait du contrat est posé ; vide seulement s'il est admis vide
  local f c
  c="$(contrat)"
  # chaque forme de lecture est vue : littérale, par la boucle des ports, par la liste des outils
  local attendu
  for attendu in substrat port_ssh jq sudo docker_host racine revision; do
    grep -qx "$attendu" <<<"$c" || { echo "dérivation aveugle : $attendu absent du contrat" >&2; return 1; }
  done
  for f in $c; do
    if [[ " $1 " == *" $f "* ]]; then grep -qE "^$f=" "$FACTS" || { echo "fait absent : $f" >&2; return 1; }
    else grep -qE "^$f=.+" "$FACTS" || { echo "fait absent ou vide : $f" >&2; return 1; }
    fi
  done
}

@test "les faits que l'installeur lit sont tous posés, avec une valeur, docker absent" {
  preflight docker
  faits_poses "docker_bin docker_host docker_server docker_flavor compose_why forge_fournie projet_pris apt_installs"
}

@test "les faits que l'installeur lit sont tous posés, avec une valeur, docker présent" {
  docker_qui_repond
  preflight docker DOCKER_HOST=unix:///dev/null
  faits_poses "docker_why compose_why forge_fournie projet_pris apt_installs"
}

@test "un fait par nom, jamais deux valeurs" {
  preflight docker
  local n; n="$(cut -d= -f1 "$FACTS" | sort | uniq -d | head -1)"
  [ -z "$n" ] || { echo "fait posé deux fois : $n" >&2; return 1; }
}

@test "sous apply, sans fichier de faits, les faits qui ne servent qu'à l'installeur ne se calculent pas" {
  # l'historique apt (un date par entrée) et le paquet du dockerd ne servent qu'aux faits
  docker_qui_repond
  sed -i 's/29.0.0|Docker Engine - Test/29.1.3|/' "$BIN/docker"
  double dockerd ''
  double dpkg-query "echo dpkg-query >> '$BATS_TEST_TMPDIR/calculs'; exit 1"
  double date "echo date >> '$BATS_TEST_TMPDIR/calculs'; exec /bin/date \"\$@\""
  printf 'Start-Date: 2026-09-11  22:37:57\nInstall: openssh-server:amd64 (1:10.2p1)\n' > "$APT_HISTORY"
  naissance_est 1
  run env PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight PROVISION_RUN=1 PROV_SUBSTRATE=wsl \
      PROV_DOCKER_BIN="$BIN/docker" DOCKER_HOST=unix:///dev/null \
      PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$MOD" apply
  [ "$status" -ne 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/calculs" ] || { echo "calculé pour rien : $(sort -u "$BATS_TEST_TMPDIR/calculs" | paste -sd' ')"; return 1; }
  # le même décor, avec un fichier de faits : les deux calculs ont lieu, l'instrument voit ce qu'il cherche
  preflight wsl DOCKER_HOST=unix:///dev/null
  grep -qx date "$BATS_TEST_TMPDIR/calculs"
  grep -qx dpkg-query "$BATS_TEST_TMPDIR/calculs"
}

# bats test_tags=structure
@test "aucun fait n'est posé après le dernier rapport : pas de bloc récapitulatif" {
  local dernier_rapport dernier_fait
  dernier_rapport="$(grep -nE '^\s*(p_ok|p_warn|p_fail|p_drift) ' "$MOD" | tail -1 | cut -d: -f1)"
  dernier_fait="$(grep -nE '^\s*p_fact ' "$MOD" | tail -1 | cut -d: -f1)"
  [ "$dernier_fait" -lt "$dernier_rapport" ]
}


@test "le système est décrit : distribution, noyau, cœurs, systemd, utilisateur et groupes" {
  mkdir -p "$LCARS_DECOR_ROOT/run/systemd/system"
  preflight docker
  [ -n "$(fact distro)" ]
  [ -n "$(fact noyau)" ]
  [ "$(fact cpu)" -ge 1 ]
  [ "$(fact systemd)" = oui ]
  [ "$(fact utilisateur)" = "$(id -un)" ]
  [[ "$(fact groupes)" == *"$(id -gn)"* ]]
}

@test "forge : avec --bench, un FORGE_BASE_URL résiduel est ignoré et dit — le fait forge_fournie reste vide" {
  preflight docker PROV_FORGE_MONTEE=1 FORGE_BASE_URL=http://ancienne-forge:9999
  [ -z "$(fact forge_fournie)" ]
  [ "$(fact forge_joignable)" = sans-objet ]
  [[ "$output" == *"WARN  00-preflight: FORGE_BASE_URL (http://ancienne-forge:9999) est ignorée"* ]]
}

@test "systemd : le fait suit le répertoire de systemd du décor — absent, « non »" {
  preflight docker
  [ "$(fact systemd)" = non ]
}

@test "l'utilisateur est celui qui a lancé sudo, pas root" {
  preflight docker SUDO_USER=alice
  [ "$(fact utilisateur)" = "alice" ]
}


@test "linux sans LCARS_ALLOW_ANY_HOST : le fait dit none et le verdict est un échec" {
  preflight linux
  [ "$status" -eq 2 ]
  [ "$(fact consent)" = "none" ]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST=1"* ]]
}

@test "linux sans déclaration : à l'apply le refus rend 1, le code d'un échec d'apply" {
  run env PROV_FACTS_FILE="$FACTS" PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight \
      PROV_SUBSTRATE=linux PROV_DOCKER_BIN="$BIN/docker" \
      PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$MOD" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"Linux natif sans déclaration"* ]]
}

@test "linux avec LCARS_ALLOW_ANY_HOST : le fait dit env, rien ne bloque" {
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$status" -ne 2 ]
  [ "$(fact consent)" = "env" ]
}

@test "hors linux la garde est sans objet" {
  preflight wsl
  [ "$(fact consent)" = "sans-objet" ]
  preflight docker
  [ "$(fact consent)" = "sans-objet" ]
}


@test "docker est mesuré sur tout substrat, avec sa raison quand il manque" {
  local s
  for s in wsl linux docker; do
    rm -f "$FACTS"
    preflight "$s" LCARS_ALLOW_ANY_HOST=1
    [ "$(fact docker)" = "absent" ] || { echo "substrat $s : docker=$(fact docker)" >&2; return 1; }
    [ -n "$(fact docker_why)" ]
  done
}

@test "docker absent est un échec sous wsl seulement" {
  preflight wsl
  [ "$status" -eq 2 ]
  rm -f "$FACTS"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$status" -ne 2 ]
}

@test "docker présent : version du serveur, variante et endpoint sont des faits" {
  docker_qui_repond
  preflight docker DOCKER_HOST=unix:///dev/null
  [ "$(fact docker)" = "oui" ]
  [ "$(fact docker_server)" = "29.0.0" ]
  [ "$(fact docker_flavor)" = "Docker Engine - Test" ]
  [ "$(fact docker_host)" = "unix:///dev/null" ]
  [ "$(fact compose)" = "oui" ]
}

@test "docker sans nom de plateforme : la variante est le paquet propriétaire du dockerd local" {
  docker_qui_repond
  sed -i 's/29.0.0|Docker Engine - Test/29.1.3|/' "$BIN/docker"
  printf '#!/usr/bin/env bash\n' > "$BIN/dockerd"; chmod 0755 "$BIN/dockerd"
  printf '#!/usr/bin/env bash\n[[ "$1" == -S && "$2" == "%s" ]] || exit 1\necho "docker.io: $2"\n' "$BIN/dockerd" > "$BIN/dpkg-query"; chmod 0755 "$BIN/dpkg-query"
  preflight docker DOCKER_HOST=unix:///dev/null
  [ "$(fact docker_server)" = "29.1.3" ]
  [ "$(fact docker_flavor)" = "docker.io" ]
}

@test "docker sans nom de plateforme, dockerd hors paquet : la variante reste vide et le préflight rend son verdict" {
  docker_qui_repond
  sed -i 's/29.0.0|Docker Engine - Test/29.1.3|/' "$BIN/docker"
  printf '#!/usr/bin/env bash\n' > "$BIN/dockerd"; chmod 0755 "$BIN/dockerd"
  printf '#!/usr/bin/env bash\necho "dpkg-query: no path found" >&2; exit 1\n' > "$BIN/dpkg-query"; chmod 0755 "$BIN/dpkg-query"
  preflight docker DOCKER_HOST=unix:///dev/null
  [ "$status" -ne 3 ]
  [ "$(fact docker)" = "oui" ]
  [ -z "$(fact docker_flavor)" ]
  [ -n "$(fact sudo)" ]
}

@test "docker sans nom de plateforme ni dockerd local : la variante reste vide" {
  docker_qui_repond
  sed -i 's/29.0.0|Docker Engine - Test/29.1.3|/' "$BIN/docker"
  preflight docker DOCKER_HOST=unix:///dev/null PATH="$BIN:$(path_sans dockerd)"
  [ "$(fact docker)" = "oui" ]
  [ -z "$(fact docker_flavor)" ]
}

@test "mv --exchange refusé : échec dit, rien ne reste de la sonde" {
  double mv '[[ "$*" != *--exchange* ]] || { echo "mv: unrecognized option" >&2; exit 1; }
exec /bin/mv "$@"'
  preflight docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  00-preflight: « mv --exchange » refusé sous $LCARS_DECOR_ROOT/opt/lcars"* ]]
  [ -z "$(ls -Ad "$LCARS_DECOR_ROOT"/opt/lcars/.prov-echange.* 2>/dev/null)" ]
}

@test "mv --exchange se sonde sur le système de fichiers des bascules, sous PROV_ROOT — pas dans TMPDIR" {
  double mv "echo \"\$*\" >> '$BATS_TEST_TMPDIR/mv.args'; exec /bin/mv \"\$@\""
  preflight docker
  [[ "$output" == *"OK    00-preflight: « mv --exchange » joué sous $LCARS_DECOR_ROOT/opt/lcars"* ]]
  grep -q -- "--exchange -T -- $LCARS_DECOR_ROOT/opt/lcars/.prov-echange\." "$BATS_TEST_TMPDIR/mv.args"
}

@test "mv --exchange sous une racine que ce compte ne peut pas écrire : non mesuré, et dit" {
  chmod 0555 "$LCARS_DECOR_ROOT/opt/lcars"
  preflight docker
  chmod 0755 "$LCARS_DECOR_ROOT/opt/lcars"
  [[ "$output" == *"WARN  00-preflight: « mv --exchange » non sondé : $LCARS_DECOR_ROOT/opt/lcars n'est pas inscriptible"* ]]
}

@test "WSL1 : un noyau WSL sans WSL2 est une dérive qui nomme le geste ; un noyau WSL2 n'en dit rien" {
  printf 'Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com) (gcc version 5.4.0 (GCC) )\n' > "$LCARS_DECOR_ROOT/proc/version"
  preflight wsl
  [ "$status" -ne 3 ]
  [[ "$output" == *"DRIFT 00-preflight: WSL1 ("*"bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"* ]]
  printf 'Linux version 6.6.114.1-microsoft-standard-WSL2 (root@machine) (gcc) #1 SMP\n' > "$LCARS_DECOR_ROOT/proc/version"
  preflight wsl
  [[ "$output" != *"WSL1"* ]]
  preflight docker
  [[ "$output" != *"WSL1"* ]]
}

@test "disque : mesuré sur l'ancêtre existant de PROV_ROOT, jamais sur / par défaut" {
  rm -rf "$LCARS_DECOR_ROOT/opt/lcars"
  df_rend 9000
  preflight docker
  [ "$(fact disque_mb)" = 9000 ]
  grep -qx -- "-Pm $LCARS_DECOR_ROOT/opt" "$BATS_TEST_TMPDIR/df.args"
}

@test "disque : sous 2048 Mo une dérive, sous 5120 Mo un seul avertissement, au-delà conforme" {
  df_rend 1000
  preflight docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 00-preflight: disque 1000 Mo libres sur $LCARS_DECOR_ROOT/opt/lcars < 2048 Mo"* ]]
  df_rend 4000
  preflight docker
  [ "$(lignes 'disque 4000 Mo')" -eq 1 ]
  [[ "$output" == *"WARN  00-preflight: disque 4000 Mo libres"* ]]
  df_rend 9000
  preflight docker
  [[ "$output" == *"OK    00-preflight: disque 9000 Mo libres"* ]]
}

@test "RAM : lue dans meminfo, sous 1536 Mo une dérive, sous 3072 Mo un seul avertissement" {
  printf 'MemTotal:       1048576 kB\n' > "$LCARS_DECOR_ROOT/proc/meminfo"
  preflight docker
  [ "$status" -eq 1 ]
  [ "$(fact ram_mb)" = 1024 ]
  [[ "$output" == *"DRIFT 00-preflight: RAM 1024 Mo < 1536 Mo"* ]]
  printf 'MemTotal:       2097152 kB\n' > "$LCARS_DECOR_ROOT/proc/meminfo"
  preflight docker
  [ "$(lignes 'RAM 2048 Mo')" -eq 1 ]
  [[ "$output" == *"WARN  00-preflight: RAM 2048 Mo < 3072 Mo"* ]]
}

@test "arch : une architecture hors cible est une dérive, et le fait la nomme" {
  double uname "[[ \"\$1\" != -m ]] || { echo riscv64; exit 0; }
exec $(command -v uname) \"\$@\""
  preflight docker
  [ "$status" -eq 1 ]
  [ "$(fact arch)" = riscv64 ]
  [[ "$output" == *"DRIFT 00-preflight: arch non supportée : riscv64"* ]]
}

@test "OS : sans dpkg, hors famille Debian est une dérive" {
  preflight docker PATH="$BIN:$(path_sans dpkg)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 00-preflight: OS hors famille Debian"* ]]
}


@test "forge fournie : l'URL est un fait, sa joignabilité un autre" {
  preflight docker FORGE_BASE_URL="http://127.0.0.1:1/forge-absente"
  [ "$(fact forge_fournie)" = "http://127.0.0.1:1/forge-absente" ]
  [ "$(fact forge_joignable)" = "non" ]
}

@test "forge absente : le fait est vide, la joignabilité sans objet" {
  preflight docker
  [ -z "$(fact forge_fournie)" ]
  [ "$(fact forge_joignable)" = "sans-objet" ]
}


@test "un port libre est dit libre, avec son numéro" {
  local p; p="$(free_port)"
  preflight docker PROV_DECK_PORT="$p"
  [ "$(fact port_deck)" = "$p libre" ]
}

@test "un port publié par un conteneur d'un autre projet est dit pris, par qui" {
  docker_qui_repond autre-forge-gitea-1 autre-forge
  preflight docker DOCKER_HOST=unix:///dev/null PROV_FORGE_HOST_PORT=21000
  [ "$(fact port_forge)" = "21000 pris par autre-forge-gitea-1 (projet autre-forge)" ]
  [[ "$output" == *"port 21000 (forge) pris par autre-forge-gitea-1"* ]]
}

@test "un port publié par nos propres projets est dit nous, jamais pris" {
  docker_qui_repond lcars-forge-gitea-1 lcars-forge
  local p; p="$(free_port)"
  listen_on "$p"
  preflight docker DOCKER_HOST=unix:///dev/null PROV_FORGE_HOST_PORT="$p" PROV_FORGE_BASE=lcars
  kill "$LISTENER" 2>/dev/null || true
  [ "$(fact port_forge)" = "$p nous lcars-forge-gitea-1 (projet lcars-forge)" ]
  [[ "$output" != *"port $p"*"pris"* ]]
}

@test "un port écouté que ni docker ni ss ne savent nommer est dit pris, docker présent ou non" {
  local p; p="$(free_port)"
  ss_muet "$p"
  listen_on "$p"
  preflight docker PROV_DECK_PORT="$p"
  [ "$(fact port_deck)" = "$p pris" ]
  docker_qui_repond
  preflight docker DOCKER_HOST=unix:///dev/null PROV_DECK_PORT="$p"
  kill "$LISTENER" 2>/dev/null || true
  [ "$(fact port_deck)" = "$p pris" ]
}

landing_ici() { # landing_ici <cgroup rendu par systemd, vide si arrêtée> <cgroup de la socket> <port> — ss ne nomme pas le processus, il nomme le cgroup
  double systemctl "[[ \"\$*\" == 'show -p ControlGroup --value lcars-landing.service' ]] && echo '$1'"
  double ss "[[ \"\$*\" == *--cgroup* ]] && c=' cgroup:$2'
echo \"LISTEN 0 4096 127.0.0.1:$3 0.0.0.0:*\${c:-}\""
}

@test "le port du deck tenu par la landing en marche ici est dit nous, services.env illisible compris ; arrêtée ici, la même socket est prise" {
  local p; p="$(free_port)"
  listen_on "$p"
  printf 'LCARS_LANDING_PORT=%s\n' "$p" > "$LCARS_DECOR_ROOT/etc/lcars/services.env"
  chmod 0000 "$LCARS_DECOR_ROOT/etc/lcars/services.env"
  landing_ici /system.slice/lcars-landing.service /system.slice/lcars-landing.service "$p"
  preflight wsl PROV_DECK_PORT="$p"
  [ "$(fact port_deck)" = "$p nous lcars-landing (service)" ]
  [[ "$output" != *"port $p"*"pris"* ]]
  # sous WSL la hiérarchie des cgroups est partagée : la landing d'une autre distribution porte le même nom
  landing_ici "" /system.slice/lcars-landing.service "$p"
  preflight wsl PROV_DECK_PORT="$p"
  kill "$LISTENER" 2>/dev/null || true
  [ "$(fact port_deck)" = "$p pris" ]
}

@test "l'utilisateur des faits est l'humain que --human nomme" {
  preflight docker SUDO_USER=alice PROV_HUMAN=zoe
  [ "$(fact utilisateur)" = zoe ]
}

@test "les trois ports suivent leurs variables, ssh compris" {
  preflight docker PROV_FORGE_HOST_PORT=30001 PROV_DECK_PORT=30002 PROV_SSH_PORT=30003
  [[ "$(fact port_forge)" == 30001* ]]
  [[ "$(fact port_deck)" == 30002* ]]
  [[ "$(fact port_ssh)" == 30003* ]]
}

@test "un projet compose déjà présent sur le daemon est nommé" {
  docker_qui_repond "" "" lcars-fleet
  preflight docker DOCKER_HOST=unix:///dev/null PROV_FORGE_BASE=lcars
  [ "$(fact projet)" = "lcars" ]
  [ "$(fact projet_pris)" = "lcars-fleet" ]
  [[ "$output" == *"projet compose déjà présent"*"lcars-fleet"* ]]
}

@test "la forge et le runner que ce poste a montés sont présents sans avertissement ; une instance du même nom en garde un" {
  local mode; mode="$LCARS_DECOR_ROOT$(sed -n 's/^PROV_FORGE_MODE_FILE=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env")"
  docker_qui_repond "" "" lcars-forge
  preflight wsl DOCKER_HOST=unix:///dev/null PROV_FORGE_BASE=lcars
  [ "$(fact projet_pris)" = "lcars-forge" ]
  [[ "$output" == *"WARN"*"projet compose déjà présent sur ce daemon : lcars-forge"* ]]
  mkdir -p "$(dirname "$mode")"; echo poste > "$mode"
  preflight wsl DOCKER_HOST=unix:///dev/null PROV_FORGE_BASE=lcars
  [ "$(fact projet_pris)" = "lcars-forge" ]
  [[ "$output" == *"OK"*"projet compose de la forge de ce poste présent : lcars-forge"* ]]
  refute_out 'projet compose déjà présent' <<<"$output"
  docker_qui_repond "" "" lcars-fleet
  preflight wsl DOCKER_HOST=unix:///dev/null PROV_FORGE_BASE=lcars
  [[ "$output" == *"WARN"*"projet compose déjà présent sur ce daemon : lcars-fleet"* ]]
}

@test "sans docker, aucun projet n'est dit pris" {
  preflight docker PROV_FORGE_BASE=lcars
  [ -z "$(fact projet_pris)" ]
}


@test "les paquets installés après la naissance de l'instance sont listés, sans les mises à jour ni les dépendances" {
  cat > "$APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0), libfoo:amd64 (1.0, automatic)
End-Date: 2026-04-20  18:07:00

Start-Date: 2026-09-11  22:37:16
Commandline: apt -y upgrade
Upgrade: libperl5.40:amd64 (5.40.1-7build1, 5.40.1-7ubuntu0.3)
End-Date: 2026-09-11  22:37:40

Start-Date: 2026-09-11  22:37:57
Commandline: apt install -y openssh-server
Install: libwrap0:amd64 (7.6, automatic), openssh-server:amd64 (1:10.2p1), openssh-sftp-server:amd64 (1:10.2p1, automatic)
End-Date: 2026-09-11  22:38:10
EOF
  naissance_est "$(date -d '2026-09-11 22:36:29' +%s)"
  preflight wsl
  [ "$(fact apt_installs)" = "openssh-server (2026-09-11)" ]
}

@test "une instance sans installation après sa naissance rend un fait vide" {
  cat > "$APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0)
End-Date: 2026-04-20  18:07:00
EOF
  naissance_est "$(date +%s)"
  preflight wsl
  [ -z "$(fact apt_installs)" ]
}

@test "une naissance d'instance que le système ne sait pas donner rend inconnu, jamais l'image entière" {
  cat > "$APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0)
End-Date: 2026-04-20  18:07:00
EOF
  naissance_est 0
  preflight wsl
  [ "$(fact apt_installs)" = "inconnu" ]
  naissance_est "?"
  preflight wsl
  [ "$(fact apt_installs)" = "inconnu" ]
}

@test "en conteneur, l'historique apt est sans objet" {
  preflight docker
  [ "$(fact apt_installs)" = "sans-objet" ]
}

@test "les comptes humains sont ceux que login.defs borne, UID_MAX compris" {
  # une frontière déplacée par l'administrateur déplace le fait : 1000 et 60000 ne sont pas des constantes
  printf 'UID_MIN\t2000\nUID_MAX\t3000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  printf 'root:x:0:0::/root:/bin/bash\nbob:x:1000:1000::/home/bob:/bin/bash\ncarol:x:2000:2000::/home/carol:/bin/bash\ndave:x:3000:3000::/home/dave:/bin/bash\neve:x:3001:3001::/home/eve:/bin/bash\nnobody:x:65534:65534::/:/usr/sbin/nologin\n' > "$LCARS_DECOR_ROOT/etc/passwd"
  preflight wsl
  [ "$(fact comptes_humains)" = "carol,dave" ]
}

@test "login.defs illisible : le fait des comptes humains reste vide, jamais deviné" {
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  preflight wsl
  grep -qx 'comptes_humains=' "$FACTS"
}


@test "sudo : présent sur le PATH, le fait dit « oui » (« root » sous root)" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sudo"; chmod 0755 "$BIN/sudo"
  local attendu=oui; [[ "$EUID" -ne 0 ]] || attendu=root
  preflight docker
  [ "$(fact sudo)" = "$attendu" ]
}

@test "sudo : absent du PATH, le fait dit « absent » (« root » sous root)" {
  local sans; sans="$(path_sans sudo)"
  local attendu=absent; [[ "$EUID" -ne 0 ]] || attendu=root
  preflight docker PATH="$BIN:$sans"
  [ "$(fact sudo)" = "$attendu" ]
}

@test "le canal dit qui a posé, ou aucun ; l'arbre dit ce qu'il poserait" {
  local v
  for v in source kit; do
    printf '%s\n' "$v" > "$CHANNEL"
    preflight linux LCARS_ALLOW_ANY_HOST=1
    [ "$(fact channel)" = "$v" ]
  done
  rm -f "$CHANNEL"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$(fact channel)" = "aucun" ]
  [ "$(fact channel_tree)" = "source" ]
}

@test "un canal illisible est un échec qui compte, et le fait dit invalide" {
  printf 'snap\n' > "$CHANNEL"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$status" -eq 2 ]
  [ "$(fact channel)" = "invalide" ]
}

@test "jq présent : le fait dit oui" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/jq"; chmod 0755 "$BIN/jq"
  preflight docker
  [ "$(fact jq)" = oui ]
}

@test "un outil d'amorçage absent est un fait, jamais une dérive — l'installeur décide, 10-packages le pose" {
  local t
  for t in curl git jq; do
    preflight docker PATH="$BIN:$(path_sans "$t")"
    [ "$(fact "$t")" = absent ] || { echo "$t : fait $(fact "$t")"; return 1; }
    [ "$status" -eq 0 ] || { echo "$t absent : status $status"; echo "$output"; return 1; }
    printf '%s\n' "$output" | refute_out "$t (absent|présent)"
  done
}
