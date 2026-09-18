#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/provision.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-14
# STATUS: témoins du runner — substrat mesuré, sélection par en-têtes, barrière du préflight, codes de verdict, journal

load refute
load support/decor

setup() {
  # rien de l'environnement du lanceur ne doit décider d'un cas : ni un port, ni une forge, ni un siège
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  unset SUDO_USER
  SRC="$BATS_TEST_DIRNAME/.."
  MODULES="$SRC/modules.d"
  SANDBOX="$BATS_TEST_TMPDIR/prov"
  mkdir -p "$SANDBOX/lib" "$SANDBOX/modules.d"
  cp "$SRC/provision" "$SRC/installer-constants.env" "$SRC/system.manifest" "$SANDBOX/"
  cp "$SRC/lib/provision-lib.sh" "$SRC/lib/provision-audit.sh" "$SRC/lib/docker-endpoint.sh" "$SANDBOX/lib/"
  export RUN_LOG="$BATS_TEST_TMPDIR/run.log"
  : > "$RUN_LOG"
  # prov_lock_path exige un emplacement sûr : sans lui, tout apply refuse son verrou
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  decor_pose
  JOURNAL="$LCARS_DECOR_ROOT/opt/lcars/var/install.journal"
}

terrain() { # terrain <wsl|docker|linux> — ce que detect_substrate mesure sous le décor
  rm -rf "$LCARS_DECOR_ROOT/proc" "$LCARS_DECOR_ROOT/.dockerenv"
  case "$1" in
    wsl)    mkdir -p "$LCARS_DECOR_ROOT/proc"
            echo 'Linux version 6.6.114.1-microsoft-standard-WSL2' > "$LCARS_DECOR_ROOT/proc/version" ;;
    docker) : > "$LCARS_DECOR_ROOT/.dockerenv" ;;
  esac
}

stub_module() { # stub_module <NN-nom> <APPLY-ON> <CHECK-ON> [variable du rc]
  local name="$1" apply_on="$2" check_on="$3" rcvar="${4:-STUB_RC_UNSET}"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: $apply_on
# CHECK-ON: $check_on
# NEEDS: root
set -euo pipefail
echo "$name:\$1" >> "\$RUN_LOG"
exit "\${$rcvar:-0}"
EOF
}

lib_module() { # lib_module <NN-nom> <corps de la sonde> — un module qui source la lib et rend un verdict
  local name="$1" body="$2"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
set -euo pipefail
. "\${PROVISION_LIB:?}"
probe() { $body; }
echo "$name:\$1" >> "\$RUN_LOG"
case "\$1" in
  check) probe; verdict_check ;;
  apply) probe; verdict_apply ;;
esac
EOF
}

mort_module() { # mort_module <NN-nom> <source la lib : 0|1> — meurt sous pipefail avant tout verdict
  { echo '#!/usr/bin/env bash'
    echo '# APPLY-ON: any'
    echo '# CHECK-ON: any'
    echo '# NEEDS: root'
    echo 'set -euo pipefail'
    [[ "$2" -eq 1 ]] && echo '. "${PROVISION_LIB:?}"'
    echo 'x="$(sed -n '"'"'s/^X=//p'"'"' /inexistant-par-construction 2>/dev/null | tail -n1)"'
    echo 'echo "jamais atteint: $x"'
  } > "$SANDBOX/modules.d/$1.sh"
}

# ─── le substrat ────────────────────────────────────────────────────────────────────────────────

@test "doctor sous docker joue le check d'un module que l'image a appliqué, sans une ligne ERREUR" {
  terrain docker
  stub_module 10-pkgstub "wsl linux" any
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  grep -q "10-pkgstub:check" "$RUN_LOG"
  [[ "$output" != *"ERREUR"* ]]
}

@test "apply sous docker applique ce qui déclare docker et vérifie le reste" {
  terrain docker
  stub_module 60-deploystub "wsl linux" any
  stub_module 61-imagestub "wsl linux docker" any
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  grep -q "61-imagestub:apply" "$RUN_LOG"
}

@test "doctor et list se jouent sous docker" {
  terrain docker
  stub_module 60-deploystub "wsl linux" any
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  run "$SANDBOX/provision" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"60-deploystub"* ]]
}

@test "un drift au doctor sous docker : rc 1, et le remède se joue depuis l'hôte par qui a tiré l'image — jamais rebâtir" {
  terrain docker
  stub_module 60-deploystub "wsl linux" any STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  local root
  root="$(PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -n "$root" ]
  echo "abcd1234" > "$root/.source-revision"
  run "$SANDBOX/provision" doctor
  rm -f "$root/.source-revision"
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift: 1"* ]]
  [[ "$output" == *"depuis l'hôte, tirer à nouveau l'image de cette version"*"deploy/container pull"*"deploy/container -p <projet> up"*"bench-swap-image.sh"* ]]
  [[ "$output" == *"le signaler avec"*"la révision abcd1234"* ]]
  refute_out 'pack\.sh|rebâtir' <<<"$output"
  [[ "$output" != *"converger : sudo"* ]]
}

@test "doctor : un check qui rend 2 sur ses lignes FAIL est un échec dit par elles, jamais une sonde en erreur" {
  terrain docker
  lib_module 00-preflight 'p_fail "port 20999 (deck) tenu par un autre"'
  lib_module 20-okstub 'p_ok "conforme"'
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  00-preflight: port 20999 (deck) tenu par un autre"*"échecs: 1"* ]]
  refute_out 'ERREUR|sonde en erreur' <<<"$output"
  run "$SANDBOX/provision" doctor --porcelain
  grep -qx "00-preflight=FAIL" <<<"$output"
  refute_out '=ERROR' <<<"$output"
}

