#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/service_accounts.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for modules.d/21-service-accounts.sh — le GROUPE PRIMAIRE des comptes de service
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# Le module portait quatre seams d'injection — `LCARS_USERADD`, `LCARS_USERMOD`, `LCARS_PASSWD_FILE`,
# `LCARS_NOLOGIN` — et AUCUN lecteur. Des coutures posees pour un temoin qui n'a jamais ete ecrit :
# le module etait donc entierement non joue, et c'est dans cet angle mort que le defaut vivait.
#
# LE DEFAUT : `useradd -g` ne pose le groupe primaire QU'A LA CREATION. Un compte qui existait deja
# — parce qu'un operateur l'avait cree, parce qu'un `usermod` l'a deplace, parce qu'une install
# ancienne l'a laisse — garde le groupe qu'il a. `check` ne le regardait pas et `apply` ne le
# corrigeait pas : `lcars-system` retombe sur `nogroup` passait au VERT, en rendant le secret OAuth2
# du deck lisible par tout ce qui porte ce groupe. C'est exactement l'etat que le message de drift
# du module decrit comme la raison d'etre du compte.
#
# ⚠ CE QUI EST MESURE EST LA DECISION, PAS `usermod`. Les binaires d'identite sont des doublures qui
# ecrivent dans un `/etc/passwd` et un `/etc/group` de tmpdir. Ce temoin ne cree aucun compte.

# ⚠ SC2030/SC2031 : chaque `@test` de bats est un sous-shell, et c'est l'isolation qu'on veut.
# shellcheck disable=SC2030,SC2031

load refute

setup() {
  MOD="$BATS_TEST_DIRNAME/../modules.d/21-service-accounts.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -f "$MOD" ]
  export PROVISION_LIB="$LIB"

  PASSWD="$BATS_TEST_TMPDIR/passwd"
  GROUP="$BATS_TEST_TMPDIR/group"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  export LCARS_PASSWD_FILE="$PASSWD"
  export LCARS_GROUP_FILE="$GROUP"
  export PROV_AUTHORITY_USER=lcars-authority
  export PROV_SYSTEM_USER=lcars-system
  export PROV_FLEET_GROUP=fleet
  export LCARS_NOLOGIN=/usr/sbin/nologin

  # Le decor nominal : les groupes existent, les comptes aussi, chacun sur SON groupe eponyme.
  # ⚠ `lcars-authority` EST MEMBRE DE `fleet` DANS LE DECOR NOMINAL, et ce n'est pas un detail de
  # confort : sans cette adhesion SECONDAIRE, `check` rend un drift legitime (il ne traverserait pas
  # l'install RO) et le temoin du decor mesurerait ce drift-la au lieu du sien.
  printf '%s\n' 'root:x:0:'            'fleet:x:2000:lcars-authority' 'lcars-authority:x:2002:' \
                'lcars-system:x:2003:' 'nogroup:x:65534:'             > "$GROUP"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' \
                'lcars-authority:x:900:2002::/nonexistent:/usr/sbin/nologin' \
                'lcars-system:x:901:2003::/nonexistent:/usr/sbin/nologin' > "$PASSWD"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # `getent` et `id` lisent NOS deux fichiers — sans quoi le module mesurerait la machine qui joue
  # la suite, et le decor ne servirait a rien.
  cat > "$BATS_TEST_TMPDIR/bin/getent" <<'EOS'
#!/usr/bin/env bash
[[ "$1" == "group" ]] || exit 2
[[ -n "${2:-}" ]] || { cat "$LCARS_GROUP_FILE"; exit 0; }
awk -F: -v n="$2" '$1==n {print; found=1} END {exit !found}' "$LCARS_GROUP_FILE"
EOS
  cat > "$BATS_TEST_TMPDIR/bin/id" <<'EOS'
#!/usr/bin/env bash
# Deux formes, et les DEUX sont appelees : `id <user>` (existence, par `ensure_member`) et
# `id -nG <user>` (le groupe primaire plus les secondaires portes par /etc/group).
if [[ "${1:-}" != "-nG" ]]; then
  awk -F: -v n="${1:-}" '$1==n {found=1} END {exit !found}' "$LCARS_PASSWD_FILE"; exit
fi
u="$2"; gid="$(awk -F: -v n="$u" '$1==n {print $4; exit}' "$LCARS_PASSWD_FILE")"
{ awk -F: -v g="$gid" '$3==g {print $1}' "$LCARS_GROUP_FILE"
  awk -F: -v u="$u" '{n=split($4,m,","); for(i=1;i<=n;i++) if (m[i]==u) print $1}' "$LCARS_GROUP_FILE"
} | sort -u | tr '\n' ' '
EOS
  cat > "$BATS_TEST_TMPDIR/bin/groupadd" <<'EOS'
#!/usr/bin/env bash
echo "groupadd $*" >> "$CALLS"
printf '%s:x:9999:\n' "${*: -1}" >> "$LCARS_GROUP_FILE"
EOS
  # ⚠ LA DOUBLURE D'`usermod` APPLIQUE VRAIMENT `-g`. Une doublure qui se contenterait de tracer
  # l'appel rendrait l'idempotence intestable : `apply` deux fois de suite doit converger UNE fois.
  cat > "$BATS_TEST_TMPDIR/bin/usermod" <<'EOS'
#!/usr/bin/env bash
echo "usermod $*" >> "$CALLS"
if [[ "${1:-}" == "-g" ]]; then
  gid="$(awk -F: -v n="$2" '$1==n {print $3; exit}' "$LCARS_GROUP_FILE")"
  [[ -n "$gid" ]] || exit 1
  awk -F: -v OFS=: -v n="${*: -1}" -v g="$gid" '$1==n {$4=g} {print}' "$LCARS_PASSWD_FILE" \
    > "$LCARS_PASSWD_FILE.new" && mv "$LCARS_PASSWD_FILE.new" "$LCARS_PASSWD_FILE"
elif [[ "${1:-}" == "-aG" ]]; then
  # L'adhesion SECONDAIRE s'ecrit dans la quatrieme colonne de /etc/group. Sans elle, le
  # `ensure_member` du module echoue, `verdict_apply` coupe, et tout ce qui suit dans `apply` n'est
  # jamais joue — un temoin vert sur la moitie du module qu'il croit mesurer.
  awk -F: -v OFS=: -v g="$2" -v u="${*: -1}" \
    '$1==g {$4=($4=="" ? u : $4","u)} {print}' "$LCARS_GROUP_FILE" \
    > "$LCARS_GROUP_FILE.new" && mv "$LCARS_GROUP_FILE.new" "$LCARS_GROUP_FILE"
fi
EOS
  cat > "$BATS_TEST_TMPDIR/bin/useradd" <<'EOS'
#!/usr/bin/env bash
echo "useradd $*" >> "$CALLS"
grp=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-g" ]] && grp="$2"; last="$1"; shift; done
gid="$(awk -F: -v n="$grp" '$1==n {print $3; exit}' "$LCARS_GROUP_FILE")"
printf '%s:x:999:%s::/nonexistent:/usr/sbin/nologin\n' "$last" "${gid:-65534}" >> "$LCARS_PASSWD_FILE"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin"/*
  export CALLS
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

@test "CHECK : un compte de service derive vers nogroup est un DRIFT, pas un vert" {
  # LE DEFAUT, dans son etat exact. `nogroup` est partage par plusieurs comptes systeme : un secret
  # ecrit par `lcars-system` y naitrait lisible par tous.
  derive lcars-system nogroup
  check
  # ⚠ LE VERDICT, PAS LE TEXTE. Premiere version de ce temoin : elle ne cherchait que la phrase.
  # Mutation jouee — `p_drift` remplace par `p_ok` — et les trois temoins de sonde restaient VERTS,
  # sur un module qui rendait desormais rc 0 sur un compte derive. Un temoin qui lit la prose d'un
  # verdict mesure la prose ; ce qui engage le doctor est le CODE DE SORTIE.
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"groupe primaire de lcars-system : « nogroup » au lieu de lcars-system"* ]]
}

