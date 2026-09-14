#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/install.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: témoins d'install.sh — ce qu'il mesure, ce qu'il montre, ce qu'il refuse, où il délègue

# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/install.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  # un sudo, un docker et un unshare qui rougissent s'ils sont appelés : l'installeur n'escalade jamais et ne sonde pas lui-même
  local t
  for t in sudo docker unshare; do
    printf '#!/usr/bin/env bash\necho %s-APPELE >&2; exit 97\n' "${t^^}" > "$BINDIR/$t"; chmod 0755 "$BINDIR/$t"
  done
  export PATH="$BINDIR:$PATH"
  TAG="9.9.9-test"
}


# shellcheck disable=SC2054  # les virgules sont dans les valeurs (groupes, comptes), pas entre les éléments
_faits_sains=(git=oui curl=oui sudo=oui docker=oui docker_bin=/usr/bin/docker docker_host=unix:///var/run/docker.sock
  docker_server=29.0.0 "docker_flavor=Docker Engine" docker_why= compose=oui substrat=wsl consent=sans-objet
  distro=Ubuntu distro_version=26.04 noyau=6.6.0 arch=x86_64 cpu=4 ram_mb=8192 disque_mb=102400 systemd=oui
  utilisateur=temoin groupes=temoin,sudo,docker forge_fournie= forge_joignable=sans-objet
  "port_forge=21000 libre" "port_deck=20999 libre" "port_ssh=2222 libre" projet=lcars projet_pris=
  apt_installs= comptes_humains=temoin channel=aucun channel_tree=source jq=oui)

_faux_provision() { # _faux_provision <arbre> [nom=valeur…] — le doctor écrit ces faits ; FAUX_PREFLIGHT_REFUS : sa ligne de refus, et le verdict qui va avec
  local arbre="$1"; shift
  mkdir -p "$arbre/deploy"
  { echo '#!/usr/bin/env bash'
    echo "echo \"PROVISION:\$*\" >> '$BATS_TEST_TMPDIR/provision.calls'"
    echo '[[ -n "${PROV_FACTS_FILE:-}" ]] || exit 0'
    echo 'cat > "$PROV_FACTS_FILE" <<'"'"'FACTS'"'"''
    printf '%s\n' "$@"
    echo 'FACTS'
    echo '[[ -z "${FAUX_PREFLIGHT_REFUS:-}" ]] || { echo "OK    00-preflight: décor"; echo "$FAUX_PREFLIGHT_REFUS"; exit 1; }'
  } > "$arbre/deploy/provision"
  chmod 0755 "$arbre/deploy/provision"
}

_arbre() { # _arbre [nom=valeur…] -> un arbre « kit » (sans .git) avec délégués espions ; les faits donnés écrasent les sains
  local a="$BATS_TEST_TMPDIR/arbre"
  rm -rf "$a"; mkdir -p "$a/deploy/docker/bench"
  cp "$SRC" "$a/install.sh"
  cp "$REPO/deploy/installer-constants.env" "$a/deploy/"
  printf 'cafe1234\n' > "$a/.source-revision"
  _faux_provision "$a" "${_faits_sains[@]}" "$@"
  printf '#!/usr/bin/env bash\necho "WORKSTATION:$*"; env | grep -E "^(PROV_FORGE_MONTEE|LCARS_BUILTIN_HUMAN)=" | sort\n' > "$a/deploy/workstation"
  printf '#!/usr/bin/env bash\necho "CONTAINER:$*"\n' > "$a/deploy/container"
  printf '#!/usr/bin/env bash\necho "BENCHUP:$*"; echo "DOCKER_BIN=${DOCKER_BIN:-}"\n' > "$a/deploy/docker/bench/bench-up.sh"
  chmod 0755 "$a/deploy/workstation" "$a/deploy/container" "$a/deploy/docker/bench/bench-up.sh"
  printf '%s' "$a"
}

porte() { # porte <arbre> [args…] — sans terminal : une session à part, stdin fermé
  local a="$1"; shift
  run setsid -w bash "$a/install.sh" "$@" < /dev/null
}


# bats test_tags=structure
@test "root est refusé avant tout parsing" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  grep -q 'EUID" -eq 0' <<<"$code"
  local l_garde l_parse
  l_garde="$(grep -n 'EUID" -eq 0' "$SRC" | head -1 | cut -d: -f1)"
  l_parse="$(grep -n '^while \[\[ \$# -gt 0 \]\]' "$SRC" | head -1 | cut -d: -f1)"
  [ "$l_garde" -lt "$l_parse" ]
}

# bats test_tags=structure
@test "tout le code vit dans main, appelé en dernière ligne entre accolades" {
  [ "$(tail -1 "$SRC")" = '{ main "$@"; }' ]
  local l_main l_appel total
  l_main="$(grep -n '^main() {$' "$SRC" | head -1 | cut -d: -f1)"
  l_appel="$(grep -n '^{ main "\$@"; }$' "$SRC" | head -1 | cut -d: -f1)"
  total="$(wc -l < "$SRC")"
  [ -n "$l_main" ]
  [ "$l_appel" -eq "$total" ]
  # hors de main : le shebang, l'en-tête, set, la version, la fermeture et l'appel
  local hors; hors="$(awk -v m="$l_main" -v a="$l_appel" 'NR<m || NR>=a' "$SRC" | grep -vE '^\s*#|^\s*$|^set -euo pipefail$|^LCARS_DOOR_VERSION=|^}$|^\{ main' || true)"
  [ -z "$hors" ] || { echo "hors de main : $hors" >&2; return 1; }
}

# bats test_tags=structure
@test "une porte pipée et coupée n'exécute rien" {
  local n; n="$(wc -c < "$SRC")"
  local p c out
  for p in 10 25 50 75 90 95 98 99; do
    c=$(( n * p / 100 ))
    out="$(head -c "$c" "$SRC" | bash -s -- 2>&1 | grep -c 'Source\|Système\|Installation\|téléchargé' || true)"
    [ "$out" -eq 0 ] || { echo "fuite à $p % : $out ligne(s) exécutée(s)" >&2; return 1; }
  done
}