@test "un substrat forcé qui contredit la mesure est refusé avant tout module ; le substrat mesuré passe" {
  # sous WSL, --substrate linux écarterait 30-wsl et poserait docker-ce à côté de Docker Desktop
  terrain wsl
  stub_module 12-enginestub linux linux
  stub_module 30-wslstub wsl wsl
  run "$SANDBOX/provision" apply --substrate linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"--substrate linux : ce système se mesure « wsl »"* ]]
  [ ! -s "$RUN_LOG" ]
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [ ! -s "$RUN_LOG" ]
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_LOG")" = "30-wslstub:apply" ]
}

@test "list lit les en-têtes d'un autre substrat : rien ne se joue" {
  terrain wsl
  stub_module 12-enginestub linux linux
  run "$SANDBOX/provision" list --substrate linux
  [ "$status" -eq 0 ]
  [[ "$output" == 12-enginestub* ]]
  [ ! -s "$RUN_LOG" ]
}

@test "un module ne lit jamais l'entrée du lanceur : une ligne tapée n'atteint aucun module" {
  terrain docker
  cat > "$SANDBOX/modules.d/10-lecteur.sh" <<'EOF'
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
ligne=""; IFS= read -r ligne || true
echo "10-lecteur:$1:[$ligne]" >> "$RUN_LOG"
EOF
  run bash -c "printf 'jeton-tapé\n' | '$SANDBOX/provision' apply"
  [ "$status" -eq 0 ]
  grep -qxF "10-lecteur:apply:[]" "$RUN_LOG"
}

@test "apply sur son substrat joue l'apply" {
  terrain wsl
  stub_module 60-deploystub "wsl linux" any
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:apply" "$RUN_LOG"
}

@test "un module hors CHECK-ON n'est pas sélectionné" {
  terrain docker
  stub_module 15-toolstub "wsl linux" "wsl linux"
  stub_module 20-anystub any any
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  refute grep -q "15-toolstub" "$RUN_LOG"
  grep -q "20-anystub:check" "$RUN_LOG"
}

# ─── l'identité ─────────────────────────────────────────────────────────────────────────────────

@test "hors décor, sans root : apply et doctor sont refusés avant tout module, mesure se joue" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  # un module qui se déclarerait « human » ne rouvre ni l'apply ni le doctor sans privilège : le runner ne change pas d'identité
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\necho "20-humain:$1" >> "$RUN_LOG"\n' > "$SANDBOX/modules.d/20-humain.sh"
  stub_module 00-preflight any any
  run env -u LCARS_DECOR_ROOT "$SANDBOX/provision" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"doctor exige root"*"relancer : sudo $SANDBOX/provision doctor"* ]]
  run env -u LCARS_DECOR_ROOT "$SANDBOX/provision" apply --only 20
  [ "$status" -eq 1 ]
  [[ "$output" == *"apply exige root"*"relancer : sudo $SANDBOX/provision apply --only 20"* ]]
  [ ! -s "$RUN_LOG" ]
  run env -u LCARS_DECOR_ROOT "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$RUN_LOG")" = "00-preflight:check" ]
}

phase_module() { # phase_module <rc> — un préflight qui note la phase que le runner lui donne, et un fait
  cat > "$SANDBOX/modules.d/00-preflight.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
. "\${PROVISION_LIB:?}"
echo "00-preflight:\$1 phase=\${PROV_PHASE:-}" >> "\$RUN_LOG"
p_fact phase "\${PROV_PHASE:-entier}"
[[ "$1" -eq 0 ]] || p_fail "port 20999 (deck) tenu par python3 (pid 4243)"
verdict_check
EOF
}

@test "mesure joue le préflight seul, en phase sans privilège, et écrit ses faits suivis de son verdict" {
  terrain wsl
  phase_module 0
  stub_module 20-suivant any any
  run "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$RUN_LOG")" = "00-preflight:check phase=sans-privilege" ]
  [ "$(cat "$BATS_TEST_TMPDIR/faits")" = "$(printf 'phase=sans-privilege\npreflight=conforme')" ]
}

@test "un refus du préflight en mesure est un verdict, jamais une sonde en erreur" {
  terrain wsl
  phase_module 1
  run "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 2 ]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/faits")" = "preflight=refuse" ]
  [[ "$output" == *"FAIL  00-preflight: port 20999 (deck) tenu par python3 (pid 4243)"*"échecs: 1"* ]]
  refute_out 'ERREUR|sonde en erreur' <<<"$output"
}

@test "mesure en root joue la phase root, et aucune option ne lui tend de faits d'avant sudo" {
  # sans décor : le runner refuse root sous LCARS_DECOR_ROOT ; le module de décor ne lit rien de la machine
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : root ne se joue pas ici"
  phase_module 0
  run env -u LCARS_DECOR_ROOT unshare -Ur "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$RUN_LOG")" = "00-preflight:check phase=root" ]
  grep -qx 'phase=root' "$BATS_TEST_TMPDIR/faits"
  run env -u LCARS_DECOR_ROOT unshare -Ur "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits" --ports-tenus ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue: --ports-tenus"* ]]
  # la grille d'un installeur lancé en root se mesure en phase sans privilège, sur demande explicite
  : > "$RUN_LOG"
  run env -u LCARS_DECOR_ROOT unshare -Ur "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits" --sans-privilege
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$RUN_LOG")" = "00-preflight:check phase=sans-privilege" ]
  run "$SANDBOX/provision" doctor --sans-privilege
  [ "$status" -eq 1 ]
  [[ "$output" == *"--sans-privilege ne vaut que pour mesure"* ]]
}

