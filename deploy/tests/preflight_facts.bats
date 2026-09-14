#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/preflight_facts.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-31
# STATUS: témoins de 00-preflight — les faits que l'installeur lit, et les verdicts qui ne bougent pas

load refute
load support/decor

setup() {
  # le décor possède l'environnement : toute la famille est effacée, pas les noms connus
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  unset SUDO_USER

  MOD="$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
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
}

teardown() { [[ -z "${LISTENER:-}" ]] || kill "$LISTENER" 2>/dev/null || true; }

preflight() { # preflight <substrat> [VAR=val…]
  local sub="$1"; shift
  run env PROV_FACTS_FILE="$FACTS" PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight \
      PROV_SUBSTRATE="$sub" PROV_DOCKER_BIN="$BIN/docker" \
      PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$@" bash "$MOD" check
}

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


CONTRAT="os distro distro_version noyau cpu systemd bash arch ram_mb disque_mb utilisateur groupes
substrat consent wsl2 userns_knob docker docker_bin docker_host docker_server docker_flavor docker_why
compose compose_why forge_fournie forge_joignable port_forge port_deck port_ssh projet projet_pris
apt_installs comptes_humains sudo curl git jq channel channel_tree"

faits_poses() { # faits_poses <faits admis vides> — chaque fait du contrat est posé ; vide seulement s'il est admis vide
  local f
  for f in $CONTRAT; do
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

@test "sans PROV_FACTS_FILE le module ne change rien" {
  run env PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight PROV_SUBSTRATE=docker \
      PROV_DOCKER_BIN="$BIN/docker" bash "$MOD" check
  [ ! -e "$FACTS" ]
}

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

@test "mv --exchange refusé : échec dit, une bascule de dossier n'aurait pas de forme atomique" {
  printf '#!/usr/bin/env bash\n[[ "$*" != *--exchange* ]] || { echo "mv: unrecognized option" >&2; exit 1; }\nexec /bin/mv "$@"\n' > "$BIN/mv"; chmod 0755 "$BIN/mv"
  preflight docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  00-preflight: « mv --exchange » refusé"* ]]
  [ -z "$(ls -d "${TMPDIR:-/tmp}"/prov-echange.* 2>/dev/null)" ]
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

@test "le port du deck tenu par notre service landing est dit nous" {
  local p; p="$(free_port)"
  ss_muet "$p"
  listen_on "$p"
  printf 'LCARS_LANDING_PORT=%s\n' "$p" > "$LCARS_DECOR_ROOT/etc/lcars/services.env"
  preflight wsl PROV_DECK_PORT="$p"
  kill "$LISTENER" 2>/dev/null || true
  [ "$(fact port_deck)" = "$p nous lcars-landing (service)" ]
  [[ "$output" != *"port $p"*"pris"* ]]
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
  preflight wsl LCARS_INSTANCE_BIRTH="$(date -d '2026-09-11 22:36:29' +%s)"
  [ "$(fact apt_installs)" = "openssh-server (2026-09-11)" ]
}

@test "une instance sans installation après sa naissance rend un fait vide" {
  cat > "$APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0)
End-Date: 2026-04-20  18:07:00
EOF
  preflight wsl LCARS_INSTANCE_BIRTH="$(date +%s)"
  [ -z "$(fact apt_installs)" ]
}

@test "une naissance d'instance que le système ne sait pas donner rend inconnu, jamais l'image entière" {
  cat > "$APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0)
End-Date: 2026-04-20  18:07:00
EOF
  preflight wsl LCARS_INSTANCE_BIRTH=0
  [ "$(fact apt_installs)" = "inconnu" ]
  preflight wsl LCARS_INSTANCE_BIRTH="?"
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

@test "un produit posé sans tampon rend inconnu" {
  mkdir -p "$LCARS_DECOR_ROOT/opt/lcars/runtime"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$(fact channel)" = "inconnu" ]
}

@test "jq présent : le fait dit oui" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/jq"; chmod 0755 "$BIN/jq"
  preflight docker
  [ "$(fact jq)" = oui ]
}

@test "jq absent : le fait le dit, en avertissement et sans dérive" {
  # ce système le pose lui-même (10-packages) : seul le conteneur l'exige, et install.sh en décide
  preflight docker PATH="$BIN:$(path_sans jq)"
  [ "$(fact jq)" = absent ]
  [[ "$output" == *"WARN  00-preflight: jq absent"* ]]
  printf '%s\n' "$output" | refute_out 'DRIFT.*jq'
}
