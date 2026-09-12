#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/preflight_facts.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-31
# STATUS: témoins de 00-preflight — les faits que l'installeur lit, et les verdicts qui ne bougent pas

load refute

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

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod 0755 "$BIN/docker"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export LCARS_APT_HISTORY="$BATS_TEST_TMPDIR/apt-history.log"
  export LCARS_PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0::/root:/bin/bash\nbob:x:1000:1000::/home/bob:/bin/bash\n' > "$LCARS_PASSWD_FILE"
}

teardown() { [[ -z "${LISTENER:-}" ]] || kill "$LISTENER" 2>/dev/null || true; }

preflight() { # preflight <substrat> [VAR=val…]
  local sub="$1"; shift
  run env PROV_FACTS_FILE="$FACTS" PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight \
      PROV_SUBSTRATE="$sub" PROV_DOCKER_BIN="$BIN/docker" \
      LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/absent.sock" \
      PATH="$BIN:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$@" bash "$MOD" check
}

fact() { sed -n "s/^$1=//p" "$FACTS" 2>/dev/null | tail -1; }

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
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do timeout 1 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

# ─── le contrat ─────────────────────────────────────────────────────────────────────────────────

CONTRAT="os distro distro_version noyau cpu systemd bash arch ram_mb disque_mb utilisateur groupes
substrat consent wsl2 userns_knob docker docker_bin docker_host docker_server docker_flavor docker_why
compose compose_why forge_fournie forge_joignable port_forge port_deck port_ssh projet projet_pris
apt_installs comptes_humains sudo curl git channel channel_tree"

@test "les faits que l'installeur lit sont tous posés, docker absent" {
  preflight docker
  local f
  for f in $CONTRAT; do grep -qE "^$f=" "$FACTS" || { echo "fait absent : $f" >&2; return 1; }; done
}

@test "les faits que l'installeur lit sont tous posés, docker présent" {
  docker_qui_repond
  preflight docker DOCKER_HOST=unix:///dev/null
  local f
  for f in $CONTRAT; do grep -qE "^$f=" "$FACTS" || { echo "fait absent : $f" >&2; return 1; }; done
}

@test "un fait par nom, jamais deux valeurs" {
  preflight docker
  local n; n="$(cut -d= -f1 "$FACTS" | sort | uniq -d | head -1)"
  [ -z "$n" ] || { echo "fait posé deux fois : $n" >&2; return 1; }
}

@test "sans PROV_FACTS_FILE le module ne change rien" {
  run env PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight PROV_SUBSTRATE=docker \
      PROV_DOCKER_BIN="$BIN/docker" LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/absent.sock" \
      bash "$MOD" check
  [ ! -e "$FACTS" ]
}

@test "aucun fait n'est posé après le dernier rapport : pas de bloc récapitulatif" {
  local dernier_rapport dernier_fait
  dernier_rapport="$(grep -nE '^\s*(p_ok|p_warn|p_fail|p_drift) ' "$MOD" | tail -1 | cut -d: -f1)"
  dernier_fait="$(grep -nE '^\s*p_fact ' "$MOD" | tail -1 | cut -d: -f1)"
  [ "$dernier_fait" -lt "$dernier_rapport" ]
}

# ─── le système ─────────────────────────────────────────────────────────────────────────────────

@test "le système est décrit : distribution, noyau, cœurs, systemd, utilisateur et groupes" {
  preflight docker
  [ -n "$(fact distro)" ]
  [ -n "$(fact noyau)" ]
  [ "$(fact cpu)" -ge 1 ]
  case "$(fact systemd)" in oui|non) ;; *) return 1 ;; esac
  [ "$(fact utilisateur)" = "$(id -un)" ]
  [[ "$(fact groupes)" == *"$(id -gn)"* ]]
}

@test "l'utilisateur est celui qui a lancé sudo, pas root" {
  preflight docker SUDO_USER=alice
  [ "$(fact utilisateur)" = "alice" ]
}

# ─── le substrat et la garde ────────────────────────────────────────────────────────────────────

@test "linux sans LCARS_ALLOW_ANY_HOST : le fait dit none et le verdict est un échec" {
  preflight linux
  [ "$status" -eq 2 ]
  [ "$(fact consent)" = "none" ]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST=1"* ]]
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

# ─── docker ─────────────────────────────────────────────────────────────────────────────────────

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

# ─── la forge ───────────────────────────────────────────────────────────────────────────────────

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

# ─── les ports et le projet ─────────────────────────────────────────────────────────────────────

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

# ─── l'instance ─────────────────────────────────────────────────────────────────────────────────

@test "les paquets installés après la naissance de l'instance sont listés, sans les mises à jour ni les dépendances" {
  cat > "$LCARS_APT_HISTORY" <<'EOF'

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
  cat > "$LCARS_APT_HISTORY" <<'EOF'

Start-Date: 2026-04-20  18:06:23
Commandline: apt-get install ubuntu-wsl
Install: ubuntu-wsl:amd64 (1.0)
End-Date: 2026-04-20  18:07:00
EOF
  preflight wsl LCARS_INSTANCE_BIRTH="$(date +%s)"
  [ -z "$(fact apt_installs)" ]
}

@test "une naissance d'instance que le système ne sait pas donner rend inconnu, jamais l'image entière" {
  cat > "$LCARS_APT_HISTORY" <<'EOF'

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

@test "les comptes humains sont ceux au-dessus de l'uid 1000, nobody exclu" {
  printf 'root:x:0:0::/root:/bin/bash\nbob:x:1000:1000::/home/bob:/bin/bash\nalice:x:1001:1001::/home/alice:/bin/bash\nnobody:x:65534:65534::/:/usr/sbin/nologin\n' > "$LCARS_PASSWD_FILE"
  preflight wsl
  [ "$(fact comptes_humains)" = "bob,alice" ]
}

# ─── sudo et le canal ───────────────────────────────────────────────────────────────────────────

@test "sudo : root, présent ou absent" {
  preflight docker
  case "$(fact sudo)" in root|oui|absent) ;; *) return 1 ;; esac
}

@test "le canal dit qui a posé, ou aucun ; l'arbre dit ce qu'il poserait" {
  local v
  for v in source kit; do
    mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"; printf '%s\n' "$v" > "$LCARS_CHANNEL_FILE"
    preflight linux LCARS_ALLOW_ANY_HOST=1
    [ "$(fact channel)" = "$v" ]
  done
  rm -f "$LCARS_CHANNEL_FILE"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$(fact channel)" = "aucun" ]
  [ "$(fact channel_tree)" = "source" ]
}

@test "un canal illisible est un échec qui compte, et le fait dit invalide" {
  mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"; printf 'snap\n' > "$LCARS_CHANNEL_FILE"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$status" -eq 2 ]
  [ "$(fact channel)" = "invalide" ]
}

@test "un produit posé sans tampon rend inconnu" {
  mkdir -p "$BATS_TEST_TMPDIR/opt/lcars/runtime"
  preflight linux LCARS_ALLOW_ANY_HOST=1 PROV_ROOT="$BATS_TEST_TMPDIR/opt/lcars" PROV_PREFIX="$BATS_TEST_TMPDIR/opt/lcars/runtime"
  [ "$(fact channel)" = "inconnu" ]
}
