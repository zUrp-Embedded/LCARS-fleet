#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/install.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-14
# STATUS: témoins d'install.sh — ce qu'il mesure sans privilège, ce qu'il montre, ce qu'il refuse, la relance en root par sudo, où il délègue

# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  # la distribution de la machine qui joue la porte : un cas qui la lit la pose lui-même
  unset WSL_DISTRO_NAME
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/install.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  # un docker qui rougit s'il est appelé : l'installeur ne sonde pas lui-même
  printf '#!/usr/bin/env bash\necho DOCKER-APPELE >&2; exit 97\n' > "$BINDIR/docker"
  # sudo note son argv sur une ligne, puis joue la suite comme le vrai : root, un environnement remis à
  # zéro, SUDO_USER posé ; seuls le PATH des doublures, le HOME, TMPDIR et le décor du témoin passent.
  # SUDO_ALTERE nomme un fichier qu'un programme du compte modifie pendant l'invite de sudo.
  cat > "$BINDIR/sudo" <<EOF
#!/usr/bin/env bash
[[ "\$1" != -n ]] || { echo "SUDO-N:\$*" >> '$BATS_TEST_TMPDIR/sudo.calls'; exit "\${SUDO_N_RC:-0}"; }
a="\$*"; echo "SUDO:\${a//\$'\n'/\\\\n}" >> '$BATS_TEST_TMPDIR/sudo.calls'
[[ -z "\${SUDO_ALTERE:-}" ]] || printf 'altéré\n' >> "\$SUDO_ALTERE"
exec unshare -Ur env -i PATH="\$PATH" HOME="\$HOME" \${TMPDIR:+TMPDIR="\$TMPDIR"} \${LCARS_DECOR_ROOT:+LCARS_DECOR_ROOT="\$LCARS_DECOR_ROOT"} \
  SUDO_USER="\$(id -un)" "\$@"
EOF
  chmod 0755 "$BINDIR/docker" "$BINDIR/sudo"
  export PATH="$BINDIR:$PATH"
  TAG="9.9.9-test"
}

sudo_ligne() { sed -n 's/^SUDO://p' "$BATS_TEST_TMPDIR/sudo.calls" 2>/dev/null; }

# shellcheck disable=SC2054  # les virgules sont dans les valeurs (groupes, comptes), pas entre les éléments
_faits_sains=(git=oui curl=oui sudo=oui docker=oui docker_bin=/usr/bin/docker docker_host=unix:///var/run/docker.sock
  docker_server=29.0.0 "docker_flavor=Docker Engine" docker_why= compose=oui substrat=wsl consent=sans-objet
  distro=Ubuntu distro_version=26.04 noyau=6.6.0 arch=x86_64 cpu=4 ram_mb=8192 disque_mb=102400 systemd=oui
  utilisateur=temoin groupes=temoin,sudo,docker forge_fournie= forge_joignable=sans-objet
  "port_forge=21000 libre" "port_deck=20999 libre" "port_ssh=2222 libre" projet=lcars projet_pris=
  apt_installs= comptes_humains=temoin channel=aucun channel_tree=source jq=oui racine=/opt/lcars revision=cafe1234)

# provision de décor : « mesure » sans root écrit ces faits et son verdict (FAUX_PREFLIGHT_REFUS : sa ligne de
# refus) ; en root, sans rien lire d'avant sudo, l'écriture sous la racine et le deck, qu'il rend à la
# landing, ou à un processus étranger quand le fichier refus-root existe
_faux_provision() { # _faux_provision <arbre> [nom=valeur…]
  local arbre="$1"; shift
  mkdir -p "$arbre/deploy"
  { echo '#!/usr/bin/env bash'
    echo "echo \"PROVISION:\$*\" >> '$BATS_TEST_TMPDIR/provision.calls'"
    echo "echo \"PROVISION-ENV:PROV_FORGE_MONTEE=\${PROV_FORGE_MONTEE:-}\" >> '$BATS_TEST_TMPDIR/provision.calls'"
    echo '[[ "$1" == mesure ]] || exit 0'
    echo 'tous=" $* "; while [[ "$1" != --faits ]]; do shift; done; faits="$2"; shift 2'
    echo 'if [[ "$EUID" -eq 0 && "$tous" != *" --sans-privilege "* ]]; then'
    echo '  printf "phase=root\nechange=/opt oui\n" > "$faits"'
    echo "  if [[ -e '$BATS_TEST_TMPDIR/refus-root' ]]; then"
    echo '    printf "port_deck=20999 pris par python3 (pid 4243, compte nobody)\npreflight=refuse\n" >> "$faits"'
    echo '    echo "FAIL  00-preflight: port 20999 (deck) tenu par python3 (pid 4243, compte nobody) — ce projet doit être seul à le tenir"; exit 2'
    echo '  fi'
    echo '  printf "port_deck=20999 nous lcars-landing (service)\n" >> "$faits"'
    echo '  echo preflight=conforme >> "$faits"; exit 0'
    echo 'fi'
    echo 'cat > "$faits" <<'"'"'FACTS'"'"''
    printf '%s\n' phase=sans-privilege "$@"
    echo 'FACTS'
    # la déclaration d'un Linux dédié se lit dans l'environnement du préflight, comme le vrai
    echo '[[ "${LCARS_ALLOW_ANY_HOST:-}" != 1 ]] || echo consent=env >> "$faits"'
    echo '[[ -z "${FAUX_PREFLIGHT_REFUS:-}" ]] || { echo "OK    00-preflight: décor"; echo "$FAUX_PREFLIGHT_REFUS"; echo preflight=refuse >> "$faits"; exit 1; }'
    echo 'echo preflight=conforme >> "$faits"'
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
  printf '#!/usr/bin/env bash\necho "WORKSTATION:$*"; env | grep -E "^(FORGE_BASE_URL|FORGE_PUBLIC_URL|LCARS_ALLOW_ANY_HOST|LCARS_BUILTIN_HUMAN|PROV_FORGE_ADMIN_RESET|DOCKER_HOST|SUDO_USER)=" | sort | sed "s/^/ENV:/"\n' > "$a/deploy/workstation"
  printf '#!/usr/bin/env bash\necho "CONTAINER:$*"\n' > "$a/deploy/container"
  printf '#!/usr/bin/env bash\necho "BENCHUP:$*"; echo "DOCKER_BIN=${DOCKER_BIN:-}"\n' > "$a/deploy/docker/bench/bench-up.sh"
  chmod 0755 "$a/deploy/workstation" "$a/deploy/container" "$a/deploy/docker/bench/bench-up.sh"
  printf '%s' "$a"
}

porte() { # porte <arbre> [args…] — sans terminal : une session à part, stdin fermé
  local a="$1"; shift
  run setsid -w bash "$a/install.sh" "$@" < /dev/null
}


root_de_namespace() { # root_de_namespace → UNSHARE, ou le cas sauté
  UNSHARE="$(command -v unshare || true)"
  [[ -n "$UNSHARE" ]] || skip "unshare absent de ce poste : root ne se joue pas ici"
  "$UNSHARE" -Ur true 2>/dev/null || skip "user namespaces indisponibles : root ne se joue pas ici"
}

@test "le mode conteneur ne se joue jamais en root" {
  root_de_namespace
  local a; a="$(_arbre)"
  run "$UNSHARE" -Ur bash "$a/install.sh" --bench < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cet installeur se lance sans root."* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}

@test "lancé à la main en root : la grille et la pause d'abord, sans sudo, puis la mesure root refuse un port tenu par un autre avant le délégué" {
  root_de_namespace
  local a; a="$(_arbre)"
  : > "$BATS_TEST_TMPDIR/refus-root"
  run "$UNSHARE" -Ur bash "$a/install.sh" --workstation --bench < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Installation dans ce système"*"Entrée pour continuer"*"port 20999 (deck) tenu par python3 (pid 4243, compte nobody)"*"La mesure en root refuse ce terrain"* ]]
  grep -qx 'PROVISION:mesure --faits [^ ]* --sans-privilege' "$BATS_TEST_TMPDIR/provision.calls"
  grep -qx 'PROVISION:mesure --faits [^ ]*' "$BATS_TEST_TMPDIR/provision.calls"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  refute_out 'WORKSTATION:' <<<"$output"
  rm "$BATS_TEST_TMPDIR/refus-root"
  run "$UNSHARE" -Ur bash "$a/install.sh" --workstation --bench < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Entrée pour continuer"*"WORKSTATION:up --faits "* ]]
}

@test "la relance marquée après la pause ne remontre ni grille ni pause : la mesure root décide directement" {
  root_de_namespace
  local a; a="$(_arbre)"
  : > "$BATS_TEST_TMPDIR/refus-root"
  run "$UNSHARE" -Ur bash "$a/install.sh" --workstation --bench --apres-pause < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"La mesure en root refuse ce terrain"* ]]
  refute_out 'Entrée pour continuer|Installation dans ce système' <<<"$output"
  refute grep -q -- '--sans-privilege' "$BATS_TEST_TMPDIR/provision.calls"
}

