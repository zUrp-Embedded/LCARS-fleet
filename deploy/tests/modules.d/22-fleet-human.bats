#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/22-fleet-human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 22-fleet-human — la SONDE de l'humain de fleet du poste

# shellcheck disable=SC2030,SC2031

# shellcheck disable=SC2097,SC2098

load ../refute

setup() {
  # Le decor possede l'environnement : ces temoins jugent ce que le module fait d'un environnement
  # DONNE (plancher d'uid, siege, groupe). L'heriter reviendrait a juger la machine qui les joue.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"

  SRC="$BATS_TEST_DIRNAME/../../modules.d/22-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  # `deploy/provision` derive le siege de l'appelant et l'exporte avant tout module ; sans defaut
  # `:-1000` dans la lib, une fixture qui ne le pose pas mesure une machine sans siege.
  export LCARS_SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
  export PROVISION_MODULE=22-fleet-human
  PROV_FLEET_GROUP="$(id -gn)"; export PROV_FLEET_GROUP
  PROV_HUMAN="$(id -un)"; export PROV_HUMAN

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # `login.defs` du decor : le plancher est une DONNEE du systeme, donc il se pose ici.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

nu() { # nu <check|apply>
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" \
    PASSWD_DEFS="$PASSWD_DEFS" \
    ${PASSWD_FILE:+PASSWD_FILE="$PASSWD_FILE"} \
    ${LCARS_SYSADMIN_UID:+LCARS_SYSADMIN_UID="$LCARS_SYSADMIN_UID"} \
    bash "$SRC" "$1"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "ce module ne CREE plus de compte unix — un seul createur, et ce n'est pas lui" {
  local bin="$BATS_TEST_TMPDIR/nocreate"; mkdir -p "$bin"
  local mouchard="$BATS_TEST_TMPDIR/appele"
  local u
  for u in useradd adduser; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s %s\n' \"\$0\" \"\$*\" >> '$mouchard'" \
      'exit 0' > "$bin/$u"
    chmod 0755 "$bin/$u"
  done

  PATH="$bin:$PATH" run env LCARS_BUILTIN_HUMAN="n-existe-pas-$$" \
    PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
    PROVISION_MODULE=22-fleet-human PROV_TOKENS_DIR="$BATS_TEST_TMPDIR" \
    PROV_FLEET_GROUP="$(id -gn)" PROV_HUMAN="$(id -un)" PATH="$bin:$PATH" \
    bash "$SRC" apply

  [ ! -e "$mouchard" ] || { echo "createur APPELE : $(cat "$mouchard")"; return 1; }
}

@test "TEMOIN DU TEMOIN : le mouchard attrape bien un createur, quel que soit le detour" {
  # ⚠ SANS CE PENDANT, UN MOUCHARD QUI N'ATTRAPE RIEN PASSE POUR UNE ABSENCE DE CREATION. On lui
  # donne les trois formes qui contournaient le motif de texte, et il doit voir les trois.
  local bin="$BATS_TEST_TMPDIR/probe"; mkdir -p "$bin"
  local mouchard="$BATS_TEST_TMPDIR/probe.log"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'vu %s\n' \"\$*\" >> '$mouchard'" 'exit 0' > "$bin/useradd"
  chmod 0755 "$bin/useradd"

  PATH="$bin:$PATH" bash -c 'r=$(useradd -m a); env useradd -m b'
  [ -f "$mouchard" ]
  [ "$(grep -c '^vu ' "$mouchard")" -eq 2 ]
}

@test "le verdict PROPOSE un geste — et ce n'est plus un useradd : le convergeur est le seul createur" {
  passwd_with
  mod 'observe'
  refute grep -q 'useradd' <<<"$output"
  [[ "$output" == *"inscription"* ]]
  [[ "$output" == *"lcars-converger"* ]]
}


@test "le nom d'un compte n'est JAMAIS ecrit ici — ce module ne connait personne par son nom" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '(^|[^.[:alnum:]_/])lcars([^[:alnum:]_.-]|$)' <<<"$code"
  # ⚠ ET PLUS AUCUNE SECONDE ORIGINE. `PROV_FLEET_HUMAN` etait posee par `--fleet-human`, retire :
  # la rouvrir redonnerait deux sources a un fait qui n'en a qu'une, et la seconde serait vide.
  refute grep -q 'PROV_FLEET_HUMAN' <<<"$code"
  refute grep -q 'builtin-human' <<<"$code"
}



