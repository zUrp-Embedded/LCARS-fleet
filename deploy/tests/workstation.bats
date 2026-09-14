#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/workstation.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins du délégué du poste — mesure sans privilège, sudo une fois, mesure root, provisionnement sur ses faits, acceptation, kit, sortie

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  unset SUDO_USER NO_COLOR
  SRC="$BATS_TEST_DIRNAME/../workstation"
  [ -f "$SRC" ]
  VRAI_CURL="$(command -v curl)"
  decor_pose
}

teardown() { forge_double_stop; }

deploy_copie() { # deploy_copie <dossier deploy> — le délégué, sa lib et les données qu'elle lit
  cp "$SRC" "$1/workstation"; cp -a "$BATS_TEST_DIRNAME/../lib" "$1/lib"
  cp "$BATS_TEST_DIRNAME/../installer-constants.env" "$BATS_TEST_DIRNAME/../system.manifest" "$1/"
}

# provision de décor : « mesure » écrit les faits donnés, la phase que l'identité dit et son verdict
# (DOCTOR_LIGNE, DOCTOR_RC) ; « apply » et « doctor » notent les choix de l'opérateur qu'ils reçoivent
faux_provision() { # faux_provision <fichier> <étiquette> <faits…>
  local f="$1" tag="$2"; shift 2
  { echo '#!/usr/bin/env bash'
    echo "echo \"$tag:\$*\" >> \"\${TRACE:?}\""
    echo 'if [[ "$1" != mesure ]]; then'
    echo '  env | grep -E "^(FORGE_|LCARS_ALLOW|LCARS_BENCH|LCARS_BUILTIN|PROV_FORGE_|DOCKER_HOST|SUDO_USER)" | sort | sed "s/^/ENV:/" >> "$TRACE"'
    echo '  [[ "$1" != apply ]] || exit "${PROVISION_RC:-0}"; exit 0'
    echo 'fi'
    echo 'while [[ "$1" != --faits ]]; do shift; done; faits="$2"'
    echo 'phase=sans-privilege; [[ "$EUID" -ne 0 ]] || phase=root'
    echo 'printf "phase=%s\n" "$phase" > "$faits"'
    echo 'cat >> "$faits" <<FACTS'; printf '%s\n' "$@"; echo 'FACTS'
    echo 'echo "OK    00-preflight: décor"; [[ -z "${DOCTOR_LIGNE:-}" ]] || echo "$DOCTOR_LIGNE"'
    echo 'rc="${DOCTOR_RC:-0}"; if [[ "$rc" -eq 0 ]]; then echo preflight=conforme; else echo preflight=refuse; fi >> "$faits"'
    echo 'exit "$rc"'
  } > "$f"
  chmod 0755 "$f"
}

arbre() { # arbre <faits…> — le deploy/ factice, un sudo de décor qui joue la suite en root de namespace
  local d="$BATS_TEST_TMPDIR/arbre/deploy"; rm -rf "$BATS_TEST_TMPDIR/arbre"; mkdir -p "$d"
  deploy_copie "$d"
  faux_provision "$d/provision" PROVISION substrat=wsl docker=oui docker_host=unix:///var/run/docker.sock racine=/opt/lcars \
    "port_deck=20999 libre" "port_forge=21000 libre" "$@"
  { echo '#!/usr/bin/env bash'
    echo 'echo "ACCEPT:$*" >> "${TRACE:?}"'
    echo 'echo "  OUI   décor : acceptation jouée"'
    echo '[[ "$1" == --announce-file && -n "$2" ]] && printf "forge du poste\tbob\tSECRET-DE-DECOR\n" >> "$2"'
    echo '[[ -z "${ACCEPT_KILL:-}" ]] || { kill -TERM "$PPID"; sleep 2; }'
    echo 'exit "${ACCEPT_RC:-0}"'
  } > "$d/accept"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  # sudo note son argv et l'environnement qu'on lui tend, puis joue la suite comme le vrai : root, un
  # environnement remis à zéro, SUDO_USER posé — seuls le décor et la trace du témoin passent
  cat > "$BINDIR/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" != -n ]] || { echo "SUDO-N:$*" >> "$TRACE"; exit "${SUDO_N_RC:-0}"; }