@test "--ports-tenus n'existe plus : aucune option ne dispense root de sa mesure, sans root comme en root" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench --ports-tenus ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option inconnue : --ports-tenus"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
}

@test "le script d'une release se lance sans root : root ne joue qu'une copie du kit qu'il vérifie" {
  root_de_namespace
  _release
  run "$UNSHARE" -Ur bash -c "cat '$PORTE' | bash -s -- --workstation --bench"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Le script d'une release se lance sans root."* ]]
  [ ! -s "$SERVEUR_LOG" ]
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
  grep -qx -- '--docker-host' <<<"$drapeaux"
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

@test "un drapeau inconnu fait rater le script en se nommant" {
  run bash "$SRC" --inconnu < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option inconnue : --inconnu"* ]]
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


@test "le bilan du conteneur lit les faits de la mesure et rien d'autre — ni docker ni sudo ne sont appelés" {
  # docker=oui dans les faits alors que le docker du décor rougit s'il est appelé : le bilan le dit oui
  local a; a="$(_arbre)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker     serveur 29.0.0 · Docker Engine · unix:///var/run/docker.sock"* ]]
  refute grep -q 'DOCKER-APPELE' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
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

@test "la mesure reçoit le substrat, le projet et les ports demandés, dans son fichier de faits" {
  local a; a="$(_arbre)"
  porte "$a" --check --bench --substrate wsl --forge-project bob_9 --port-forge 20090 --port-deck 20091 --port-ssh 20092
  grep -qx -- "PROVISION:mesure --faits [^ ]* --substrate wsl --forge-project bob_9 --port-forge 20090 --port-deck 20091 --port-ssh 20092" "$BATS_TEST_TMPDIR/provision.calls"
}

@test "sous --bench, la mesure sait que la forge est celle du poste : root vérifie son port avec celui du deck" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench --check
  [ "$(grep -c '^PROVISION-ENV:PROV_FORGE_MONTEE=1$' "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  rm "$BATS_TEST_TMPDIR/provision.calls"
  FORGE_BASE_URL=https://forge.example.net porte "$a" --workstation --check
  refute grep -q '^PROVISION-ENV:PROV_FORGE_MONTEE=1$' "$BATS_TEST_TMPDIR/provision.calls"
}

@test "sans fait rendu, l'installeur s'arrête et montre le rapport du préflight" {
  local a="$BATS_TEST_TMPDIR/arbre"; rm -rf "$a"; mkdir -p "$a/deploy"
  cp "$SRC" "$a/install.sh"
  cp "$REPO/deploy/installer-constants.env" "$a/deploy/"
  printf '#!/usr/bin/env bash\necho "le préflight est mort"; exit 3\n' > "$a/deploy/provision"
  printf '#!/usr/bin/env bash\necho "CONTAINER:$*"\n' > "$a/deploy/container"
  chmod 0755 "$a/deploy/provision" "$a/deploy/container"
  porte "$a" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fait"*"le préflight est mort"* ]]
}

@test "un substrat que provision refuse : aucun fait, et l'installeur cite ce refus au lieu de dire que provision n'a pas tourné" {
  # le vrai runner, sous un décor vide : ni /.dockerenv ni noyau Microsoft, ce système se mesure linux
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"; mkdir -p "$LCARS_DECOR_ROOT"
  run bash "$SRC" --check --substrate wsl < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fait"*"--substrate wsl : ce système se mesure « linux »"* ]]
  refute_out "n'a pas tourné" <<<"$output"
}

@test "un arbre sans le délégué de son mode s'arrête avant la mesure et le nomme ; un runner absent, la mesure le dit" {
  local a; a="$(_arbre)"
  rm "$a/deploy/workstation"
  porte "$a" --workstation --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'arbre est incomplet : $a/deploy/workstation absent ou non exécutable"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
  a="$(_arbre)"
  chmod 0644 "$a/deploy/provision"
  porte "$a" --bench --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fait"*"$a/deploy/provision"* ]]
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
  # le disque se mesure sous la racine que le préflight nomme, pas sur /
  [[ "$output" == *"x86_64 · 4 cœurs · 8 Go de RAM · 100 Go libres pour /opt/lcars"* ]]
  [[ "$output" == *"utilisateur temoin · groupes sudo, docker"* ]]
  [[ "$output" == *"Outils     git, curl, jq présents"* ]]   # sudo n'est requis que dans ce système, jq qu'en conteneur
  [[ "$output" == *"Forge      aucune"* ]]
  porte "$a" --workstation --check
  [[ "$output" == *"Outils     curl, sudo présents"* ]]
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
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"; mkdir -p "$LCARS_DECOR_ROOT"
  run bash "$SRC" --check < /dev/null
  [[ "$output" == *"Source     clone git · branche $(git -C "$REPO" rev-parse --abbrev-ref HEAD) · commit $(git -C "$REPO" rev-parse --short=8 HEAD)"* ]]
  [[ "$output" != *"Source     $REPO"* ]]
}

@test "la forge : montée par --bench, fournie et joignable, ou aucune — et les ports avec leur état" {
  local a; a="$(_arbre "port_deck=20999 pris par autre-fleet-lcars-1 (projet autre-fleet)")"
  porte "$a" --check --bench
  [[ "$output" == *"Forge      montée par l'installeur avec son runner CI (--bench)"* ]]
  [[ "$output" == *"21000 (forge) libre"*"20999 (deck) pris par autre-fleet-lcars-1 (projet autre-fleet)"* ]]
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
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "docker refusé à l'utilisateur n'arrête pas l'installation dans ce système : root s'en sert et le vérifie après sudo" {
  # banc .63 : docker posé par 12 sur une machine vierge, l'utilisateur hors du groupe docker ; la relance
  # de l'installeur s'arrêtait avant la grille sur un accès dont seul root a besoin
  local a; a="$(_arbre docker=refuse "docker_why=la socket est root:docker")"
  porte "$a" --bench --workstation
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Docker     refusé à « temoin » · root s'en sert, vérifié après sudo"* ]]
  refute_out 'refuse cet utilisateur' <<<"$output"
  [[ "$output" == *"WORKSTATION:up"* ]]
}

@test "sur Linux dédié, docker absent arrête le conteneur et passe pour le système, qui le posera" {
  local a; a="$(_arbre substrat=linux consent=env docker=absent "docker_why=aucun daemon")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker est absent"*"LCARS_ALLOW_ANY_HOST=1"* ]]
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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

@test "le délégué du conteneur reçoit le DOCKER_HOST que la mesure a vu répondre, pas celui de l'environnement" {
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
  # une machine que LCARS a déjà posée a été déclarée à sa pose
  a="$(_arbre substrat=linux consent=posee)"
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

@test "un préflight qui refuse le terrain arrête l'installation dans ce système avant la grille et avant sudo, en citant son constat ; le conteneur continue" {
  local a; a="$(_arbre)"
  FAUX_PREFLIGHT_REFUS="FAIL  00-preflight: cette machine est installée par « kit », et cet arbre poserait « source »" porte "$a" --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Le préflight refuse ce terrain pour l'installation dans ce système"*"installée par « kit », et cet arbre poserait « source »"* ]]
  refute_out 'OK    00-preflight|Modifie|WORKSTATION:' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  FAUX_PREFLIGHT_REFUS="DRIFT 00-preflight: RAM 1024 Mo < 1536 Mo" porte "$a" --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTAINER:--bench up"* ]]
}

@test "un port demandé déjà tenu par un autre, visible sans privilège, arrête et nomme les drapeaux qui déplacent" {
  local a; a="$(_arbre "port_ssh=2222 pris par vanille_1-fleet-lcars-1 (projet vanille_1-fleet)")"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"déjà tenu : ssh 2222 pris par vanille_1-fleet-lcars-1"*"--port-ssh"* ]]
}

