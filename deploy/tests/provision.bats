#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/provision.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: témoins du runner — sélection par en-têtes, dispatch d'identité, codes de verdict, journal

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
  decor_pose
  JOURNAL="$LCARS_DECOR_ROOT/opt/lcars/var/install.journal"
}

stub_module() { # stub_module <NN-nom> <APPLY-ON> <CHECK-ON> <NEEDS> [variable du rc]
  local name="$1" apply_on="$2" check_on="$3" needs="$4" rcvar="${5:-STUB_RC_UNSET}"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: $apply_on
# CHECK-ON: $check_on
# NEEDS: $needs
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
# NEEDS: human
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
    echo '# NEEDS: human'
    echo 'set -euo pipefail'
    [[ "$2" -eq 1 ]] && echo '. "${PROVISION_LIB:?}"'
    echo 'x="$(sed -n '"'"'s/^X=//p'"'"' /inexistant-par-construction 2>/dev/null | tail -n1)"'
    echo 'echo "jamais atteint: $x"'
  } > "$SANDBOX/modules.d/$1.sh"
}

stub_impersonation() { echo 'as_human() { "$@"; }' >> "$SANDBOX/lib/provision-lib.sh"; }


@test "doctor sous docker joue le check d'un module que l'image a appliqué, sans une ligne ERREUR" {
  stub_module 10-pkgstub "wsl linux" any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  grep -q "10-pkgstub:check" "$RUN_LOG"
  [[ "$output" != *"ERREUR"* ]]
}

@test "apply sous docker applique ce qui déclare docker et vérifie le reste" {
  stub_module 60-deploystub "wsl linux" any human
  stub_module 61-imagestub "wsl linux docker" any human
  run "$SANDBOX/provision" apply --substrate docker --human "$(id -un)"
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  grep -q "61-imagestub:apply" "$RUN_LOG"
}

@test "doctor et list se jouent sous docker" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  run "$SANDBOX/provision" list --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"60-deploystub"* ]]
}

@test "un drift au doctor sous docker est une image non conforme : rc 1 et le conseil est pack.sh" {
  stub_module 60-deploystub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"drift: 1"* ]]
  [[ "$output" == *"deploy/pack.sh"* ]]
  [[ "$output" != *"converger : sudo"* ]]
}

@test "un module ne lit jamais l'entrée du lanceur : une ligne tapée n'atteint aucun module" {
  cat > "$SANDBOX/modules.d/10-lecteur.sh" <<'EOF'
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
ligne=""; IFS= read -r ligne || true
echo "10-lecteur:$1:[$ligne]" >> "$RUN_LOG"
EOF
  run bash -c "printf 'jeton-tapé\n' | '$SANDBOX/provision' apply --substrate docker --human '$(id -un)'"
  [ "$status" -eq 0 ]
  grep -qxF "10-lecteur:apply:[]" "$RUN_LOG"
}

@test "apply sur son substrat joue l'apply" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:apply" "$RUN_LOG"
}

@test "un module hors CHECK-ON n'est pas sélectionné" {
  stub_module 15-toolstub "wsl linux" "wsl linux" human
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  refute grep -q "15-toolstub" "$RUN_LOG"
  grep -q "20-anystub:check" "$RUN_LOG"
}

@test "un en-tête manquant, quel qu'il soit, refuse le corpus entier" {
  local champ
  stub_module 20-sain any any human
  for champ in APPLY-ON CHECK-ON NEEDS; do
    stub_module 10-broken any any human
    sed -i "/^# $champ:/d" "$SANDBOX/modules.d/10-broken.sh"
    run "$SANDBOX/provision" doctor --substrate docker
    [ "$status" -eq 1 ]
    [[ "$output" == *"10-broken: header '# $champ:' manquant"* ]]
  done
  refute grep -q "20-sain" "$RUN_LOG"
}

@test "APPLY-ON hors de CHECK-ON est refusé" {
  stub_module 10-incoherent "docker" "wsl" human
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"hors de CHECK-ON"* ]]
}

@test "doctor sans root passe quand les modules root ne sont qu'en check" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-rootstub:check" "$RUN_LOG"
}

@test "apply sans root est refusé dès qu'un module NEEDS: root s'applique" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige root"* ]]
  refute grep -q "60-rootstub" "$RUN_LOG"
}

@test "--porcelain rend une ligne MODULE=verdict par module" {
  stub_module 10-okstub any any human
  stub_module 60-driftstub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" doctor --substrate docker --porcelain
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "10-okstub=OK" ]
  [ "${lines[1]}" = "60-driftstub=DRIFT" ]
}