# bats test_tags=structure
@test "le gabarit du dépôt porte ses marqueurs de version, une fois chacun" {
  local m
  for m in DOOR_VERSION DOOR_BASE DOOR_PUBKEY DOOR_IMAGE DOOR_SUMS_BEGIN DOOR_SUMS_END; do
    [ "$(grep -c "@@$m@@" "$SRC")" -eq 1 ]
  done
}


@test "--version du script du dépôt dit qu'il n'est pas publié, pipé aussi" {
  run bash "$SRC" --version
  [ "$status" -eq 0 ]
  [ "$output" = "non publiée" ]
  run bash -c "cat '$SRC' | bash -s -- --version"
  [ "$output" = "non publiée" ]
}

@test "--help, en fichier comme pipée, nomme chaque drapeau que le parseur accepte" {
  # la liste se lit dans les bras du parseur : un drapeau ajouté sans son aide rougit ici
  local drapeaux f
  drapeaux="$(sed -n '/^while \[\[ \$# -gt 0 \]\]; do$/,/^done$/p' "$SRC" | grep -oE '^ *-[-a-z|]+\)' | tr -d ' )' | tr '|' '\n')"
  grep -qx -- '--workstation' <<<"$drapeaux"
  grep -qx -- '-h' <<<"$drapeaux"
  run bash "$SRC" --help
  [ "$status" -eq 0 ]
  for f in $drapeaux; do
    [[ "$output" == *"$f"* ]] || { echo "aide sans $f" >&2; return 1; }
  done
  run bash -c "cat '$SRC' | bash -s -- --help"
  [ "$status" -eq 0 ]
  for f in $drapeaux; do
    [[ "$output" == *"$f"* ]] || { echo "aide pipée sans $f" >&2; return 1; }
  done
}

@test "un drapeau inconnu fait rater le script en se nommant, drapeaux retirés et --container compris" {
  local f
  for f in --source --branch --tar --uninstall --disposable --consented --fleet-human --container --inconnu; do
    run bash "$SRC" "$f" < /dev/null
    [ "$status" -eq 1 ] || { echo "$f accepté (rc $status)" >&2; return 1; }
    [[ "$output" == *"Option inconnue : $f"* ]] || { echo "$f : $output" >&2; return 1; }
  done
}

@test "--substrate invalide est refusé au parsing, avant toute mesure" {
  local a; a="$(_arbre)"
  porte "$a" --substrate mars
  [ "$status" -eq 1 ]
  [[ "$output" == *"inconnu (wsl|docker|linux)"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}

@test "un drapeau du provisionnement en mode conteneur est refusé au parsing" {
  local a; a="$(_arbre)"
  porte "$a" --only 10-packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only est un drapeau du mode --workstation"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}


@test "le bilan lit les faits du préflight et rien d'autre — ni docker ni sudo ne sont appelés" {
  # docker=oui dans les faits alors que le docker du décor rougit s'il est appelé : le bilan le dit oui
  local a; a="$(_arbre)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker     serveur 29.0.0 · Docker Engine · unix:///var/run/docker.sock"* ]]
  refute grep -q 'SUDO-APPELE\|DOCKER-APPELE' <<<"$output"
  grep -vE '^\s*#' "$SRC" | refute_out 'docker_endpoint|detect_substrate'
}

@test "--port-forge sans --bench est refusé au parsing, dans les deux modes : la forge fournie n'a pas de port à nous" {
  local a; a="$(_arbre)"
  porte "$a" --port-forge 21000
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-forge n'a d'objet qu'avec --bench"* ]]
  porte "$a" --workstation --port-forge 21000
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-forge n'a d'objet qu'avec --bench"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}

@test "en poste, le port SSH n'a pas d'objet : --port-ssh est refusé, et un port 2222 tenu n'arrête rien" {
  local a; a="$(_arbre "port_ssh=2222 pris par sshd")"
  porte "$a" --workstation --bench --port-ssh 2300
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-ssh est le port SSH du conteneur"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"(ssh)"* ]]
  [[ "$output" == *"WORKSTATION:up"* ]]
}

@test "le préflight reçoit le substrat, le projet et les ports demandés" {
  local a; a="$(_arbre)"
  porte "$a" --check --bench --substrate wsl --forge-project bob_9 --port-forge 20090 --port-deck 20091 --port-ssh 20092
  grep -q -- 'PROVISION:doctor --only 00-preflight --substrate wsl --forge-project bob_9 --port-forge 20090 --port-deck 20091 --port-ssh 20092' "$BATS_TEST_TMPDIR/provision.calls"
}

@test "sans fait rendu, l'installeur s'arrête et montre le rapport du préflight" {
  local a="$BATS_TEST_TMPDIR/arbre"; rm -rf "$a"; mkdir -p "$a/deploy"
  cp "$SRC" "$a/install.sh"
  cp "$REPO/deploy/installer-constants.env" "$a/deploy/"
  printf '#!/usr/bin/env bash\necho "le doctor est mort"; exit 3\n' > "$a/deploy/provision"
  printf '#!/usr/bin/env bash\necho "CONTAINER:$*"\n' > "$a/deploy/container"
  chmod 0755 "$a/deploy/provision" "$a/deploy/container"
  porte "$a" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fait"*"le doctor est mort"* ]]
}

@test "un arbre incomplet s'arrête avant la mesure et nomme ce qui manque : le runner, le délégué du mode, les constantes" {
  local a; a="$(_arbre)"
  rm "$a/deploy/installer-constants.env"
  porte "$a" --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'arbre est incomplet : constantes de l'installeur introuvables : $a/deploy/installer-constants.env"* ]]
  a="$(_arbre)"
  chmod 0644 "$a/deploy/provision"
  porte "$a" --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'arbre est incomplet : $a/deploy/provision absent ou non exécutable"* ]]
  a="$(_arbre)"
  rm "$a/deploy/workstation"
  porte "$a" --workstation --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'arbre est incomplet : $a/deploy/workstation absent ou non exécutable"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}

@test "sans fichier temporaire possible, l'installeur s'arrête en le nommant, sans erreur brute de bash" {
  local a; a="$(_arbre)"
  TMPDIR="$BATS_TEST_TMPDIR/absent" porte "$a" --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aucun fichier temporaire ne se crée dans $BATS_TEST_TMPDIR/absent"* ]]
  refute_out 'line [0-9]+:' <<<"$output"
}


@test "le bandeau porte la version, puis le bilan décrit la source, le système, docker, les outils, la forge" {
  local a; a="$(_arbre)"
  porte "$a" --check
  [ "$status" -eq 1 ]   # aucune forge : le bilan s'affiche entier, puis l'arrêt
  [[ "$output" == *"version $(bash "$SRC" --version)"* ]]
  [[ "$output" == *"Source     archive (kit) · révision cafe1234"* ]]
  [[ "$output" == *"Système    Ubuntu 26.04 sous WSL2 · noyau 6.6.0 · systemd actif"* ]]
  # le disque se mesure sous la racine des bascules (00-preflight), pas sur /
  [[ "$output" == *"x86_64 · 4 cœurs · 8 Go de RAM · 100 Go libres pour $(sed -n 's/^PROV_ROOT=//p' "$a/deploy/installer-constants.env")"* ]]
  [[ "$output" == *"utilisateur temoin · groupes sudo, docker"* ]]
  [[ "$output" == *"Outils     git, curl présents"* ]]   # sudo n'est requis que par --workstation, jq que par le banc en conteneur
  [[ "$output" == *"Forge      aucune"* ]]
  porte "$a" --workstation --check
  [[ "$output" == *"Outils     git, curl, sudo présents"* ]]
}

@test "un utilisateur hors de sudo, docker et fleet voit le bilan, et le bilan le dit" {
  local a; a="$(_arbre groupes=temoin,users)"
  porte "$a" --bench --check
  [[ "$output" == *"utilisateur temoin · groupes ni sudo, ni docker, ni fleet"* ]]
  [[ "$output" == *"Outils"* ]]
}

@test "un fait absent s'affiche comme inconnu, jamais comme une mesure" {
  local a; a="$(_arbre ram_mb= arch=)"
  porte "$a" --bench --check
  [[ "$output" == *"? · 4 cœurs · ? Go de RAM"* ]]
}

@test "depuis un clone, la source est le clone : branche et commit, jamais le chemin" {
  run bash "$SRC" --check --substrate wsl < /dev/null
  [[ "$output" == *"Source     clone git · branche $(git -C "$REPO" rev-parse --abbrev-ref HEAD) · commit $(git -C "$REPO" rev-parse --short HEAD)"* ]]
  [[ "$output" != *"Source     $REPO"* ]]
}

@test "la forge : montée par --bench, fournie et joignable, ou aucune — et les ports avec leur état" {
  local a; a="$(_arbre "port_deck=20999 pris par autre-fleet-lcars-1 (projet autre-fleet)")"
  porte "$a" --check --bench
  [[ "$output" == *"Forge      montée par l'installeur avec son runner CI (--bench)"* ]]
  [[ "$output" == *"21000 (forge) libre"*"20999 (deck) PRIS PAR AUTRE-FLEET"* ]]
  a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a" --check
  [[ "$output" == *"Forge      fournie : https://forge.example.net · joignable"* ]]
  [[ "$output" != *"(forge)"* ]]
}


@test "sans forge indiquée, l'installeur s'arrête et nomme les deux commandes" {
  local a; a="$(_arbre)"
  porte "$a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aucune n'est indiquée"* ]]
  [[ "$output" == *"--bench"* ]]
  [[ "$output" == *"FORGE_BASE_URL=https://"* ]]
  refute grep -q 'CONTAINER:\|Installation en conteneur' <<<"$output"
}

@test "une forge fournie injoignable arrête" {
  local a; a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=non)"
  porte "$a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne répond pas : https://forge.example.net"* ]]
}