@test "un port tenu par un processus que la mesure sans privilège ne voit pas : dit, jamais un refus dans ce système, vérifié après sudo ; en conteneur, un arrêt" {
  local a; a="$(_arbre "port_deck=20999 tenu")"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"20999 (deck) tenu, propriétaire vérifié après sudo"* ]]
  [ "$(grep -c '^PROVISION:mesure --faits [^ ]*$' "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  [[ "$output" == *"port 20999 (deck) tenu par lcars-landing (service), de ce projet"*"WORKSTATION:up"* ]]
  a="$(_arbre "port_deck=20999 tenu" forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"déjà tenu : deck 20999 tenu par un processus que ce compte ne voit pas"* ]]
}

@test "en root, un port tenu par un autre que ce projet est un refus : le délégué ne part pas" {
  local a; a="$(_arbre "port_deck=20999 tenu")"
  : > "$BATS_TEST_TMPDIR/refus-root"
  porte "$a" --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"port 20999 (deck) tenu par python3 (pid 4243, compte nobody)"* ]]
  [[ "$output" == *"La mesure en root refuse ce terrain"*"FAIL  00-preflight: port 20999 (deck) tenu par python3 (pid 4243, compte nobody) — ce projet doit être seul à le tenir"* ]]
  refute_out 'WORKSTATION:|PYTHON3|pid=' <<<"$output"
}

@test "la grille montre le canal de l'arbre et celui de la machine, dans ce système" {
  local a; a="$(_arbre channel=aucun channel_tree=kit)"
  porte "$a" --workstation --bench --check
  [[ "$output" == *"Source     archive (kit) · révision cafe1234"$'\n'"             canal kit · machine jamais installée"* ]]
  a="$(_arbre channel=source channel_tree=source)"
  porte "$a" --workstation --bench --check
  [[ "$output" == *"canal source · machine installée par le canal source"* ]]
}

@test "un DOCKER_HOST donné qui ne répond pas est nommé dans la grille, à côté de la socket qui sert à sa place" {
  local a; a="$(_arbre docker_host_ecarte=unix:///nulle-part/docker.sock)"
  porte "$a" --workstation --bench --check
  [[ "$output" == *"Docker     serveur 29.0.0 · Docker Engine · unix:///var/run/docker.sock"$'\n'"             DOCKER_HOST=unix:///nulle-part/docker.sock ne répond pas : la socket par défaut sert à sa place"* ]]
  [[ "$(sudo_ligne)" == *"--docker-host unix:///var/run/docker.sock" ]]
}

@test "une instance déjà posée n'est pas réinstallée : le refus nomme sa mise à jour, volumes gardés, jamais sa destruction" {
  local a; a="$(_arbre projet_pris=lcars-fleet forge_fournie=https://forge.example.net forge_joignable=oui)"
  LCARS_IMAGE=lcars-fleet:neuve porte "$a" --port-deck 20091
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'instance « lcars-fleet » existe déjà"*"volumes et magasin gardés"*"LCARS_IMAGE=lcars-fleet:neuve $a/deploy/container -p lcars-fleet up"* ]]
  refute_out 'reset|CONTAINER:' <<<"$output"
  # sans forge indiquée, la mise à jour de l'instance vient avant la demande d'une forge
  a="$(_arbre projet_pris=lcars-fleet)"
  porte "$a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"L'instance « lcars-fleet » existe déjà"* ]]
  refute_out 'Aucune n.est indiquée' <<<"$output"
  a="$(_arbre projet_pris=lcars-fleet,lcars-forge,lcars-runner)"
  porte "$a" --bench --forge-project lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"Le banc « lcars » existe déjà"*"$a/deploy/docker/bench/bench-swap-image.sh --image <image> --forge-project lcars"* ]]
  refute_out 'bench-down|CONTAINER:' <<<"$output"
}

@test "une release en conteneur sur son instance déjà posée : la mise à jour tire l'image de la version, puis la monte" {
  _daemon_avec_image oui
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker" projet_pris=lcars-fleet forge_fournie=https://forge.example.net forge_joignable=oui
  pipee
  [ "$status" -eq 1 ]
  [[ "$output" == *"LCARS_IMAGE=ghcr.io/o/r:$TAG $KITS/lcars_install/deploy/container pull && LCARS_IMAGE=ghcr.io/o/r:$TAG $KITS/lcars_install/deploy/container -p lcars-fleet up"* ]]
}

@test "un projet d'une autre installation sous la même base arrête le mode conteneur, pas le mode système" {
  local a; a="$(_arbre projet_pris=lcars-forge forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"« lcars-forge » existe déjà sur ce daemon, sous la base « lcars »"*"--forge-project <autre base>"* ]]
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ]
}

