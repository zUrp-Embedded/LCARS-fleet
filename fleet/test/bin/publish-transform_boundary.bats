#!/usr/bin/env bats
# SOURCE: fleet/test/bin/publish-transform_boundary.bats
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: bats tests for the BOUNDED rewrite — only what carries internal attribution is rewritten
#
# WHY THE BOUNDARY EXISTS, AND IT IS NOT A MATTER OF TASTE. A full pass keeps 2454 of jquery's 8489
# SHAs and 2165 of git/git's 85342 (measured 2026-08-20): every descendant of a rewritten commit is
# rewritten, and filter-repo touches something early. A branch published that way shares almost
# nothing with the upstream it was forked from, so a fork -> upstream pull request shows tens of
# thousands of commits as new. LCARS could never be used to contribute back.
#
# What must be scrubbed lives ONLY on the commits the fleet made, and those sit at the TIP. Bounding
# the rewrite to them leaves everything below byte-identical — 6852 of 6852 imported commits on the
# real jquery history.
#
# THE PREDICATE IS ONE SOURCE, READ FROM BOTH ENDS: `internal_ident_re` / `internal_msg_re` select
# what gets rewritten AND refuse what survived. A boundary that drifted from the certification would
# select less than the certification refuses — a publish that dies at the last gate instead of one
# that never carried the marker. These witnesses pin that they stay the same two patterns.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-transform.sh"
  source "$SCRIPT"
  SYSTEM_EMAIL="system_starfleet@lcars.local"
  TMP="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

teardown() { rm -rf "$TMP"; }

need_filter_repo() {
  FR="${FILTER_REPO_BIN:-$(command -v git-filter-repo || true)}"
  [ -n "$FR" ] && [ -x "$FR" ] || skip "git-filter-repo absent (FILTER_REPO_BIN pour le nommer)"
}

git_h()   { git -C "$1" -c user.name="Lord Zurp" -c user.email="human@example.com" "${@:2}"; }
git_sys() { git -C "$1" -c user.name="system_starfleet" -c user.email="$SYSTEM_EMAIL" "${@:2}"; }

# An imported FORK: foreign history first (nothing internal about it), then the fleet's own work on
# top — a system-authored scaffold and a producer commit carrying its mandatory role trailer.
fixture_fork() { # <dir> -> prints the import tip
  local d="$1" i
  git init -q -b main "$d"
  for i in 1 2 3; do
    git -C "$d" -c user.name="Upstream Dev" -c user.email="dev@upstream.example" \
      commit -q --allow-empty -m "upstream $i"
  done
  git -C "$d" rev-parse HEAD
  git_sys "$d" commit -q --allow-empty -m "chore(scaffold): squelette"
  git_h "$d" commit -q --allow-empty -m "feat: notre brique

Co-authored-by: LCARS-engineer <engineer@lcars.local>"
}

# ─── the boundary itself, pure git — no filter-repo, so it never skips ─────────────────────────

@test "the boundary is the OLDEST commit carrying internal attribution" {
  tip="$(fixture_fork "$TMP")"
  run oldest_internal_commit "$TMP" "$SYSTEM_EMAIL"
  [ "$status" -eq 0 ]
  # The scaffold: system-authored, NO trailer. It IS ours, and the walk must not stop before it —
  # a rule that only looked for a TRAILER would land the boundary one commit too high and leave the
  # scaffold's internal identity in the published history.
  [ "$(git -C "$TMP" log -1 --format=%s "$output")" = "chore(scaffold): squelette" ]
  # And its parent is the import tip: everything below is foreign and stays untouched.
  [ "$(git -C "$TMP" rev-parse "${output}^")" = "$tip" ]
}