@test "docker absent sous WSL arrête les deux modes ; refusé arrête aussi" {
  local a; a="$(_arbre docker=absent "docker_why=aucun daemon")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker est absent"*"intégration WSL de Docker Desktop"* ]]
  porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker est absent"* ]]
  a="$(_arbre docker=refuse "docker_why=la socket est root:docker")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"refuse cet utilisateur"*"root:docker"* ]]
}

@test "sur Linux dédié, docker absent arrête le conteneur et passe pour le système, qui le posera" {
  local a; a="$(_arbre substrat=linux consent=env docker=absent "docker_why=aucun daemon")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker est absent"*"LCARS_ALLOW_ANY_HOST=1"* ]]
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker     absent · sera posé par l'installation"* ]]
  [[ "$output" == *"docker-ce si aucun daemon ne répond"* ]]
}

@test "compose absent : dit au bilan, arrête le conteneur avant la confirmation, laisse passer le système" {
  local a; a="$(_arbre compose=non "compose_why=docker répond, mais compose est absent (ni le plugin)")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"compose absent"*"ni le plugin"*"Docker répond, mais compose est absent"*"docker-compose-plugin"* ]]
  refute_out "Entrée pour continuer" <<<"$output"
  refute_out "CONTAINER:" <<<"$output"
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
}

@test "le délégué reçoit le DOCKER_HOST que le préflight a vu répondre, pas celui de l'environnement" {
  local a; a="$(_arbre docker_host=unix:///var/run/docker.sock)"
  printf '#!/usr/bin/env bash\necho "CONTAINER:$*"; echo "DOCKER_HOST=[${DOCKER_HOST:-}]"\n' > "$a/deploy/container"
  DOCKER_HOST=unix:///mort.sock porte "$a" --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER:--bench up"*"DOCKER_HOST=[unix:///var/run/docker.sock]"* ]]
}

@test "Linux natif : --workstation exige LCARS_ALLOW_ANY_HOST, mesuré par le préflight" {
  local a; a="$(_arbre substrat=linux consent=none)"
  porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"sans déclaration"*"(/etc, /opt/lcars,"*"LCARS_ALLOW_ANY_HOST=1"*"--workstation"* ]]
  a="$(_arbre substrat=linux consent=env)"
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation dans ce système"* ]]
}