echo "SUDO:$*" >> "$TRACE"
env | sort > "$TRACE.sudo-env"
exec unshare -Ur env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" TRACE="$TRACE" LCARS_DECOR_ROOT="$LCARS_DECOR_ROOT" \
  SUDO_USER="$(id -un)" "$@"
EOF
  chmod 0755 "$d/accept" "$d/workstation" "$BINDIR/sudo"
  export TRACE="$BATS_TEST_TMPDIR/trace"; : > "$TRACE"
  export PATH="$BINDIR:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  WS="$d/workstation"
}

kit() { # kit <nom> [--sans-sha256|--sha256-faux] — un kit.tar.gz (lcars_install/, tampon, deploy complet) et son .sha256
  local nom="$1" mode="${2:-}"
  local st="$BATS_TEST_TMPDIR/stage-$nom"
  mkdir -p "$st/lcars_install/deploy"
  printf 'cafe1234\n' > "$st/lcars_install/.source-revision"
  deploy_copie "$st/lcars_install/deploy"
  faux_provision "$st/lcars_install/deploy/provision" KIT-PROVISION substrat=wsl docker=absent racine=/opt/lcars
  cp "$BATS_TEST_TMPDIR/arbre/deploy/accept" "$st/lcars_install/deploy/"
  mkdir -p "$BATS_TEST_TMPDIR/kits"
  tar -czf "$BATS_TEST_TMPDIR/kits/$nom.tar.gz" -C "$st" lcars_install
  case "$mode" in
    --sans-sha256) ;;
    --sha256-faux) printf '%s  %s\n' "$(printf 'x%.0s' {1..64})" "$nom.tar.gz" > "$BATS_TEST_TMPDIR/kits/$nom.tar.gz.sha256" ;;
    *) ( cd "$BATS_TEST_TMPDIR/kits" && sha256sum "$nom.tar.gz" > "$nom.tar.gz.sha256" ) ;;
  esac
  printf '%s\n' "$BATS_TEST_TMPDIR/kits/$nom.tar.gz"
}

ws()   { run setsid -w bash "$WS" up "$@" < /dev/null; }
root() {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le chemin root ne se joue pas ici"
  run unshare -Ur bash "$WS" up "$@"
}
sans_faits_restants() { [ -z "$(compgen -G "$TMPDIR/lcars-*" || true)" ]; }
sudo_ligne() { sed -n 's/^SUDO://p' "$TRACE"; }

# ─── structure ──────────────────────────────────────────────────────────────────────────────────

