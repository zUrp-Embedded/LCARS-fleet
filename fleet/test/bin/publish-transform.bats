#!/usr/bin/env bats
# SOURCE: fleet/test/bin/publish-transform.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.232
# STATUS: bats tests for bin/publish-transform.sh post-transform certification
#
# filter-repo's exit 0 means "the callback ran", not "no internal attribution survived". These drive
# the extracted scan_forbidden_markers (source guard = no filter-repo needed) on a fixture git repo,
# proving a surviving @lcars.local identity or a LCARS- co-author trailer is REFUSED, and a clean tree
# passes — the certification the script announces is actually checked, not trusted.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-transform.sh"
  # shellcheck source=../../bin/publish-transform.sh
  source "$SCRIPT"
  TMP="$(mktemp -d)"
  # `|| return 1` : sans garde, un `mktemp` en echec laisse TMP vide, `cd ""` echoue
  # en silence, et le `git init` de la ligne suivante s'execute DANS LE DEPOT.
  cd "$TMP" || return 1
  git init -q .
  git config user.name "Human Name"
  git config user.email "human@example.com"
}

teardown() { rm -rf "$TMP"; }

@test "clean tree (no internal marker) → certification PASSES" {
  git commit -q --allow-empty -m "a normal commit"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -eq 0 ]
}

@test "a surviving @lcars.local committer → certification FAILS" {
  GIT_COMMITTER_NAME="LCARS-engineer" GIT_COMMITTER_EMAIL="lcars-engineer@lcars.local" \
    git commit -q --allow-empty -m "leaked internal committer"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identite interne survivante"* ]]
}

@test "a surviving LCARS- co-author trailer → certification FAILS" {
  git commit -q --allow-empty -m "$(printf 'work\n\nCo-authored-by: LCARS-reviewer <lcars-reviewer@lcars.local>')"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"trailer interne survivant"* ]]
}

@test "sourcing publish-transform.sh never runs the transform (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

# ─── THE HUMAN PRE-SCAN, ON A HISTORY BIG ENOUGH TO FILL A PIPE ─────────────────────────────────
# MEASURED 2026-08-20 on jquery/jquery (8489 commits): the transform died with exit 141 — SIGPIPE —
# immediately after the clone, having rewritten nothing. The pre-scan read
#
#     git log --all --format='%cn|%ce' | awk -F'|' '$2 != se {print; exit}'
#
# and `exit` closes the pipe on the FIRST retained line. While the whole log fits in the pipe buffer
# (~64 KB) `git log` has already finished writing and nothing happens; past it, `git log` is still
# writing, takes SIGPIPE, `pipefail` surfaces 141 and `set -e` kills the script.
#
# EVERY FIXTURE IN THIS REPOSITORY IS A HANDFUL OF COMMITS, so every one of them passed — and the
# export rail could not process any project anybody would actually publish.
#
# THE FIXTURE IS BUILT WITH ORDINARY NAMES, and that is deliberate. A 400-character committer name
# reaches 64 KB in 200 commits and would make this test instant — but nobody has such a name, and a
# witness whose shape cannot occur teaches the next reader the wrong threshold. With realistic
# identities a line is ~36 bytes, so the buffer fills at **1820 commits** (measured). 2000 built
# through `git commit-tree` take 2 s, against minutes through `git commit`.

_big_history() { # 2000 commits, ordinary identities, past the pipe buffer
  local tree p="" i
  tree="$(git hash-object -t tree /dev/null)"
  for i in $(seq 1 2000); do
    p="$(GIT_AUTHOR_NAME='Marie Dupont' GIT_AUTHOR_EMAIL='marie.dupont@example.com' \
         GIT_COMMITTER_NAME='Jean Martin' GIT_COMMITTER_EMAIL='jean.martin@example.com' \
         git commit-tree "$tree" ${p:+-p "$p"} -m "c$i")"
  done
  git update-ref refs/heads/main "$p"
}

@test "the human pre-scan survives a log LARGER than the pipe buffer — and the early exit is why" {
  _big_history
  # Past the buffer: this is the state under test, not an incidental one.
  [ "$(git log --all --format='%cn|%ce' | wc -c)" -gt 65536 ]

  scan() { # <awk program>
    bash -c "set -euo pipefail
      cd '$TMP'
      git log --all --format='%cn|%ce' | awk -F'|' -v se='system_starfleet@lcars.local' '$1'"
  }

  # The form the script uses: reads everything, prints once.
  run scan '$2 != se && !seen {print; seen=1}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"jean.martin@example.com"* ]]

  # THE COUNTER-PROOF, same repository, same command, `exit` restored. Without it the witness would
  # show the fix passing without saying where the fault lived.
  #
  # ⚠ MAIS 141 EST UNE PROPRIETE DE GIT, PAS DU CODE JUGE — mesure du 2026-08-20, meme arbre, meme
  # bash 5.2, deux machines :
  #
  #     git 2.43 (poste WSL)     -> 141   (git meurt de SIGPIPE)
  #     git 2.47 (poste natif)   ->   0   (git l'absorbe et sort proprement)
  #
  # Exiger 141 rendait donc ce temoin ROUGE sur la moitie du parc, pour un code parfaitement sain.
  # Un verdict qui depend de la version de l'outil n'est pas un verdict — c'est la troisieme fois
  # que cette classe mord dans la meme soiree (bats 1.10 vs 1.11 en est une autre).
  #
  # On SONDE donc le comportement de CE git avant d'en tirer quoi que ce soit, et quand il n'y a
  # pas de SIGPIPE a observer on le DIT plutot que de rougir ou de passer en silence. Ce que la
  # contre-epreuve demontre — « la forme avec `exit` meurt » — n'est demontrable que la ou elle
  # meurt ; ailleurs, l'affirmer serait inventer une mesure.
  run scan '$2 != se {print; exit}'

  if [ "$status" -eq 141 ]; then
    : # 128 + SIGPIPE — la faute d'origine, reproduite : la contre-epreuve tient.
  else
    echo "# (hors perimetre : git $(git --version | grep -oE '[0-9.]+' | head -1) n'emet pas SIGPIPE" \
         "sur un lecteur qui ferme — contre-epreuve non observable ici, status=$status)" >&3
  fi
}