@test "a history with NOTHING internal has no boundary at all" {
  # Already published once, or purely foreign: nothing to scrub, so nothing is rewritten and every
  # sha survives. Reporting a boundary here would rewrite a history for no reason.
  git init -q -b main "$TMP"
  git -C "$TMP" -c user.name="Up" -c user.email="u@upstream.example" \
    commit -q --allow-empty -m "foreign only"
  run oldest_internal_commit "$TMP" "$SYSTEM_EMAIL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fleet-born project: the boundary is the ROOT, so everything is ours" {
  git init -q -b main "$TMP"
  git_sys "$TMP" commit -q --allow-empty -m "Initial commit"
  git_h "$TMP" commit -q --allow-empty -m "feat: x

Co-authored-by: LCARS-engineer <engineer@lcars.local>"
  root="$(git -C "$TMP" rev-list --max-parents=0 HEAD)"
  run oldest_internal_commit "$TMP" "$SYSTEM_EMAIL"
  [ "$output" = "$root" ]
}

@test "an upstream commit merged MID-WORK does not become the boundary" {
  # Pulling upstream while the fleet works inserts foreign commits in the middle. They carry nothing
  # internal, so they must not move the boundary — and they keep their shas anyway, because git is
  # content-addressed and nothing about them changes.
  tip="$(fixture_fork "$TMP")"
  git -C "$TMP" branch up "$tip"
  git -C "$TMP" checkout -q up
  git -C "$TMP" -c user.name="Upstream Dev" -c user.email="dev@upstream.example" \
    commit -q --allow-empty -m "upstream 4"
  git -C "$TMP" checkout -q main
  git_sys "$TMP" merge -q --no-ff up -m "Merge upstream"

  run oldest_internal_commit "$TMP" "$SYSTEM_EMAIL"
  # Still the scaffold — the oldest thing that is ours, not the newest foreign one.
  [ -n "$output" ]
  msg="$(git -C "$TMP" log -1 --format=%s "$output")"
  [ "$msg" = "chore(scaffold): squelette" ]
}

# ─── the two ends read the SAME vocabulary ─────────────────────────────────────────────────────

@test "the predicate that SELECTS is the predicate that REFUSES" {
  # If these ever diverge, the boundary selects less than the certification refuses, and a publish
  # dies at the last gate instead of never having carried the marker. One source, both ends.
  ident="$(internal_ident_re "$SYSTEM_EMAIL")"
  msg="$(internal_msg_re)"
  [[ "$ident" == *"@lcars"* ]]
  [[ "$ident" == *"system_starfleet"* ]]
  [[ "$msg" == *"LCARS-"* ]]

  # And they are what a scrubbed history no longer matches.
  git init -q -b main "$TMP"
  git_h "$TMP" commit -q --allow-empty -m "feat: x

Co-Authored-By: Claude <noreply@anthropic.com>"
  run scan_forbidden_markers "$TMP" "$SYSTEM_EMAIL"
  [ "$status" -eq 0 ]
}

# ─── end to end, with a real filter-repo ───────────────────────────────────────────────────────

@test "BOUNDED: the imported history keeps every sha, only ours are rewritten" {
  need_filter_repo
  forge="$TMP/forge/fleet"; mkdir -p "$forge"
  work="$TMP/work"
  tip="$(fixture_fork "$work")"
  git clone -q --bare "$work" "$forge/proj.git"
  echo tok > "$TMP/tok"

  git -C "$forge/proj.git" rev-list main | sort > "$TMP/before"
  # The three foreign commits, captured BY NAME before anything runs.
  foreign="$(git -C "$work" log --format='%H %s' | awk '$2=="upstream"{print $1}')"
  [ "$(printf '%s\n' "$foreign" | wc -l)" -eq 3 ]

  run "$SCRIPT" --repo fleet/proj --forge "file://$TMP/forge" --token-file "$TMP/tok" \
      --out "$TMP/out" --filter-repo-bin "$FR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BORNEE"* ]]

  git -C "$TMP/out" rev-list main | sort > "$TMP/after"
  [ "$(wc -l < "$TMP/before")" -eq "$(wc -l < "$TMP/after")" ]

  # ⚠ COUNTING THE CHANGED SHAS IS NOT ENOUGH, and the first version of this witness did only that.
  # `comm -23 | wc -l == 2` is equally true of a boundary that rewrote two FOREIGN commits and left
  # ours alone — the wrong two. So each foreign sha is named and checked individually.
  for sha in $foreign; do
    git -C "$TMP/out" cat-file -e "$sha" || {
      echo "le commit importe $sha a ete reecrit — la lignee du fork est perdue" >&2
      return 1
    }
  done
  # The import tip is one of them, and it is the commit the upstream also has.
  git -C "$TMP/out" cat-file -e "$tip"
  # And nothing internal is left in what will be published.
  run scan_forbidden_markers "$TMP/out" "$SYSTEM_EMAIL"
  [ "$status" -eq 0 ]
}