@test "mesure refuse ce qu'elle n'honore pas : sans --faits, avec --only ; --faits hors mesure et apply" {
  terrain wsl
  phase_module 0
  run "$SANDBOX/provision" mesure
  [ "$status" -eq 1 ]
  [[ "$output" == *"mesure écrit ses faits dans --faits FICHIER"* ]]
  run "$SANDBOX/provision" mesure --faits "$BATS_TEST_TMPDIR/faits" --only 00
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only ne vaut pas pour mesure"* ]]
  run "$SANDBOX/provision" doctor --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--faits ne vaut que pour mesure"* ]]
  [ ! -s "$RUN_LOG" ]
}

@test "apply --faits reçoit une mesure root conforme : le préflight n'est pas rejoué, il compte, rendu par la mesure ; appelé seul, il le joue" {
  terrain wsl
  phase_module 0
  stub_module 20-suivant any any
  ( umask 077; printf 'phase=root\nport_deck=20999 nous lcars-landing (service)\npreflight=conforme\n' > "$BATS_TEST_TMPDIR/faits" )
  run "$SANDBOX/provision" apply --faits "$BATS_TEST_TMPDIR/faits"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$RUN_LOG")" = "20-suivant:apply" ]
  [[ "$output" == *"=== 00-preflight (rendu par la mesure) ==="*"modules: 2 · conformes/convergés: 2"* ]]
  grep -qx "modules       total=2 ok=2 drift=0 failed=0" "$JOURNAL"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_LOG")" = "$(printf '00-preflight:apply phase=\n20-suivant:apply')" ]
}

@test "apply --faits refuse, avant tout module, des faits qui ne sont pas une mesure root conforme, ou qu'un autre que ce compte a pu écrire" {
  terrain wsl
  phase_module 0
  stub_module 20-suivant any any
  local faits="$BATS_TEST_TMPDIR/faits" contenu
  for contenu in 'phase=root\npreflight=refuse' 'phase=sans-privilege\npreflight=conforme' 'phase=root'; do
    ( umask 077; printf '%b\n' "$contenu" > "$faits" )
    run "$SANDBOX/provision" apply --faits "$faits"
    [ "$status" -eq 1 ] || { echo "« $contenu » : $output"; return 1; }
    [[ "$output" == *"ce n'est pas une mesure root conforme"* ]]
  done
  run "$SANDBOX/provision" apply --faits "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  # une mesure conforme, lisible et modifiable par d'autres : elle ne dispense pas du préflight
  printf 'phase=root\npreflight=conforme\n' > "$faits"; chmod 0644 "$faits"
  run "$SANDBOX/provision" apply --faits "$faits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ce fichier n'a pas été écrit par la mesure de ce compte"* ]]
  [ ! -s "$RUN_LOG" ]
}

@test "le runner ne change jamais d'identité : --human nomme l'humain servi, le module tourne sous le runner" {
  terrain wsl
  lib_module 50-humain 'echo "sous=$(id -un) servi=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "servi"'
  sed -i 's/^# NEEDS: root$/# NEEDS: human/' "$SANDBOX/modules.d/50-humain.sh"
  run "$SANDBOX/provision" apply --human root
  [ "$status" -eq 0 ]
  grep -qx "sous=$(id -un) servi=root" "$RUN_LOG"
}

@test "l'uid du siège est celui du compte qui lance : illisible, il ne se devine pas et rien ne se joue ; donné, il sert" {
  terrain wsl
  lib_module 50-siege 'echo "siege=$LCARS_SYSADMIN_UID" >> "$RUN_LOG"; p_ok "siège"'
  run env SUDO_USER=compte-qui-n-existe-pas "$SANDBOX/provision" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"uid du siège illisible pour « compte-qui-n-existe-pas »"* ]]
  [ ! -s "$RUN_LOG" ]
  run env SUDO_USER=compte-qui-n-existe-pas LCARS_SYSADMIN_UID=4242 "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  grep -qx "siege=4242" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor
  grep -qx "siege=$(id -u)" "$RUN_LOG"
}

# ─── options ────────────────────────────────────────────────────────────────────────────────────

@test "--porcelain rend une ligne MODULE=verdict par module" {
  terrain docker
  stub_module 10-okstub any any
  stub_module 60-driftstub "wsl linux" any STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" doctor --porcelain
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "10-okstub=OK" ]
  [ "${lines[1]}" = "60-driftstub=DRIFT" ]
}

@test "--porcelain est refusé à l'apply : rien ne se joue, aucun accumulateur ne reste" {
  terrain wsl
  stub_module 20-x any any
  run "$SANDBOX/provision" apply --porcelain
  [ "$status" -eq 1 ]
  [[ "$output" == *"--porcelain ne vaut que pour doctor"* ]]
  [ ! -s "$RUN_LOG" ]
  [ -z "$(compgen -G "$TMPDIR/prov-journal.*" || true)" ]
}

@test "list montre les deux axes et AFTER" {
  terrain docker
  stub_module 10-pkgstub "wsl linux" any
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: root\n# AFTER: 10-pkgstub\nexit 0\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" list
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == 10-pkgstub*"APPLY-ON=wsl linux"*"CHECK-ON=any"*"NEEDS=root"* ]]
  [[ "${lines[1]}" == 30-aval*"AFTER=10-pkgstub" ]]
}

@test "--only joue ce qu'on lui nomme, par nom ou préfixe, sans fermer AFTER" {
  terrain docker
  stub_module 20-amont any any
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: root\n# AFTER: 20-amont\necho "30-aval:$1" >> "$RUN_LOG"\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" doctor --only 30
  [ "$status" -eq 0 ]
  grep -q "30-aval:check" "$RUN_LOG"
  refute grep -q "20-amont:check" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --only 30-aval
  [ "$status" -eq 0 ]
  grep -q "30-aval:check" "$RUN_LOG"
  refute grep -q "20-amont:check" "$RUN_LOG"
}