@test "list montre les deux axes et AFTER" {
  stub_module 10-pkgstub "wsl linux" any root
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\n# AFTER: 10-pkgstub\nexit 0\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" list --substrate docker
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == 10-pkgstub*"APPLY-ON=wsl linux"*"CHECK-ON=any"*"NEEDS=root"* ]]
  [[ "${lines[1]}" == 30-aval*"AFTER=10-pkgstub" ]]
}

@test "--only joue ce qu'on lui nomme, par nom ou préfixe, sans fermer AFTER" {
  stub_module 20-amont any any human
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\n# AFTER: 20-amont\necho "30-aval:$1" >> "$RUN_LOG"\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" doctor --substrate docker --only 30
  [ "$status" -eq 0 ]
  grep -q "30-aval:check" "$RUN_LOG"
  refute grep -q "20-amont:check" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --substrate docker --only 30-aval
  [ "$status" -eq 0 ]
  grep -q "30-aval:check" "$RUN_LOG"
  refute grep -q "20-amont:check" "$RUN_LOG"
}

@test "un préflight en échec à l'apply est une barrière : rien d'autre n'est joué, sortie 1" {
  stub_module 00-preflight any any human STUB_RC_PRE
  stub_module 20-suivant any any human
  export STUB_RC_PRE=1
  stub_impersonation
  run "$SANDBOX/provision" apply --substrate wsl --human "$(id -un)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ARRÊT"*"le préflight refuse ce terrain"* ]]
  grep -q "00-preflight:apply" "$RUN_LOG"
  refute grep -q "20-suivant" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --substrate wsl
  grep -q "20-suivant:check" "$RUN_LOG"
}

@test "apply --only garde le préflight comme barrière : un terrain refusé ne reçoit pas le module choisi" {
  stub_module 00-preflight any any human STUB_RC_PRE
  stub_module 20-suivant any any human
  export STUB_RC_PRE=1
  stub_impersonation
  run "$SANDBOX/provision" apply --substrate wsl --human "$(id -un)" --only 20
  [ "$status" -eq 1 ]
  [[ "$output" == *"le préflight refuse ce terrain"* ]]
  refute grep -q "20-suivant" "$RUN_LOG"
}

@test "apply --only sur un terrain accepté joue le préflight puis le seul module choisi" {
  stub_module 00-preflight any any human
  stub_module 20-suivant any any human
  stub_module 30-autre any any human
  stub_impersonation
  run "$SANDBOX/provision" apply --substrate wsl --human "$(id -un)" --only 20
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN_LOG")" = "$(printf '00-preflight:apply\n20-suivant:apply')" ]
}

@test "aucun module sélectionné est un refus qui nomme le substrat et le filtre" {
  stub_module 20-amont any any human
  run "$SANDBOX/provision" doctor --substrate docker --only 99-absent
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun module ne matche"*"docker"*"99-absent"* ]]
}

@test "une option inconnue est refusée, --fleet-human comprise" {
  stub_module 20-amont any any human
  run "$SANDBOX/provision" list --fleet-human lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue: --fleet-human"* ]]
}


@test "un drift dans l'apply rend 2 : appliqué, l'état-cible n'est pas tenu, rien n'est un échec" {
  lib_module 50-forgestub 'p_drift "adhesion org non convergee"'
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 2 ]
  [[ "$output" == *"conformes/convergés: 0"*"drift: 1"*"échecs: 0"* ]]
  [[ "$output" == *"ÉTAT-CIBLE N'EST PAS TENU"* ]]
  [[ "$output" == *"Rien n'est cassé"* ]]
}