@test "--workstation hors WSL et hors Linux est refusé, et le conteneur est nommé" {
  local a; a="$(_arbre substrat=docker)"
  porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne s'installe que dans une distribution WSL2 ou sur une machine Linux dédiée"* ]]
}

@test "sous WSL, l'installeur ne sonde pas les namespaces lui-même : aucun des deux modes n'appelle unshare" {
  local a; a="$(_arbre)"
  porte "$a" --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out 'UNSHARE-APPELE' <<<"$output"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out 'UNSHARE-APPELE' <<<"$output"
}

@test "un préflight qui refuse le terrain arrête l'installation dans ce système avant la grille, en citant son constat ; le conteneur continue" {
  local a; a="$(_arbre)"
  FAUX_PREFLIGHT_REFUS="DRIFT 00-preflight: RAM 1024 Mo < 1536 Mo — la release ne se construira pas" porte "$a" --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Le préflight refuse ce terrain pour l'installation dans ce système"*"DRIFT 00-preflight: RAM 1024 Mo < 1536 Mo"* ]]
  refute_out 'OK    00-preflight|Modifie|WORKSTATION:' <<<"$output"
  FAUX_PREFLIGHT_REFUS="FAIL  00-preflight: Linux natif sans déclaration" porte "$a" --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER:--bench up"* ]]
}

@test "un port demandé déjà tenu arrête et nomme les drapeaux qui déplacent" {
  local a; a="$(_arbre "port_ssh=2222 pris par vanille_1-fleet-lcars-1 (projet vanille_1-fleet)")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"déjà tenu : ssh 2222 pris par vanille_1-fleet-lcars-1"*"--port-ssh"* ]]
}

@test "un projet compose déjà présent arrête le mode conteneur, pas le mode système" {
  local a; a="$(_arbre projet_pris=lcars-fleet)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-fleet » existe déjà"*"--forge-project"* ]]
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
}

@test "outils manquants : arrêt qui les nomme" {
  local a; a="$(_arbre git=absent)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outils manquants : git"* ]]
}

@test "jq absent : arrête le banc en conteneur avant la confirmation en le nommant, laisse passer le conteneur sans banc et le système qui le pose" {
  local a; a="$(_arbre jq=absent forge_fournie=http://forge.example forge_joignable=oui)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outils manquants : jq"* ]]
  refute_out "Entrée pour continuer" <<<"$output"
  refute_out "CONTAINER:" <<<"$output"
  porte "$a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outils     git, curl présents"* ]]
  [[ "$output" == *"CONTAINER:up"* ]]
  porte "$a" --bench --workstation
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSTATION:up"* ]]
}

vrai_poste() { # vrai_poste <arbre> — le vrai délégué du poste et sa lib dans l'arbre ; sudo note son argv
  cp "$REPO/deploy/workstation" "$1/deploy/workstation"
  cp -a "$REPO/deploy/lib" "$1/deploy/lib"
  cp "$REPO/deploy/system.manifest" "$1/deploy/"
  printf '#!/usr/bin/env bash\necho "SUDO:$*" >> "%s"\n' "$BATS_TEST_TMPDIR/sudo.calls" > "$BINDIR/sudo"
}

@test "l'argv que l'installeur émet est lu par le vrai délégué du poste, jusqu'au sudo" {
  local a; a="$(_arbre)"
  vrai_poste "$a"
  porte "$a" --workstation --bench --human alice --port-deck 20091 --only 60
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^PROVISION:doctor --only 00-preflight --port-deck 20091$' "$BATS_TEST_TMPDIR/provision.calls"
  [[ "$(cat "$BATS_TEST_TMPDIR/sudo.calls")" == "SUDO:"*"PROV_FORGE_MONTEE=1 LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=lcars DOCKER_HOST=unix:///var/run/docker.sock bash $a/deploy/workstation up --human alice --only 60 --port-deck 20091" ]]
}

@test "le canal : le mélange est refusé par le délégué, avant tout sudo ; un canal illisible arrête avec le préflight ; le conteneur ne lit pas le canal" {
  local a; a="$(_arbre channel=source channel_tree=kit)"
  vrai_poste "$a"
  porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"installée par « source »"*"poserait « kit »"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  a="$(_arbre channel=invalide)"
  FAUX_PREFLIGHT_REFUS="FAIL  00-preflight: canal d'installation illisible" porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"Le préflight refuse ce terrain"*"canal d'installation illisible"* ]]
  a="$(_arbre channel=inconnu)"
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
  a="$(_arbre channel=kit channel_tree=source)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ]
}


@test "sans --workstation le mode est le conteneur : sa grille, et l'autre mode nommé" {
  local a; a="$(_arbre projet=bob_10)"
  porte "$a" --bench --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur"*"Modifie"*"bob_10-fleet"*"Requiert"*"docker · la forge"*"Retour     deploy/container -p bob_10-fleet reset"* ]]
  [[ "$output" == *"Pour installer dans ce système à la place :"*"--workstation"* ]]
  [[ "$output" != *"Choix ["* ]]
}

@test "--workstation : sa grille, avec /etc/wsl.conf sous WSL et la machine sur Linux" {
  local a; a="$(_arbre)"
  porte "$a" --bench --workstation --check
  [[ "$output" == *"Installation dans ce système"*"Modifie    /etc/wsl.conf, /opt/lcars, des groupes et des comptes de service, des paquets apt, ~/.config, ~/.docker et ~/.claude de l'utilisateur"*"Requiert   sudo, demandé une fois"*"wsl --unregister"* ]]
  [[ "$output" == *"Pour installer en conteneur à la place :"* ]]
  a="$(_arbre substrat=linux consent=env)"
  porte "$a" --bench --workstation --check
  [[ "$output" == *"Modifie    /opt/lcars, des groupes et des comptes de service, des paquets apt, ~/.claude de l'utilisateur, docker-ce"*"la machine se réinstalle"* ]]
}

@test "--check s'arrête après la grille, rien n'est appelé" {
  local a; a="$(_arbre)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"--check : rien n'est fait"* ]]
  refute grep -q 'BENCHUP:\|CONTAINER:\|WORKSTATION:' <<<"$output"
}

