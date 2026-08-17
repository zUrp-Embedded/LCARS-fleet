#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/docker_sh_project.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-07
# STATUS: bats tests for docker.sh — a project NAME is not proof you are talking about the same box
#
# WHY THIS EXISTS. `docker.sh` targeted the compose project `lcars` as a hardcoded constant. Compose
# will happily apply a file to a project it never created: it computes the desired state from THAT
# file and recreates, republishes ports, drops what is absent — with no error, because from its own
# point of view nothing is wrong. The name is enough to address the project; it is not enough to
# prove both parties mean the same object.
#
# Measured on this workstation on 2026-08-07: `lcars` was a 47-hour-old working box created from
# `fleet/provisioning_v2/docker/docker-compose.install.yml` — a path DELETED by the 2026-08-04 move.
# `./docker.sh down` stopped it, `./docker.sh reset` took its /home volume, and neither said a word.
# That is the dominant defect family here: a defect that breaks gets killed by whoever meets it; a
# defect that returns GREEN survives indefinitely.
#
# WHAT IS PINNED. The guard reads the container's own `com.docker.compose.project.config_files`
# label — the list of files that actually created it — instead of trusting the name. What matters is
# both directions: it must REFUSE a foreign project, and it must NOT refuse an empty one (there is
# nothing to confuse, and `up` is entitled to create it).
#
# The last test has nothing to do with projects and everything to do with the same family: the help
# text used to be extracted by line numbers (`sed -n '6,35p'`), so inserting one header line
# truncated it silently. An amputated help never reports itself either.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SRC="$REPO/docker.sh"
  CF="$REPO/fleet/deploy/docker/docker-compose.yml"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # A docker daemon seen through a keyhole. Two env knobs drive it:
  #   STUB_IDS           what `ps -aq --filter label=…project=<p>` returns ("" = project has no
  #                      container at all, which is the case the guard must let through)
  #   STUB_CONFIG_FILES  what `inspect --format` prints, i.e. the comma-separated list of compose
  #                      files that created those containers
  cat > "$BINDIR/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "ps -aq")          printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0 ;;
  "inspect \${STUB_IDS:-__none__}") echo "\${STUB_CONFIG_FILES:-}"; exit 0 ;;
esac
# Le verdict de provisionnement, lu par `up` DANS la boite. `STUB_PROV_RC` vide = le fichier n'est
# pas encore la, ce qui est l'etat normal pendant tout le provisionnement.
if [[ "\$*" == *"cat /run/lcars-provision.rc"* ]]; then
  [[ -n "\${STUB_PROV_RC:-}" ]] || exit 1
  printf '%s\n' "\${STUB_PROV_RC}"
  exit 0
fi
exit 0
EOF
  chmod 0755 "$BINDIR/docker"

  export PATH="$BINDIR:$PATH"
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_PROV_RC
}

# A project holding one container, created from the files given as arguments.
seed_project() {
  export STUB_IDS="c0ffee"
  export STUB_CONFIG_FILES="$1"
}

@test "an EMPTY project is not refused — up is entitled to create it" {
  # STUB_IDS unset: `ps -aq` returns nothing, so there is no container whose provenance to read.
  run bash "$SRC" -p lcars-jamais-cree down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
  # It really went through to compose rather than short-circuiting.
  grep -q -- "-p lcars-jamais-cree down" "$CALLS"
}

@test "a project created by THIS compose file passes the guard" {
  seed_project "$CF"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
  grep -q -- "-p lcars down" "$CALLS"
}

@test "a project created by ANOTHER compose file is refused, and the refusal names both" {
  # The real case: the box predating the move, whose creating file no longer exists on disk.
  seed_project "/home/projects/LCARS/fleet/provisioning_v2/docker/docker-compose.install.yml"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  # A refusal that does not say WHAT it saw cannot be acted on.
  [[ "$output" == *"provisioning_v2"* ]]
  [[ "$output" == *"$CF"* ]]
  [[ "$output" == *"docker compose ls"* ]]
  # Nothing reached compose: the guard is upstream, not a post-mortem.
  ! grep -q "down" "$CALLS"
}

@test "the file must match a WHOLE list element, never a prefix of one" {
  # `<file>` is a strict prefix of `<file>.bak`. Substring matching would call this project ours
  # and hand a live box to `down`.
  seed_project "$CF.bak"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
}

@test "one match inside a multi-file list is enough" {
  seed_project "/somewhere/base.yml,$CF,/somewhere/override.yml"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
}

@test "reset refuses BEFORE asking for confirmation" {
  # Order is the contract. A confirmation prompt shown first teaches the operator to type `yes` at
  # a question about the wrong box, and destruction follows their own answer.
  seed_project "/elsewhere/docker-compose.install.yml"

  run bash "$SRC" -p lcars-valid reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  [[ "$output" != *"RESET du projet"* ]]
  ! grep -q "volume rm" "$CALLS"
}

