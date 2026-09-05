#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/docker-endpoint.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the escalation shim — ce qui traverse sudo, et ce qui ne doit JAMAIS traverser
#
# POURQUOI CE FICHIER. Sur WSL la socket docker appartient a root : le rail escalade pour LA JOINDRE,
# sans rien modifier. L'escalade prend la forme d'un shim, et ce shim a deux devoirs opposes :
#
#   - FAIRE TRAVERSER ce qui pilote compose. `sudo` remet l'environnement a zero, et le rail conduit
#     compose PAR DES VARIABLES (`LCARS_DEVFORGE_PORT`, `LCARS_IMAGE`, `FORGE_BASE_URL`…). Mesure sur
#     instance vierge : sans ce relais, une forge demandee sur le port 21199 monte sur 3300 — le
#     defaut du compose — et le banc meurt sur « la forge ne repond pas », en accusant la forge ;
#   - NE JAMAIS FAIRE TRAVERSER UN SECRET. Une assignation `sudo VAR=valeur` vit dans la LIGNE DE
#     COMMANDE, exposee par `/proc/<pid>/cmdline` a tout l'hote pendant l'appel (cicatrice 6-141,
#     payee deux fois). Les credentials de ce rail voyagent par STDIN, jamais par l'environnement.
#
# ⚠ CE QUI EST MESURE ICI EST STRUCTUREL, ET C'EST ASSUME. Faire tourner le shim exigerait une socket
# appartenant a root ET un sudo non interactif — donc un test qui ne passerait que sur certaines
# machines, c'est-a-dire un test qui mesure la machine. On epingle donc la FORME du shim genere : le
# filtre existe, il refuse la bonne classe de noms, et les deux listes ne sont pas inversees.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh"
  [ -f "$LIB" ]
}

# ─── docker_compose_cmd — UNE SEULE REPONSE A « QUEL COMPOSE » ──────────────────────────────────
#
# ⚠ ELLE A VECU EN DEUX EXEMPLAIRES — une resolution dans la porte, un DEFAUT dans le delegue. Deux
# detections pour un fait donnent deux verdicts possibles selon la porte empruntee — et celui qu'on
# ne lit pas est celui qui decide le jour ou ca casse. Elle vit ici, a cote de la sonde d'endpoint,
# en un exemplaire ; chaque porte la joue puis TRANSMET son resultat.

compose_lib() { # compose_lib <script> — joue la fonction dans un shell decore
  run bash -c ". '$LIB' >/dev/null 2>&1; $1"
}

@test "compose: le plugin est prefere, et il porte le binaire qu'on lui donne" {
  local bin="$BATS_TEST_TMPDIR/mydocker"
  printf '#!/usr/bin/env bash\n[[ "$1" == compose ]] && exit 0\nexit 1\n' > "$bin"; chmod +x "$bin"
  compose_lib "docker_compose_cmd '$bin' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[$bin compose]"* ]]
}

@test "compose: sans plugin, l'autonome prend le relais" {
  local bin="$BATS_TEST_TMPDIR/nodocker"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin"; chmod +x "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/docker-compose"
  chmod +x "$BATS_TEST_TMPDIR/docker-compose"
  compose_lib "PATH='$BATS_TEST_TMPDIR:\$PATH'; docker_compose_cmd '$bin' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[docker-compose]"* ]]
}

@test "compose: aucune des deux formes -> REFUS nomme, jamais une commande vide" {
  # ⚠ Un `PROV_COMPOSE_CMD` vide rendu avec un code 0 ferait lancer `"" -f … up` : le rail
  # echouerait sur « command not found » en accusant le compose, pas l'absence.
  local bin="$BATS_TEST_TMPDIR/nodocker2"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin"; chmod +x "$bin"
  compose_lib "PATH='$BATS_TEST_TMPDIR/vide'; docker_compose_cmd '$bin' && echo OUI || echo \"NON [\$PROV_COMPOSE_WHY]\""
  [[ "$output" == *"NON ["* ]]
  [[ "$output" == *"compose est absent"* ]]
}

@test "compose: qui SONDE nomme sa reponse a qui CONSOMME — jamais un second defaut" {
  # ⚠ CE TEMOIN A EPINGLE UN FICHIER, ET LE FICHIER A BOUGE. Sa premiere forme cherchait le cablage
  # dans la porte ; l'etape qui a fait passer le preflight dans le delegue l'a rendu rouge sans que
  # rien ne soit casse. Ce qui se tient est la REGLE : celui qui sonde pose `PROV_COMPOSE_CMD`, et
  # celui qui lance compose le LIT — sans repli, parce qu'un repli est la seconde reponse qu'on
  # vient de supprimer.
  local container="$BATS_TEST_DIRNAME/../../container"
  grep -q 'docker_compose_cmd || fail' "$container"
  grep -q 'COMPOSE=(\$PROV_COMPOSE_CMD)' "$container"
  refute grep -q 'LCARS_COMPOSE_CMD:-' "$container"
  # Et personne ne redecouvre : une seconde detection dans l'arbre rendrait deux verdicts possibles.
  [ "$(grep -rl 'compose version >/dev/null' "$BATS_TEST_DIRNAME/../../.." --include='*.sh' --include=container --include=provision 2>/dev/null | wc -l)" -le 1 ]
}