@test "--dry-run dit la commande exacte, mot à mot, sans l'exécuter" {
  local a; a="$(_arbre)"
  porte "$a" --bench --dry-run --forge-project bob_10 --port-deck 20101
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run : rien n'est fait. La commande serait :"*"$a/deploy/container --forge-project bob_10 --port-deck 20101 --bench up"* ]]
  refute grep -q 'CONTAINER:' <<<"$output"
  porte "$a" --workstation --bench --dry-run --substrate wsl --only 10-packages
  [ "$status" -eq 0 ]
  [[ "$output" == *"$a/deploy/workstation up --substrate wsl --only 10-packages"* ]]
}


@test "mode conteneur : exec deploy/container avec le projet et les ports, puis up" {
  local a; a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  porte "$a" --forge-project bob_10 --port-deck 20101 --port-ssh 20102
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur — deploy/container up"* ]]
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 --port-deck 20101 --port-ssh 20102 up" ]]
  refute grep -q 'SUDO-APPELE\|DOCKER-APPELE' <<<"$output"
  # le fichier de faits ne survit pas à l'exec
  [ -z "$(ls "$TMPDIR")" ]
}

@test "mode conteneur avec --bench : exec deploy/container avec les mêmes drapeaux, puis --bench up" {
  local a; a="$(_arbre)"
  porte "$a" --bench --forge-project bob_10 --port-forge 20100
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur, avec le banc — deploy/container --bench up"* ]]
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 --port-forge 20100 --bench up" ]]
  refute grep -q 'SUDO-APPELE\|DOCKER-APPELE' <<<"$output"
}

@test "mode système : exec deploy/workstation up avec le substrat et les drapeaux du provisionnement" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench --substrate wsl --human alice --port-deck 20091
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation dans ce système — deploy/workstation up"* ]]
  [[ "$output" == *"WORKSTATION:up --substrate wsl --human alice --port-deck 20091"* ]]
  # --bench sur ce mode : la forge montée et le compte de démonstration, transmis par l'environnement
  [[ "$output" == *"LCARS_BUILTIN_HUMAN=lcars"* ]]
  [[ "$output" == *"PROV_FORGE_MONTEE=1"* ]]
  refute grep -q 'SUDO-APPELE\|DOCKER-APPELE' <<<"$output"   # sudo est l'affaire du délégué
  porte "$a" --workstation
  [ "$status" -eq 1 ]   # sans forge : arrêt, pas de montée silencieuse
}


@test "sous WSL, des traces d'usage sont montrées ; sans terminal on continue, le terrain est jetable" {
  local a; a="$(_arbre "apt_installs=openssh-server (2026-09-11)" comptes_humains=temoin,alice)"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"traces d'usage"*"openssh-server (2026-09-11)"*"comptes humains : temoin,alice"*"sans terminal, l'installation continue"* ]]
  [[ "$output" == *"Entrée pour continuer"*"WORKSTATION:up"* ]]
  # l'absence de terminal se dit une fois, pas à la question puis à la pause
  [ "$(grep -ciE 'sans terminal|pas de terminal' <<<"$output")" -eq 1 ]
}

@test "une instance déjà posée par LCARS ne pose pas la question : c'est une mise à jour" {
  local a; a="$(_arbre "apt_installs=openssh-server (2026-09-11)" channel=source channel_tree=source)"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" != *"traces d'usage"* ]]
}

@test "une instance vierge ne dit rien ; sur Linux dédié les traces sont une information ; en --dry-run la question est nommée" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench
  [[ "$output" != *"traces d'usage"* ]]
  a="$(_arbre substrat=linux consent=env comptes_humains=temoin,alice)"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"traces d'usage"*"machine déclarée dédiée : à titre d'information"* ]]
  a="$(_arbre comptes_humains=temoin,alice)"
  porte "$a" --workstation --bench --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"traces d'usage"*"--dry-run : la question serait posée ici"* ]]
  [[ "$output" != *"déclarée dédiée"* ]]
}

@test "la pause avant l'exec : annoncée, et sans terminal l'installation continue en le disant" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"Entrée pour continuer"*"Ctrl+C pour annuler"*"Pas de terminal : l'installation continue."*"WORKSTATION:up"* ]]
  porte "$a" --workstation --bench --dry-run
  [[ "$output" != *"Entrée pour continuer"* ]]
}