@test "outils manquants : arrêt qui les nomme ; sans sudo, l'installation dans ce système s'arrête avant la grille" {
  local a; a="$(_arbre git=absent)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outils manquants : git"* ]]
  a="$(_arbre sudo=absent)"
  porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outils manquants : sudo."* ]]
  refute_out 'Modifie|Entrée pour continuer' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "sans terminal, un sudo qui demande un mot de passe arrête l'installation dans ce système avant la grille, en une phrase" {
  local a; a="$(_arbre)"
  SUDO_N_RC=1 porte "$a" --bench --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"Sans terminal, sudo ne peut pas demander de mot de passe, et « sudo -n » est refusé"* ]]
  refute_out 'Modifie|Entrée pour continuer|WORKSTATION:' <<<"$output"
  [ "$(cat "$BATS_TEST_TMPDIR/sudo.calls")" = "SUDO-N:-n true" ]
  # le conteneur ne demande jamais root : ni sonde, ni sudo
  a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  rm -f "$BATS_TEST_TMPDIR/sudo.calls"
  SUDO_N_RC=1 porte "$a"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "jq absent : arrête le conteneur, banc ou forge fournie, avant la confirmation en le nommant ; laisse passer le système, qui le pose" {
  local a; a="$(_arbre jq=absent forge_fournie=http://forge.example forge_joignable=oui)"
  local mode
  for mode in --bench ""; do
    porte "$a" $mode
    [ "$status" -eq 1 ] || { echo "« $mode » : $output"; return 1; }
    [[ "$output" == *"Outils manquants : jq"* ]]
    refute_out "Entrée pour continuer|CONTAINER:" <<<"$output"
  done
  porte "$a" --bench --workstation
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSTATION:up"* ]]
}

@test "git absent : arrête le conteneur, qui pousse depuis l'hôte ; laisse passer le système, que 10-packages équipe (machine vierge, banc .63)" {
  local a; a="$(_arbre git=absent)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outils manquants : git"* ]]
  porte "$a" --bench --workstation
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out 'Outils manquants' <<<"$output"
  [[ "$output" == *"WORKSTATION:up"* ]]
}

vrai_poste() { # vrai_poste <arbre> — le vrai délégué du poste et sa lib dans l'arbre, une acceptation de décor, sous un décor
  cp "$REPO/deploy/workstation" "$1/deploy/workstation"
  cp -a "$REPO/deploy/lib" "$1/deploy/lib"
  cp "$REPO/deploy/system.manifest" "$1/deploy/"
  printf '#!/usr/bin/env bash\necho "ACCEPT:$*"\n' > "$1/deploy/accept"
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"; mkdir -p "$LCARS_DECOR_ROOT/etc/lcars"
}