@test "les modules jouent dans l'ordre du préfixe" {
  terrain docker
  stub_module 30-aval any any
  stub_module 20-amont any any
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_LOG")" = "$(printf '20-amont:check\n30-aval:check')" ]
}

@test "aucun module sélectionné est un refus qui nomme le substrat et le filtre" {
  terrain docker
  stub_module 20-amont any any
  run "$SANDBOX/provision" doctor --only 99-absent
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun module ne matche"*"docker"*"99-absent"* ]]
}

@test "une option inconnue est refusée, --fleet-human comprise" {
  stub_module 20-amont any any
  run "$SANDBOX/provision" list --fleet-human lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue: --fleet-human"* ]]
}

@test "--env est sourcé avant tout : les modules lisent ses valeurs" {
  terrain wsl
  lib_module 50-env 'echo "deck=$PROV_DECK_PORT forge=${FORGE_BASE_URL:-}" >> "$RUN_LOG"; p_ok "lu"'
  printf 'PROV_DECK_PORT=20995\nFORGE_BASE_URL=http://forge.env:3000\n' > "$BATS_TEST_TMPDIR/env"
  run "$SANDBOX/provision" doctor --env "$BATS_TEST_TMPDIR/env"
  [ "$status" -eq 0 ]
  grep -qx "deck=20995 forge=http://forge.env:3000" "$RUN_LOG"
  run "$SANDBOX/provision" doctor --env "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--env illisible: $BATS_TEST_TMPDIR/absent"* ]]
}

# ─── la barrière du préflight ───────────────────────────────────────────────────────────────────

@test "un préflight en échec à l'apply est une barrière : rien d'autre n'est joué, sortie 1" {
  terrain wsl
  stub_module 00-preflight any any STUB_RC_PRE
  stub_module 20-suivant any any
  export STUB_RC_PRE=1
  run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ARRÊT"*"le préflight refuse ce terrain (ses lignes FAIL ci-dessus)"*"TERRAIN REFUSÉ par le préflight"* ]]
  grep -q "00-preflight:apply" "$RUN_LOG"
  refute grep -q "20-suivant" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor
  grep -q "20-suivant:check" "$RUN_LOG"
}

@test "un plancher en dérive au préflight arrête l'apply comme un échec : rien d'autre n'est joué, sortie 1" {
  # RAM, disque, arch ou OS sous le plancher rendent 2 à l'apply du préflight : le terrain ne tiendra pas l'installation
  terrain wsl
  stub_module 00-preflight any any STUB_RC_PRE
  stub_module 20-suivant any any
  export STUB_RC_PRE=2
  run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  # le constat renvoie aux seules lignes affichées : un drift n'écrit aucune ligne FAIL
  [[ "$output" == *"ARRÊT"*"le préflight refuse ce terrain (ses lignes DRIFT ci-dessus)"* ]]
  [[ "$output" == *"échecs: 1"*"TERRAIN REFUSÉ par le préflight"* ]]
  refute_out 'lignes FAIL|EN ÉCHEC' <<<"$output"
  [[ "$output" != *"Rien n'est cassé"* ]]
  refute grep -q "20-suivant" "$RUN_LOG"
}

@test "un préflight mort avant son verdict arrête l'apply, et une ligne le dit, que la garde de la lib ait parlé ou non" {
  terrain wsl
  stub_module 00-preflight any any STUB_RC_PRE
  stub_module 20-suivant any any
  STUB_RC_PRE=127 run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERREUR 00-preflight: mort avant de rendre son verdict (rc=127)"*"ARRÊT"*"(la ligne ERREUR ci-dessus)"* ]]
  refute grep -q "20-suivant" "$RUN_LOG"
  mort_module 00-preflight 1
  run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [ "$(grep -c 'ERREUR 00-preflight.*mort avant de rendre son verdict' <<<"$output")" -eq 1 ]
  [[ "$output" == *"ARRÊT"*"(la ligne ERREUR ci-dessus)"* ]]
  refute grep -q "20-suivant" "$RUN_LOG"
}

@test "curl et git absents ne sont pas un refus : le vrai préflight les rend en faits, et 10-packages, qui les pose, est joué" {
  terrain linux
  cp "$MODULES/00-preflight.sh" "$SANDBOX/modules.d/"
  stub_module 10-packages "wsl linux docker" any
  # un terrain sain sous le décor : mémoire et disque au-dessus des planchers, docker absent (un avertissement sur linux)
  mkdir -p "$LCARS_DECOR_ROOT/proc"
  printf 'MemTotal:       8388608 kB\n' > "$LCARS_DECOR_ROOT/proc/meminfo"
  printf '#!/usr/bin/env bash\nprintf "Filesystem 1048576-blocks Used Available Capacity Mounted\\nfaux 100000 0 90000 1%%%% /\\n"\n' > "$DECOR_BIN/df"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DECOR_BIN/docker"
  chmod 0755 "$DECOR_BIN/df" "$DECOR_BIN/docker"
  local sans="$BATS_TEST_TMPDIR/sans-git-curl" d f n; mkdir -p "$sans"
  for d in /usr/sbin /usr/bin /sbin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n="${f##*/}"
      [[ -x "$f" && "$n" != git && "$n" != curl && ! -e "$sans/$n" ]] || continue
      ln -s "$f" "$sans/$n"
    done
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/ss"; chmod 0755 "$DECOR_BIN/ss"
  # ⚠ CE CAS JOUE LE VRAI PRÉFLIGHT, qui SONDE les ports de la machine : tout port qu'on ne nomme
  # pas est le défaut, et celui de la forge (21000) est tenu dès qu'un banc tourne sur cet hôte.
  # Sans les deux ports libres, ce témoin mesure la machine au lieu de mesurer la barrière.
  libre() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
  run env PATH="$DECOR_BIN:$sans" LCARS_ALLOW_ANY_HOST=1 "$SANDBOX/provision" apply --port-deck "$(libre)" --port-forge "$(libre)"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"=== 00-preflight (apply) ==="*"OK    00-preflight: arch"*"=== 10-packages (apply) ==="* ]]
  [ "$(cat "$RUN_LOG")" = "10-packages:apply" ]
  refute_out 'ARRÊT' <<<"$output"
}