@test "la question au terminal : vide ou o continue, n et Ctrl-D arrêtent, une réponse inconnue arrête" {
  command -v script >/dev/null || skip "script (util-linux) absent"
  local a rep; a="$(_arbre comptes_humains=temoin,alice)"
  # script prête un terminal : ce qui entre sur son stdin ressort sur /dev/tty du script joué
  for rep in "" o n q; do
    run bash -c "printf '%s\n\n' '$rep' | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
    case "$rep" in
      ""|o) [[ "$output" == *"Continuer ? [O/n]"*"WORKSTATION:up"* ]] || { echo "réponse « $rep » : $output" >&2; return 1; } ;;
      n)    [[ "$output" == *"Rien n'a été fait"* ]] || { echo "réponse « n » : $output" >&2; return 1; }
            [[ "$output" != *"WORKSTATION:up"* ]] || { echo "réponse « n » a lancé l'installation" >&2; return 1; } ;;
      q)    [[ "$output" == *"non comprise"* ]] || { echo "réponse « q » : $output" >&2; return 1; }
            [[ "$output" != *"WORKSTATION:up"* ]] || { echo "réponse « q » a lancé l'installation" >&2; return 1; } ;;
    esac
  done
  # Ctrl-D : un terminal sans réponse est un abandon, pas une absence de terminal
  run bash -c "script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null < /dev/null"
  [[ "$output" == *"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
}

@test "la pause se joue même quand « Continuer ? » a répondu : Entrée part, Ctrl-D à la pause arrête" {
  command -v script >/dev/null || skip "script (util-linux) absent"
  local a; a="$(_arbre comptes_humains=temoin,alice)"
  run bash -c "printf 'o\n\n' | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
  [[ "$output" == *"Continuer ? [O/n]"*"Entrée pour continuer"*"WORKSTATION:up"* ]]
  run bash -c "{ printf 'o\n'; sleep 3; } | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
  [[ "$output" == *"Continuer ? [O/n]"*"Entrée pour continuer"*"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
}

@test "à la pause, un terminal sans réponse (Ctrl-D) est un abandon : le délégué ne part pas" {
  command -v script >/dev/null || skip "script (util-linux) absent"
  local a; a="$(_arbre)"
  run bash -c "script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null < /dev/null"
  [[ "$output" == *"Entrée pour continuer"*"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
}

@test "--env atteint le préflight initial, --human et --only n'y vont pas ; le délégué reçoit les trois" {
  local a; a="$(_arbre)"
  printf 'FORGE_BASE_URL=http://forge.env:3000\n' > "$BATS_TEST_TMPDIR/env"
  run bash "$a/install.sh" --workstation --bench --env "$BATS_TEST_TMPDIR/env" --human zoe --only 60 --dry-run
  [ "$status" -eq 0 ]
  grep -qx "PROVISION:doctor --only 00-preflight --env $BATS_TEST_TMPDIR/env" "$BATS_TEST_TMPDIR/provision.calls"
  [[ "$output" == *"--env $BATS_TEST_TMPDIR/env --human zoe --only 60"* ]]
}

_dist() { # _dist [nom=valeur…] — le tiroir dist/ de la version $TAG : un kit avec un préflight qui dicte ses faits
  local d="$BATS_TEST_TMPDIR/dist" st="$BATS_TEST_TMPDIR/stage"
  rm -rf "$d" "$st"; mkdir -p "$d" "$st/lcars_install/deploy/docker/bench"
  cp "$REPO/deploy/installer-constants.env" "$st/lcars_install/deploy/"
  printf 'cafe1234\n' > "$st/lcars_install/.source-revision"
  _faux_provision "$st/lcars_install" "${_faits_sains[@]}" "$@"
  printf '#!/usr/bin/env bash\necho "WORKSTATION:$*"\n' > "$st/lcars_install/deploy/workstation"
  printf '#!/usr/bin/env bash\necho "IMAGE:${LCARS_IMAGE:-}"\necho "CONTAINER:$*"\n' > "$st/lcars_install/deploy/container"
  printf '#!/usr/bin/env bash\necho "BENCHUP:$*"\n' > "$st/lcars_install/deploy/docker/bench/bench-up.sh"
  chmod 0755 "$st/lcars_install/deploy/workstation" "$st/lcars_install/deploy/container" "$st/lcars_install/deploy/docker/bench/bench-up.sh"
  tar -czf "$d/lcars-fleet-$TAG-otp27-x86_64.tar.gz" -C "$st" lcars_install
  printf '%s' "$d"
}
_machine() { # x86_64 et un HOME à nous, dictés
  printf '#!/usr/bin/env bash\necho x86_64\n' > "$BINDIR/uname"; chmod 0755 "$BINDIR/uname"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export LCARS_DOOR_INSECURE_HTTP=1
}
_serveur() { # sert <dir> en http local ; SERVEUR_URL, SERVEUR_PID, SERVEUR_LOG
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  SERVEUR_LOG="$BATS_TEST_TMPDIR/http.log"
  python3 -m http.server --bind 127.0.0.1 "$port" --directory "$1" > "$SERVEUR_LOG" 2>&1 3>&- &
  SERVEUR_PID=$!
  SERVEUR_URL="http://127.0.0.1:$port"
  local n=0
  until curl -fs "$SERVEUR_URL/" >/dev/null 2>&1; do n=$((n + 1)); [[ "$n" -lt 50 ]] || { echo "serveur de décor muet" >&2; return 1; }; sleep 0.1; done
  : > "$SERVEUR_LOG"
}
teardown() { [[ -z "${SERVEUR_PID:-}" ]] || kill "$SERVEUR_PID" 2>/dev/null || true; }
_porte() { # la porte de la version $TAG générée depuis le gabarit, base = le serveur ; IMAGE_PORTE : l'image publiée qu'elle nomme
  LCARS_DOOR_TEMPLATE="$SRC" LCARS_MINISIGN_PUBKEY="${2:-}" LCARS_DOOR_IMAGE="${IMAGE_PORTE:-}" \
    bash "$REPO/deploy/lib/door-gen.sh" "$TAG" "$SERVEUR_URL" "$1" >/dev/null 2>&1 || { echo "door-gen a échoué" >&2; return 1; }
  printf '%s' "$1/install.sh"
}
_release() { _machine; DIST="$(_dist "$@")"; _serveur "$DIST"; PORTE="$(_porte "$DIST")"; KITS="$HOME/.lcars/kits/$TAG"; }
pipee() { run bash -c "cat '$PORTE' | bash -s -- $*"; }
_daemon_avec_image() { # _daemon_avec_image <oui|non> — une doublure docker dont « image inspect » répond selon l'argument
  local rc=1; [[ "$1" == oui ]] && rc=0
  printf '#!/usr/bin/env bash\n[[ "$1 $2" == "image inspect" ]] && exit %s\nexit 0\n' "$rc" > "$BINDIR/docker"
  chmod 0755 "$BINDIR/docker"
}

@test "release en conteneur : l'image de la version absente du daemon est tirée avant up, et up la reçoit par LCARS_IMAGE" {
  _daemon_avec_image non
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'est pas sur ce daemon : elle sera tirée d'abord (ghcr.io/o/r:$TAG)"* ]]
  [[ "$output" == *"CONTAINER:pull"*"CONTAINER:--bench up"* ]]
  [[ "$output" == *"IMAGE:ghcr.io/o/r:$TAG"* ]]
}

@test "release en conteneur : l'image déjà sur le daemon n'est pas tirée" {
  _daemon_avec_image oui
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --bench
  [ "$status" -eq 0 ]
  refute_out "CONTAINER:pull" <<<"$output"
  [[ "$output" == *"IMAGE:ghcr.io/o/r:$TAG"*"CONTAINER:--bench up"* ]]
}

@test "release sans image publiée : rien n'est tiré, LCARS_IMAGE n'est pas posé, up décide" {
  _daemon_avec_image non
  IMAGE_PORTE="" _release "docker_bin=$BINDIR/docker"
  pipee --bench
  [ "$status" -eq 0 ]
  refute_out "CONTAINER:pull" <<<"$output"
  refute_out "^IMAGE:." <<<"$output"
  [[ "$output" == *"CONTAINER:--bench up"* ]]
}

@test "release en conteneur, --dry-run sur un kit déjà posé : le pull est dit avant la commande, rien n'est joué" {
  _daemon_avec_image non
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --bench
  [ "$status" -eq 0 ]
  pipee --bench --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run : d'abord"*"container pull"*"La commande serait"* ]]
  refute_out "CONTAINER:" <<<"$output"
}

@test "release en mode poste : l'image publiée ne concerne pas ce mode, rien n'est tiré" {
  _daemon_avec_image non
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --workstation --bench
  [ "$status" -eq 0 ]
  refute_out "pull" <<<"$output"
}

@test "la porte générée est le gabarit, hors les lignes marquées" {
  _release
  local norm='/@@DOOR_SUMS_BEGIN@@/,/@@DOOR_SUMS_END@@/d; /@@DOOR_/d'
  diff <(sed "$norm" "$SRC") <(sed "$norm" "$PORTE")
}

@test "une porte de version pipée et coupée ne télécharge rien, à toute coupure" {
  _release
  local n; n="$(wc -c < "$PORTE")"
  local p c
  for p in 10 25 50 75 90 95 98 99; do
    c=$(( n * p / 100 ))
    head -c "$c" "$PORTE" | bash -s -- --workstation --bench >/dev/null 2>&1 || true
    [ ! -s "$SERVEUR_LOG" ] || { echo "fuite à $p % : le serveur a été sollicité" >&2; return 1; }
    [ ! -d "$HOME/.lcars" ] || { echo "fuite à $p % : ~/.lcars créé" >&2; return 1; }
  done
}

@test "pipée : les commandes proposées sont celles d'une porte pipée, pas « bash bash »" {
  _release
  pipee
  [ "$status" -eq 1 ]
  [[ "$output" == *"curl -fsSL <install.sh> | bash -s -- --bench"* ]]
  [[ "$output" != *"bash bash"* ]]
  pipee --workstation
  [[ "$output" == *"| bash -s -- --workstation --bench"* ]]
}

@test "--check pipée ne télécharge rien : le préflight vit dans le kit, et il le dit" {
  _release
  pipee --bench --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--check : rien n'est téléchargé"*"La commande serait : deploy/container --bench up"* ]]
  [ ! -s "$SERVEUR_LOG" ]
  [ ! -d "$HOME/.lcars" ]
}

@test "--repo l'emporte sur la base gravée dans la porte ; une LCARS_DOOR_BASE de l'environnement ne compte pas" {
  _release
  LCARS_DOOR_BASE=https://ailleurs.invalide/base pipee --bench --repo https://exemple.invalide/x.git --dry-run
  [[ "$output" == *"https://exemple.invalide/x/releases/download/$TAG"* ]]
  LCARS_DOOR_BASE=https://ailleurs.invalide/base pipee --bench --dry-run
  [[ "$output" == *"$SERVEUR_URL →"* ]]
  refute_out 'ailleurs\.invalide' <<<"$output"
}

@test "un détarage interrompu n'est jamais repris : la passe suivante détare un arbre complet" {
  _release
  # un tar qui pose le runner puis meurt : l'arbre partiel porte deploy/provision exécutable
  cat > "$BINDIR/tar" <<EOF
#!/usr/bin/env bash
d="\${*: -1}"
mkdir -p "\$d/lcars_install/deploy"
printf '#!/usr/bin/env bash\n' > "\$d/lcars_install/deploy/provision"
chmod 0755 "\$d/lcars_install/deploy/provision"
exit 1
EOF
  chmod 0755 "$BINDIR/tar"
  pipee --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"le kit ne se détare pas"* ]]
  rm "$BINDIR/tar"
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"déjà là, sha256 vérifié"*"WORKSTATION:up --from $KITS/lcars_install"* ]]
}

@test "pipée : le kit de la version est téléchargé, vérifié, détaré, et le délégué part du kit" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"téléchargé, sha256 vérifié"* ]]
  [[ "$output" == *"Source     release $TAG · kit dans $KITS/lcars_install"* ]]
  [[ "$output" == *"WORKSTATION:up --from $KITS/lcars_install"* ]]
  [ -f "$KITS/lcars-fleet-$TAG-otp27-x86_64.tar.gz.sha256" ]
  # sans clé : la porte le dit, et continue
  [[ "$output" == *"provenance non vérifiée (sha256 seul)"* ]]
  # relancée : déjà là, vérifié, rien de retéléchargé
  : > "$SERVEUR_LOG"
  pipee --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà là, sha256 vérifié"* ]]
  [ ! -s "$SERVEUR_LOG" ]
}