@test "la chaîne entière : l'argv de la relance en root est lu par le vrai délégué, qui passe les faits root à l'apply sans remesure" {
  local a; a="$(_arbre)"
  vrai_poste "$a"
  porte "$a" --workstation --bench --human alice --port-deck 20091 --only 60
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $a/install.sh --workstation --bench --human alice --port-deck 20091 --only 60 --apres-pause --docker-host unix:///var/run/docker.sock" ]
  local faits
  faits="$(sed -n 's/^PROVISION:apply --faits \([^ ]*\) .*/\1/p' "$BATS_TEST_TMPDIR/provision.calls")"
  [ -n "$faits" ]
  [ "$(grep -c '^PROVISION:mesure ' "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  grep -qx "PROVISION:apply --faits $faits --human alice --only 60 --port-deck 20091" "$BATS_TEST_TMPDIR/provision.calls"
  [[ "$output" == *"ACCEPT:--announce-file"* ]]
  [ ! -e "$faits" ]
}

@test "les choix de l'opérateur passent à sudo en options, aucune variable ne le traverse, et le délégué en root les reçoit" {
  local a; a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  FORGE_BASE_URL=https://forge.example.net FORGE_PUBLIC_URL=https://forge.public.example LCARS_BUILTIN_HUMAN=demo \
    PROV_FORGE_ADMIN_RESET=1 FORGE_ADMIN_TOKEN=tres-secret porte "$a" --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $a/install.sh --workstation --bench --apres-pause --docker-host unix:///var/run/docker.sock --forge https://forge.example.net --forge-publique https://forge.public.example --humain-demo demo --forge-admin-reset" ]
  refute grep -qE '^SUDO:.* [A-Z_]+=' "$BATS_TEST_TMPDIR/sudo.calls"
  [[ "$output" == *"ENV:DOCKER_HOST=unix:///var/run/docker.sock"*"ENV:FORGE_BASE_URL=https://forge.example.net"*"ENV:FORGE_PUBLIC_URL=https://forge.public.example"*"ENV:LCARS_BUILTIN_HUMAN=demo"*"ENV:PROV_FORGE_ADMIN_RESET=1"*"ENV:SUDO_USER=$(id -un)"* ]]
  refute_out 'tres-secret' <<<"$output"
}


@test "--humain-demo sans --bench est refusé avant toute mesure, en option comme en variable, dans les deux modes ; avec --bench, il passe à la relance" {
  local a; a="$(_arbre forge_fournie=https://forge.maison forge_joignable=oui)"
  local depart
  for depart in "--workstation --humain-demo alice" "--humain-demo alice"; do
    # shellcheck disable=SC2086 # les options sont des mots
    FORGE_BASE_URL=https://forge.maison porte "$a" $depart
    [ "$status" -eq 1 ] || { echo "$depart : $output"; return 1; }
    [[ "$output" == *"--humain-demo « alice » (LCARS_BUILTIN_HUMAN) n'a d'objet qu'avec --bench"*"celui d'une forge fournie compris"*"la même commande avec --bench, ou sans --humain-demo"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
    [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  done
  LCARS_BUILTIN_HUMAN=alice porte "$a" --workstation
  [ "$status" -eq 1 ]
  [[ "$output" == *"--humain-demo « alice » (LCARS_BUILTIN_HUMAN) n'a d'objet qu'avec --bench"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/provision.calls" ]
  porte "$a" --workstation --bench --humain-demo alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $a/install.sh --workstation --bench --apres-pause --docker-host unix:///var/run/docker.sock --humain-demo alice" ] || { sudo_ligne; return 1; }
  [[ "$output" == *"ENV:LCARS_BUILTIN_HUMAN=alice"* ]]
}

@test "sans --workstation le mode est le conteneur : sa grille, et l'autre mode nommé" {
  local a; a="$(_arbre projet=bob_10)"
  porte "$a" --bench --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur"*"Modifie"*"bob_10-fleet"*"Requiert"*"docker · la forge"*"Retour     "* ]]
  [[ "$output" == *"Pour installer dans ce système à la place :"*"--workstation"* ]]
  [[ "$output" != *"Choix ["* ]]
}

@test "le retour du conteneur est celui de son cas : le banc se détruit entier, une instance sur forge fournie se remet à zéro sans son magasin" {
  local a; a="$(_arbre projet=bob_10)"
  porte "$a" --bench --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retour     $a/deploy/docker/bench/bench-down.sh --project bob_10 --yes : le conteneur, la forge, le runner et le magasin"* ]]
  refute_out 'reset' <<<"$output"
  a="$(_arbre projet=bob_10 forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a" --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retour     $a/deploy/container -p bob_10-fleet reset, 30 s : le conteneur et ses volumes ; le magasin reste"* ]]
  refute_out 'bench-down' <<<"$output"
}

@test "le retour du système sous WSL : avec --bench, la forge et le runner qui restent dans Docker Desktop sont nommés avec leur geste" {
  local a; a="$(_arbre projet=bob_10)"
  porte "$a" --bench --workstation --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retour     aucun désinstalleur : la distribution se recrée (wsl --unregister <distro>) ; la forge et le runner restent dans Docker Desktop : docker compose -p bob_10-forge down -v, docker compose -p bob_10-runner down -v"* ]]
  a="$(_arbre projet=bob_10 forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a" --workstation --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retour     aucun désinstalleur : la distribution se recrée (wsl --unregister <distro>)"$'\n'* ]]
  refute_out 'down -v' <<<"$output"
  # la distribution que la phase sans privilège connaît est nommée, prête à coller
  WSL_DISTRO_NAME=Ubuntu-24.04 porte "$a" --workstation --forge-project bob_10 --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retour     aucun désinstalleur : la distribution se recrée (wsl --unregister \"Ubuntu-24.04\")"$'\n'* ]]
}

@test "--workstation : sa grille, root par sudo après la pause, /etc/wsl.conf sous WSL et la machine sur Linux — et rien de ce que fait le conteneur" {
  local a; a="$(_arbre)"
  porte "$a" --bench --workstation --check
  [[ "$output" == *"Installation dans ce système"*"Modifie    /etc/wsl.conf, /opt/lcars, des groupes et des comptes de service, des paquets apt, ~/.config, ~/.docker et ~/.claude de l'utilisateur"*"Requiert   root, par sudo, une fois après la pause"*"wsl --unregister"* ]]
  [[ "$output" == *"Pour installer en conteneur à la place :"* ]]
  sed -n '/Installation dans ce système/,/Pour installer en conteneur/p' <<<"$output" | refute_out 'runner CI|humain de d|deploy/container'
  a="$(_arbre substrat=linux consent=env)"
  porte "$a" --bench --workstation --check
  [[ "$output" == *"Modifie    /opt/lcars, des groupes et des comptes de service, des paquets apt, ~/.claude de l'utilisateur, docker-ce"*"la machine se réinstalle"* ]]
}

@test "--check du conteneur s'arrête après la grille, sans sudo, rien n'est appelé" {
  local a; a="$(_arbre)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"--check : rien n'est fait"* ]]
  refute grep -q 'BENCHUP:\|CONTAINER:\|WORKSTATION:' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "--check dans ce système : grille, sudo, la mesure root complète la grille, rien n'est posé" {
  local a; a="$(_arbre "port_deck=20999 tenu")"
  porte "$a" --bench --workstation --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Requiert   root"*"--check : la mesure se complète en root (root, par sudo, une fois après la pause)"*"En root    /opt : écriture et « mv --exchange » joués par root"*"port 20999 (deck) tenu par lcars-landing (service), de ce projet"*"--check : rien n'est fait"* ]]
  [ "$(sudo_ligne)" = "bash $a/install.sh --bench --workstation --check --apres-pause --docker-host unix:///var/run/docker.sock" ]
  refute_out 'WORKSTATION:|Entrée pour continuer' <<<"$output"
  [ "$(grep -c "Système    " <<<"$output")" -eq 1 ]
  # sans terminal, --check dit qu'il continue, comme le parcours complet
  [[ "$output" == *"--check : la mesure se complète en root (root, par sudo, une fois après la pause) ; rien n'est posé."$'\n'"  Pas de terminal : --check continue."* ]]
}

@test "--dry-run dit la commande exacte, mot à mot, sans l'exécuter ; dans ce système, après sudo et la mesure root" {
  local a; a="$(_arbre)"
  porte "$a" --bench --dry-run --forge-project bob_10 --port-deck 20101
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run : rien n'est fait. La commande serait :"*"$a/deploy/container --forge-project bob_10 --port-deck 20101 --bench up"* ]]
  refute grep -q 'CONTAINER:' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  # la commande dite se rejoue telle quelle : elle refait sa mesure, les choix de l'opérateur en options, aucun fichier de faits
  FORGE_PUBLIC_URL=http://forge.public.test porte "$a" --workstation --bench --dry-run --substrate wsl --only 10-packages
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--dry-run : la commande se dit après la mesure en root (root, par sudo, une fois après la pause)"*"--dry-run : rien n'est fait. La commande serait :"$'\n'"    $a/deploy/workstation up --substrate wsl --only 10-packages --bench --forge-publique http://forge.public.test" ]]
  refute_out 'lcars-facts|--faits' <<<"$output"
  grep -q '^SUDO:' "$BATS_TEST_TMPDIR/sudo.calls"
  refute_out 'WORKSTATION:|Entrée pour continuer' <<<"$output"
}


@test "mode conteneur : exec deploy/container avec le projet et les ports, puis up, sans sudo" {
  local a; a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  porte "$a" --forge-project bob_10 --port-deck 20101 --port-ssh 20102
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur — deploy/container up"* ]]
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 --port-deck 20101 --port-ssh 20102 up" ]]
  refute grep -q 'DOCKER-APPELE' <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
  # le fichier de faits ne survit pas à l'exec
  [ -z "$(ls "$TMPDIR")" ]
}

@test "mode conteneur avec --bench : exec deploy/container avec les mêmes drapeaux, puis --bench up" {
  local a; a="$(_arbre)"
  porte "$a" --bench --forge-project bob_10 --port-forge 20100
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation en conteneur, avec le banc — deploy/container --bench up"* ]]
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 --port-forge 20100 --bench up" ]]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "mode système : la pause, un sudo sur ce fichier, puis en root exec deploy/workstation up sur les faits root, avec le substrat et les drapeaux" {
  local a; a="$(_arbre)"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  porte "$a" --workstation --bench --substrate wsl --human alice --port-deck 20091
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Installation dans ce système — la suite demande root : sudo, puis deploy/workstation up"*"Entrée pour continuer"* ]]
  [ "$(sudo_ligne)" = "bash $a/install.sh --workstation --bench --substrate wsl --human alice --port-deck 20091 --apres-pause --docker-host unix:///var/run/docker.sock" ]
  [[ "$output" == *"WORKSTATION:up --faits $TMPDIR/lcars-facts."*" --substrate wsl --human alice --port-deck 20091 --bench"* ]]
  # une seule mesure par phase, jamais rejouée
  [ "$(grep -c '^PROVISION:mesure --faits [^ ]* --substrate wsl --port-deck 20091$' "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  [ "$(grep -c '^PROVISION:' "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  # le bandeau se dit une fois
  [ "$(grep -c 'FEDERATION DATABASE' <<<"$output")" -eq 1 ]
  refute grep -q 'DOCKER-APPELE' <<<"$output"
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

@test "la pause avant sudo : annoncée, et sans terminal l'installation continue en le disant" {
  local a; a="$(_arbre)"
  porte "$a" --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"Entrée pour continuer"*"Ctrl+C pour annuler"*"Pas de terminal : l'installation continue."*"WORKSTATION:up"* ]]
  porte "$a" --workstation --bench --dry-run
  [[ "$output" != *"Entrée pour continuer"* ]]
}

@test "la question au terminal : vide ou o continue, n et Ctrl-D arrêtent, une réponse inconnue arrête" {
  local a rep; a="$(_arbre comptes_humains=temoin,alice)"
  # script prête un terminal : ce qui entre sur son stdin ressort sur /dev/tty du script joué
  for rep in "" o n q; do
    rm -f "$BATS_TEST_TMPDIR/sudo.calls"
    run bash -c "printf '%s\n\n' '$rep' | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
    case "$rep" in
      ""|o) [[ "$output" == *"Continuer ? [O/n]"*"WORKSTATION:up"* ]] || { echo "réponse « $rep » : $output" >&2; return 1; } ;;
      n)    [[ "$output" == *"Rien n'a été fait"* ]] || { echo "réponse « n » : $output" >&2; return 1; }
            [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ] || { echo "réponse « n » a demandé sudo" >&2; return 1; } ;;
      q)    [[ "$output" == *"non comprise"* ]] || { echo "réponse « q » : $output" >&2; return 1; }
            [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ] || { echo "réponse « q » a demandé sudo" >&2; return 1; } ;;
    esac
  done
  # Ctrl-D : un terminal sans réponse est un abandon, pas une absence de terminal
  run bash -c "script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null < /dev/null"
  [[ "$output" == *"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
}

@test "la pause se joue même quand « Continuer ? » a répondu : Entrée part, Ctrl-D à la pause arrête avant sudo" {
  local a; a="$(_arbre comptes_humains=temoin,alice)"
  run bash -c "printf 'o\n\n' | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
  [[ "$output" == *"Continuer ? [O/n]"*"Entrée pour continuer"*"WORKSTATION:up"* ]]
  rm -f "$BATS_TEST_TMPDIR/sudo.calls"
  run bash -c "{ printf 'o\n'; sleep 3; } | script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null"
  [[ "$output" == *"Continuer ? [O/n]"*"Entrée pour continuer"*"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "à la pause, un terminal sans réponse (Ctrl-D) est un abandon : sudo n'est pas demandé" {
  local a; a="$(_arbre)"
  run bash -c "script -qec \"bash '$a/install.sh' --workstation --bench\" /dev/null < /dev/null"
  [[ "$output" == *"Entrée pour continuer"*"Rien n'a été fait"* ]]
  [[ "$output" != *"WORKSTATION:up"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "--env atteint la mesure, --human et --only n'y vont pas ; le délégué reçoit les trois" {
  local a; a="$(_arbre)"
  printf 'FORGE_BASE_URL=http://forge.env:3000\n' > "$BATS_TEST_TMPDIR/env"
  run bash "$a/install.sh" --workstation --bench --env "$BATS_TEST_TMPDIR/env" --human zoe --only 60 --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -cx "PROVISION:mesure --faits [^ ]* --env $BATS_TEST_TMPDIR/env" "$BATS_TEST_TMPDIR/provision.calls")" -eq 2 ]
  [[ "$output" == *"--env $BATS_TEST_TMPDIR/env --human zoe --only 60"* ]]
}

_dist() { # _dist [nom=valeur…] — le tiroir dist/ de la version $TAG : un kit, son installeur de gabarit et une mesure qui dicte ses faits
  local d="$BATS_TEST_TMPDIR/dist" st="$BATS_TEST_TMPDIR/stage"
  rm -rf "$d" "$st"; mkdir -p "$d" "$st/lcars_install/deploy/docker/bench"
  cp "$SRC" "$st/lcars_install/install.sh"
  cp "$REPO/deploy/installer-constants.env" "$st/lcars_install/deploy/"
  printf 'cafe1234\n' > "$st/lcars_install/.source-revision"
  _faux_provision "$st/lcars_install" "${_faits_sains[@]}" "$@"
  # le délégué du kit dit d'où il joue : le dossier au-dessus de lcars_install et son mode
  printf '#!/usr/bin/env bash\necho "WORKSTATION:$*"\nd="$(cd "$(dirname "$0")/../.." && pwd)"; echo "COPIE:$d $(stat -c %%a "$d")"\n' > "$st/lcars_install/deploy/workstation"
  printf '#!/usr/bin/env bash\necho "IMAGE:${LCARS_IMAGE:-}"\necho "CONTAINER:$*"\n' > "$st/lcars_install/deploy/container"
  printf '#!/usr/bin/env bash\necho "BENCHUP:$*"\n' > "$st/lcars_install/deploy/docker/bench/bench-up.sh"
  chmod 0755 "$st/lcars_install/deploy/workstation" "$st/lcars_install/deploy/container" "$st/lcars_install/deploy/docker/bench/bench-up.sh"
  tar -czf "$d/lcars-fleet-$TAG-otp27-x86_64.tar.gz" -C "$st" lcars_install
  printf '%s' "$d"
}
_machine() { # x86_64, un HOME et un TMPDIR à nous, dictés
  printf '#!/usr/bin/env bash\necho x86_64\n' > "$BINDIR/uname"; chmod 0755 "$BINDIR/uname"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
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
_release() { # _release [nom=valeur…] — la version $TAG servie ; PORTE, KITS, et l'ARCHIVE du kit posée avec sa SOMME inscrite
  _machine; DIST="$(_dist "$@")"; _serveur "$DIST"; PORTE="$(_porte "$DIST")"; KITS="$HOME/.lcars/kits/$TAG"
  ARCHIVE="$KITS/lcars-fleet-$TAG-otp27-x86_64.tar.gz"
  SOMME="$(sha256sum "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz" | cut -d' ' -f1)"
}
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
  [[ "$output" == *"CONTAINER:--forge-project lcars pull"*"CONTAINER:--bench up"* ]]
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
  [[ "$output" == *"--dry-run : d'abord"*"container --forge-project lcars pull"*"La commande serait"* ]]
  refute_out "CONTAINER:" <<<"$output"
}

@test "release en mode poste : l'image publiée ne concerne pas ce mode, rien n'est tiré" {
  _daemon_avec_image non
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
  [[ "$output" == *"curl -fsSL $SERVEUR_URL/install.sh | bash -s -- --bench"* ]]
  refute_out "<install.sh>" <<<"$output"
  [[ "$output" != *"bash bash"* ]]
  pipee --workstation
  [[ "$output" == *"| bash -s -- --workstation --bench"* ]]
  [[ "$output" == *"curl -fsSL $SERVEUR_URL/install.sh | FORGE_BASE_URL=https://… bash -s -- --workstation" ]]
}

suivre_remedes() { # suivre_remedes <commande> — la joue, puis le premier remède de chaque refus, tel qu'imprimé, jusqu'à un passage
  local cmd="$1" n tirage="cat '${PORTE:-}'"
  SUITE="$cmd"
  for n in 1 2 3 4; do
    run setsid -w bash -c "$cmd" < /dev/null
    [ "$status" -ne 0 ] || return 0
    cmd="$(sed -n 's/^.* : \{2,\}//p' <<<"$output" | head -1)"
    [ -n "$cmd" ] || { echo "refus sans remède, après : $SUITE"; echo "$output"; return 1; }
    SUITE+=" → $cmd"
    # pipé, la porte est servie à la place de son adresse
    cmd="${cmd/curl -fsSL ${SERVEUR_URL:-<aucune>}\/install.sh/$tirage}"
  done
  echo "les remèdes ne mènent à aucun passage : $SUITE"; return 1
}

@test "Linux dédié non déclaré, sans forge : chaque remède suivi tel quel mène à l'installation, pipée ou non, avec ou sans --bench, drapeaux gardés" {
  _release substrat=linux consent=none
  local a; a="$(_arbre substrat=linux consent=none)"
  local depart
  for depart in "cat '$PORTE' | bash -s -- --workstation --human alice --port-deck 20091" \
                "cat '$PORTE' | bash -s -- --workstation --bench --human alice --port-deck 20091" \
                "bash '$a/install.sh' --workstation --human alice --port-deck 20091" \
                "bash '$a/install.sh' --workstation --bench --human alice --port-deck 20091"; do
    suivre_remedes "$depart" || return 1
    [[ "$output" == *"WORKSTATION:up"*"--human alice --port-deck 20091"* ]] || { echo "$SUITE"; echo "$output"; return 1; }
  done
  [[ "$SUITE" == *"→ LCARS_ALLOW_ANY_HOST=1 bash $a/install.sh --workstation --bench --port-deck 20091 --human alice" ]]
}

@test "Linux sans docker, en conteneur : le remède donne la machine au système, et la suite des remèdes mène à l'installation" {
  local a; a="$(_arbre substrat=linux consent=none docker=absent "docker_why=aucun daemon")"
  local depart
  for depart in "bash '$a/install.sh' --forge-project bob_9 --port-ssh 20092" "bash '$a/install.sh' --bench --forge-project bob_9"; do
    suivre_remedes "$depart" || return 1
    [[ "$output" == *"WORKSTATION:up --faits "*" --forge-project bob_9"* ]] || { echo "$SUITE"; echo "$output"; return 1; }
  done
}

@test "Linux sans docker, posé par un autre canal : le refus ne propose pas l'installation dans ce système, que le préflight refuserait" {
  local a; a="$(_arbre substrat=linux consent=posee docker=absent "docker_why=aucun daemon" channel=source channel_tree=kit)"
  porte "$a" --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker est absent."*"Le conteneur ne l'installe pas"* ]]
  refute_out 'workstation' <<<"$output"
}

@test "--check pipée ne télécharge rien : la mesure vit dans le kit, et il le dit" {
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
  [[ "$output" == *"déjà là, sha256 vérifié"*"WORKSTATION:up --faits "* ]]
  [[ "$(sudo_ligne)" == "bash -c set -eu"*" lcars-kit $ARCHIVE $SOMME "* ]]
}

@test "pipée : le kit de la version est téléchargé, vérifié, détaré, et root joue une copie qu'il vérifie lui-même, jamais l'entrée du tube" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"téléchargé, sha256 vérifié"* ]]
  [[ "$output" == *"Source     release $TAG · kit dans $KITS/lcars_install"* ]]
  [[ "$(sudo_ligne)" == "bash -c set -eu"*" lcars-kit $ARCHIVE $SOMME --workstation --bench --apres-pause --docker-host unix:///var/run/docker.sock" ]]
  [[ "$output" == *"WORKSTATION:up --faits "*" --bench"* ]]
  # le délégué joue d'un dossier que root a créé, sous TMPDIR, et que la sortie retire : lisible par les gestes
  # joués sous l'humain (60-deploy pose la release sous lui — refusé en 700 sur une machine vierge), écrit par root seul
  [[ "$output" == *"COPIE:$TMPDIR/lcars-kit."??????" 755"* ]]
  [ -z "$(compgen -G "$TMPDIR/lcars-kit.*" || true)" ]
  # sans clé : la porte le dit, et continue
  [[ "$output" == *"provenance non vérifiée (sha256 seul)"* ]]
  # relancée : déjà là, vérifié, rien de retéléchargé
  : > "$SERVEUR_LOG"
  pipee --workstation --bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"déjà là, sha256 vérifié"* ]]
  [ ! -s "$SERVEUR_LOG" ]
}

@test "l'arbre du kit détaré sous le compte de l'utilisateur, modifié après sa vérification : root n'exécute pas la modification" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local f
  for f in install.sh deploy/workstation; do
    printf '#!/usr/bin/env bash\n[[ "$EUID" -ne 0 ]] || echo "MARQUEUR-ROOT:%s"\nexit 0\n' "$f" > "$KITS/lcars_install/$f"
  done
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out 'MARQUEUR-ROOT' <<<"$output"
  [[ "$output" == *"WORKSTATION:up --faits "*" --bench"* ]]
  pipee --workstation --bench --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute_out 'MARQUEUR-ROOT' <<<"$output"
}

@test "l'archive modifiée entre la vérification sous le compte de l'utilisateur et root : root refuse de la détarer, rien n'est fait" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  SUDO_ALTERE="$ARCHIVE" pipee --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"$ARCHIVE ne porte plus la somme inscrite dans l'installeur : root ne le détare pas, rien n'est fait ; relancer l'installeur."* ]]
  refute_out 'WORKSTATION:' <<<"$output"
  [ -z "$(compgen -G "$TMPDIR/lcars-kit.*" || true)" ]
}

@test "--check et --dry-run pipés sur un kit déjà posé revérifient son archive à chaque passe : altérée, rien n'est téléchargé ni joué" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'altéré\n' >> "$ARCHIVE"
  : > "$SERVEUR_LOG"; rm -f "$BATS_TEST_TMPDIR/sudo.calls"
  local drapeau
  for drapeau in --check --dry-run; do
    pipee --workstation --bench "$drapeau"
    [ "$status" -eq 0 ] || { echo "$drapeau : $output"; return 1; }
    [[ "$output" == *"$drapeau : rien n'est téléchargé. Le préflight vit dans le kit, qui n'est pas là, ou dont l'archive ne porte plus sa somme."* ]]
    refute_out 'déjà là' <<<"$output"
  done
  [ ! -s "$SERVEUR_LOG" ]
  [ ! -e "$BATS_TEST_TMPDIR/sudo.calls" ]
}