# ─── LE REFUS ACCUSE LA PREMIERE SOCKET, PAS LA DERNIERE ────────────────────────────────────────
#
# ⚠ MESURE D'UN BANC WSL A INTEGRATION ACTIVEE (2026-08-30) : le message de refus nommait
# `docker.proxy.sock` en `root:root 755`, alors que la socket qui compte est `/var/run/docker.sock`
# en `root:docker 660` — refusee faute d'appartenance au groupe, ce qui est une cause TOUTE AUTRE et
# un geste tout autre. Le balayage voit la seconde d'abord, la premiere ensuite, et l'affectation
# ecrasait : c'est donc le dernier repli qui parlait, jamais la cause.
#
# Un diagnostic qui accuse le mauvais objet coute plus qu'un diagnostic absent — il envoie chercher
# la panne la ou elle n'est pas.

@test "le premier refus est celui qu'on garde — l'affectation ne s'ecrase pas" {
  # La FORME, comme tout ce fichier : jouer la boucle demanderait deux sockets refusees et un daemon
  # qui repond, c'est-a-dire une machine precise. `:=` n'affecte que si la variable est vide.
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  grep -q ': "${PROV_DOCKER_SOCK:=$sock}"' <<<"$code"
  refute grep -q 'PROV_DOCKER_SOCK="$sock"' <<<"$code"
}

@test "TEMOIN DU TEMOIN : l'affectation conditionnelle garde la premiere, l'affectation nue la derniere" {
  # Sans lui, le temoin ci-dessus epingle une syntaxe sans prouver qu'elle fait ce qu'on lui prete —
  # et le jour ou quelqu'un la « simplifie », rien ne dira ce qui a ete perdu.
  run bash -c 'p=""; for s in premiere derniere; do : "${p:=$s}"; done; echo "$p"'
  [ "$output" = "premiere" ]
  run bash -c 'p=""; for s in premiere derniere; do p="$s"; done; echo "$p"'
  [ "$output" = "derniere" ]
}

# ─── LE `DOCKER_CONFIG` SE POSE SUR UNE MESURE, PAS SUR UN SUBSTRAT ─────────────────────────────

@test "le DOCKER_CONFIG n'est fabrique que si compose ne repond PAS — jamais par deduction" {
  # ⚠ CE QUE CETTE CONDITION COUTAIT, MESURE SUR UN BANC WSL A INTEGRATION ACTIVEE (2026-08-30).
  # Elle portait sur « substrat WSL ET la CLI du montage » — vrai sur toute distro integree, ou
  # `docker compose version` repond pourtant NU. Le config fabrique remplacait alors celui de
  # l'humain, donc ses CONTEXTS :
  #     contexts AVANT : default desktop-linux
  #     contexts APRES : default
  # Le rail ne s'en apercevait pas (il porte `DOCKER_HOST`) ; l'humain qui herite de cet
  # environnement, si. Un contournement ecrit contre le montage NU s'appliquait la ou il n'a plus
  # d'objet — et il n'etait pas neutre.
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  local cond; cond="$(grep -n 'DOCKER_CONFIG:-' <<<"$code" | head -1)"
  [ -n "$cond" ]
  # La mesure, et pas la deduction : `compose version` decide, `detect_substrate` n'a rien a y faire.
  grep -qE 'DOCKER_CONFIG:-.*\]\] && ! "\$PROV_DOCKER_BIN" compose version' <<<"$code"
  refute grep -qE 'detect_substrate.*==.*wsl.*&&.*_docker_mount_cli.*&&.*DOCKER_CONFIG' <<<"$code"
}

# ─── LE REPLI PAR LA SOCKET DU MONTAGE EST MORT (⚖ user 2026-08-31) ─────────────────────────────
#
# Sous WSL, le balayage essayait `/var/run/docker.sock` PUIS la socket du montage Docker Desktop
# (`shared-sockets/guest-services/docker.proxy.sock`), qui est `root:root 755`. Ce repli n'avait
# qu'un cas — une distro dont l'INTEGRATION WSL est desactivee — et il y repondait par `sudo`.
#
# ⚠ IL A COUTE DEUX FOIS. Le 2026-08-30, le refus accusait la proxy au lieu de la socket qui compte,
# et envoyait chercher des droits qui ne bloquaient personne. Le 2026-08-31, il a fait batir un
# diagnostic entier sur une socket hors sujet pendant que l'autre repondait.
#
# L'integration WSL devient un PRE-REQUIS : elle pose `/var/run/docker.sock` en `root:docker`, ce qui
# rend WSL identique au linux natif — meme socket, meme groupe, meme condition d'acces.