# bats test_tags=structure
@test "il est exécutable dans l'index git : la porte l'appelle" {
  run git -C "$BATS_TEST_DIRNAME/../.." ls-files -s deploy/workstation
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

# ─── l'entrée ───────────────────────────────────────────────────────────────────────────────────

@test "l'aide marche sans root et sans rien d'autre" {
  run env -i PATH=/usr/bin:/bin bash "$SRC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"workstation <commande>"*"up "*"--from <kit.tar.gz>"*"doctor "*"EXIT"* ]]
  [[ "$output" == *"EXIT  up      0 convergé"*"doctor  les codes de « provision doctor »"*"un verbe inconnu sort en 1"* ]]
  [[ "$output" == *"ne se pose pas sur un autre"*"fait confiance à cet arbre"*"--docker-host"*"--linux-dedie"*"--forge URL"* ]]
  refute_out '\.deb' <<<"$output"
}

@test "un verbe inconnu est refusé" {
  run bash "$SRC" zzz
  [ "$status" -eq 1 ]
  [[ "$output" == *"verbe inconnu : zzz"* ]]
}

# ─── sans root : la mesure, puis sudo une fois ──────────────────────────────────────────────────

@test "up sans root : mesure sans privilège, dit ce que root pose, puis sudo sur ce fichier, les choix en options et aucune variable" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre docker_host=unix:///run/user/1000/docker.sock "port_deck=20999 tenu"
  LCARS_ALLOW_ANY_HOST=1 FORGE_BASE_URL=http://forge.test FORGE_PUBLIC_URL=http://forge.public.test \
    LCARS_BUILTIN_HUMAN=demo PROV_FORGE_ADMIN_RESET=1 FORGE_ADMIN_TOKEN=tres-secret DOCKER_HOST=unix:///mort.sock \
    ws --port-deck 20991 --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(sed -n 1p "$TRACE")" =~ ^PROVISION:mesure\ --faits\ [^\ ]+\ --port-deck\ 20991$ ]]
  [[ "$output" == *"La suite se joue en root, par sudo : provision apply pose /etc, /opt/lcars"* ]]
  [ "$(sudo_ligne)" = "bash $WS up --port-deck 20991 --bench --linux-dedie --forge http://forge.test --forge-publique http://forge.public.test --humain-demo demo --forge-admin-reset --docker-host unix:///run/user/1000/docker.sock" ]
  # sudo remet l'environnement à zéro : la suite en root reçoit chaque choix par son option, le jeton nulle part
  grep -qx 'ENV:FORGE_BASE_URL=http://forge.test' "$TRACE"
  grep -qx 'ENV:FORGE_PUBLIC_URL=http://forge.public.test' "$TRACE"
  grep -qx 'ENV:LCARS_ALLOW_ANY_HOST=1' "$TRACE"
  grep -qx 'ENV:LCARS_BENCH=1' "$TRACE"
  grep -qx 'ENV:PROV_FORGE_MONTEE=1' "$TRACE"
  grep -qx 'ENV:LCARS_BUILTIN_HUMAN=demo' "$TRACE"
  grep -qx 'ENV:PROV_FORGE_ADMIN_RESET=1' "$TRACE"
  grep -qx 'ENV:DOCKER_HOST=unix:///run/user/1000/docker.sock' "$TRACE"
  grep -qx "ENV:SUDO_USER=$(id -un)" "$TRACE"
  refute grep -q 'tres-secret' "$TRACE"
  refute grep -qE '^SUDO:.* [A-Z_]+=' "$TRACE"
  sans_faits_restants
}

@test "la suite en root refait sa mesure en root, puis l'apply reçoit ces faits sans remesure, et les retire" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre "port_deck=20999 tenu"
  ws --only 60
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local faits
  faits="$(sed -n 's/^PROVISION:apply --faits \([^ ]*\) .*/\1/p' "$TRACE")"
  [ -n "$faits" ]
  [ "$(grep -c '^PROVISION:mesure ' "$TRACE")" -eq 2 ]
  grep -qx "PROVISION:mesure --faits $faits" "$TRACE"
  grep -qx "PROVISION:apply --faits $faits --only 60" "$TRACE"
  grep -q '^ACCEPT:--announce-file ' "$TRACE"
  [ ! -e "$faits" ]
  sans_faits_restants
}

@test "une mesure root qui refuse le terrain arrête avant l'apply, en citant son constat" {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le chemin root ne se joue pas ici"
  arbre
  DOCTOR_RC=2 DOCTOR_LIGNE='FAIL  00-preflight: port 20999 (deck) tenu par python3 (pid 4243, compte nobody)' root
  [ "$status" -eq 1 ]
  [[ "$output" == *"le préflight refuse ce terrain"*"port 20999 (deck) tenu par python3"* ]]
  refute grep -q '^PROVISION:apply' "$TRACE"
  sans_faits_restants
}

@test "reçus d'install.sh, les faits root vont à l'apply sans aucune mesure, et sont retirés à la sortie" {
  arbre
  local faits="$TMPDIR/lcars-facts.recus"
  printf 'phase=root\npreflight=conforme\n' > "$faits"
  root --faits "$faits" --port-deck 20991 --bench
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q '^PROVISION:mesure' "$TRACE"
  grep -qx "PROVISION:apply --faits $faits --port-deck 20991" "$TRACE"
  grep -qx 'ENV:LCARS_BENCH=1' "$TRACE"
  [ ! -e "$faits" ]
}