@test "pipée en mode conteneur : même kit, exec deploy/container depuis le kit" {
  _release forge_fournie=https://forge.example.net forge_joignable=oui
  pipee --forge-project bob_10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "${lines[-1]}" == "CONTAINER:--forge-project bob_10 up" ]]
  [[ "$output" == *"Source     release $TAG · kit dans $KITS/lcars_install"* ]]
}

@test "la grille du conteneur donne sa commande de statut, et sa durée mesurée selon le banc et l'image de la version" {
  _daemon_avec_image non
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker"
  pipee --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pipee --bench --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Espace     ~3 Go · durée ~2 min, tirage de l'image compris · ports"* ]]
  [[ "$output" == *"Statut     $KITS/lcars_install/deploy/container -p lcars-fleet status"$'\n'"    Retour     $KITS/lcars_install/deploy/docker/bench/bench-down.sh --project lcars --yes"* ]]
  [[ "$output" == *"--check : rien n'est fait. Pour un déploiement existant : $KITS/lcars_install/deploy/container -p lcars-fleet status"* ]]
  refute_out '15 min' <<<"$output"
  _daemon_avec_image oui
  pipee --bench --check
  [[ "$output" == *"durée ~1 min 30, l'image est sur ce daemon · ports"* ]]
  # le banc pose la structure de sa forge dans sa durée ; une instance seule la laisse à forge-apply, qui la suit
  refute_out 'hors structure' <<<"$output"
  # hors release, l'image n'est pas nommée : les deux durées
  local a; a="$(_arbre forge_fournie=https://forge.example.net forge_joignable=oui)"
  porte "$a" --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"durée moins d'une minute image présente, ~1 min à tirer, hors structure de la forge"* ]]
}