@test "apply --only garde le préflight comme barrière : un terrain refusé ne reçoit pas le module choisi" {
  terrain wsl
  stub_module 00-preflight any any STUB_RC_PRE
  stub_module 20-suivant any any
  export STUB_RC_PRE=1
  run "$SANDBOX/provision" apply --only 20
  [ "$status" -eq 1 ]
  [[ "$output" == *"le préflight refuse ce terrain"* ]]
  refute grep -q "20-suivant" "$RUN_LOG"
}

@test "apply --only sur un terrain accepté joue le préflight puis le seul module choisi" {
  terrain wsl
  stub_module 00-preflight any any
  stub_module 20-suivant any any
  stub_module 30-autre any any
  run "$SANDBOX/provision" apply --only 20
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_LOG")" = "$(printf '00-preflight:apply\n20-suivant:apply')" ]
}

# ─── les verdicts ───────────────────────────────────────────────────────────────────────────────

@test "un drift dans l'apply rend 2 : appliqué, l'état-cible n'est pas tenu, rien n'est un échec" {
  terrain wsl
  lib_module 50-forgestub 'p_drift "adhesion org non convergee"'
  run "$SANDBOX/provision" apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"conformes/convergés: 0"*"drift: 1"*"échecs: 0"* ]]
  [[ "$output" == *"ÉTAT-CIBLE N'EST PAS TENU"* ]]
  [[ "$output" == *"Rien n'est cassé"* ]]
}

