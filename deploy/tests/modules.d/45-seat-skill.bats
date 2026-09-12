#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/45-seat-skill.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du skill system-issues posé chez le siège
#
# Le siège des témoins est l'utilisateur qui les joue : la clé est l'uid, le home est un décor.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/45-seat-skill.sh"; [ -f "$MOD" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=45-seat-skill PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export LCARS_SYSADMIN_UID; LCARS_SYSADMIN_UID="$(id -u)"
  export LCARS_SIEGE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$LCARS_SIEGE_HOME"
  export LCARS_ADMIRAL_SKILLS_SRC="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$LCARS_ADMIRAL_SKILLS_SRC/system-issues"
  printf '# skill\n' > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/SKILL.md"
  printf '#!/usr/bin/env bash\necho liste\n' > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
}

mod() { run bash "$MOD" "$@"; }
skill() { echo "$LCARS_SIEGE_HOME/.claude/skills/system-issues"; }

@test "check : skill absent chez le siège — drift qui dit la conséquence" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 45-seat-skill: skill system-issues absent chez $PROV_HUMAN — la boîte de réception"* ]]
}

@test "apply : SKILL.md et list.sh exécutable posés dans le ~/.claude du siège, le check passe au vert, le second apply ne repose rien" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$(skill)/SKILL.md" ] && [ -x "$(skill)/list.sh" ]
  [ "$(stat -c %a "$(skill)")" = 755 ]
  [[ "$output" == *"OK    45-seat-skill: skill system-issues posé chez $PROV_HUMAN"* ]]
  mod check
  [ "$status" -eq 0 ]
  mod apply
  [[ "$output" != *"POSÉ"* ]]
}

@test "apply : le don au siège ne nomme aucun groupe — « <humain>: » seul, le groupe de connexion" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/chown.argv" > "$BIN/chown"
  chmod 0755 "$BIN/chown"
  mod apply
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/chown.argv" ]
  refute grep -qE ':[^[:space:]]+$' "$BATS_TEST_TMPDIR/chown.argv"
  grep -qx -- "$PROV_HUMAN:" "$BATS_TEST_TMPDIR/chown.argv"
}

@test "apply : ~/.claude qui ne peut pas être rendu au siège est un drift dit, le skill est posé quand même" {
  printf '#!/usr/bin/env bash\n[[ "$1" == -h ]] && exit 1\nexec /usr/bin/chown "$@"\n' > "$BIN/chown"; chmod 0755 "$BIN/chown"
  mod apply
  [ "$status" -eq 2 ]
  [ -x "$(skill)/list.sh" ]
  [[ "$output" == *"DRIFT 45-seat-skill: skill system-issues posé chez $PROV_HUMAN, mais $LCARS_SIEGE_HOME/.claude et"*"n'ont pas pu lui être rendus"* ]]
}

@test "l'humain n'est pas le siège : rien n'est posé, check et apply verts" {
  export LCARS_SYSADMIN_UID=99999
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'est pas le siège (uid 99999) — rien à poser"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_SIEGE_HOME/.claude" ]
}

@test "apply : un lien à la place de ~/.claude est refusé, sa cible reste intacte" {
  mkdir -p "$BATS_TEST_TMPDIR/ailleurs"
  ln -s "$BATS_TEST_TMPDIR/ailleurs" "$LCARS_SIEGE_HOME/.claude"
  mod apply
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/ailleurs")" ]
}

@test "apply : source du skill absente ou home introuvable — échec nommé, rien de posé" {
  rm -rf "$LCARS_ADMIRAL_SKILLS_SRC/system-issues"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  45-seat-skill: source du skill absente ($LCARS_ADMIRAL_SKILLS_SRC/system-issues)"* ]]
  mkdir -p "$LCARS_ADMIRAL_SKILLS_SRC/system-issues"; : > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/SKILL.md"; : > "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  export LCARS_SIEGE_HOME="$BATS_TEST_TMPDIR/nulle-part"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"home de $PROV_HUMAN introuvable"* ]]
}