@test "lancé en root à la main, sans faits reçus : la mesure root se joue, puis l'apply sur ses faits" {
  arbre
  root --port-deck 20991 --only 60-deploy --forge-project bob_9 --human alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q '^SUDO' "$TRACE"
  local faits
  faits="$(sed -n 's/^PROVISION:mesure --faits \([^ ]*\) .*/\1/p' "$TRACE")"
  [ "$(grep '^PROVISION:' "$TRACE")" = "$(printf 'PROVISION:mesure --faits %s --port-deck 20991 --forge-project bob_9\nPROVISION:apply --faits %s --port-deck 20991 --only 60-deploy --forge-project bob_9 --human alice' "$faits" "$faits")" ]
  grep -q '^ACCEPT:--announce-file ' "$TRACE"
  [[ "$output" == *"provisionnement terminé"* ]]
  [[ "$output" != *"creds claude"* ]]
  # la mesure root qui refuse arrête avant l'apply, sans option pour l'en dispenser
  : > "$TRACE"
  DOCTOR_RC=2 DOCTOR_LIGNE='FAIL  00-preflight: port 20991 (deck) tenu par python3 (pid 4243)' root --port-deck 20991
  [ "$status" -eq 1 ]
  refute grep -q '^PROVISION:apply' "$TRACE"
}

@test "--faits sans root est refusé : il appartient à la suite en root" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  ws --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--faits appartient à la suite en root"* ]]
  refute grep -qE '^(SUDO|PROVISION):' "$TRACE"
}

@test "sans sudo, le refus tient en une phrase, après la mesure et sans rien poser" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local nu="$BATS_TEST_TMPDIR/nu" t; mkdir -p "$nu"
  for t in bash sed tail cat mktemp env readlink dirname basename id getent cut grep tr head sort awk rm setsid; do
    ln -sf "$(command -v "$t")" "$nu/$t"
  done
  PATH="$nu" ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"root requis et sudo absent"*"installer sudo"* ]]
  refute grep -q '^PROVISION:apply' "$TRACE"
}

@test "sans terminal, un sudo qui demande un mot de passe (sudo -n refusé) est un refus en une phrase ; accepté, la suite part" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  SUDO_N_RC=1 ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"sans terminal, sudo ne peut pas demander de mot de passe, et « sudo -n » est refusé"* ]]
  grep -qx 'SUDO-N:-n true' "$TRACE"
  refute grep -q '^SUDO:' "$TRACE"
  : > "$TRACE"
  ws
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^SUDO:bash ' "$TRACE"
}

@test "sans docker mesuré, aucun --docker-host ne part à sudo" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre docker=absent docker_host=
  DOCKER_HOST=unix:///mort.sock ws
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $WS up" ]
}

@test "un port tenu par un processus visible et étranger arrête avant sudo ; la forge ne compte que sous --bench" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre "port_deck=20999 pris par autre-fleet-lcars-1 (projet autre-fleet)"
  ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"le port 20999 (deck) est pris par autre-fleet-lcars-1"*"--port-deck"* ]]
  refute grep -q '^SUDO' "$TRACE"
  arbre "port_forge=21000 pris par python3 (pid 4243)"
  ws
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^SUDO:' "$TRACE"
  : > "$TRACE"
  ws --bench
  [ "$status" -eq 1 ]
  [[ "$output" == *"le port 21000 (forge) est pris par python3 (pid 4243)"* ]]
  refute grep -q '^SUDO' "$TRACE"
}

