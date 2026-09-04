#!/usr/bin/env bats
# SOURCE: runtime/git-hooks/tests/go7_exempt.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for pre-commit — the evidence-directory marker, and what it must NOT relax
#
# WHY THIS EXISTS. GO-7 requires a declarative header on every versioned file. A campaign corpus —
# a captured SP, a verbatim brief, a replay input — is worth exactly the byte the agent read, so
# adding a header to it changes what a replay replays. Every corpus so far went in under
# `--no-verify`, which does not skip GO-7 for the corpus: it skips EVERY check for EVERY file in
# that commit. The silent blast radius was the real cost.
#
# The marker is a DECLARATION next to what it exempts, not a path list in the hook — a future
# campaign cannot be foreseen from in here. The tests below pin the two halves that matter: the
# exemption must reach PASS 1 (which rewrites date stamps in place, and would alter the very piece
# it is meant to protect), and it must NOT leak one directory upward.
#
# Real git throughout: the hook reads `git diff --cached`, and a test asserting on its source text
# would prove the string rather than the behaviour.

setup() {
  HOOKS_SRC="$BATS_TEST_DIRNAME/.."
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.git-init"
  git init -q --initial-branch main "$REPO"
  git -C "$REPO" config user.email a@b.c
  git -C "$REPO" config user.name a

  cp "$HOOKS_SRC/pre-commit" "$REPO/.git/hooks/pre-commit"
  [[ -f "$HOOKS_SRC/hook-config.sh" ]] && cp "$HOOKS_SRC/hook-config.sh" "$REPO/.git/hooks/hook-config.sh"
  chmod 0755 "$REPO/.git/hooks/pre-commit"
}

# A doc with no declarative header — the thing GO-7 exists to refuse.
headerless() {
  mkdir -p "$(dirname "$REPO/$1")"
  printf '# Titre\n\nDu texte, et pas la moindre metadonnee.\n' > "$REPO/$1"
}

mark_evidence() {
  mkdir -p "$REPO/$1"
  : > "$REPO/$1/.go7-exempt"
}

commit_all() {
  git -C "$REPO" add -A
  run git -C "$REPO" commit -q -m "sujet"
}

@test "without the marker, a headerless doc is REFUSED — the wall still stands" {
  headerless "corpus/verbatim.md"

  commit_all

  [ "$status" -ne 0 ]
  [[ "$output" == *"GO-7 violation"* ]]
}

@test "with the marker, the same doc goes in" {
  headerless "corpus/verbatim.md"
  mark_evidence "corpus"

  commit_all

  [ "$status" -eq 0 ]
}

@test "the marker reaches SUBDIRECTORIES — a corpus is a tree, not a flat folder" {
  headerless "corpus/round-2/sp-capture.md"
  mark_evidence "corpus"

  commit_all

  [ "$status" -eq 0 ]
}

@test "it does NOT leak upward: a sibling outside the marked dir is still refused" {
  headerless "corpus/verbatim.md"
  mark_evidence "corpus"
  headerless "docs/note.md"

  commit_all

  # The blast radius of `--no-verify` is what this replaces. An exemption that quietly covered the
  # whole commit would be the same defect wearing a marker.
  [ "$status" -ne 0 ]
  [[ "$output" == *"docs/note.md"* ]]
  [[ "$output" != *"corpus/verbatim.md"* ]]
}

@test "PASS 1 is exempt too — the piece is not REWRITTEN, only un-refused" {
  # The half a check-only exemption would miss. Pass 1 does `sed -i` on date stamps; a corpus file
  # carrying a stamp-shaped line would have been silently edited, which is the exact falsification
  # the marker exists to prevent. Protecting the file from refusal and not from alteration would
  # have been worse than useless: it would have looked handled.
  mark_evidence "corpus"
  mkdir -p "$REPO/corpus"
  printf '# Piece captee\n\nSTARDATE: 1999.001\n**Dernière révision** : 1999-01-01\n' \
    > "$REPO/corpus/piece.md"
  local before
  before="$(md5sum < "$REPO/corpus/piece.md")"

  commit_all

  [ "$status" -eq 0 ]
  [ "$(md5sum < "$REPO/corpus/piece.md")" = "$before" ]
}

@test "the exemption covers EVERY extension — a captured script is a piece too" {
  mark_evidence "corpus"
  printf '#!/usr/bin/env bash\necho ce que le pod a lance\n' > "$REPO/corpus/run.sh"

  commit_all

  # Without the marker this fails on the SOURCE header rule, not the .md one — same falsification,
  # different branch of the hook.
  [ "$status" -eq 0 ]
}

@test "a source file outside the marked dir keeps its header requirement" {
  mark_evidence "corpus"
  mkdir -p "$REPO/bin"
  printf '#!/usr/bin/env bash\necho hello\n' > "$REPO/bin/tool.sh"

  commit_all

  [ "$status" -ne 0 ]
  [[ "$output" == *"bin/tool.sh"* ]]
}
