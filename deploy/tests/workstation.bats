#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/workstation.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du délégué du poste — escalade, canal, kit, provisionnement, acceptation, sortie
#
# Le délégué est copié dans un deploy/ factice avec la lib réelle ; provision, accept et sudo sont
# des doublures qui notent leurs appels dans TRACE. Le chemin root se joue sous « unshare -Ur »,
# où EUID vaut 0 sans privilège : rien n'est posé sur la machine.

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  unset SUDO_USER
  SRC="$BATS_TEST_DIRNAME/../workstation"
  [ -f "$SRC" ]
}

arbre() { # arbre <faits…> — le deploy/ factice ; les faits sont ceux que provision doctor rendra
  local d="$BATS_TEST_TMPDIR/arbre/deploy"; rm -rf "$BATS_TEST_TMPDIR/arbre"; mkdir -p "$d"
  cp "$SRC" "$d/workstation"; cp -a "$BATS_TEST_DIRNAME/../lib" "$d/lib"
  { echo '#!/usr/bin/env bash'
    echo 'echo "PROVISION:$*" >> "${TRACE:?}"'
    echo 'if [[ "$1" == apply ]]; then [[ "$*" == *--only* ]] || exit "${PROVISION_RC:-0}"; exit 0; fi'
    echo '[[ -n "${PROV_FACTS_FILE:-}" ]] || exit 0'
    echo 'cat > "$PROV_FACTS_FILE" <<FACTS'; printf '%s\n' "$@"; echo 'FACTS'
  } > "$d/provision"
  { echo '#!/usr/bin/env bash'
    echo 'echo "ACCEPT:$*" >> "${TRACE:?}"'
    echo 'echo "  OUI   décor : acceptation jouée"'
    echo '[[ "$1" == --announce-file && -n "$2" ]] && printf "forge du poste\tbob\tSECRET-DE-DECOR\n" >> "$2"'
    echo '[[ -z "${ACCEPT_KILL:-}" ]] || { kill -TERM "$PPID"; sleep 2; }'
    echo 'exit "${ACCEPT_RC:-0}"'
  } > "$d/accept"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  printf '#!/usr/bin/env bash\necho "SUDO:$*" >> "${TRACE:?}"\nexit 0\n' > "$BINDIR/sudo"
  chmod 0755 "$d/provision" "$d/accept" "$d/workstation" "$BINDIR/sudo"
  export TRACE="$BATS_TEST_TMPDIR/trace"; : > "$TRACE"
  export PATH="$BINDIR:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  WS="$d/workstation"
}

kit() { # kit <nom> [--sans-sha256|--sha256-faux] — un kit.tar.gz (lcars_install/, tampon, deploy complet) et son .sha256
  local nom="$1" mode="${2:-}"
  local st="$BATS_TEST_TMPDIR/stage-$nom"
  mkdir -p "$st/lcars_install/deploy"
  printf 'cafe1234\n' > "$st/lcars_install/.source-revision"
  cp "$SRC" "$st/lcars_install/deploy/workstation"; cp -a "$BATS_TEST_DIRNAME/../lib" "$st/lcars_install/deploy/lib"
  { echo '#!/usr/bin/env bash'
    echo 'echo "KIT-PROVISION:$*" >> "${TRACE:?}"'
    echo '[[ -z "${PROV_FACTS_FILE:-}" || -z "${KIT_FACTS:-}" ]] || printf "%s\n" "$KIT_FACTS" > "$PROV_FACTS_FILE"'
  } > "$st/lcars_install/deploy/provision"
  chmod 0755 "$st/lcars_install/deploy/provision" "$st/lcars_install/deploy/workstation"
  mkdir -p "$BATS_TEST_TMPDIR/kits"
  tar -czf "$BATS_TEST_TMPDIR/kits/$nom.tar.gz" -C "$st" lcars_install
  case "$mode" in
    --sans-sha256) ;;
    --sha256-faux) printf '%s  %s\n' "$(printf 'x%.0s' {1..64})" "$nom.tar.gz" > "$BATS_TEST_TMPDIR/kits/$nom.tar.gz.sha256" ;;
    *) ( cd "$BATS_TEST_TMPDIR/kits" && sha256sum "$nom.tar.gz" > "$nom.tar.gz.sha256" ) ;;
  esac
  printf '%s\n' "$BATS_TEST_TMPDIR/kits/$nom.tar.gz"
}

ws()   { run bash "$WS" up "$@"; }
root() {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le chemin root ne se joue pas ici"
  run unshare -Ur bash "$WS" up "$@"
}

