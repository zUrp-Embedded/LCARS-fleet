#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/21-service-accounts.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests for modules.d/21-service-accounts.sh — deux comptes de service, posés s'ils manquent, refusés s'ils s'écartent

# chaque `@test` de bats est un sous-shell, et c'est l'isolation qu'on veut
# shellcheck disable=SC2030,SC2031

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/21-service-accounts.sh"
  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  [ -f "$MOD" ]
  export PROVISION_LIB="$LIB" PROVISION_MODULE=21-service-accounts PROV_SUBSTRATE=linux PROVISION_RUN=1

  decor_pose
  decor_comptes
  PASSWD="$LCARS_DECOR_ROOT/etc/passwd"
  GROUP="$LCARS_DECOR_ROOT/etc/group"
  CALLS="$DECOR_COMPTES"

  printf '%s\n' 'root:x:0:'            'fleet:x:2000:lcars-authority' 'lcars-authority:x:2002:' \
                'lcars-system:x:2003:' 'nogroup:x:65534:'             > "$GROUP"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' \
                'lcars-authority:x:900:2002::/nonexistent:/usr/sbin/nologin' \
                'lcars-system:x:901:2003::/nonexistent:/usr/sbin/nologin' > "$PASSWD"
}

check() { run bash "$MOD" check; }
apply() { run bash "$MOD" apply; }

pg() { # le groupe primaire d'un compte, lu dans le décor
  local gid; gid="$(awk -F: -v n="$1" '$1==n {print $4; exit}' "$PASSWD")"
  awk -F: -v g="$gid" '$3==g {print $1; exit}' "$GROUP"
}

derive() { # derive <compte> <groupe> — déplace le groupe primaire d'un compte, sans passer par le module
  local gid; gid="$(awk -F: -v n="$2" '$1==n {print $3; exit}' "$GROUP")"
  awk -F: -v OFS=: -v n="$1" -v g="$gid" '$1==n {$4=g} {print}' "$PASSWD" > "$PASSWD.n"
  mv "$PASSWD.n" "$PASSWD"
}

shell_de() { # shell_de <compte> <shell>
  awk -F: -v OFS=: -v n="$1" -v s="$2" '$1==n {$7=s} {print}' "$PASSWD" > "$PASSWD.n"; mv "$PASSWD.n" "$PASSWD"
}

retire() { grep -v "^$1:" "$PASSWD" > "$PASSWD.n"; mv "$PASSWD.n" "$PASSWD"; }

@test "check : le décor nominal est conforme, les deux comptes sont nommés" {
  check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    21-service-accounts: compte de service lcars-authority (groupe lcars-authority, /usr/sbin/nologin)"* ]]
  [[ "$output" == *"OK    21-service-accounts: compte de service lcars-system (groupe lcars-system, /usr/sbin/nologin)"* ]]
  [[ "$output" == *"lcars-authority ∈ fleet"* ]]
}

@test "check : un groupe primaire qui s'écarte est un drift qui nomme l'écart, ce que le compte détient et le geste" {
  derive lcars-system nogroup
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 21-service-accounts: compte lcars-system : groupe primaire « nogroup » au lieu de lcars-system — il détient le secret OAuth2 du deck"*"userdel lcars-system"* ]]
}

@test "check : un compte de service qui se connecte est un drift" {
  shell_de lcars-authority /bin/bash
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 21-service-accounts: compte lcars-authority : shell « /bin/bash » au lieu de /usr/sbin/nologin — il détient les secrets de forge"* ]]
}

@test "check : les deux comptes passent par la même mesure — deux écarts, deux drifts" {
  derive lcars-authority nogroup
  shell_de lcars-system /bin/bash
  check
  [ "$status" -eq 1 ]
  [ "$(grep -c '^DRIFT 21-service-accounts: compte lcars-' <<<"$output")" -eq 2 ]
}

@test "apply : un compte existant qui s'écarte est refusé et nommé, jamais corrigé" {
  derive lcars-system nogroup
  shell_de lcars-authority /bin/false
  apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  21-service-accounts: compte lcars-authority : shell « /bin/false » au lieu de /usr/sbin/nologin"* ]]
  [[ "$output" == *"FAIL  21-service-accounts: compte lcars-system : groupe primaire « nogroup » au lieu de lcars-system"* ]]
  refute grep -qE '^usermod -(s|g) ' "$CALLS"
  [ "$(pg lcars-system)" = nogroup ]
  [ "$(awk -F: '$1=="lcars-authority" {print $7}' "$PASSWD")" = /bin/false ]
}

@test "apply : un compte existant sans son groupe éponyme est refusé avant tout geste — aucun groupe ne lui est créé" {
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:lcars-authority' 'lcars-system:x:2003:' 'nogroup:x:65534:' > "$GROUP"
  derive lcars-authority nogroup
  apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  21-service-accounts: compte lcars-authority : groupe primaire « nogroup » au lieu de lcars-authority"*"userdel lcars-authority"* ]]
  refute_out '^POSÉ' <<<"$output"
  refute grep -q '^groupadd' "$CALLS"
}

@test "apply : un compte absent est créé sur son groupe éponyme, et lcars-authority rejoint fleet" {
  retire lcars-authority
  retire lcars-system
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:' 'nogroup:x:65534:' > "$GROUP"
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'groupadd lcars-authority' "$CALLS"
  grep -qx 'useradd --system --no-create-home --shell /usr/sbin/nologin -g lcars-authority -- lcars-authority' "$CALLS"
  grep -qx 'useradd --system --no-create-home --shell /usr/sbin/nologin -g lcars-system -- lcars-system' "$CALLS"
  grep -qx 'usermod -aG fleet lcars-authority' "$CALLS"
  [ "$(pg lcars-system)" = lcars-system ]
  run bash "$MOD" check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "apply : un compte que useradd pose de travers est relu, et l'écart est un échec" {
  retire lcars-system
  DECOR_USERADD_SHELL=/bin/bash apply
  [ "$status" -eq 1 ]
  grep -q '^useradd .* lcars-system$' "$CALLS"
  [[ "$output" == *"FAIL  21-service-accounts: compte lcars-system : shell « /bin/bash » au lieu de /usr/sbin/nologin"* ]]
}

@test "apply : lcars-authority hors de fleet est ajouté — check le dit avant" {
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:' 'lcars-authority:x:2002:' 'lcars-system:x:2003:' > "$GROUP"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 21-service-accounts: lcars-authority ∉ fleet"* ]]
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'usermod -aG fleet lcars-authority' "$CALLS"
}

@test "apply : idempotent — un état conforme ne produit aucun geste" {
  apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -s "$CALLS" ] || { cat "$CALLS"; return 1; }
}

@test "le group du décor est lu — la sonde ne lit pas /etc/group de la machine" {
  # le gid 2002 change de nom dans le décor : seul un module qui lit ce fichier peut le nommer
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:lcars-authority' 'renomme-au-decor:x:2002:' 'lcars-system:x:2003:' 'lcars-authority:x:2004:' > "$GROUP"
  check
  [[ "$output" == *"compte lcars-authority : groupe primaire « renomme-au-decor » au lieu de lcars-authority"* ]]
}
