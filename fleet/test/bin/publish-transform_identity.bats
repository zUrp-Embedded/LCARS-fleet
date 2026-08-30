#!/usr/bin/env bats
# SOURCE: fleet/test/bin/publish-transform_identity.bats
# AUTHOR: bob
# STARDATE: 2026-08-21
# STATUS: bats tests for the identity substitution — INTERNAL is a domain, on BOTH sides of a commit
#
# WHAT THIS PINS, AND WHY IT WAS FOUND IN PRODUCTION RATHER THAN HERE. The rewrite keyed on ONE
# address (`system_starfleet@lcars.local`) while the certification refuses on the DOMAIN
# `@lcars.local`. The two did not mean the same thing by "internal", and the guard was the one
# telling the truth: measured 2026-08-21 on a real 319-commit project, 3 survivors out of the 8
# commits the fleet had authored, in two shapes the address test cannot see.
#
# The fleet has TEN internal accounts (`system_chief`, `fleet_engineer`, `fleet_scribe`…), all
# authoring as `<login>@lcars.local`. Keying on one of them covers one tenth of the surface, and the
# earlier witnesses could not show it: every fixture in this suite used `system_starfleet` alone —
# the single account the code happened to handle.
#
# ⚠ THE FOUR COMBINATIONS ARE THE TEST. author × committer, internal × external. Three of them touch
# internal attribution and each one is repaired differently; the fourth must come out BYTE-IDENTICAL,
# because rewriting a foreign commit is what makes contributing back impossible.

load ../support/refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-transform.sh"
  TMP="$(mktemp -d)"
  FORGE="$TMP/forge"
  OUT="$TMP/out"
  TOKEN="$TMP/token"
  echo "not-a-real-token" > "$TOKEN"
  mkdir -p "$FORGE/fleet"

  # The vendor identity the co-author trailer is rewritten to — the script requires NAME= and EMAIL=.
  VENDOR="$TMP/vendor.identity"
  printf 'NAME="Claude"\nEMAIL="noreply@anthropic.com"\n' > "$VENDOR"

  # No ambient git identity by default: the declared-identity path is opted INTO per test, so a
  # developer's own `~/.gitconfig` can never decide which branch these witnesses exercise.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

teardown() { rm -rf "$TMP"; }

need_filter_repo() {
  FR="${FILTER_REPO_BIN:-$(command -v git-filter-repo || true)}"
  [ -n "$FR" ] && [ -x "$FR" ] || skip "git-filter-repo absent (FILTER_REPO_BIN pour le nommer)"
}

commit_as() { # <dir> <author-name> <author-email> <committer-name> <committer-email> <msg>
  GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$3" \
    GIT_COMMITTER_NAME="$4" GIT_COMMITTER_EMAIL="$5" \
    git -C "$1" commit -q --allow-empty -m "$6"
}

# THE FOUR SHAPES, in one history. The foreign commit is FIRST so the boundary has something below
# it to preserve — a fixture whose every commit is internal would prove the rewrite works and say
# nothing about what it must leave alone.
fixture() { # -> prints the foreign commit sha
  local w="$TMP/work"
  git init -q -b main "$w"
  commit_as "$w" "Upstream Dev" "dev@upstream.example" "Upstream Dev" "dev@upstream.example" "upstream: rien de nous"
  git -C "$w" rev-parse HEAD

  # 1. author internal, committer human — the ONLY shape the old code handled
  commit_as "$w" "system_starfleet" "system_starfleet@lcars.local" "Lord Zurp" "human@example.com" "chore(scaffold): squelette"
  # 1bis. SAME shape, ANOTHER internal account. Distinct path: the old code matched shape 1 on the
  # address and left this one whole, so a fixture built on `system_starfleet` alone goes green on
  # the broken code and proves nothing.
  commit_as "$w" "system_scribe" "system_scribe@lcars.local" "Lord Zurp" "human@example.com" "docs(scribe): lot

Co-authored-by: system_chief <system_chief@lcars.local>"
  # 2. author internal on ANOTHER account, committer internal too — never matched
  commit_as "$w" "system_chief" "system_chief@lcars.local" "system_chief" "system_chief@lcars.local" "chore(chief): passe"
  # 3. author human, committer internal — the side the callback never looked at
  commit_as "$w" "Lord Zurp" "human@example.com" "system_chief" "system_chief@lcars.local" "feat: brique

Co-authored-by: LCARS-engineer <engineer@lcars.local>"

  git clone -q --bare "$w" "$FORGE/fleet/proj.git"
}

run_transform() {
  run "$SCRIPT" --repo fleet/proj --forge "$FORGE" --token-file "$TOKEN" \
    --out "$OUT" --vendor-identity "$VENDOR" --filter-repo-bin "$FR" "$@"
}

emails_after() { git -C "$OUT" log --all --format='%ae %ce' | tr ' ' '\n' | sort -u; }

# ─── The instrument first ───────────────────────────────────────────────────────────────────────