@test "pipée en mode conteneur : même kit, exec deploy/container depuis le kit" {
  _release forge_fournie=https://forge.example.net forge_joignable=oui
  pipee --forge-project bob_10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 up" ]]
  [[ "$output" == *"Source     release $TAG · kit dans $KITS/lcars_install"* ]]
}

@test "sha256 faux dans la table : refus qui nomme attendu et obtenu, fichier effacé, rien de détaré" {
  _release
  sed -i "s/^\([0-9a-f]\{32\}\)[0-9a-f]\{32\}\(  lcars-fleet-\)/\1$(printf '0%.0s' {1..32})\2/" "$PORTE"
  pipee --workstation --bench
  [ "$status" -ne 0 ]
  [[ "$output" == *"attendu "*"00000000"*", obtenu "*"rien n'est posé"* ]]
  [ ! -f "$KITS/lcars-fleet-$TAG-otp27-x86_64.tar.gz" ]
  [ ! -d "$KITS/lcars_install" ]
  refute grep -q 'WORKSTATION:' <<<"$output"
}

@test "un kit hors table n'existe pas : rien n'est composé, rien n'est demandé au serveur" {
  _release
  sed -i "/  lcars-fleet-$TAG-otp27-x86_64.tar.gz\$/d" "$PORTE"
  pipee --workstation --bench
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun kit $TAG pour x86_64 dans la table"* ]]
  [ ! -s "$SERVEUR_LOG" ]
}

