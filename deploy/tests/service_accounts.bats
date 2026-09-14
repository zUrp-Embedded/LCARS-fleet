#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/service_accounts.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests for modules.d/21-service-accounts.sh — le GROUPE PRIMAIRE et le shell des comptes de service

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
  export PROVISION_LIB="$LIB" PROVISION_MODULE=21-service-accounts PROV_SUBSTRATE=linux

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
printf '%s:x:9999:\n' "${*: -1}" >> "$LCARS_DECOR_ROOT/etc/group"
EOS
  # la doublure d'`usermod` applique vraiment -g, -s et -aG : l'idempotence se mesure sur le décor
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
  # l'adhésion secondaire s'écrit dans la quatrième colonne du group : sans elle, ensure_member
  # échoue, verdict_apply coupe, et la suite d'apply n'est jamais jouée
  awk -F: -v OFS=: -v gr="$2" -v u="${*: -1}" \
    '$1==gr {$4=($4=="" ? u : $4","u)} {print}' "$g" > "$g.new" && mv "$g.new" "$g"
fi
EOS
  cat > "$DECOR_BIN/useradd" <<'EOS'
#!/usr/bin/env bash
echo "useradd $*" >> "$CALLS"
grp=""; shell=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-g" ]] && grp="$2"; [[ "$1" == "--shell" ]] && shell="$2"; last="$1"; shift; done
gid="$(awk -F: -v n="$grp" '$1==n {print $3; exit}' "$LCARS_DECOR_ROOT/etc/group")"
printf '%s:x:999:%s::/nonexistent:%s\n' "$last" "${gid:-65534}" "$shell" >> "$LCARS_DECOR_ROOT/etc/passwd"
EOS
  chmod +x "$DECOR_BIN"/*
}

check() { run bash "$MOD" check; }
apply() { run bash "$MOD" apply; }

# Le groupe primaire d'un compte, lu comme le module le lit.
pg() {
  local gid; gid="$(awk -F: -v n="$1" '$1==n {print $4; exit}' "$PASSWD")"
  awk -F: -v g="$gid" '$3==g {print $1; exit}' "$GROUP"
}

# Deplace un compte vers un autre groupe primaire, sans passer par le module.
derive() {
  local gid; gid="$(awk -F: -v n="$2" '$1==n {print $3; exit}' "$GROUP")"
  awk -F: -v OFS=: -v n="$1" -v g="$gid" '$1==n {$4=g} {print}' "$PASSWD" > "$PASSWD.n"
  mv "$PASSWD.n" "$PASSWD"
}

@test "DECOR : le module se joue, et le decor nominal ne porte aucun drift de groupe primaire" {
  check
  [ "$status" -eq 0 ]                 # un decor nominal ne rend AUCUN drift, sinon les autres mentent
  printf '%s\n' "$output" | refute_out 'groupe primaire de .* au lieu de'
  [[ "$output" == *"groupe primaire de lcars-authority : lcars-authority"* ]]
  [[ "$output" == *"groupe primaire de lcars-system : lcars-system"* ]]
}

@test "le groupe de chaque compte est son nom — PROV_AUTHORITY_GROUP et PROV_SYSTEM_GROUP exportés n'y changent rien" {
  PROV_AUTHORITY_GROUP=nogroup PROV_SYSTEM_GROUP=nogroup check
  [ "$status" -eq 0 ]
  [[ "$output" == *"groupe primaire de lcars-authority : lcars-authority"* ]]
  [[ "$output" == *"groupe primaire de lcars-system : lcars-system"* ]]
}

@test "CHECK : un compte de service derive vers nogroup est un DRIFT, pas un vert" {
  # `nogroup` est partagé par plusieurs comptes système : un secret écrit par `lcars-system` y naîtrait lisible par tous
  derive lcars-system nogroup
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"groupe primaire de lcars-system : « nogroup » au lieu de lcars-system"* ]]
}

@test "CHECK : le drift nomme la CONSEQUENCE, pas seulement l'ecart" {
  # ce qui décide d'agir, c'est ce qui se passe si on n'agit pas
  derive lcars-authority nogroup
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets de forge"* ]]
}

@test "CHECK : les DEUX comptes sont sondes — pas seulement le premier" {
  # La symetrie du module est sa forme, et une moitie oubliee y est invisible a la lecture.
  derive lcars-authority nogroup
  derive lcars-system nogroup
  check
  [ "$status" -eq 1 ]
  local n; n="$(grep -c 'DRIFT.*groupe primaire de .* au lieu de' <<<"$output" || true)"
  [ "$n" -eq 2 ]
}

@test "CHECK : un compte de service qui se connecte est un drift — le shell attendu est /usr/sbin/nologin" {
  awk -F: -v OFS=: '$1=="lcars-system" {$7="/bin/bash"} {print}' "$PASSWD" > "$PASSWD.n"; mv "$PASSWD.n" "$PASSWD"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 21-service-accounts: compte lcars-system présent mais son shell n'est pas /usr/sbin/nologin"* ]]
}

@test "APPLY : le shell converge vers /usr/sbin/nologin — un LCARS_NOLOGIN exporté n'y change rien" {
  awk -F: -v OFS=: '$1=="lcars-system" {$7="/bin/false"} {print}' "$PASSWD" > "$PASSWD.n"; mv "$PASSWD.n" "$PASSWD"
  LCARS_NOLOGIN=/bin/false apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'usermod -s /usr/sbin/nologin -- lcars-system' "$CALLS"
  [ "$(awk -F: '$1=="lcars-system" {print $7}' "$PASSWD")" = /usr/sbin/nologin ]
}

@test "APPLY : la derive est CONVERGEE, pas seulement signalee" {
  derive lcars-system nogroup
  [ "$(pg lcars-system)" = "nogroup" ]
  apply
  [ "$(pg lcars-system)" = "lcars-system" ]
  grep -q -- 'usermod -g lcars-system' "$CALLS"
}

@test "APPLY : idempotent — le second passage ne touche plus au groupe primaire" {
  # un état déjà bon ne produit aucun geste : un usermod inconditionnel ferait mentir les compteurs
  derive lcars-authority nogroup
  apply
  : > "$CALLS"
  apply
  refute grep -q -- 'usermod -g' "$CALLS"
}

@test "APPLY : un compte CREE par nous ne se fait pas corriger derriere — useradd -g suffit" {
  # sur un compte neuf, `useradd -g` a déjà posé le bon groupe : un usermod de plus dirait que les deux gestes s'ignorent
  grep -v '^lcars-system:' "$PASSWD" > "$PASSWD.n"
  mv "$PASSWD.n" "$PASSWD"
  apply
  [ "$(pg lcars-system)" = "lcars-system" ]
  grep -qx 'useradd --system --no-create-home --shell /usr/sbin/nologin -g lcars-system -- lcars-system' "$CALLS"
  refute grep -q -- 'usermod -g lcars-system' "$CALLS"
}

@test "le group du décor est lu — la sonde ne lit pas /etc/group de la machine" {
  # le gid 2002 change de nom dans le décor : seul un module qui lit ce fichier peut le nommer
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:lcars-authority' 'renomme-au-decor:x:2002:' 'lcars-system:x:2003:' > "$GROUP"
  check
  [[ "$output" == *"groupe primaire de lcars-authority : « renomme-au-decor » au lieu de lcars-authority"* ]]
}