@test "UNE SEULE socket, sur TOUS les substrats — la proxy du montage a disparu" {
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  refute grep -q 'docker.proxy.sock' <<<"$code"
  refute grep -q '_docker_mount_sock' <<<"$code"
  # Et le balayage ne depend plus du substrat : un seul chemin, partout.
  local corps; corps="$(sed -n '/^_docker_sockets()/,/^}/p' <<<"$code")"
  refute grep -q 'detect_substrate' <<<"$corps"
  grep -q '/var/run/docker.sock' <<<"$corps"
}

@test "le refus SANS daemon nomme l INTEGRATION, pas seulement Docker Desktop" {
  # Demarrer Docker Desktop ne suffit pas : sans l'integration activee pour CETTE distro, la socket
  # n'apparait pas dans la distro. Un refus qui ne dit que « demarre Docker Desktop » envoie
  # verifier ce qui est deja vrai.
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  grep -q 'INTEGRATION WSL activee' <<<"$code"
  grep -q 'WSL integration' <<<"$code"
}

# ─── LE REFUS NOMME LE GESTE, ET IL DISTINGUE TROIS ETATS ───────────────────────────────────────

@test "docker_denied_geste : dans le groupe POUR LA SESSION" {
  # L'acces est refuse alors que l'appartenance est active : ce n'est plus une question de groupe,
  # c'est le mode de la socket. Le geste change de sujet.
  local out; out="$(bash -c '. "$1"; docker_denied_geste "$2"' _ "$LIB" /var/run/docker.sock 2>/dev/null)"
  if id -nG | tr ' ' '\n' | grep -qx "$(stat -Lc '%G' /var/run/docker.sock 2>/dev/null)"; then
    [[ "$out" == *"bit d'ecriture"* ]]
  else
    skip "cette session n'est pas dans le groupe de la socket — cas couvert par les deux temoins suivants"
  fi
}

@test "docker_denied_geste : dans /etc/group mais PAS dans la session — le cas qui s inverse" {
  # ⚠ LES GROUPES D'UN PROCESSUS SONT FIXES A L'OUVERTURE DE SA SESSION. Un compte qu'on vient
  # d'ajouter est membre pour le SYSTEME et ne l'est pas pour son SHELL. Dire « ajoute-toi au
  # groupe » a quelqu'un qui y est deja l'envoie refaire ce qui est fait, et chercher ailleurs.
  # Mesure du 2026-08-31 sur ce depot : ce cas exact s'est presente.
  local grp; grp="$(stat -Lc '%G' /var/run/docker.sock 2>/dev/null)"
  getent group "$grp" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$(id -un)" \
    || skip "ce compte n'est pas dans « $grp » dans /etc/group — rien a simuler"
  # On simule une session qui n'a PAS le groupe, en surchargeant `id -nG`.
  run bash -c '. "$1"
    id() { if [[ "$1" == "-nG" ]]; then echo "sans-le-groupe"; else command id "$@"; fi; }
    docker_denied_geste /var/run/docker.sock' _ "$LIB"
  [[ "$output" == *"DANS /etc/group mais PAS dans cette session"* ]]
  [[ "$output" == *"sg "* ]]
}

@test "docker_denied_geste : hors du groupe — le geste est usermod, ET la reouverture" {
  # `/etc/shadow` est root:shadow sur toute Debian : un groupe reel ou aucun compte de travail n'est.
  [ -e /etc/shadow ] || skip "pas de /etc/shadow pour servir de groupe temoin"
  local out; out="$(bash -c '. "$1"; docker_denied_geste "$2"' _ "$LIB" /etc/shadow 2>/dev/null)"
  [[ "$out" == *"usermod -aG"* ]]
  # ⚠ ET LA REOUVERTURE EST DITE. Sans elle, l'operateur joue usermod, relance, et retombe sur le
  # meme refus — le geste etait bon, il manquait sa moitie.
  [[ "$out" == *"ROUVRE ta session"* ]]
}

@test "docker_denied_geste : socket illisible — il ne raconte rien qu il ne sait pas" {
  local out; out="$(bash -c '. "$1"; docker_denied_geste "$2"' _ "$LIB" /nexistepas/docker.sock 2>/dev/null)"
  [[ "$out" == *"illisible"* ]]
  refute grep -q 'usermod' <<<"$out"
}