@test "http est refusé sans LCARS_DOOR_INSECURE_HTTP, et curl porte ses flags de transport" {
  _release
  unset LCARS_DOOR_INSECURE_HTTP
  pipee --workstation --bench
  [ "$status" -ne 0 ]
  [[ "$output" == *"n'est pas https"* ]]
  [ ! -s "$SERVEUR_LOG" ]
  grep -q -- "curl --proto \"\$proto\" -fsSL" "$SRC"
}

@test "minisign : une signature invalide refuse et efface ; une clé sans .minisig refuse ; minisign absent se dit" {
  _release
  local pub="RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
  : > "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz.minisig"
  PORTE="$(_porte "$DIST" "$pub")"
  rm -f "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz.minisig"   # la signature disparue du serveur après la génération
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/minisign"; chmod 0755 "$BINDIR/minisign"
  pipee --workstation --bench
  [ "$status" -ne 0 ]
  [[ "$output" == *".minisig introuvable"* ]]
  printf 'untrusted comment: x\nRUQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3AAAA\ntrusted comment: x\nAAAA\n' > "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz.minisig"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BINDIR/minisign"; chmod 0755 "$BINDIR/minisign"
  pipee --workstation --bench
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature de lcars-fleet-$TAG-otp27-x86_64.tar.gz invalide"* ]]
  [ ! -f "$KITS/lcars-fleet-$TAG-otp27-x86_64.tar.gz" ]
  rm "$BINDIR/minisign"
  # un PATH qui porte tout sauf minisign : l'absence se joue, quel que soit le poste
  local sans="$BATS_TEST_TMPDIR/sans-minisign" d f n; mkdir -p "$sans"
  local -a dirs; IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      n="$(basename "$f")"
      [ "$n" = minisign ] && continue
      [ -e "$sans/$n" ] || ln -sf "$f" "$sans/$n"
    done
  done
  [ ! -e "$sans/minisign" ]
  run env PATH="$sans" bash -c "cat '$PORTE' | bash -s -- --workstation --bench"
  [ "$status" -eq 0 ]
  [[ "$output" == *"minisign absent : provenance non vérifiée"* ]]
}

@test "--dry-run pipée : les artefacts et leurs sha256, rien de téléchargé, la sortie dite" {
  _release
  pipee --workstation --bench --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local a="lcars-fleet-$TAG-otp27-x86_64.tar.gz"
  [[ "$output" == *"$a "*"sha256 $(sha256sum "$DIST/$a" | cut -d' ' -f1)"* ]]
  [[ "$output" == *"rien n'est téléchargé"*"deploy/workstation up --from <kit>"* ]]
  [ ! -s "$SERVEUR_LOG" ]
  [ ! -d "$HOME/.lcars" ]
  # une fois le kit posé, --dry-run dit la commande exacte, --from compris
  pipee --workstation --bench
  [ "$status" -eq 0 ]
  pipee --workstation --bench --dry-run
  [[ "$output" == *"kit déjà posé"*"$KITS/lcars_install/deploy/workstation up --from $KITS/lcars_install"* ]]
}

@test "le script du dépôt, pipé avec --dry-run, dit l'installeur de la dernière release qu'il rejouerait, sans rien télécharger" {
  _machine
  run bash -c "cat '$SRC' | bash -s -- --workstation --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rien n'est téléchargé"*"curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | bash -s -- --workstation --dry-run"* ]]
  [ ! -e "$HOME/.lcars" ]
}

@test "--from-release depuis un clone : l'installeur de la dernière release est vérifié par sa somme, rejoué, et pose le kit de sa version" {
  _machine; DIST="$(_dist)"
  local forge="$BATS_TEST_TMPDIR/forge"
  mkdir -p "$forge/o/r/releases/latest" "$forge/o/r/releases/download"
  _serveur "$forge"
  ln -s "$DIST" "$forge/o/r/releases/download/$TAG"
  LCARS_DOOR_TEMPLATE="$SRC" bash "$REPO/deploy/lib/door-gen.sh" "$TAG" "$SERVEUR_URL/o/r/releases/download/$TAG" "$DIST" >/dev/null 2>&1
  ln -s "$DIST" "$forge/o/r/releases/latest/download"
  run bash "$SRC" --from-release --workstation --bench --repo "$SERVEUR_URL/o/r" < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"dernière release de $SERVEUR_URL/o/r — installeur vérifié par sa somme"* ]]
  [[ "$output" == *"Source     release $TAG"* ]]
  [ -x "$HOME/.lcars/kits/$TAG/lcars_install/deploy/provision" ]
}

@test "--from-release depuis un clone : un installeur qui ne correspond pas à sa somme n'est pas rejoué" {
  _machine
  local forge="$BATS_TEST_TMPDIR/forge"; mkdir -p "$forge/o/r/releases/latest/download"
  printf '#!/usr/bin/env bash\necho EXECUTE\n' > "$forge/o/r/releases/latest/download/install.sh"
  printf '%064d  install.sh\n' 0 > "$forge/o/r/releases/latest/download/install.sh.sha256"
  _serveur "$forge"
  run bash "$SRC" --from-release --workstation --repo "$SERVEUR_URL/o/r" < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne correspond pas à sa somme publiée"* ]]
  [[ "$output" != *"EXECUTE"* ]]
}

@test "--from-release depuis un clone prend le kit de la version, pas l'arbre courant" {
  _release
  cp "$PORTE" "$BATS_TEST_TMPDIR/arbre-porte.sh"
  mkdir -p "$BATS_TEST_TMPDIR/deploy"; _faux_provision "$BATS_TEST_TMPDIR" "${_faits_sains[@]}"
  run bash "$BATS_TEST_TMPDIR/arbre-porte.sh" --from-release --workstation --bench < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Source     release $TAG"* ]]
}