@test "un préflight qui refuse le terrain (Linux non déclaré, plancher en dérive) sort avant sudo en citant son constat" {
  local cas
  for cas in "2|FAIL  00-preflight: Linux natif sans déclaration|substrat=linux consent=none" \
             "1|DRIFT 00-preflight: RAM 512 Mo < 1536 Mo|substrat=wsl consent=sans-objet"; do
    # shellcheck disable=SC2086 # les faits sont des mots, un par ligne
    arbre ${cas##*|}
    DOCTOR_RC="${cas%%|*}" DOCTOR_LIGNE="$(cut -d'|' -f2 <<<"$cas")" ws
    [ "$status" -eq 1 ] || { echo "$cas : $output"; return 1; }
    [[ "$output" == *"le préflight refuse ce terrain"*"$(cut -d'|' -f2 <<<"$cas")"* ]]
    refute_out 'OK    00-preflight: décor' <<<"$output"
    refute grep -qE '^SUDO|^PROVISION:apply' "$TRACE"
    sans_faits_restants
  done
}

@test "la mesure sur le vrai provision : ses options atteignent le préflight, un --substrate contredit sort avant sudo avec ce qu'il a dit" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local d; d="$(dirname "$WS")"
  cp "$BATS_TEST_DIRNAME/../provision" "$d/provision"
  mkdir -p "$d/modules.d"
  cat > "$d/modules.d/00-preflight.sh" <<'EOF'
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
set -euo pipefail
. "${PROVISION_LIB:?}"
echo "PREFLIGHT:$1 phase=$PROV_PHASE deck=$PROV_DECK_PORT base=$PROV_FORGE_BASE" >> "$TRACE"
p_fact docker oui
p_fact docker_host unix:///decor.sock
p_fact port_deck "$PROV_DECK_PORT tenu"
p_ok "décor"
verdict_check
EOF
  ws --port-deck 20991 --forge-project bob_9 --only 60
  grep -qx "PREFLIGHT:check phase=sans-privilege deck=20991 base=bob_9" "$TRACE"
  [ "$(sudo_ligne)" = "bash $WS up --port-deck 20991 --forge-project bob_9 --only 60 --docker-host unix:///decor.sock" ]
  : > "$TRACE"
  # le décor ne porte ni /.dockerenv ni noyau Microsoft : ce système se mesure linux
  ws --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"la mesure n'a rendu aucun fait"*"--substrate docker : ce système se mesure « linux »"* ]]
  refute grep -q '^SUDO' "$TRACE"
  sans_faits_restants
}

@test "un fichier temporaire impossible à créer arrête la mesure en le nommant, sans sudo" {
  arbre
  TMPDIR="$BATS_TEST_TMPDIR/nulle-part" ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fichier temporaire ne se crée dans $BATS_TEST_TMPDIR/nulle-part"*"corriger TMPDIR"* ]]
  refute grep -qE '^(SUDO|PROVISION):' "$TRACE"
}

@test "avant sudo, docker absent sur un linux s'annonce en une ligne" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  local decor
  for decor in "substrat=linux docker=absent" "substrat=linux docker=oui" "substrat=wsl docker=absent"; do
    # shellcheck disable=SC2086 # les faits sont des mots, un par ligne
    arbre $decor
    ws
    [ "$status" -eq 0 ] || { echo "$decor : $output"; return 1; }
    grep -q '^SUDO:' "$TRACE"
    if [[ "$decor" == "substrat=linux docker=absent" ]]; then
      [ "$(grep -c 'docker est absent : le provisionnement pose docker-ce' <<<"$output")" -eq 1 ]
    else
      refute_out 'docker est absent' <<<"$output"
    fi
  done
}

# ─── doctor ─────────────────────────────────────────────────────────────────────────────────────

@test "doctor sans root : sudo sur ce fichier, les choix et le daemon qui a répondu en options ; en root, la sonde complète reçoit ses options" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  printf '#!/usr/bin/env bash\n[[ "$1" == version && "$DOCKER_HOST" == unix:///run/user/1000/docker.sock ]]\n' > "$BINDIR/docker"; chmod 0755 "$BINDIR/docker"
  FORGE_BASE_URL=http://forge.test DOCKER_HOST=unix:///run/user/1000/docker.sock run setsid -w bash "$WS" doctor --port-deck 20991 < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $WS doctor --port-deck 20991 --forge http://forge.test --docker-host unix:///run/user/1000/docker.sock" ]
  grep -qx "PROVISION:doctor --port-deck 20991" "$TRACE"
  grep -qx 'ENV:FORGE_BASE_URL=http://forge.test' "$TRACE"
  grep -qx 'ENV:DOCKER_HOST=unix:///run/user/1000/docker.sock' "$TRACE"
  refute grep -q '^PROVISION:mesure' "$TRACE"
}

@test "doctor sans root : un DOCKER_HOST qui ne répond pas ne part pas à sudo, et c'est dit" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BINDIR/docker"; chmod 0755 "$BINDIR/docker"
  DOCKER_HOST=unix:///nulle-part/docker.sock run setsid -w bash "$WS" doctor < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $WS doctor" ]
  [[ "$output" == *"DOCKER_HOST=unix:///nulle-part/docker.sock ne répond pas : la sonde ne le reçoit pas"* ]]
  refute grep -q 'ENV:DOCKER_HOST' "$TRACE"
}

