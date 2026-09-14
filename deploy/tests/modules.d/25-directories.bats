#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/25-directories.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-20
# STATUS: bats tests for 25-directories.sh — les dossiers que le module pose, au mode que le manifeste déclare, et la racine des sockets de console au reboot

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  [ -f "$SRC" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=25-directories PROVISION_RUN=1
  export PROV_HUMAN=temoin
  export PROV_SUBSTRATE=linux
  LCARS_BUILTIN_HUMAN="$(id -un)"; export LCARS_BUILTIN_HUMAN

  # le décor possède son dossier runtime : `prov_lock_path` le veut, et un compte de service n'en a pas
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  decor_pose
  D="$LCARS_DECOR_ROOT"
  ME="$(id -un):$(id -gn)"
  CONF="$D/etc/tmpfiles.d/lcars-console.conf"
  mkdir -p "$(dirname "$CONF")"

  # Le corps du module SANS sa dernière ligne, le dispatch : on appelle ses fonctions, on ne le lance pas.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '$d' "$SRC" > "$MOD"
}

# une fonction seule ne rend pas de verdict : la garde du runner n'est pas armée
mod() { run env -u PROVISION_RUN bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }
entier() { run bash "$SRC" "$1"; }

@test "substrat natif : la racine des sockets de console, son parent et le dossier de l'humain de démonstration, au mode et au propriétaire du manifeste" {
  mod 'prov_runtime_dirs | dir_specs'
  [ "$status" -eq 0 ]
  grep -qx "$D/run/lcars 0755 root:root" <<<"$output"
  grep -qx "$D/run/lcars/console 0711 root:root" <<<"$output"
  grep -qx "$D/run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN:lcars-console" <<<"$output"
  refute_out '/run/lcars/console/temoin' <<<"$output"
}

@test "sans humain de démonstration, la console est celle de l'humain de la passe" {
  LCARS_BUILTIN_HUMAN='' mod 'prov_runtime_dirs | dir_specs'
  [ "$status" -eq 0 ]
  grep -qx "$D/run/lcars/console/temoin 2710 temoin:lcars-console" <<<"$output"
}

@test "l'humain de démonstration retenu par le journal atteint le geste de forge, sans LCARS_BUILTIN_HUMAN dans l'environnement" {
  PROV_BUILTIN_HUMAN="$LCARS_BUILTIN_HUMAN" run env -u LCARS_BUILTIN_HUMAN -u PROVISION_RUN \
    bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_tmpfiles_body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"d /run/lcars/console/$(id -un) 2710 $(id -un) lcars-console -"* ]]
  refute_out '/run/lcars/console/temoin' <<<"$output"
}

@test "humain de démonstration pas encore créé : la déclaration tmpfiles le nomme déjà, son dossier attend son compte, dit sans échec" {
  local absent="pas-encore-cree-$$"
  LCARS_BUILTIN_HUMAN="$absent" entier apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "d /run/lcars/console/$absent 2710 $absent lcars-console -" "$CONF"
  [[ "$output" == *"WARN  25-directories: $D/run/lcars/console/$absent : le compte « $absent » n'existe pas encore"* ]]
  [ ! -e "$D/run/lcars/console/$absent" ]
  [ ! -e "$D/run/lcars/console/temoin" ]
}

