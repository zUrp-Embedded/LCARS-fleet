#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/service_accounts.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests for modules.d/21-service-accounts.sh — deux comptes de service, posés s'ils manquent, refusés s'ils s'écartent

# chaque `@test` de bats est un sous-shell, et c'est l'isolation qu'on veut
# shellcheck disable=SC2030,SC2031

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../modules.d/21-service-accounts.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -f "$MOD" ]
  export PROVISION_LIB="$LIB" PROVISION_MODULE=21-service-accounts PROV_SUBSTRATE=linux PROVISION_RUN=1

  decor_pose
  PASSWD="$LCARS_DECOR_ROOT/etc/passwd"
  GROUP="$LCARS_DECOR_ROOT/etc/group"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  printf '%s\n' 'root:x:0:'            'fleet:x:2000:lcars-authority' 'lcars-authority:x:2002:' \
                'lcars-system:x:2003:' 'nogroup:x:65534:'             > "$GROUP"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' \
                'lcars-authority:x:900:2002::/nonexistent:/usr/sbin/nologin' \
                'lcars-system:x:901:2003::/nonexistent:/usr/sbin/nologin' > "$PASSWD"

  # `getent` et `id` lisent le passwd et le group du décor — sans quoi le module mesurerait la machine
  cat > "$DECOR_BIN/getent" <<'EOS'
#!/usr/bin/env bash
g="$LCARS_DECOR_ROOT/etc/group"
[[ "$1" == "group" ]] || exit 2
[[ -n "${2:-}" ]] || { cat "$g"; exit 0; }
awk -F: -v n="$2" '$1==n {print; found=1} END {exit !found}' "$g"
EOS
  cat > "$DECOR_BIN/id" <<'EOS'
#!/usr/bin/env bash
# deux formes, et les deux sont appelées : `id <user>` (existence, par `ensure_member`) et
# `id -nG <user>` (le groupe primaire plus les secondaires portés par le group du décor)
p="$LCARS_DECOR_ROOT/etc/passwd" g="$LCARS_DECOR_ROOT/etc/group"
if [[ "${1:-}" == -u || "${1:-}" == -g || "${1:-}" == -un || "${1:-}" == -gn ]]; then exec /usr/bin/id "$@"; fi
if [[ "${1:-}" != "-nG" ]]; then
  awk -F: -v n="${1:-}" '$1==n {found=1} END {exit !found}' "$p"; exit
fi
u="$2"; gid="$(awk -F: -v n="$u" '$1==n {print $4; exit}' "$p")"
{ awk -F: -v g="$gid" '$3==g {print $1}' "$g"
  awk -F: -v u="$u" '{n=split($4,m,","); for(i=1;i<=n;i++) if (m[i]==u) print $1}' "$g"
} | sort -u | tr '\n' ' '
EOS
  cat > "$DECOR_BIN/groupadd" <<'EOS'
#!/usr/bin/env bash
echo "groupadd $*" >> "$CALLS"
printf '%s:x:%s:\n' "${*: -1}" "$((3000 + $(wc -l < "$LCARS_DECOR_ROOT/etc/group")))" >> "$LCARS_DECOR_ROOT/etc/group"
EOS
  # la doublure d'`usermod` applique vraiment -g, -s et -aG : un geste interdit se verrait sur le décor
  cat > "$DECOR_BIN/usermod" <<'EOS'
#!/usr/bin/env bash
p="$LCARS_DECOR_ROOT/etc/passwd" g="$LCARS_DECOR_ROOT/etc/group"
echo "usermod $*" >> "$CALLS"
if [[ "${1:-}" == "-g" ]]; then
  gid="$(awk -F: -v n="$2" '$1==n {print $3; exit}' "$g")"
  [[ -n "$gid" ]] || exit 1
  awk -F: -v OFS=: -v n="${*: -1}" -v g="$gid" '$1==n {$4=g} {print}' "$p" > "$p.new" && mv "$p.new" "$p"
elif [[ "${1:-}" == "-s" ]]; then
  awk -F: -v OFS=: -v n="${*: -1}" -v s="$2" '$1==n {$7=s} {print}' "$p" > "$p.new" && mv "$p.new" "$p"
elif [[ "${1:-}" == "-aG" ]]; then
  awk -F: -v OFS=: -v gr="$2" -v u="${*: -1}" \
    '$1==gr {$4=($4=="" ? u : $4","u)} {print}' "$g" > "$g.new" && mv "$g.new" "$g"
fi
EOS
  # useradd pose le compte avec le shell et le groupe demandés ; STUB_USERADD_SHELL simule un outil qui les ignore
  cat > "$DECOR_BIN/useradd" <<'EOS'
#!/usr/bin/env bash
echo "useradd $*" >> "$CALLS"
grp=""; shell=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-g" ]] && grp="$2"; [[ "$1" == "--shell" ]] && shell="$2"; last="$1"; shift; done
gid="$(awk -F: -v n="$grp" '$1==n {print $3; exit}' "$LCARS_DECOR_ROOT/etc/group")"
printf '%s:x:999:%s::/nonexistent:%s\n' "$last" "${gid:-65534}" "${STUB_USERADD_SHELL:-$shell}" >> "$LCARS_DECOR_ROOT/etc/passwd"
EOS
  chmod +x "$DECOR_BIN"/*
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
  STUB_USERADD_SHELL=/bin/bash apply
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