@test "AUCUN humain : la sonde le DIT sans deriver, et elle dit qui s'en occupera" {
  passwd_with
  nu check
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"convergeur"* ]]
}

@test "AUCUN humain : l'APPLY non plus ne derive pas — les deux verbes s'accordent enfin" {
  passwd_with
  nu apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT"* ]]
}

@test "TEMOIN: un humain qui PASSE GUARD B et porte le groupe est conforme" {
  passwd_with "$(id -un):x:1234:1234::/home/$(id -un):/bin/bash"
  mod 'check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"il peut lancer la fleet"* ]]
}


@test "l'adhesion au GROUPE est mesuree ici, et par personne d'autre" {
  # Le compte qui joue les tests existe et passe GUARD B ; on lui demande un groupe auquel il
  # n'appartient pas, donc seule l'assertion d'adhesion peut rougir.
  LCARS_SYSADMIN_UID=0 LCARS_BUILTIN_HUMAN="$(id -un)" \
    PROV_FLEET_GROUP="groupe-absent-$$" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hors du groupe"* ]]
  local secdir
  secdir="$(env -i PATH="$PATH" bash -c ". '$PROVISION_LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [ -n "$secdir" ] || { echo "PROV_TOKENS_DIR ne se lit plus dans provision-lib" >&2; return 1; }
  [[ "$output" == *"$secdir"* ]]
}

@test "TEMOIN DU TEMOIN : la population, elle, ne regarde AUCUN groupe" {
  passwd_with "$(id -un):x:1001:1004::/home/$(id -un):/bin/bash"
  LCARS_SYSADMIN_UID=1000 PROV_FLEET_GROUP="groupe-absent-$$" mod 'fleet_humans'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(id -un)"* ]]
}


passwd_with() { # passwd_with <ligne>...  → pose le fichier passwd du decor
  local f="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$f"
  printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >> "$f"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  export PASSWD_FILE="$f"
}

@test "nobody n'est JAMAIS un humain de fleet — enumerer exige la borne HAUTE" {
  # Il est sur toute machine, uid 65534 : superieur a UID_MIN et different du siege. La regle basse
  # seule le compte — enumerer exige donc les DEUX bornes que `login.defs` declare.
  passwd_with
  LCARS_SYSADMIN_UID=1000 mod 'fleet_humans'
  [ -z "$output" ]
}

@test "bornes ILLISIBLES : le check DERIVE et nomme la frontiere — il ne dit pas « aucun humain », et le remede est dit UNE FOIS" {
  passwd_with "zoe:x:1001:1001::/home/zoe:/bin/bash"
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  LCARS_SYSADMIN_UID=1000 nu check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE "^DRIFT .*frontiere systeme/humain n'est pas etablie"
  [[ "$output" == *"repare $PASSWD_DEFS"* ]]
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 2 ]   # le WARN de la lib (une fois) + le DRIFT du module
  refute grep -q 'aucun humain de fleet sur cette machine' <<<"$output"
  refute grep -q 'zoe' <<<"$output"
  # Et l'apply ne pose rien sur une frontiere devinee : il derive de la meme facon, sans usermod.
  LCARS_SYSADMIN_UID=1000 nu apply
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qE "^DRIFT .*frontiere systeme/humain n'est pas etablie"
}

@test "un compte ABSENT : DRIFT dans la sonde, JAMAIS un echec dans l'apply — chaque verbe son code" {
  passwd_with 'horsgroupe:x:1001:1001::/home/horsgroupe:/bin/bash'

  nu check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]

  # Et l'apply, lui, ne rend PAS 1 : son `1` a lui veut dire ECHEC, et un groupe manquant n'en est
  # pas un. C'est la moitie du contrat que le partage de verdict avait cassee.
  nu apply
  [ "$status" -ne 1 ]
}

@test "un apply ne DELEGUE JAMAIS a check — le verdict n'est pas partageable" {
  # Le VERDICT porte le dialecte, donc il ne se partage pas. Ce temoin garde la regle pour les
  # VINGT-CINQ modules, pas seulement pour celui qui l'a payee.
  local m bad=0
  for m in "$BATS_TEST_DIRNAME"/../../modules.d/*.sh; do
    awk '/^apply\(\) \{/,/^\}/' "$m" | grep -vE '^\s*#' | grep -qE '(^|[^_[:alnum:]])check;' \
      && { echo "apply() delegue a check() : $(basename "$m")"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}