@test "doctor refuse --faits : il appartient à up" {
  arbre
  run bash "$WS" doctor --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--faits appartient à up"* ]]
  refute grep -qE '^(SUDO|PROVISION):' "$TRACE"
}

# ─── le chemin root : provisionnement, acceptation, sortie ──────────────────────────────────────

@test "root : sur un TERM reçu après l'acceptation, les identifiants sont imprimés avant que leur fichier parte" {
  arbre
  ACCEPT_KILL=1 root
  [ "$status" -ne 0 ]
  [[ "$output" == *"SECRET-DE-DECOR"* ]]
  [[ "$output" != *"provisionnement terminé"* ]]
  sans_faits_restants
}

@test "root : un drift résiduel de provision laisse jouer l'acceptation, la sortie est 2" {
  arbre
  PROVISION_RC=2 root
  [ "$status" -eq 2 ]
  grep -q '^ACCEPT:' "$TRACE"
  [[ "$output" == *"provisionnement terminé"* ]]
}

@test "root : un échec de provision arrête tout avant l'acceptation, la sortie est 1" {
  arbre
  PROVISION_RC=1 root
  [ "$status" -eq 1 ]
  refute grep -q '^ACCEPT:' "$TRACE"
  [[ "$output" != *"provisionnement terminé"* ]]
  sans_faits_restants
}

@test "root : une acceptation en échec rend 1 même quand provision a convergé" {
  arbre
  ACCEPT_RC=1 root
  [ "$status" -eq 1 ]
  [[ "$output" == *"provisionnement terminé"* ]]
}

@test "root : les identifiants annoncés sont imprimés en dernier, après le bandeau, et leur fichier ne reste pas" {
  arbre
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"provisionnement terminé"*"IDENTIFIANTS"*"SECRET-DE-DECOR"* ]]
  [ "$(grep -c 'SECRET-DE-DECOR' <<<"$output")" -eq 1 ]
  sans_faits_restants
}

@test "root : le bandeau dit la suite du terrain mesuré — WSL redémarre, linux non — sans familiarité" {
  arbre
  mkdir -p "$LCARS_DECOR_ROOT/proc"; printf 'Linux version 6.6.114.1-microsoft-standard-WSL2\n' > "$LCARS_DECOR_ROOT/proc/version"
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"wsl --shutdown"*"<humain de fleet> fleet start"* ]]
  [[ "$output" != *"Rien à redémarrer"* ]]
  refute_out '\b(ton|toi|tu|Inscris)\b' <<<"$output"
  rm "$LCARS_DECOR_ROOT/proc/version"
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rien à redémarrer"* ]]
  [[ "$output" != *"wsl --shutdown"* ]]
}

banc() { # banc [code du PATCH] — le décor du contrat de banc : getent et chpasswd doublés, curl noté, la forge locale, son adresse et le jeton master
  local hroot="$BATS_TEST_TMPDIR/hroot"; mkdir -p "$hroot"
  # comme le vrai getent, un nom vide ne rend rien et sort en 2
  printf '#!/usr/bin/env bash\n[[ "$1" == passwd && -n "$2" ]] || exit 2\nprintf "%%s:x:0:0::%s:/bin/bash\\n" "$2"\n' "$hroot" > "$BINDIR/getent"
  printf '#!/usr/bin/env bash\ncat >> "%s"\n' "$TRACE" > "$BINDIR/chpasswd"
  # un curl qui note son argv puis joue le vrai : un secret passé en argv s'y lirait
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$BATS_TEST_TMPDIR/curl.argv'
exec '$VRAI_CURL' "\$@"
EOF
  chmod 0755 "$BINDIR/getent" "$BINDIR/chpasswd" "$BINDIR/curl"
  [[ -n "${FORGE_DOUBLE_PID:-}" ]] || forge_double_start
  : > "$FORGE_DOUBLE_DIR/routes"
  forge_route PATCH /api/v1/admin/users/root "${1:-200}" '{}'
  forge_route GET /api/v1/users/root 200 '{"is_admin":true}'
  forge_route GET /api/v1/user 200 '{"login":"root"}'
  forge_route POST /api/v1/users/root/tokens 201 '{"sha1":"OP-TOKEN"}'
  local tokens="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  echo "$FORGE_DOUBLE_URL" > "$tokens/forge.url"; echo "tok-master" > "$tokens/forge-master.token"
  HROOT="$hroot"
}