@test "l'humain de la console est demandé au geste de forge une fois par passe" {
  local t="$BATS_TEST_TMPDIR/arbre" src="$BATS_TEST_DIRNAME/../.."
  mkdir -p "$t/deploy/lib" "$t/deploy/modules.d" "$t/runtime/services"
  cp "$src"/lib/*.sh "$t/deploy/lib/"
  cp "$src/installer-constants.env" "$src/system.manifest" "$t/deploy/"
  cp "$SRC" "$t/deploy/modules.d/"
  printf '#!/usr/bin/env bash\necho appel >> "%s"\necho "%s"\n' "$BATS_TEST_TMPDIR/geste" "$(id -un)" > "$t/runtime/services/forge-gestures.sh"
  run env PROVISION_LIB="$t/deploy/lib/provision-lib.sh" bash "$t/deploy/modules.d/25-directories.sh" apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$BATS_TEST_TMPDIR/geste")" -eq 1 ]
}

@test "la racine du magasin dans la table est la constante PROV_STORE_ROOT, sous le décor" {
  mod 'prov_dirs | dir_specs'
  [ "$status" -eq 0 ]
  grep -qx "$D/var/lib/lcars 0755 root:root" <<<"$output"
}

@test "chaque dossier de la table est déclaré au manifeste, sur tout substrat" {
  local s
  for s in linux wsl docker; do
    PROV_SUBSTRATE="$s" mod 'prov_dirs | dir_specs'
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<<"$output")" -ge 10 ] || { echo "$s : la table rend $(grep -c . <<<"$output") lignes"; return 1; }
    refute_out ' - ' <<<"$output"
  done
}

@test "un dossier que le manifeste ne déclare pas n'est pas posé : échec nommé, et la table continue" {
  local suivant="$BATS_TEST_TMPDIR/decor/etc/lcars"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '$D/opt/lcars/inconnu-du-manifeste' '$suivant'; }
    apply_tmpfiles() { :; }
    apply"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  25-directories: $D/opt/lcars/inconnu-du-manifeste : absent de system.manifest"* ]]
  [ ! -e "$D/opt/lcars/inconnu-du-manifeste" ]
  [ -d "$suivant" ]
}

@test "la declaration tmpfiles est DERIVEE de la table — une seule source, pas deux" {
  mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"d /run/lcars/console 0711 root root -"* ]]
  [[ "$output" == *"d /run/lcars/console/$LCARS_BUILTIN_HUMAN 2710 $LCARS_BUILTIN_HUMAN lcars-console -"* ]]
  # Autant de lignes `d ` que d'entrees dans la table : une entree ajoutee a la table arrive ici
  # sans geste, et une entree qui n'y est pas ne peut pas y apparaitre.
  mod 'prov_tmpfiles_body | grep -c "^d "'
  [ "$output" = "$(env -u PROVISION_RUN bash -c "source '$MOD' >/dev/null 2>&1; prov_runtime_dirs | wc -l" | tr -d ' ')" ]
}

@test "le corps tmpfiles nomme les chemins de la machine, jamais ceux du décor — systemd le lit au boot" {
  mod 'prov_tmpfiles_body'
  [ "$status" -eq 0 ]
  refute_out "$D" <<<"$output"
  grep -qx 'd /run/lcars 0755 root root -' <<<"$output"
}

@test "apply pose la declaration, et check la voit ; rejouée, elle se dit conforme, jamais posée" {
  run env -u PROVISION_RUN bash -c "set -euo pipefail; source '$MOD'; apply_tmpfiles"
  [ "$status" -eq 0 ]
  [ -f "$CONF" ]
  [ "$(stat -c %a "$CONF")" = 644 ]
  [[ "$output" == *"POSÉ  25-directories: $CONF"* ]]
  mod 'check_tmpfiles'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  run env -u PROVISION_RUN bash -c "set -euo pipefail; source '$MOD'; apply_tmpfiles"
  [ "$status" -eq 0 ]
  [ "$output" = "OK    25-directories: tmpfiles: $CONF conforme" ]
}

@test "declaration ABSENTE = drift, et le drift dit la CONSEQUENCE (la fleet ne demarrera pas)" {
  mod 'check_tmpfiles; echo "drift=$PROV_DRIFT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"*"$CONF absent"* ]]
  [[ "$output" == *"reboot"* ]]
  [[ "$output" == *"drift=1"* ]]
}

@test "declaration PERIMEE = drift — un contenu qui ne suit plus le manifeste ment au boot" {
  printf 'd /run/quelque-part-dautre 0755 root root -\n' > "$CONF"
  mod 'check_tmpfiles; echo "drift=$PROV_DRIFT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ne correspond plus"* ]]
  [[ "$output" == *"drift=1"* ]]
}

@test "apply puis check, joués entiers : tout est conforme, /opt/lcars/var compris — le propriétaire attendu se lit par prov_owner" {
  entier apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  entier check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    25-directories: $D/opt/lcars/var/tokens (710 $ME)"* ]]
  [[ "$output" == *"OK    25-directories: $D/opt/lcars/var (755 $ME)"* ]]
  [[ "$output" == *"OK    25-directories: $D/home/projects (2775 $ME)"* ]]
  [[ "$output" == *"OK    25-directories: tmpfiles: $CONF"* ]]
  refute_out 'DRIFT' <<<"$output"
}

@test "joué entier sous docker : ni /run ni tmpfiles, les volumes et le hors-substrat sont dits, apply puis check conforme" {
  PROV_SUBSTRATE=docker entier apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$CONF" ]
  [ ! -e "$D/run/lcars" ]
  [ ! -e "$D/home/projects" ]
  PROV_SUBSTRATE=docker entier check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"volume du conteneur"*"$D/home/projects"* ]]
  [[ "$output" == *"hors substrat docker"*"$D/opt/lcars/var/tofu"* ]]
  [[ "$output" == *"OK    25-directories: $D/opt/lcars (755 $ME)"* ]]
  refute_out 'tmpfiles' <<<"$output"
}

@test "une entree en echec n'arrete pas la table : les suivantes sont posees quand meme" {
  # `/proc/...` ne peut pas etre cree, a coup sur et sans droits speciaux : la premiere entree
  # echoue pour de vrai, pas par un stub.
  local bonne="$BATS_TEST_TMPDIR/apres"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' /proc/impossible-a-creer '$bonne'; }
    dir_specs() { while read -r p; do echo \"\$p 0755 $ME\"; done; }
    apply_tmpfiles() { :; }
    apply"
  [ -d "$bonne" ] || { echo "la table s'est arretee a la premiere entree en echec" >&2; return 1; }
  [ "$status" -eq 1 ] || { echo "un module en echec a rendu $status — le verdict a ete avale" >&2; return 1; }
}

@test "une table SANS echec rend toujours 0 — le correctif n'a pas rendu l'echec permanent" {
  local a="$BATS_TEST_TMPDIR/ok-a" b="$BATS_TEST_TMPDIR/ok-b"
  run bash -c "set -uo pipefail
    source '$MOD' >/dev/null 2>&1
    prov_dirs() { printf '%s\n' '$a' '$b'; }
    dir_specs() { while read -r p; do echo \"\$p 0755 $ME\"; done; }
    apply_tmpfiles() { :; }
    apply"
  [ "$status" -eq 0 ]
  [ -d "$a" ]
  [ -d "$b" ]
}

@test "le compteur de changement VOIT l'ecriture du tmpfiles — write_atomic ne tourne plus dans un pipe" {
  mod 'PROV_CHANGED=0; apply_tmpfiles; echo "changed=$PROV_CHANGED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=1"* ]]
}


# des entrées réelles du manifeste, sous le décor : any, wsl+linux, et une sur le volume /opt/lcars/var
docker_decor() {
  D_ANY="$D/opt/lcars/share"
  D_POSTE="$D/opt/lcars/var/tofu"
  D_VOL="$D/opt/lcars/var/tokens"
  mkdir -p "$D_ANY" "$D_POSTE" "$D_VOL"
  chmod 0755 "$D_ANY"; chmod 0700 "$D_POSTE"; chmod 0710 "$D_VOL"
  TABLE="printf '%s\n' '$D_ANY' '$D_POSTE' '$D_VOL'"
}

# check_on <substrat> : joue `check` sur la table de decor, sous ce substrat
check_on() {
  run env PROV_SUBSTRATE="$1" bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; prov_dirs() { $TABLE; }; check"
}

@test "docker : la table runtime est VIDE — /run est un fait de boot, et il n'y a pas de tmpfiles a declarer" {
  PROV_SUBSTRATE=docker mod 'prov_runtime_dirs'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  PROV_SUBSTRATE=docker mod 'prov_dirs'
  [ "$status" -eq 0 ]
  refute_out '/run/' <<<"$output"
  # la même table, sur le poste, n'est pas vide : un `return 0` inconditionnel passerait les lignes du dessus
  mod 'prov_runtime_dirs | grep -c "/run/"'
  [ "$output" -ge 5 ]
}

@test "docker : une entree any avec un mauvais mode est un DRIFT NOMME — l'instrument est stat, pas -r" {
  docker_decor
  chmod 0700 "$D_ANY"
  check_on docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_ANY : 700 $ME ≠ 755 $ME"* ]]
  # repare, le verdict revient a 0 : le drift etait celui-la et pas un autre
  chmod 0755 "$D_ANY"
  check_on docker
  [ "$status" -eq 0 ]
}

@test "docker : une entree wsl+linux n est PAS mesuree — meme absente, meme fausse — et le module le DIT" {
  docker_decor
  chmod 0755 "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE : " <<<"$output"
  rm -rf "$D_POSTE"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_POSTE absent" <<<"$output"
  [[ "$output" == *"hors substrat docker"*"$D_POSTE"* ]]
}

@test "docker : une entree sur un VOLUME du conteneur n'a pas de verite au build — non mesuree, et DITE" {
  docker_decor
  rm -rf "$D_VOL"
  check_on docker
  [ "$status" -eq 0 ]
  refute_out -- "$D_VOL absent" <<<"$output"
  [[ "$output" == *"volume du conteneur"*"$D_VOL"* ]]
}

@test "poste : le meme decor, tout se mesure — l'entree wsl+linux ET celle du volume, et rien n'est dit hors mesure" {
  # Le filtre docker ne fuit pas sur le poste : `wsl+linux` y est chez lui, et un volume n'y existe pas.
  docker_decor
  chmod 0755 "$D_POSTE"; rm -rf "$D_VOL"
  check_on linux
  [ "$status" -eq 1 ]
  [[ "$output" == *"$D_POSTE : 755 $ME ≠ 700 $ME"* ]]
  [[ "$output" == *"$D_VOL absent"* ]]
  refute_out 'hors substrat|volume du conteneur' <<<"$output"
}

@test "mode, propriétaire et substrat d'un dossier viennent du manifeste — la table du module n'en porte aucun" {
  local code tables
  code="$(sed 's/#.*//' "$SRC")"
  grep -q 'prov_manifest_mode' <<<"$code"
  grep -q 'prov_manifest_owner' <<<"$code"
  grep -q 'prov_manifest_substrate' <<<"$code"
  tables="$(sed -n '/^prov_runtime_dirs()/,/^}$/p;/^prov_dirs()/,/^}$/p' "$SRC")"
  [ -n "$tables" ]
  refute grep -qE ' [0-7]{3,4}( |")|root:|wsl\+linux' <<<"$tables"
}

@test "les volumes que le module ecarte au build sont ceux que le Dockerfile declare VOLUME — deux ecritures, une valeur" {
  local df="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  local declares; declares="$(grep -E '^VOLUME ' "$df" | tr -d '[]",' | sed 's/^VOLUME //' | tr ' ' '\n' | sort)"
  [ -n "$declares" ]
  mod 'prov_container_volumes | sort'
  [ "$status" -eq 0 ]
  [ "$(sed "s|^$D||" <<<"$output")" = "$declares" ]
}