@test "CHECK : le drift nomme la CONSEQUENCE, pas seulement l'ecart" {
  # Un verdict qui dit « ce n'est pas la valeur attendue » n'apprend rien a qui lit le doctor. Ce
  # qui decide d'agir, c'est ce qui se passe si on n'agit pas.
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

@test "APPLY : la derive est CONVERGEE, pas seulement signalee" {
  derive lcars-system nogroup
  [ "$(pg lcars-system)" = "nogroup" ]
  apply
  [ "$(pg lcars-system)" = "lcars-system" ]
  grep -q -- 'usermod -g lcars-system' "$CALLS"
}

@test "APPLY : idempotent — le second passage ne touche plus au groupe primaire" {
  # « converge » veut dire qu'un etat deja bon ne produit AUCUN geste. Un `usermod` inconditionnel
  # passerait le premier temoin et ferait mentir tous les compteurs de changement.
  derive lcars-authority nogroup
  apply
  : > "$CALLS"
  apply
  refute grep -q -- 'usermod -g' "$CALLS"
}

@test "APPLY : un compte CREE par nous ne se fait pas corriger derriere — useradd -g suffit" {
  # La convergence vient APRES la creation. Sur un compte neuf, `useradd -g` a deja pose le bon
  # groupe : un `usermod` de plus serait le signe que les deux gestes s'ignorent.
  grep -v '^lcars-system:' "$PASSWD" > "$PASSWD.n" && mv "$PASSWD.n" "$PASSWD"
  apply
  [ "$(pg lcars-system)" = "lcars-system" ]
  grep -q 'useradd .*lcars-system' "$CALLS"
  refute grep -q -- 'usermod -g lcars-system' "$CALLS"
}

@test "SEAM : LCARS_GROUP_FILE est LU — la sonde ne lit pas /etc/group de la machine" {
  # Une couture qu'aucun temoin ne tire est une couture qui ne tient rien. Celle-ci porte tout le
  # fichier : sans elle, ces temoins mesureraient la machine qui joue la suite.
  printf '%s\n' 'root:x:0:' 'fleet:x:2000:' > "$GROUP"   # les deux groupes de service disparaissent
  check
  [[ "$output" == *"groupe lcars-authority absent"* ]]
}