@test "root, banc : l'humain reçoit ses mots de passe unix et forge, l'adminité, son jeton opérateur, et l'absence de creds est dite" {
  arbre
  banc
  SUDO_USER=root root --bench --humain-demo root
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'root:toto32toto32' "$TRACE"
  [ "$(forge_requests 'select(.method == "PATCH") | .auth')" = '"token tok-master"' ]
  [ "$(forge_requests 'select(.method == "PATCH") | .body | fromjson | [.password, .admin] | @csv')" = '"\"toto32toto32\",true"' ]
  [ "$(forge_requests 'select(.method == "POST") | .auth')" = '"basic root:toto32toto32"' ]
  [ -s "$BATS_TEST_TMPDIR/curl.argv" ]
  refute grep -qE 'tok-master|toto32toto32' "$BATS_TEST_TMPDIR/curl.argv"
  [ "$(cat "$HROOT/.gitea_token")" = "OP-TOKEN" ]
  [ "$(stat -c %a "$HROOT/.gitea_token")" = "600" ]
  [[ "$output" == *"banc : mot de passe unix posé sur « root »"*"« root » sur la forge — mot de passe de banc, site-admin, jeton opérateur"*"creds claude non posées chez « root »"*"n'en a pas"*"/login"* ]]
  refute_out '\b(rejoue|tu|ton)\b' <<<"$output"
}

@test "root, banc, lancé en root sans sudo : l'absence du compte d'origine est dite, l'acceptation se joue, la sortie est 0" {
  arbre
  banc
  LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=root root
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"creds claude non posées chez « root » : le compte qui a lancé l'installation est inconnu"* ]]
  grep -q '^ACCEPT:' "$TRACE"
}

@test "root, banc : un humain pas encore matérialisé est dit, rien n'est posé ; un refus de la forge est dit" {
  arbre
  banc
  printf '#!/usr/bin/env bash\nexit 2\n' > "$BINDIR/getent"
  LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=root root
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc : « root » n'existe pas encore sur cette machine"* ]]
  [ ! -s "$FORGE_DOUBLE_DIR/requests.jsonl" ]
  banc 403
  LCARS_BENCH=1 LCARS_BUILTIN_HUMAN=root root
  [ "$status" -eq 0 ]
  [[ "$output" == *"refuse le compte « root » (HTTP 403)"*"« root » non semé sur la forge"* ]]
  [ ! -e "$HROOT/.gitea_token" ]
}

@test "root, hors banc : l'humain de démonstration n'est pas semé même s'il est nommé" {
  arbre
  banc
  LCARS_BUILTIN_HUMAN=root root
  [ "$status" -eq 0 ]
  [[ "$output" != *"banc :"* ]]
  [ ! -s "$FORGE_DOUBLE_DIR/requests.jsonl" ]
  refute grep -q 'toto32toto32' "$TRACE"
}

# ─── le kit ─────────────────────────────────────────────────────────────────────────────────────

@test "--from <kit.tar.gz> : sha256 vérifié, détaré sous l'utilisateur, puis la mesure et sudo se jouent depuis le kit" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local k; k="$(kit lcars-fleet-1.0-abc)"
  ws --from "$k" --port-deck 20991
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"sha256 vérifié"* ]]
  local racine="$HOME/.lcars/kits/lcars-fleet-1.0-abc/lcars_install"
  [ -x "$racine/deploy/provision" ]
  [ -f "$racine/.source-revision" ]
  [[ "$output" == *"kit : $racine"*"depuis ce kit"* ]]
  grep -q '^KIT-PROVISION:mesure --faits [^ ]* --port-deck 20991$' "$TRACE"
  [ "$(sudo_ligne)" = "bash $racine/deploy/workstation up --port-deck 20991" ]
  grep -q '^KIT-PROVISION:apply --faits ' "$TRACE"
  refute grep -qE '^PROVISION:' "$TRACE"
  refute grep -qE '^(SUDO|KIT-PROVISION):.*\.tar\.gz' "$TRACE"
  sans_faits_restants
}