@test "reset NAMES the project it is about to destroy" {
  # `setsid` detaches from the controlling terminal, so opening /dev/tty FAILS and the confirmation
  # read yields nothing. Without it this test HANGS whenever the suite runs from a terminal — the
  # prompt would wait for a human who is not there. Skipping loudly beats a test that blocks a gate.
  command -v setsid >/dev/null || skip "setsid absent: cannot detach the tty without risking a hang"
  seed_project "$CF"

  # The empty answer takes the abort path. What is pinned is the QUESTION — a destruction prompt
  # that does not say which box is not a question, it is a reflex to type `yes` into.
  run setsid --wait bash "$SRC" -p lcars-a-moi reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi"* ]]
  [[ "$output" == *"lcars-a-moi_lcars-home"* ]]
  [[ "$output" == *"annulé"* ]]
}

@test "LCARS_PROJECT is read, and -p overrides it" {
  seed_project "$CF"

  LCARS_PROJECT=depuis-env run bash "$SRC" down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-env down" "$CALLS"

  : > "$CALLS"
  LCARS_PROJECT=depuis-env run bash "$SRC" -p depuis-flag down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-flag down" "$CALLS"
  ! grep -q -- "-p depuis-env " "$CALLS"
}

@test "-p without a value is refused rather than swallowing the command" {
  # `./docker.sh -p down` must not silently target a project named "down" and run no command.
  run bash "$SRC" -p

  [ "$status" -eq 1 ]
  [[ "$output" == *"-p attend un nom de projet"* ]]
}

@test "help works with NO docker at all, and is not truncated" {
  # Help is the one command that must survive a machine without docker — it is what you read to
  # find out what is missing.
  run env PATH=/usr/bin:/bin bash "$SRC" help

  [ "$status" -eq 0 ]
  # First line of the block and last line of the block: the extraction is anchored on content, so
  # inserting a header line can no longer amputate the tail.
  [[ "$output" == *"LCARS fleet v2 en conteneur"* ]]
  [[ "$output" == *"EXIT :"* ]]
  # And the -p contract is documented where an operator looks for it.
  [[ "$output" == *"LCARS_PROJECT"* ]]
}

# ─── `up` REND LE VERDICT DE PROVISIONNEMENT ────────────────────────────────────────────────────
#
# ⚠ CES TEMOINS EXISTENT PARCE QUE `up` RENDAIT LA MAIN AVANT DE SAVOIR. `compose up -d` sort des
# que le conteneur demarre ; le provisionnement tourne DANS l'entrypoint et dure. Une boite qui n'a
# rien pu provisionner annoncait « fleet up », se declarait *healthy* (son healthcheck teste le port
# 22) et ne pouvait demarrer AUCUN pod — le seul endroit ou ca se lisait etant les logs, qu'on ne va
# pas lire apres une commande qui a dit oui.
#
# Les quatre etats sont distincts PARCE QU'ILS APPELLENT QUATRE GESTES DIFFERENTS, et le quatrieme
# est celui qui compte : ne pas avoir LU le verdict n'est pas l'avoir lu mauvais. On le dit, et on
# sort 0 — sortir non nul sur une non-mesure apprendrait a ignorer le code de sortie, ce qui coute
# exactement le jour ou il est vrai.

@test "up: verdict 0 -> CONVERGE, sortie 0" {
  STUB_PROV_RC=0 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"provisionnement CONVERGÉ"* ]]
}

@test "up: verdict 2 -> DRIFT nomme, mais PAS un echec (un geste manque, rien n'est casse)" {
  STUB_PROV_RC=2 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT RÉSIDUEL"* ]]
  [[ "$output" != *"EN ÉCHEC"* ]]
}

@test "up: verdict non nul -> ECHEC, sortie NON NULLE, et la consequence est nommee" {
  STUB_PROV_RC=1 run "$SRC" -p lcars up
  [ "$status" -eq 1 ]
  [[ "$output" == *"EN ÉCHEC"* ]]
  # « la boite tourne » ET « ne produira rien » : les deux moities, sinon le lecteur croit que
  # le conteneur est mort et va le relancer au lieu de diagnostiquer.
  [[ "$output" == *"la boîte tourne"* ]]
  [[ "$output" == *"ne produira RIEN"* ]]
}

@test "up: verdict ILLISIBLE -> on le DIT et on sort 0 — une non-mesure n'est pas un echec" {
  LCARS_UP_VERDICT_TIMEOUT=1 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON LU"* ]]
  [[ "$output" == *"n'est PAS mesuré"* ]]
  [[ "$output" != *"EN ÉCHEC"* ]]
}
