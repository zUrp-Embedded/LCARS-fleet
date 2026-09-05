#!/usr/bin/env bats
# SOURCE: runtime/test/bin/lcars_approve_existence.bats
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: bats tests for `lcars approve` — the THREE states of destination existence
#
# WHY THIS FILE EXISTS. `forge-cli.sh repo-exists` answers three things: present (0), absent (1),
# UNDECIDABLE (2 — somebody else's private repository, insufficient rights). The helper documents
# that distinction at length and holds it. The CALL SITE flattened it back: a bare
# `_dest_repo_exists … && repo_exists=1` puts 2 in the same bag as 1, so `approve` walked on to the
# creation, which failed with "name already exists" — precisely the defect the helper closes.
#
# Closing a class in the right place buys nothing if the call site squashes the result. An
# adversarial code review found this, and it found it because NO witness covered the path. This is
# that witness.

load ../support/refute

setup() {
  HOMEDIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOMEDIR/.lcars/forges"
  export HOME="$HOMEDIR"

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cp "$BATS_TEST_DIRNAME/../../bin/lcars" "$BIN/lcars"
  SUT="$BIN/lcars"
  FCLOG="$BATS_TEST_TMPDIR/fclog"

  # The forge pool entry the verb resolves its destination from.
  printf '{"host":"github","dest_host":"github.com","owner":"acme"}' > "$HOMEDIR/.lcars/forges/gh.json"

  # The container env `approve` refuses to run without.
  #
  # ⚠ `FORGE_TOKEN_FILE` A QUITTE CE FICHIER D'ENV, ET C'EST LE CHANTIER, PAS LA FIXTURE. Le jeton
  # systeme vivait en `0640 root:fleet`, lisible par l'humain a travers un groupe qui n'etait qu'une
  # projection de l'equipe `humans` de la forge. `approve` le DEMANDE maintenant au service
  # d'autorite. Ce que le conteneur ecrit encore ici est le nom du COMPTE, pas un chemin vers un secret.
  printf 'FORGE_BASE_URL=file://%s/forge\nFORGE_BOT_LOGIN=system_starfleet\n' "$HOMEDIR" \
    > "$HOMEDIR/fleet.env"
  export LCARS_FLEET_ENV="$HOMEDIR/fleet.env"

  # La doublure du client d'autorite : elle rend un jeton, comme le vrai quand la forge dit oui.
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask"
  printf '#!/usr/bin/env bash\nprintf "t\\n"\n' > "$LCARS_AUTHORITY_ASK_BIN"
  chmod +x "$LCARS_AUTHORITY_ASK_BIN"

  # The transform is stubbed: it must leave a real git repo at --out, because the verb `cd`s into it
  # and runs git against it. What it CONTAINS is irrelevant to the existence probe.
  cat > "$BIN/publish-transform.sh" <<EOF
#!/usr/bin/env bash
out=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--out" ]] && out="\$2"; shift; done
mkdir -p "\$out" && git init -q -b main "\$out"
git -C "\$out" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
EOF
  chmod +x "$BIN/publish-transform.sh"
}

# The helper is stubbed so the three states can be driven; what is under test is how the VERB reads
# them, not how the helper computes them (`test/bin/forge-cli.bats` covers that side).
_forge_cli_stub() { # <exit code for repo-exists>
  cat > "$BIN/forge-cli.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FCLOG"
case "\$1" in
  auth-ok)        exit 0 ;;
  repo-exists)    exit ${1} ;;
  default-branch) echo main; exit 0 ;;
  repo-create)    exit 0 ;;
  *)              exit 0 ;;
esac
EOF
  chmod +x "$BIN/forge-cli.sh"
}

@test "existence UNDECIDABLE (2) -> refus nomme, et RIEN n'est cree" {
  # THE DEFECT THIS FORBIDS: 2 read as "absent", the verb creating a repository that exists, and the
  # forge answering "name already exists" — a message that blames the creation for a failure of the
  # read, and teaches the operator nothing about rights.
  _forge_cli_stub 2
  run "$SUT" approve fleet/demo --forge gh --as widget
  [ "$status" -eq 1 ]
  [[ "$output" == *"INDECIDABLE"* ]]
  [[ "$output" == *"Rien n'a ete cree"* ]]
  refute grep -q "^repo-create" "$FCLOG"
}

@test "existence ABSENT (1) -> la creation est tentee" {
  _forge_cli_stub 1
  run "$SUT" approve fleet/demo --forge gh --as widget
  grep -q "^repo-create" "$FCLOG"
}

@test "existence PRESENT (0) -> aucune creation, la base est derivee de la destination" {
  _forge_cli_stub 0
  run "$SUT" approve fleet/demo --forge gh --as widget
  refute grep -q "^repo-create" "$FCLOG"
  # And it ASKS the destination for its default branch instead of assuming `main`.
  grep -q "^default-branch" "$FCLOG"
}