# ─── structure ──────────────────────────────────────────────────────────────────────────────────

# bats test_tags=structure
@test "il est exécutable dans l'index git : la porte l'appelle" {
  run git -C "$BATS_TEST_DIRNAME/../.." ls-files -s deploy/workstation
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

# bats test_tags=structure
@test "toute FORGE_ que la lib lit dans l'environnement traverse le sudo" {
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh" lues manquantes="" v
  lues="$(grep -ohE '\$\{FORGE_[A-Z_]+' "$lib" | tr -d '${' | sort -u)"
  [ -n "$lues" ]
  for v in $lues; do
    grep -qE "ESCALADE_ENV=\(.*[( ]$v([) ]|\$)" "$SRC" || manquantes="$manquantes $v"
  done
  [ -z "$manquantes" ] || { echo "lue(s) par la lib et perdue(s) au sudo :$manquantes"; return 1; }
}

# ─── l'entrée ───────────────────────────────────────────────────────────────────────────────────

@test "l'aide marche sans root et sans rien d'autre" {
  run env -i PATH=/usr/bin:/bin bash "$SRC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"workstation up"*"--from <kit.tar.gz>"*"workstation doctor"*"EXIT"* ]]
  [[ "$output" == *"ne se pose pas sur un autre"* ]]
  refute_out '\.deb' <<<"$output"
}

@test "un verbe inconnu est refusé" {
  run bash "$SRC" zzz
  [ "$status" -eq 1 ]
  [[ "$output" == *"verbe inconnu : zzz"* ]]
}

@test "doctor n'escalade pas et passe ses options à provision" {
  arbre channel=aucun
  run bash "$WS" doctor --port-deck 20991
  [ "$status" -eq 0 ]
  grep -qx "PROVISION:doctor --port-deck 20991" "$TRACE"
  refute grep -q '^SUDO:' "$TRACE"
}

# ─── l'escalade ─────────────────────────────────────────────────────────────────────────────────

@test "sans root, le délégué se relance par sudo avec la liste blanche posée, jamais un secret" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun
  LCARS_ALLOW_ANY_HOST=1 PROV_FORGE_MONTEE=1 LCARS_BUILTIN_HUMAN=lcars FORGE_BASE_URL=http://forge.test \
    FORGE_ADMIN_TOKEN=tres-secret PROV_VERBOSE='' ws --port-deck 20991
  [ "$status" -eq 0 ]
  [[ "$output" == *"[sudo] Privilèges root requis"* ]]
  local ligne; ligne="$(grep '^SUDO:' "$TRACE")"
  [[ "$ligne" == SUDO:*"LCARS_ALLOW_ANY_HOST=1 PROV_FORGE_MONTEE=1 LCARS_BUILTIN_HUMAN=lcars FORGE_BASE_URL=http://forge.test bash $WS up --port-deck 20991" ]]
  [[ "$ligne" != *"TOKEN"* && "$ligne" != *"tres-secret"* && "$ligne" != *"PROV_VERBOSE"* ]]
  refute grep -q 'apply' "$TRACE"
}

@test "sans sudo, le refus est propre et nommé" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun
  local nu="$BATS_TEST_TMPDIR/nu" t; mkdir -p "$nu"
  for t in bash sed tail cat mktemp env readlink dirname basename id getent cut grep tr head sort awk; do
    ln -sf "$(command -v "$t")" "$nu/$t"
  done
  PATH="$nu" ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"root requis et sudo absent"*"installer sudo"* ]]
}

# ─── le canal ───────────────────────────────────────────────────────────────────────────────────

@test "sans --from, une machine installée par kit refuse le checkout et nomme le geste, avant tout sudo" {
  arbre channel=kit channel_tree=source
  ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"installée par « kit »"*"poserait « source »"*"--from <kit.tar.gz>"*"refaire le terrain"* ]]
  refute grep -q '^SUDO:' "$TRACE"
  grep -q '^PROVISION:doctor --only 00-preflight' "$TRACE"
}

@test "un canal illisible est un refus qui nomme le fichier" {
  arbre channel=invalide channel_tree=source
  ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"illisible"*"/channel"* ]]
  refute grep -q '^SUDO:' "$TRACE"
}

@test "un canal inconnu (produit posé sans tampon) laisse passer un checkout" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=inconnu channel_tree=kit
  ws
  [ "$status" -eq 0 ]
  grep -q '^SUDO:' "$TRACE"
}

# ─── le chemin root : provisionnement, acceptation, sortie ──────────────────────────────────────