@test "the fixture really carries the three internal shapes — otherwise everything below passes on nothing" {
  need_filter_repo
  fixture >/dev/null
  local src="$TMP/work"

  # Two DISTINCT internal accounts, and an internal committer under a human author. A fixture with
  # only `system_starfleet` is what let the defect live: it is the one account the old code knew.
  [ "$(git -C "$src" log --format='%ae' | grep -c '@lcars\.local$')" -eq 3 ]
  [ "$(git -C "$src" log --format='%ce' | grep -c '@lcars\.local$')" -eq 2 ]
  [ "$(git -C "$src" log --format='%ae %ce' | grep -c 'system_chief')" -eq 2 ]

  # THREE distinct internal accounts. One alone — whichever the old code happened to handle — is
  # what let the defect live through a whole chantier.
  [ "$(git -C "$src" log --format='%ae%n%ce' | grep '@lcars\.local$' | sort -u | wc -l)" -eq 3 ]

  # A co-author trailer WITHOUT the `LCARS-` prefix: the old pattern anchored on that prefix and
  # would leave this one for the certification to refuse.
  git -C "$src" log --format='%B' | grep -q 'Co-authored-by: system_chief'
}

# ─── The substitution ───────────────────────────────────────────────────────────────────────────

@test "ZERO internal attribution survives — author, committer and trailer alike" {
  need_filter_repo
  fixture >/dev/null
  run_transform
  [ "$status" -eq 0 ]

  # The whole point, asserted on the OBJECTS and not on the script's own certificate: a witness that
  # believed the certificate would pass on any code that prints it.
  refute_internal
}

refute_internal() {
  git -C "$OUT" log --all --format='%ae|%ce|%B' | refute_out -i 'lcars\.local'
}

@test "author internal + committer internal falls back to the DECLARED identity" {
  need_filter_repo
  fixture >/dev/null
  local gc="$TMP/gitconfig"
  printf '[user]\n\tname = Lord Zurp\n\temail = declared@example.com\n' > "$gc"

  GIT_CONFIG_GLOBAL="$gc" run_transform
  [ "$status" -eq 0 ]
  [[ "$output" == *"identite humaine DECLAREE"* ]]

  # That commit had NO human anywhere: the only honest source is the box's declared identity.
  local line
  line="$(git -C "$OUT" log --format='%ae|%ce|%s' | grep 'chore(chief)')"
  [[ "$line" == "declared@example.com|declared@example.com|"* ]]
}

@test "author human + committer internal keeps ITS OWN author, not the repo-wide human" {
  need_filter_repo
  fixture >/dev/null
  local gc="$TMP/gitconfig"
  printf '[user]\n\tname = Someone Else\n\temail = declared@example.com\n' > "$gc"

  GIT_CONFIG_GLOBAL="$gc" run_transform
  [ "$status" -eq 0 ]

  # ⚠ THE ASSERTION THAT SEPARATES FAITHFUL FROM MERELY CLEAN. The same person authored and
  # committed through the system; substituting the declared human here would attribute the commit to
  # somebody who never wrote it — scrubbed, and false.
  local line
  line="$(git -C "$OUT" log --format='%ae|%ce|%s' | grep 'feat: brique')"
  [[ "$line" == "human@example.com|human@example.com|"* ]]
}

@test "the co-author trailer becomes the vendor, whatever role carried it" {
  need_filter_repo
  fixture >/dev/null
  run_transform
  [ "$status" -eq 0 ]

  git -C "$OUT" log --all --format='%B' | grep -qi 'Co-Authored-By: Claude'
  git -C "$OUT" log --all --format='%B' | refute_out -i 'LCARS-engineer'
}

# ─── What must NOT move ─────────────────────────────────────────────────────────────────────────

@test "the foreign commit keeps its SHA — the boundary is what makes contributing back possible" {
  need_filter_repo
  local foreign
  foreign="$(fixture)"
  run_transform
  [ "$status" -eq 0 ]

  git -C "$OUT" cat-file -e "$foreign^{commit}"
  [ "$(git -C "$OUT" log --format='%ae' "$foreign" -n 1)" = "dev@upstream.example" ]
}

# ─── The fallback, and its own guard ────────────────────────────────────────────────────────────

@test "no declared identity: the human is DEDUCED from history, and it is said" {
  need_filter_repo
  fixture >/dev/null
  run_transform
  [ "$status" -eq 0 ]

  # Silence here would be the defect: an identity picked by log ordering must announce that it was
  # picked, not pass for a decision.
  [[ "$output" == *"DEDUITE de l historique"* ]]
  refute_internal
}

@test "a DECLARED identity that is itself internal is refused, not used" {
  need_filter_repo
  fixture >/dev/null
  local gc="$TMP/gitconfig"
  printf '[user]\n\tname = system_chief\n\temail = system_chief@lcars.local\n' > "$gc"

  # A pod, or a box whose global git carries a role account, would otherwise substitute the very
  # thing this pass exists to remove — and the certification would refuse afterwards, blaming the
  # history for a choice the script made.
  GIT_CONFIG_GLOBAL="$gc" run_transform
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDUITE de l historique"* ]]
  refute_internal
}