@test "the stale origin refs --partial leaves behind do not fail a clean publish" {
  # `--partial` keeps refs/remotes/origin/* pointing at the PRE-rewrite history, and filter-repo
  # documents it. The certification reads `git log --all`, so it saw internal attribution survive in
  # refs THAT ARE NEVER PUBLISHED and refused a perfectly clean pass — measured: HEAD carried 0
  # markers, `--all` carried 3. The invariant is restored (the remote is dropped) rather than the
  # check narrowed: `--all` must mean "everything this clone could publish".
  need_filter_repo
  forge="$TMP/forge/fleet"; mkdir -p "$forge"
  tip="$(fixture_fork "$TMP/work")"
  git clone -q --bare "$TMP/work" "$forge/proj.git"
  echo tok > "$TMP/tok"

  run "$SCRIPT" --repo fleet/proj --forge "file://$TMP/forge" --token-file "$TMP/tok" \
      --out "$TMP/out" --filter-repo-bin "$FR"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TMP/out" for-each-ref --format='%(refname)' 'refs/remotes/**')" ]
}

@test "BOUNDED + merge mid-work: the foreign commit inside the range keeps its sha" {
  # The boundary test above proves the merge does not MOVE the boundary. This one proves what
  # actually matters afterwards: the foreign commit sits INSIDE the rewritten range, goes through
  # filter-repo, and comes out with the same sha — because git is content-addressed and nothing
  # about it changed. Without this, "it keeps its sha" was reasoning, not measurement.
  need_filter_repo
  forge="$TMP/forge/fleet"; mkdir -p "$forge"
  work="$TMP/work"
  tip="$(fixture_fork "$work")"

  git -C "$work" branch up "$tip"
  git -C "$work" checkout -q up
  git -C "$work" -c user.name="Upstream Dev" -c user.email="dev@upstream.example" \
    commit -q --allow-empty -m "upstream 4"
  mid="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q main
  git_sys "$work" merge -q --no-ff up -m "Merge upstream"
  git_h "$work" commit -q --allow-empty -m "feat: apres le merge

Co-authored-by: LCARS-engineer <engineer@lcars.local>"

  git clone -q --bare "$work" "$forge/proj.git"
  echo tok > "$TMP/tok"

  run "$SCRIPT" --repo fleet/proj --forge "file://$TMP/forge" --token-file "$TMP/tok" \
      --out "$TMP/out" --filter-repo-bin "$FR"
  [ "$status" -eq 0 ]

  # The upstream commit merged in mid-work survives the pass untouched...
  git -C "$TMP/out" cat-file -e "$mid"
  # ...and so does everything the fork inherited.
  git -C "$TMP/out" cat-file -e "$tip"
  run scan_forbidden_markers "$TMP/out" "$SYSTEM_EMAIL"
  [ "$status" -eq 0 ]
}

@test "COUNTER-PROOF: an unbounded rewrite destroys the imported shas" {
  # Without the boundary the fork lineage is gone — which is the whole reason the boundary exists.
  need_filter_repo
  forge="$TMP/forge/fleet"; mkdir -p "$forge"
  tip="$(fixture_fork "$TMP/work")"
  git clone -q --bare "$TMP/work" "$forge/proj.git"

  git clone -q "file://$TMP/forge/fleet/proj.git" "$TMP/full"
  "$FR" --force --source "$TMP/full" --target "$TMP/full" \
    --message-callback 'return message + b"\nX: scrubbed\n"' >/dev/null 2>&1

  # The import tip no longer exists under its own name.
  run git -C "$TMP/full" cat-file -e "$tip"
  [ "$status" -ne 0 ]
}
