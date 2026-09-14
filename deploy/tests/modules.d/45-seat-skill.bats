#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/45-seat-skill.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du skill system-issues posé chez le siège
#
# Le siège des témoins est l'utilisateur qui les joue : la clé est l'uid, le home vient d'un getent de décor.

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/45-seat-skill.sh"; [ -f "$MOD" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=45-seat-skill PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export LCARS_SYSADMIN_UID; LCARS_SYSADMIN_UID="$(id -u)"
  decor_pose
  BIN="$DECOR_BIN"
  export SIEGE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$SIEGE_HOME"
  # le home du siège est celui que getent rend : la doublure le lit dans SIEGE_HOME, vide = compte inconnu
  cat > "$DECOR_BIN/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == passwd && -n "${SIEGE_HOME:-}" ]] || exit 2
printf '%s:x:%s:%s::%s:/bin/bash\n' "${@: -1}" "$(id -u)" "$(id -g)" "$SIEGE_HOME"
EOF
  chmod 0755 "$DECOR_BIN/getent"
  export LCARS_ADMIRAL_SKILLS_SRC="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$LCARS_ADMIRAL_SKILLS_SRC/system-issues"
  printf '# skill\n' > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/SKILL.md"
  printf '#!/usr/bin/env bash\necho liste\n' > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
}

mod() { run bash "$MOD" "$@"; }
skill() { echo "$SIEGE_HOME/.claude/skills/system-issues"; }

@test "check : skill absent chez le siège — drift qui dit la conséquence" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 45-seat-skill: skill system-issues absent ou incomplet chez $PROV_HUMAN — la boîte de réception"* ]]
}

@test "check : un skill sans son SKILL.md est incomplet, pas posé" {
  mkdir -p "$(skill)"; printf '#!/usr/bin/env bash\n' > "$(skill)/list.sh"; chmod 0755 "$(skill)/list.sh"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"absent ou incomplet chez $PROV_HUMAN"* ]]
}

@test "apply : SKILL.md et list.sh exécutable posés dans le ~/.claude du siège, le check passe au vert, le second apply ne repose rien" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$(skill)/SKILL.md" ]
  [ -x "$(skill)/list.sh" ]
  [ "$(stat -c %a "$(skill)")" = 755 ]
  [[ "$output" == *"OK    45-seat-skill: skill system-issues posé chez $PROV_HUMAN"* ]]
  mod check
  [ "$status" -eq 0 ]
  mod apply
  [[ "$output" != *"POSÉ"* ]]
}

@test "apply : chaque don au siège nomme son groupe de connexion en entier — jamais la forme « humain: » nue, que les coreutils uutils ignorent" {
  printf '#!/usr/bin/env bash\nfor a; do [[ "$a" == -* ]] || { printf "%%s\\n" "$a" >> "%s"; break; }; done\nexec /usr/bin/chown "$@"\n' "$BATS_TEST_TMPDIR/chown.argv" > "$BIN/chown"
  chmod 0755 "$BIN/chown"
  mod apply
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/chown.argv")" -ge 3 ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/chown.argv")" = "$PROV_HUMAN:$(id -gn)" ]
}

@test "apply : ~/.claude qui ne peut pas être rendu au siège est un drift dit, le skill est posé quand même" {
  printf '#!/usr/bin/env bash\n[[ "$1" == -h ]] && exit 1\nexec /usr/bin/chown "$@"\n' > "$BIN/chown"; chmod 0755 "$BIN/chown"
  mod apply
  [ "$status" -eq 2 ]
  [ -x "$(skill)/list.sh" ]
  [[ "$output" == *"DRIFT 45-seat-skill: skill system-issues posé chez $PROV_HUMAN, mais $SIEGE_HOME/.claude et"*"n'ont pas pu lui être rendus"* ]]
}

@test "l'humain n'est pas le siège : rien n'est posé, check et apply verts, les deux uid dits" {
  export LCARS_SYSADMIN_UID=99999
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    45-seat-skill: $PROV_HUMAN (uid $(id -u)) n'est pas le siège (uid 99999) — rien à poser"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [ ! -e "$SIEGE_HOME/.claude" ]
}

@test "apply : un lien à la place de ~/.claude est refusé, sa cible reste intacte" {
  mkdir -p "$BATS_TEST_TMPDIR/ailleurs"
  ln -s "$BATS_TEST_TMPDIR/ailleurs" "$SIEGE_HOME/.claude"
  mod apply
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/ailleurs")" ]
}

@test "apply : source du skill absente — échec nommé, rien de posé" {
  rm -rf "$LCARS_ADMIRAL_SKILLS_SRC/system-issues"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  45-seat-skill: source du skill absente ($LCARS_ADMIRAL_SKILLS_SRC/system-issues)"* ]]
  [ ! -e "$SIEGE_HOME/.claude" ]
}

@test "apply : home du siège absent du disque — échec nommé" {
  export SIEGE_HOME="$BATS_TEST_TMPDIR/nulle-part"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  45-seat-skill: home de $PROV_HUMAN introuvable"* ]]
}

@test "apply : un siège que getent ne connaît pas — échec nommé, rien de posé" {
  export SIEGE_HOME=""
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  45-seat-skill: home de $PROV_HUMAN introuvable"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/home/.claude" ]
}