@test "un échec rend 1, le drift ne l'écrase pas, et la phrase rassurante ne sort pas" {
  lib_module 40-failstub  'p_fail "quelque chose est casse"'
  lib_module 50-driftstub 'p_drift "et un geste manque"'
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"échecs: 1"*"drift: 1"* ]] || [[ "$output" == *"drift: 1"*"échecs: 1"* ]]
  [[ "$output" == *"EN ÉCHEC"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "un apply convergé rend 0" {
  lib_module 20-okstub 'p_ok "converge"'
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  [[ "$output" == *"conformes/convergés: 1"*"drift: 0"*"échecs: 0"* ]]
}

@test "le doctor rend 0 conforme et 1 drift, et conseille l'apply sur un rail" {
  lib_module 20-okstub 'p_ok "conforme"'
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 0 ]
  rm -f "$SANDBOX/modules.d"/*.sh
  lib_module 50-forgestub 'p_drift "pas conforme"'
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"converger :"*"provision apply"* ]]
}

@test "le récap nomme la révision lue dans le tampon d'une copie hors git" {
  local root
  root="$(PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -n "$root" ]
  echo "abcd1234" > "$root/.source-revision"
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  rm -f "$root/.source-revision"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source abcd1234"* ]]
}

@test "ni git ni tampon : la révision est inconnue, jamais devinée" {
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"source inconnue"* ]]
}


@test "un module NEEDS: human dont l'identité ne peut pas être prise ne tourne pas" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège"
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  run env LCARS_SYSADMIN_UID=0 "$SANDBOX/provision" apply --substrate linux --human root
  [ "$status" -ne 0 ]
  refute grep -q "^human=" "$RUN_LOG"
}

@test "un module NEEDS: human est joué une seule fois, sous l'humain de --human" {
  stub_impersonation
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  run env LCARS_SYSADMIN_UID=0 "$SANDBOX/provision" apply --substrate linux --human root
  [ "$status" -eq 0 ]
  [ "$(grep -c "^human=" "$RUN_LOG")" = "1" ]
  grep -qx "human=root" "$RUN_LOG"
}


@test "doctor : un module mort sans verdict est nommé, rc 2" {
  mort_module 90-mort 1
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 90-mort"*"mort avant de rendre son verdict"* ]]
}

@test "apply : un module mort est un échec, pas un drift résiduel" {
  mort_module 91-mort 1
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERREUR 91-mort"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "mort avant de sourcer la lib : le runner nomme quand même" {
  mort_module 93-tot 0
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 93-tot"* ]]
}

@test "un petit-fils qui source la lib ne déclenche pas la garde de sortie" {
  cat > "$SANDBOX/modules.d/94-petitfils.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
set -euo pipefail
. "\$PROVISION_LIB"
rc=0
bash -c '. "\$PROVISION_LIB"; echo PETIT-FILS-OK; exit 0' || rc=\$?
echo "PETIT-FILS-RC=\$rc"
p_ok "le module rend son verdict"
verdict_apply
EOF
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  [[ "$output" == *"PETIT-FILS-OK"*"PETIT-FILS-RC=0"* ]]
  [[ "$output" != *"mort avant de rendre son verdict"* ]]
}


# bats test_tags=unit
@test "les trois ports sont validés au parseur : un nombre, dans la plage" {
  stub_module 10-x any any root
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
  stub_module 10-x any any root
  run "$SANDBOX/provision" list --forge-project Bob_9
  [ "$status" -eq 1 ]
  [[ "$output" == *"--forge-project : « Bob_9 »"* ]]
  run "$SANDBOX/provision" list --forge-project bob_9
  [ "$status" -eq 0 ]
}

@test "les ports atteignent les modules, et une passe suivante les relit dans le journal" {
  lib_module 50-ports 'echo "deck=$PROV_DECK_PORT" >> "$RUN_LOG"; p_ok "ok"'
  run "$SANDBOX/provision" apply --substrate wsl --port-deck 20997
  [ "$status" -eq 0 ]
  grep -qx "deck=20997" "$RUN_LOG"
  grep -q "^params .*PROV_DECK_PORT=20997" "$JOURNAL"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 0 ]
  grep -qx "deck=20997" "$RUN_LOG"
  : > "$RUN_LOG"
  run "$SANDBOX/provision" doctor --substrate wsl --port-deck 20990
  [ "$status" -eq 0 ]
  grep -qx "deck=20990" "$RUN_LOG"
}

@test "la ligne params ne retient que les choix hors défaut : absente, posée, relue, retirée au défaut" {
  # un défaut écrit au journal deviendrait un choix : la passe suivante ne distinguerait plus l'opérateur de l'usine
  lib_module 50-ports 'p_ok "ok"'
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -qx 'params *' "$JOURNAL"
  run "$SANDBOX/provision" apply --substrate wsl --port-deck 3000
  [ "$status" -eq 0 ]
  grep -qx 'params *PROV_DECK_PORT=3000' "$JOURNAL"
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -qx 'params *PROV_DECK_PORT=3000' "$JOURNAL"
  run "$SANDBOX/provision" apply --substrate wsl --port-deck "$(sed -n 's/^PROV_DECK_PORT_DEFAULT=//p' "$SRC/installer-constants.env")"
  [ "$status" -eq 0 ]
  grep -qx 'params *' "$JOURNAL"
}

@test "apply écrit le journal de la machine sous le décor et additionne les inventaires apt des passes" {
  lib_module 20-okstub 'p_ok "converge"'
  mkdir -p "$(dirname "$JOURNAL")"
  printf 'apt_installed  curl git\nposed_at      2026-01-01T00:00:00Z\n' > "$JOURNAL"
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -q "^substrate     wsl$" "$JOURNAL"
  grep -q "^modules       total=1 ok=1 drift=0 failed=0$" "$JOURNAL"
  grep -q "^apt_installed .*curl git" "$JOURNAL"
  [ "$(grep -c "^posed_at" "$JOURNAL")" = "1" ]
  refute grep -q "2026-01-01T00:00:00Z" "$JOURNAL"
}

@test "en root sous un décor, le runner refuse avant tout module, et dit de retirer LCARS_DECOR_ROOT" {
  # sous root, le décor déplacerait les chemins et laisserait useradd, apt, systemctl et docker agir sur la machine
  stub_module 10-rootstub "wsl linux" "wsl linux" root
  run unshare -Ur "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [ ! -s "$RUN_LOG" ]
  [[ "$output" == *"LCARS_DECOR_ROOT est posée et le runner tourne en root"*"Retirer LCARS_DECOR_ROOT de l'environnement"* ]]
  run env -u LCARS_DECOR_ROOT unshare -Ur "$SANDBOX/provision" list --substrate wsl
  [ "$status" -eq 0 ]
  [[ "$output" == *"10-rootstub"* ]]
}

@test "un corpus sans le fichier des constantes est refusé, et le fichier est nommé" {
  stub_module 10-x any any human
  rm "$SANDBOX/installer-constants.env"
  run "$SANDBOX/provision" list --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"constantes de l'installeur illisibles : $SANDBOX/lib/../installer-constants.env"* ]]
}

@test "le fd du verrou n'est pas légué au module" {
  local fdlog="$BATS_TEST_TMPDIR/fds-du-module"
  cat > "$SANDBOX/modules.d/61-legue.sh" <<MODEOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
set -euo pipefail
. "\${PROVISION_LIB:?}"
ls -l /proc/\$\$/fd > "$fdlog"
p_ok "decor"; verdict_apply
MODEOF
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  [ -s "$fdlog" ]
  refute grep -qE 'lcars/provision[^/]*\.lock' "$fdlog"
}


@test "AFTER vers un rang qui ne précède pas est refusé au démarrage" {
  stub_module 40-amont any any human
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\n# AFTER: 40-amont\nexit 0\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"30-aval"*"40-amont"*"précède"* ]]
}

@test "AFTER vers un module inconnu est refusé et le nomme" {
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\n# AFTER: 20-fantome\nexit 0\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"20-fantome"* ]]
}

@test "AFTER satisfait : les deux modules jouent dans l'ordre" {
  stub_module 20-amont any any human
  printf '#!/usr/bin/env bash\n# APPLY-ON: any\n# CHECK-ON: any\n# NEEDS: human\n# AFTER: 20-amont\necho "30-aval:$1" >> "$RUN_LOG"\n' > "$SANDBOX/modules.d/30-aval.sh"
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  [ "$(grep -n '20-amont:check' "$RUN_LOG" | cut -d: -f1)" -lt "$(grep -n '30-aval:check' "$RUN_LOG" | cut -d: -f1)" ]
}


# bats test_tags=structure
@test "les modules réels : APPLY-ON couvert par CHECK-ON, et aucun check-seul hors docker" {
  local m name apply check s bad=""
  for m in "$MODULES"/*.sh; do
    name="$(basename "$m" .sh)"
    apply="$(sed -n 's/^# APPLY-ON:[[:space:]]*//p' "$m" | head -1)"
    check="$(sed -n 's/^# CHECK-ON:[[:space:]]*//p' "$m" | head -1)"
    [ -n "$apply" ] && [ -n "$check" ] || { echo "$name : en-tête manquante" >&2; false; }
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
  local mod name dep n=0
  for mod in "$MODULES"/[0-9][0-9]-*.sh; do
    name="$(basename "$mod" .sh)"
    for dep in $(sed -n 's/^# AFTER: *//p' "$mod" | head -1); do
      n=$((n+1))
      [ -f "$MODULES/$dep.sh" ]
      [[ "$dep" < "$name" ]]
    done
  done
  [ "$n" -ge 10 ]
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