@test "pipée, chaque commande donnée à l'opérateur porte le chemin du kit et se joue depuis n'importe quel dossier : statut, retour, --check, et la sonde du système après sudo" {
  _daemon_avec_image oui
  IMAGE_PORTE="ghcr.io/o/r:$TAG" _release "docker_bin=$BINDIR/docker" forge_fournie=https://forge.example.net forge_joignable=oui
  pipee
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pipee --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local statut retour check
  statut="$(sed -n 's/^    Statut     //p' <<<"$output")"
  retour="$(sed -n 's/^    Retour     \(.*\), 30 s : .*$/\1/p' <<<"$output")"
  check="$(sed -n "s/^.*--check : rien n'est fait. Pour un déploiement existant : //p" <<<"$output")"
  [ "$statut" = "$KITS/lcars_install/deploy/container -p lcars-fleet status" ]
  [ "$check" = "$statut" ]
  run bash -c "cd / && $statut && $retour"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "IMAGE:"$'\n'"CONTAINER:-p lcars-fleet status"$'\n'"IMAGE:"$'\n'"CONTAINER:-p lcars-fleet reset" ]
  # après sudo, root joue une copie vérifiée du kit, qu'il retire à la sortie : la sonde nommée est celle du kit de l'opérateur
  pipee --workstation --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  check="$(sed -n "s/^.*--check : rien n'est fait. Pour un déploiement existant : //p" <<<"$output")"
  [ "$check" = "$KITS/lcars_install/deploy/workstation doctor" ] || { echo "$output"; return 1; }
  run bash -c "cd / && $check"
  [[ "$output" == "WORKSTATION:doctor"* ]]
}