@test "root : la mesure et l'apply reçoivent les mêmes options, l'acceptation suit, la sortie est 0" {
  arbre channel=aucun substrat=linux docker=present consent=env
  root --port-deck 20991 --forge-project bob_9
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q '^SUDO:' "$TRACE"
  grep -qx "PROVISION:doctor --only 00-preflight --port-deck 20991 --forge-project bob_9" "$TRACE"
  grep -qx "PROVISION:apply --port-deck 20991 --forge-project bob_9" "$TRACE"
  grep -q '^ACCEPT:--announce-file ' "$TRACE"
  [[ "$output" == *"provisionnement terminé"* ]]
  [[ "$output" != *"creds claude"* ]]
}

@test "root : docker absent sur un linux déclaré, la tranche paquets se joue d'abord et la mesure est rejouée" {
  arbre channel=aucun substrat=linux docker=absent consent=env
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker est absent"* ]]
  [ "$(grep -c '^PROVISION:' "$TRACE")" -eq 4 ]
  [ "$(sed -n 2p "$TRACE")" = "PROVISION:apply --only 00-preflight --only 10-packages --only 12-docker-engine" ]
  [ "$(sed -n 3p "$TRACE")" = "PROVISION:doctor --only 00-preflight" ]
  [ "$(sed -n 4p "$TRACE")" = "PROVISION:apply" ]
}

@test "root : docker présent, substrat wsl, ou linux non déclaré par l'environnement : aucune tranche paquets" {
  local decor
  for decor in "substrat=linux docker=present consent=env" \
               "substrat=wsl docker=absent consent=sans-objet" \
               "substrat=linux docker=absent consent=none"; do
    # shellcheck disable=SC2086 # les faits sont des mots, un par ligne
    arbre channel=aucun $decor
    root
    [ "$status" -eq 0 ] || { echo "$decor : $output"; return 1; }
    refute grep -q -- '--only 10-packages' "$TRACE"
  done
}

@test "root : sur un TERM reçu après l'acceptation, les identifiants sont imprimés avant que leur fichier parte" {
  arbre channel=aucun substrat=wsl
  ACCEPT_KILL=1 root
  [ "$status" -ne 0 ]
  [[ "$output" == *"SECRET-DE-DECOR"* ]]
  [[ "$output" != *"provisionnement terminé"* ]]
  [ -z "$(compgen -G "$TMPDIR/lcars-*" || true)" ]
}

@test "root : un drift résiduel de provision est dit, l'acceptation se joue, la sortie est 2" {
  arbre channel=aucun substrat=wsl
  PROVISION_RC=2 root
  [ "$status" -eq 2 ]
  [[ "$output" == *"drift résiduel"*"deploy/workstation doctor"* ]]
  grep -q '^ACCEPT:' "$TRACE"
}

@test "root : un échec de provision arrête tout avant l'acceptation, la sortie est 1" {
  arbre channel=aucun substrat=wsl
  PROVISION_RC=1 root
  [ "$status" -eq 1 ]
  [[ "$output" == *"Provisionnement en échec (rc=1)"* ]]
  refute grep -q '^ACCEPT:' "$TRACE"
  [[ "$output" != *"provisionnement terminé"* ]]
}

@test "root : une acceptation en échec rend 1 même quand provision a convergé" {
  arbre channel=aucun substrat=wsl
  ACCEPT_RC=1 root
  [ "$status" -eq 1 ]
  [[ "$output" == *"provisionnement terminé"* ]]
}

@test "root : les identifiants annoncés sont imprimés en dernier, après le bandeau, et leur fichier ne reste pas" {
  arbre channel=aucun substrat=wsl
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"provisionnement terminé"*"IDENTIFIANTS"*"SECRET-DE-DECOR"* ]]
  [ "$(grep -c 'SECRET-DE-DECOR' <<<"$output")" -eq 1 ]
  [ -z "$(compgen -G "$TMPDIR/lcars-*" || true)" ]
}

@test "root : le bandeau dit la suite de ce terrain — WSL redémarre, linux non — sans familiarité" {
  arbre channel=aucun substrat=wsl
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"wsl --shutdown"*"<humain de fleet> fleet start"* ]]
  [[ "$output" != *"Rien à redémarrer"* ]]
  refute_out '\b(ton|toi|tu|Inscris)\b' <<<"$output"
  arbre channel=aucun substrat=linux
  root
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rien à redémarrer"* ]]
  [[ "$output" != *"wsl --shutdown"* ]]
}