@test "--from : sans .sha256 à côté, il le dit et continue ; avec un .sha256 faux, il refuse et ne détare rien" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local k; k="$(kit sans --sans-sha256)"
  ws --from "$k"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun $k.sha256 à côté"*"n'est pas vérifié"* ]]
  [ -d "$HOME/.lcars/kits/sans/lcars_install" ]
  grep -q '^SUDO:' "$TRACE"
  : > "$TRACE"
  k="$(kit faux --sha256-faux)"
  ws --from "$k"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne correspond pas"*"$k.sha256"* ]]
  [ ! -d "$HOME/.lcars/kits/faux" ]
  refute grep -q '^SUDO:' "$TRACE"
  sans_faits_restants
}

@test "--from : un répertoire détaré vaut s'il porte son tampon et deploy/workstation ; sinon un seul refus nommé" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local k; k="$(kit k2)"; mkdir -p "$BATS_TEST_TMPDIR/detare"; tar -xzf "$k" -C "$BATS_TEST_TMPDIR/detare"
  local racine="$BATS_TEST_TMPDIR/detare/lcars_install"
  ws --from "$racine"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sudo_ligne)" = "bash $racine/deploy/workstation up" ]
  rm -f "$racine/.source-revision"
  ws --from "$racine"
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $racine » n'est pas un kit LCARS"*"un checkout se pose sans --from"* ]]
  ws --from "$BATS_TEST_TMPDIR/detare"
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $BATS_TEST_TMPDIR/detare » n'est pas un kit LCARS"* ]]
  ws --from "$BATS_TEST_TMPDIR/nulle-part"
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $BATS_TEST_TMPDIR/nulle-part » n'est pas un kit LCARS"* ]]
}

@test "--from : un tar sans racine de kit est refusé, et le compte des racines trouvées est juste" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  mkdir -p "$BATS_TEST_TMPDIR/kits" "$BATS_TEST_TMPDIR/vide/x"
  tar -czf "$BATS_TEST_TMPDIR/kits/vide.tar.gz" -C "$BATS_TEST_TMPDIR/vide" x
  ws --from "$BATS_TEST_TMPDIR/kits/vide.tar.gz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne porte pas un kit LCARS (0 racine(s)"* ]]
  refute grep -q '^SUDO:' "$TRACE"
}

@test "--from : un tar tronqué ne touche pas au kit déjà détaré de ce nom, et aucun échafaudage ne reste" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre
  local k; k="$(kit k7 --sans-sha256)"
  ws --from "$k"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local kits="$HOME/.lcars/kits"
  [ "$(cat "$kits/k7/lcars_install/.source-revision")" = cafe1234 ]
  # le même nom, une autre révision : un fichier en tête d'archive, puis un gros fichier coupé en route
  local st="$BATS_TEST_TMPDIR/stage-tronque"; mkdir -p "$st/lcars_install"
  printf 'beef5678\n' > "$st/lcars_install/.source-revision"
  head -c 4000000 /dev/urandom > "$st/lcars_install/gros"
  tar -czf "$k" -C "$st" lcars_install/.source-revision lcars_install/gros
  truncate -s 1000000 "$k"
  : > "$TRACE"
  ws --from "$k"
  [ "$status" -eq 1 ]
  [[ "$output" == *"détarage de $k en échec"* ]]
  [ "$(cat "$kits/k7/lcars_install/.source-revision")" = cafe1234 ]
  [ ! -e "$kits/k7/lcars_install/gros" ]
  [ -z "$(compgen -G "$kits/.*.partiel" || true)" ]
  refute grep -q '^SUDO:' "$TRACE"
}

@test "--from : deux kits dans le même geste est un refus, un seul arbre se pose" {
  arbre
  local k1 k2; k1="$(kit k3)"; k2="$(kit k4)"
  ws --from "$k1" --from "$k2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"un seul kit à la fois"* ]]
  refute grep -qE '^(SUDO|KIT-PROVISION|PROVISION):' "$TRACE"
}

@test "--from : un kit ne se détare pas sous root" {
  arbre
  local k; k="$(kit k5)"
  root --from "$k"
  [ "$status" -eq 1 ]
  [[ "$output" == *"se lance sans sudo"* ]]
  [ ! -d "$HOME/.lcars/kits/k5" ]
}