@test "une commande proposée par la porte pipée porte l'adresse de sa release ; l'installation dans ce système n'est proposée qu'à une machine que ce canal peut poser" {
  _release
  pipee --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pipee --bench --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Pour installer dans ce système à la place :  curl -fsSL $SERVEUR_URL/install.sh | bash -s -- --workstation --bench --check"* ]]
  refute_out '<install.sh>' <<<"$output"
  # .63 : posée par un checkout, le kit d'une release y serait refusé par le préflight
  local a; a="$(_arbre channel=source channel_tree=kit)"
  porte "$a" --bench --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Dans ce système : cette machine est posée par le canal « source » et cet arbre poserait « kit » — un canal ne se pose pas sur un autre."* ]]
  refute_out 'Pour installer dans ce système' <<<"$output"
}

@test "un kit déjà posé s'annonce en une ligne" {
  _release
  pipee --workstation --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pipee --workstation --bench --check
  [ "$(grep -cE 'déjà (là|posé)' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lcars-fleet-$TAG-otp27-x86_64.tar.gz : déjà là, sha256 vérifié, rien n'est téléchargé"* ]]
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

@test "http est refusé sans LCARS_DOOR_INSECURE_HTTP : le serveur n'est jamais sollicité, rien n'est posé" {
  _release
  unset LCARS_DOOR_INSECURE_HTTP
  pipee --workstation --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"téléchargement en échec — rien n'est posé"* ]]
  [ ! -s "$SERVEUR_LOG" ]
  [ ! -d "$KITS/lcars_install" ]
  refute_out 'WORKSTATION:' <<<"$output"
}

@test "minisign : une signature invalide refuse et efface ; une clé sans .minisig refuse ; minisign absent se dit" {
  _release
  local pub="RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
  : > "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz.minisig"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/minisign"; chmod 0755 "$BINDIR/minisign"
  PORTE="$(_porte "$DIST" "$pub")"
  rm -f "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz.minisig"   # la signature disparue du serveur après la génération
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
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"minisign absent : provenance non vérifiée"* ]]
}

@test "--dry-run pipée : les artefacts et leurs sha256, rien de téléchargé, la sortie dite" {
  _release
  pipee --workstation --bench --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local a="lcars-fleet-$TAG-otp27-x86_64.tar.gz"
  [[ "$output" == *"$a "*"sha256 $(sha256sum "$DIST/$a" | cut -d' ' -f1)"* ]]
  [[ "$output" == *"rien n'est téléchargé"*"sudo sur l'installeur du kit vérifié, puis deploy/workstation up"* ]]
  [ ! -s "$SERVEUR_LOG" ]
  [ ! -d "$HOME/.lcars" ]
  # --check ne promet pas le provisionnement
  pipee --workstation --bench --check
  [[ "$output" == *"La commande serait : sudo sur l'installeur du kit vérifié, pour la mesure en root ; rien n'est posé"* ]]
  refute_out 'workstation up' <<<"$output"
  # une fois le kit posé, --dry-run dit la commande, après sudo sur la copie vérifiée du kit, qui ne survit pas à la sortie
  pipee --workstation --bench
  [ "$status" -eq 0 ]
  pipee --workstation --bench --dry-run
  [[ "$output" == *"déjà là, sha256 vérifié, rien n'est téléchargé"*"Depuis le kit vérifié, dont root retire la copie à la sortie :"*"La commande serait :"$'\n'"    deploy/workstation up --bench" ]]
  refute_out 'lcars-kit\.|--faits' <<<"$output"
}

@test "le script du dépôt, pipé avec --dry-run, dit l'installeur de la dernière release qu'il rejouerait, déclaration gardée, sans rien télécharger" {
  _machine
  run bash -c "cat '$SRC' | LCARS_ALLOW_ANY_HOST=1 bash -s -- --workstation --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rien n'est téléchargé"*"curl -fsSL https://github.com/zurp-embedded/LCARS-fleet/releases/latest/download/install.sh | LCARS_ALLOW_ANY_HOST=1 bash -s -- --workstation --dry-run"* ]]
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
  # la relance en root ne retélécharge rien : --from-release et --repo ne la suivent pas
  [[ "$(sudo_ligne)" == "bash -c set -eu"*" lcars-kit $HOME/.lcars/kits/$TAG/lcars-fleet-$TAG-otp27-x86_64.tar.gz $(sha256sum "$DIST/lcars-fleet-$TAG-otp27-x86_64.tar.gz" | cut -d' ' -f1) --workstation --bench --apres-pause --docker-host unix:///var/run/docker.sock" ]]
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