@test "root : les creds du banc — l'humain absent est dit, le compte sans credentials est dit, en termes impersonnels" {
  arbre channel=aucun substrat=wsl
  LCARS_BUILTIN_HUMAN="inexistant-$$" root
  [ "$status" -eq 0 ]
  [[ "$output" == *"creds claude : « inexistant-$$ » n'existe pas encore"* ]]
  LCARS_BUILTIN_HUMAN="$(id -un)" LCARS_CREDS_SRC="$BATS_TEST_TMPDIR/absent.json" SUDO_USER="$(id -un)" root
  [ "$status" -eq 0 ]
  [[ "$output" == *"creds claude non posées chez « $(id -un) »"*"n'en a pas"*"/login"* ]]
  refute_out '\b(rejoue|tu|ton)\b' <<<"$output"
}

# ─── le kit ─────────────────────────────────────────────────────────────────────────────────────

@test "--from <kit.tar.gz> : sha256 vérifié, détaré sous l'utilisateur, puis tout se joue depuis le kit" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun channel_tree=source
  local k; k="$(kit lcars-fleet-1.0-abc)"
  ws --from "$k" --port-deck 20991
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"sha256 vérifié"* ]]
  local racine="$HOME/.lcars/kits/lcars-fleet-1.0-abc/lcars_install"
  [ -x "$racine/deploy/provision" ] && [ -f "$racine/.source-revision" ]
  [[ "$output" == *"kit : $racine"*"depuis ce kit"* ]]
  grep -q '^KIT-PROVISION:doctor --only 00-preflight --port-deck 20991' "$TRACE"
  grep -q "^SUDO:.* bash $racine/deploy/workstation up --from $racine --port-deck 20991$" "$TRACE"
  refute grep -qE '^(SUDO|KIT-PROVISION):.*\.tar\.gz' "$TRACE"
  refute grep -q 'PROVISION:apply' "$TRACE"
}

@test "--from : sans .sha256 à côté, il le dit et continue ; avec un .sha256 faux, il refuse et ne détare rien" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun channel_tree=source
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
}

@test "--from : un répertoire détaré vaut s'il porte deploy/provision et se déclare paquet ; sinon refus nommé" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun channel_tree=source
  local k; k="$(kit k2)"; mkdir -p "$BATS_TEST_TMPDIR/detare"; tar -xzf "$k" -C "$BATS_TEST_TMPDIR/detare"
  local racine="$BATS_TEST_TMPDIR/detare/lcars_install"
  ws --from "$racine"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^SUDO:.* bash $racine/deploy/workstation up --from $racine$" "$TRACE"
  rm -f "$racine/.source-revision"
  ws --from "$racine"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne se déclare pas paquet"* ]]
  ws --from "$BATS_TEST_TMPDIR/detare"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ni un kit.tar.gz, ni un kit détaré"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/vide/x"; tar -czf "$BATS_TEST_TMPDIR/kits/vide.tar.gz" -C "$BATS_TEST_TMPDIR/vide" x
  ws --from "$BATS_TEST_TMPDIR/kits/vide.tar.gz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un kit LCARS"* ]]
}

@test "--from : la seconde instance, dans le kit, mesure et refuse le mélange à son tour" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  arbre channel=aucun channel_tree=source
  local k; k="$(kit k6)"
  KIT_FACTS="channel=source" ws --from "$k"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tout se joue depuis ce kit"*"installée par « source »"*"poserait « kit »"* ]]
  grep -q '^KIT-PROVISION:doctor --only 00-preflight' "$TRACE"
  refute grep -q '^SUDO:' "$TRACE"
}

@test "--from : deux kits dans le même geste est un refus, un seul arbre se pose" {
  arbre channel=aucun channel_tree=source
  local k1 k2; k1="$(kit k3)"; k2="$(kit k4)"
  ws --from "$k1" --from "$k2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"un seul kit à la fois"* ]]
  refute grep -qE '^(SUDO|KIT-PROVISION):' "$TRACE"
}

@test "--from : le refus de mélange vient avant le détarage, et un kit ne se détare pas sous root" {
  arbre channel=kit channel_tree=source
  local k; k="$(kit k5)"
  ws
  [ "$status" -eq 1 ]
  [ ! -d "$HOME/.lcars/kits/k5" ]
  arbre channel=aucun channel_tree=source
  root --from "$k"
  [ "$status" -eq 1 ]
  [[ "$output" == *"se lance sans sudo"* ]]
  [ ! -d "$HOME/.lcars/kits/k5" ]
}