# ─── M2 : « REFUSE » N'EST PAS « REPOND » — L'ECOUTE S'ETABLIT AVANT D'ACCUSER LE GROUPE ─────────
#
# ⚠ RELECTURE HOSTILE DU 2026-09-04. `PROV_DOCKER_DENIED=1` se posait des que la socket existait
# sans etre inscriptible, quelle que soit la raison de l'echec de `docker version`. Sur une socket
# ORPHELINE (daemon crashe, fichier survivant) lue par un compte hors du groupe, le message disait
# « le daemon docker REPOND, mais pas a « X » » et envoyait chercher un probleme de groupe.
#
# ⚠ CES TEMOINS JOUENT LA FONCTION, pas sa forme : une vraie socket unix, posee par python3 dans le
# bac a sable, avec ou sans processus qui ecoute derriere. La CLI est une doublure qui ne repond
# jamais ; le balayage ne voit que la socket du decor (LCARS_DOCKER_SOCKETS). Sous root `-w` est
# toujours vrai et le cas « refuse » n'existe pas : on saute, on ne simule pas.

ecouteur() { # ecouteur <socket> — un processus qui ecoute sur cette socket, mode 000 ; pose ECOUTEUR_PID
  python3 - "$1" <<'PY' &
import os, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); os.chmod(sys.argv[1], 0)
time.sleep(30)
PY
  ECOUTEUR_PID=$!
  local _i; for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$1" ]] && break; sleep 0.2; done
  [[ -S "$1" ]]
}
orpheline() { # orpheline <socket> — le fichier d'une socket dont le processus est mort, mode 000
  python3 - "$1" <<'PY'
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); os.chmod(sys.argv[1], 0); s.close()
PY
  [[ -S "$1" ]]
}
teardown() { [[ -n "${ECOUTEUR_PID:-}" ]] && kill "$ECOUTEUR_PID" 2>/dev/null; return 0; }

sonde() { # sonde <socket> — joue docker_endpoint avec une CLI muette ; rend DENIED et WHY
  local cli="$BATS_TEST_TMPDIR/cli-muette"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$cli"; chmod +x "$cli"
  run env -u DOCKER_HOST LCARS_DOCKER_SOCKETS="$1" PROV_DOCKER_BIN="$cli" DOCKER_CONFIG="$BATS_TEST_TMPDIR/dc" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? denied=$PROV_DOCKER_DENIED"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
}

@test "M2 : un processus ECOUTE et la socket refuse → « REPOND, mais pas a » (le groupe est la question)" {
  [ "$EUID" -ne 0 ] || skip "root ecrit sur toute socket : le cas « refuse » n'existe pas ici"
  command -v python3 >/dev/null || skip "python3 absent : pas de socket de decor"
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix : l ecoute n est pas mesurable ici"
  local sock="$BATS_TEST_TMPDIR/vivante.sock"
  ecouteur "$sock"
  sonde "$sock"
  [[ "$output" == *"rc=1 denied=1"* ]]
  [[ "$output" == *"REPOND, mais pas a"* ]]
  refute grep -q 'NON etabli' <<<"$output"
}

@test "M2 : socket ORPHELINE (personne n'ecoute) → daemon vivant NON etabli, et le groupe n'est PAS accuse" {
  [ "$EUID" -ne 0 ] || skip "root ecrit sur toute socket : le cas « refuse » n'existe pas ici"
  command -v python3 >/dev/null || skip "python3 absent : pas de socket de decor"
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix : l ecoute n est pas mesurable ici"
  local sock="$BATS_TEST_TMPDIR/morte.sock"
  orpheline "$sock"
  sonde "$sock"
  [[ "$output" == *"rc=1 denied=0"* ]]
  [[ "$output" == *"aucun daemon docker joignable"* ]]
  [[ "$output" == *"aucun processus n'y ecoute"* ]]
  [[ "$output" == *"NON etabli"* ]]
  refute grep -q 'REPOND, mais pas a' <<<"$output"
  refute grep -q 'usermod' <<<"$output"
}

@test "M2 : TEMOIN DU TEMOIN — _docker_sock_listening distingue les deux sockets, et dit quand il ne peut pas" {
  command -v python3 >/dev/null || skip "python3 absent : pas de socket de decor"
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix"
  ecouteur "$BATS_TEST_TMPDIR/v.sock"; orpheline "$BATS_TEST_TMPDIR/m.sock"
  run bash -c '. "$1"; _docker_sock_listening "$2"; echo "v=$?"; _docker_sock_listening "$3"; echo "m=$?"' _ "$LIB" "$BATS_TEST_TMPDIR/v.sock" "$BATS_TEST_TMPDIR/m.sock"
  [[ "$output" == *"v=0"* ]]
  [[ "$output" == *"m=1"* ]]
}