@test "un échec rend 1, le drift ne l'écrase pas, et la phrase rassurante ne sort pas" {
  terrain wsl
  lib_module 40-failstub  'p_fail "quelque chose est casse"'
  lib_module 50-driftstub 'p_drift "et un geste manque"'
  run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift: 1"*"échecs: 1"* ]]
  [[ "$output" == *"EN ÉCHEC"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "un apply convergé rend 0" {
  terrain wsl
  lib_module 20-okstub 'p_ok "converge"'
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"conformes/convergés: 1"*"drift: 0"*"échecs: 0"* ]]
}

@test "le doctor rend 0 conforme et 1 drift, et conseille l'apply sur un rail" {
  terrain wsl
  lib_module 20-okstub 'p_ok "conforme"'
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  rm -f "$SANDBOX/modules.d"/*.sh
  lib_module 50-forgestub 'p_drift "pas conforme"'
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"converger :"*"provision apply"* ]]
}

@test "le récap nomme la révision lue dans le tampon d'une copie hors git" {
  terrain docker
  local root
  root="$(PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -n "$root" ]
  echo "abcd1234" > "$root/.source-revision"
  stub_module 20-anystub any any
  run "$SANDBOX/provision" doctor
  rm -f "$root/.source-revision"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source abcd1234"* ]]
}

@test "ni git ni tampon : la révision est inconnue, jamais devinée" {
  terrain docker
  stub_module 20-anystub any any
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"source inconnue"* ]]
}

@test "doctor : un module mort sans verdict est nommé, rc 2" {
  terrain docker
  mort_module 90-mort 1
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 90-mort"*"mort avant de rendre son verdict"* ]]
}

@test "apply : un module mort est un échec, pas un drift résiduel" {
  terrain wsl
  mort_module 91-mort 1
  run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERREUR 91-mort"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "mort avant de sourcer la lib : le runner nomme quand même" {
  terrain docker
  mort_module 93-tot 0
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 93-tot"* ]]
}

@test "un petit-fils qui source la lib ne déclenche pas la garde de sortie" {
  terrain wsl
  cat > "$SANDBOX/modules.d/94-petitfils.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
set -euo pipefail
. "\$PROVISION_LIB"
rc=0
bash -c '. "\$PROVISION_LIB"; echo PETIT-FILS-OK; exit 0' || rc=\$?
echo "PETIT-FILS-RC=\$rc"
p_ok "le module rend son verdict"
verdict_apply
EOF
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"PETIT-FILS-OK"*"PETIT-FILS-RC=0"* ]]
  [[ "$output" != *"mort avant de rendre son verdict"* ]]
}

# ─── ports et projet ────────────────────────────────────────────────────────────────────────────

# bats test_tags=unit
@test "les trois ports sont validés au parseur : un nombre, dans la plage" {
  stub_module 10-x any any
  run "$SANDBOX/provision" list --port-forge 21001 --port-deck 20998 --port-ssh 2222
  [ "$status" -eq 0 ]
  run "$SANDBOX/provision" list --port-forge 80
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-forge : 80 hors plage"*"son compte de service, ne peut pas binder"* ]]
  printf '%s\n' "$output" | refute_out 'lcars-system'
  run "$SANDBOX/provision" list --port-ssh pasunport
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-ssh : « pasunport » n'est pas un nombre"* ]]
}

# bats test_tags=unit
@test "--forge-project refuse ce qui n'est pas un nom de projet compose" {
  stub_module 10-x any any
  run "$SANDBOX/provision" list --forge-project Bob_9
  [ "$status" -eq 1 ]
  [[ "$output" == *"--forge-project : « Bob_9 »"* ]]
  run "$SANDBOX/provision" list --forge-project bob_9
  [ "$status" -eq 0 ]
}

@test "la base de projet donne un hostname : un bord « _ » ou « - », ou plus de 63 caractères, est refusé avant tout module — drapeau ou --env" {
  terrain wsl
  lib_module 10-pose 'echo pose >> "$RUN_LOG"; p_ok "ok"'
  local base
  for base in bob_ bob- "$(printf 'a%.0s' {1..64})"; do
    : > "$RUN_LOG"
    run "$SANDBOX/provision" apply --forge-project "$base"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--forge-project : « $base » n'est pas une base de projet"* ]] || { echo "$output"; return 1; }
    printf 'PROV_FORGE_BASE=%s\n' "$base" > "$BATS_TEST_TMPDIR/base.env"
    run "$SANDBOX/provision" apply --env "$BATS_TEST_TMPDIR/base.env"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PROV_FORGE_BASE : « $base » n'est pas une base de projet"* ]] || { echo "$output"; return 1; }
    [ ! -s "$RUN_LOG" ]
  done
  run "$SANDBOX/provision" apply --forge-project "b_$(printf 'a%.0s' {1..61})"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "les ports atteignent les modules, et une passe suivante les relit dans le journal" {
  terrain wsl
  lib_module 50-ports 'echo "deck=$PROV_DECK_PORT" >> "$RUN_LOG"; p_ok "ok"'
  run "$SANDBOX/provision" apply --port-deck 20997
  [ "$status" -eq 0 ]
  grep -qx "deck=20997" "$RUN_LOG"
  grep -q "^params .*PROV_DECK_PORT=20997" "$JOURNAL"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  grep -qx "deck=20997" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --port-deck 20990
  [ "$status" -eq 0 ]
  grep -qx "deck=20990" "$RUN_LOG"
}

@test "l'humain de démonstration d'un banc est retenu : une passe sans lui le relit, et le produit reçoit le même nom" {
  terrain wsl
  lib_module 50-humain 'prov_product_env; printf "%s\n" "prov=$PROV_BUILTIN_HUMAN" "${PROV_PRODUCT_ENV[@]}" | grep -E "^(prov=|LCARS_BUILTIN_HUMAN=)" >> "$RUN_LOG"; p_ok "ok"'
  run env LCARS_BUILTIN_HUMAN=demo "$SANDBOX/provision" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'params *PROV_BUILTIN_HUMAN=demo' "$JOURNAL"
  : > "$RUN_LOG"
  run env -u LCARS_BUILTIN_HUMAN "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -qx "prov=demo" "$RUN_LOG"
  grep -qx "LCARS_BUILTIN_HUMAN=demo" "$RUN_LOG"
  : > "$RUN_LOG"
  run env LCARS_BUILTIN_HUMAN=autre "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -qx "LCARS_BUILTIN_HUMAN=autre" "$RUN_LOG"
}

@test "un humain de démonstration qui porte le nom de l'org système est refusé — par le drapeau comme par le journal, avant tout module" {
  # sur Gitea une org EST un utilisateur : les deux partagent un espace de noms. Sans ce refus, la
  # structure de la forge meurt au milieu d'un plan tofu, sur une ligne qui parle d'org (mesuré le
  # 2026-09-17 sur le banc 2003). Le journal compte autant que le drapeau : une machine installée
  # avant ce refus le rejoue tel quel, et un changement de défaut ne la rattrape pas.
  terrain wsl
  lib_module 50-humain 'printf "joue=%s\\n" "$PROV_BUILTIN_HUMAN" >> "$RUN_LOG"; p_ok "ok"'
  local org; org="$(sed -n 's/^PROV_FORGE_ORG_DEFAULT=//p' "$SANDBOX/installer-constants.env")"
  [ -n "$org" ]

  run env "LCARS_BUILTIN_HUMAN=$org" "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $org » porte le nom de l'org système"*"Rien n'a été fait"* ]] || { echo "$output"; return 1; }
  refute grep -q . "$RUN_LOG"

  # par le journal, sans aucun drapeau : le nom vient de la ligne `params` d'une passe d'avant
  printf '%s\n' '# SOURCE: journal' "params        PROV_BUILTIN_HUMAN=$org" > "$JOURNAL"
  run env -u LCARS_BUILTIN_HUMAN "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $org » porte le nom de l'org système"* ]] || { echo "$output"; return 1; }
  refute grep -q . "$RUN_LOG"

  # l'org du catalogue EMBARQUE vit dans le meme espace de noms, et la meme recette la pose
  local cat; cat="$(sed -n 's/^PROV_BUNDLED_CATALOGUE=//p' "$SANDBOX/installer-constants.env")"
  [ -n "$cat" ]
  run env "LCARS_BUILTIN_HUMAN=$cat" "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« $cat » porte le nom de l'org du catalogue embarqué"* ]] || { echo "$output"; return 1; }

  # CE QUI LIT NE REFUSE RIEN : la machine dont le journal retient le nom fautif est exactement
  # celle qu'on veut sonder, et « doctor » est la sonde que le bandeau de l'installeur imprime
  printf '%s\n' '# SOURCE: journal' "params        PROV_BUILTIN_HUMAN=$org" > "$JOURNAL"
  run env -u LCARS_BUILTIN_HUMAN "$SANDBOX/provision" list
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env -u LCARS_BUILTIN_HUMAN "$SANDBOX/provision" doctor
  [ "$status" -ne 1 ] || { echo "$output"; return 1; }

  # desarme : tout autre nom passe, et le module joue
  printf '%s\n' '# SOURCE: journal' 'params        PROV_BUILTIN_HUMAN=captain' > "$JOURNAL"
  run env -u LCARS_BUILTIN_HUMAN "$SANDBOX/provision" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "joue=captain" "$RUN_LOG" || { cat "$RUN_LOG"; return 1; }
}

@test "la ligne params ne retient que les choix hors défaut : absente, posée, relue, retirée au défaut" {
  # un défaut écrit au journal deviendrait un choix : la passe suivante ne distinguerait plus l'opérateur de l'usine
  terrain wsl
  lib_module 50-ports 'p_ok "ok"'
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -qx 'params *' "$JOURNAL"
  run "$SANDBOX/provision" apply --port-deck 3000
  [ "$status" -eq 0 ]
  grep -qx 'params *PROV_DECK_PORT=3000' "$JOURNAL"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -qx 'params *PROV_DECK_PORT=3000' "$JOURNAL"
  run "$SANDBOX/provision" apply --port-deck "$(sed -n 's/^PROV_DECK_PORT_DEFAULT=//p' "$SRC/installer-constants.env")"
  [ "$status" -eq 0 ]
  grep -qx 'params *' "$JOURNAL"
}

# ─── le journal ─────────────────────────────────────────────────────────────────────────────────

@test "apply écrit le journal de la machine sous le décor, une passe à la fois, et additionne l'inventaire apt" {
  terrain wsl
  lib_module 20-okstub 'p_ok "converge"'
  mkdir -p "$(dirname "$JOURNAL")"
  printf 'apt_installed  curl git\nposed_at      2026-01-01T00:00:00Z\n' > "$JOURNAL"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  grep -q "^# STATUS: mesure, pas declaration" "$JOURNAL"
  grep -q "^substrate     wsl$" "$JOURNAL"
  grep -q "^modules       total=1 ok=1 drift=0 failed=0$" "$JOURNAL"
  grep -q "^apt_installed .*curl git" "$JOURNAL"
  [ "$(grep -c "^posed_at" "$JOURNAL")" = "1" ]
  refute grep -q "2026-01-01T00:00:00Z" "$JOURNAL"
  [ -z "$(compgen -G "$TMPDIR/prov-journal.*" || true)" ]
}

@test "un journal sans inventaire apt antérieur ni note de la passe ne porte aucune ligne vide" {
  terrain wsl
  lib_module 20-okstub 'p_ok "converge"'
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  refute grep -qE '^\s*$' "$JOURNAL"
}

@test "apply sans fichier temporaire possible est refusé avant tout module, en le nommant : le journal de la passe ne se perd pas en silence" {
  terrain wsl
  lib_module 20-okstub 'echo joue >> "$RUN_LOG"; p_ok "converge"'
  TMPDIR="$BATS_TEST_TMPDIR/nulle-part" run "$SANDBOX/provision" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun fichier temporaire ne se crée dans $BATS_TEST_TMPDIR/nulle-part"* ]]
  [ ! -s "$RUN_LOG" ]
  [ ! -e "$JOURNAL" ]
}

@test "l'inventaire du journal dédoublonne ce que plusieurs modules et la passe précédente notent" {
  terrain wsl
  lib_module 10-apt 'prov_journal_note apt_installed socat jq; p_ok "noté"'
  lib_module 12-apt 'prov_journal_note apt_installed jq gh; p_ok "noté"'
  mkdir -p "$(dirname "$JOURNAL")"
  printf 'apt_installed curl jq\n' > "$JOURNAL"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [ "$(grep -c '^apt_installed ' "$JOURNAL")" -eq 1 ]
  local mots; mots="$(sed -n 's/^apt_installed *//p' "$JOURNAL" | tr ' ' '\n' | sort | paste -sd' ')"
  [ "$mots" = "curl gh jq socat" ]
}

@test "doctor n'ouvre aucun accumulateur et n'écrit aucun journal" {
  # un doctor ne pose rien : un journal écrit par lui raconterait une pose qui n'a pas eu lieu
  terrain wsl
  lib_module 20-note 'prov_journal_note apt_installed socat; p_ok "sonde"'
  run "$SANDBOX/provision" doctor
  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
  [ -z "$(compgen -G "$TMPDIR/prov-journal.*" || true)" ]
}

@test "un journal impossible à écrire se dit en une ligne et ne renverse pas le verdict" {
  terrain wsl
  lib_module 20-okstub 'p_ok "converge"'
  mkdir -p "$JOURNAL"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [ "$(grep -c "journal NON écrit ($JOURNAL)" <<<"$output")" -eq 1 ]
  rm -rf "$LCARS_DECOR_ROOT/opt/lcars/var"
  : > "$LCARS_DECOR_ROOT/opt/lcars/var"
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [ "$(grep -c "journal NON écrit ($JOURNAL)" <<<"$output")" -eq 1 ]
}

# ─── garde-fous ─────────────────────────────────────────────────────────────────────────────────

@test "en root sous un décor, le runner refuse avant tout module, et dit de retirer LCARS_DECOR_ROOT" {
  # sous root, le décor déplacerait les chemins et laisserait useradd, apt, systemctl et docker agir sur la machine
  stub_module 10-rootstub "wsl linux" "wsl linux"
  run unshare -Ur "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [ ! -s "$RUN_LOG" ]
  [[ "$output" == *"LCARS_DECOR_ROOT est posée et le runner tourne en root"*"Retirer LCARS_DECOR_ROOT de l'environnement"* ]]
  run env -u LCARS_DECOR_ROOT unshare -Ur "$SANDBOX/provision" list --substrate wsl
  [ "$status" -eq 0 ]
  [[ "$output" == *"10-rootstub"* ]]
}

@test "un corpus sans le fichier des constantes est refusé, et le fichier est nommé" {
  stub_module 10-x any any
  rm "$SANDBOX/installer-constants.env"
  run "$SANDBOX/provision" list
  [ "$status" -eq 1 ]
  [[ "$output" == *"constantes de l'installeur illisibles : $SANDBOX/lib/../installer-constants.env"* ]]
}

@test "le fd du verrou n'est pas légué au module" {
  terrain wsl
  local fdlog="$BATS_TEST_TMPDIR/fds-du-module"
  cat > "$SANDBOX/modules.d/61-legue.sh" <<MODEOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
set -euo pipefail
. "\${PROVISION_LIB:?}"
ls -l /proc/\$\$/fd > "$fdlog"
p_ok "decor"; verdict_apply
MODEOF
  run "$SANDBOX/provision" apply
  [ "$status" -eq 0 ]
  [ -s "$fdlog" ]
  refute grep -qE 'lcars/provision[^/]*\.lock' "$fdlog"
}

# ─── les modules réels ──────────────────────────────────────────────────────────────────────────

# bats test_tags=structure
@test "les modules réels : NEEDS root, APPLY-ON couvert par CHECK-ON, et aucun check-seul hors docker" {
  # le runner joue chaque module sous sa propre identité : un module qui déclarerait un autre besoin tournerait en root
  local m name apply check needs s bad=""
  for m in "$MODULES"/*.sh; do
    name="$(basename "$m" .sh)"
    apply="$(sed -n 's/^# APPLY-ON:[[:space:]]*//p' "$m" | head -1)"
    check="$(sed -n 's/^# CHECK-ON:[[:space:]]*//p' "$m" | head -1)"
    needs="$(sed -n 's/^# NEEDS:[[:space:]]*//p' "$m" | head -1)"
    [[ -n "$apply" && -n "$check" ]] || bad="$bad $name(en-tête APPLY-ON ou CHECK-ON manquant)"
    [[ "$needs" == root ]] || bad="$bad $name(NEEDS « $needs »)"
    [[ "$apply" == any ]] && apply="wsl linux docker"
    [[ "$check" == any ]] && check="wsl linux docker"
    for s in $apply; do [[ " $check " == *" $s "* ]] || bad="$bad $name(APPLY-ON $s hors CHECK-ON)"; done
    for s in wsl linux; do
      [[ " $check " == *" $s "* ]] || continue
      [[ " $apply " == *" $s "* ]] || bad="$bad $name(check-seul sur $s)"
    done
  done
  [ -z "$bad" ] || { echo "$bad" >&2; false; }
}

# bats test_tags=structure
@test "les modules réels : chaque AFTER nomme un module qui précède" {
  local mod name dep n=0 bad=""
  for mod in "$MODULES"/[0-9][0-9]-*.sh; do
    name="$(basename "$mod" .sh)"
    for dep in $(sed -n 's/^# AFTER: *//p' "$mod" | head -1); do
      n=$((n+1))
      [[ -f "$MODULES/$dep.sh" ]] || bad="$bad $name(AFTER $dep inconnu)"
      [[ "$dep" < "$name" ]] || bad="$bad $name(AFTER $dep ne précède pas)"
    done
  done
  [ "$n" -ge 10 ]
  [ -z "$bad" ] || { echo "$bad" >&2; false; }
}

# bats test_tags=structure
@test "les modules réels : AFTER déclare ce que l'apply emploie — la chaîne de 60, l'hôte de la forge, les avatars de la charte" {
  after() { sed -n 's/^# AFTER: *//p' "$MODULES/$1.sh" | head -1; }
  local manque="" paire mod dep
  for paire in 60-deploy:15-toolchain 60-deploy:20-groups 48-forge-host:12-docker-engine 48-forge-host:21-service-accounts \
               48-forge-host:25-directories 64-services:21-service-accounts 46-tofu:10-packages 61-forge-structure:44-media; do
    mod="${paire%%:*}"; dep="${paire#*:}"
    [[ " $(after "$mod") " == *" $dep "* ]] || manque="$manque $mod(sans $dep)"
  done
  [ -z "$manque" ] || { echo "$manque" >&2; false; }
  # 48 ne lit aucun média : la charte, qui pose les avatars sur la forge, est jouée par 61
  [[ " $(after 48-forge-host) " != *" 44-media "* ]]
}

# bats test_tags=structure
@test "le README de deploy décrit chaque module avec les terrains qu'il déclare" {
  local readme="$SRC/README.md" missing="" wrong="" f name row a c ra rc
  for f in "$MODULES"/*.sh; do
    name="$(basename "$f" .sh)"
    row="$(grep -m1 "^| $name |" "$readme" || true)"
    [[ -n "$row" ]] || { missing+=" $name"; continue; }
    a="$(cut -d'|' -f3 <<<"$row" | sed 's/^ *//;s/ *$//')"
    c="$(cut -d'|' -f4 <<<"$row" | sed 's/^ *//;s/ *$//')"
    ra="$(sed -n 's/^# APPLY-ON:[[:space:]]*//p' "$f" | head -1)"
    rc="$(sed -n 's/^# CHECK-ON:[[:space:]]*//p' "$f" | head -1)"
    [[ "$a" == "$ra" && "$c" == "$rc" ]] || wrong+=" $name(README:$a|$c vs source:$ra|$rc)"
  done
  [[ -z "$missing" ]] || { echo "absents du tableau:$missing"; false; }
  [[ -z "$wrong" ]]   || { echo "terrains divergents:$wrong"; false; }
}

# bats test_tags=structure
@test "aucun module réel n'est exécutable : ils sont joués par bash" {
  local m n=0 bad=()
  for m in "$MODULES"/*.sh; do
    n=$((n+1))
    [[ -x "$m" ]] && bad+=("$(basename "$m")")
  done
  [ "$n" -ge 20 ]
  [[ "${#bad[@]}" -eq 0 ]] || { echo "exécutables : ${bad[*]}" >&2; false; }
}
