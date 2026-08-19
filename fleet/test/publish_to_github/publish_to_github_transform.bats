#!/usr/bin/env bats
# SOURCE: test/publish_to_github/publish_to_github_transform.bats
# AUTHOR: vanille (chantier rails gatekeeper/chief, lot D1)
# STARDATE: 2026-08-18
# STATUS: the TRANSFORM itself, end-to-end — the half publish_to_github.bats never covered.
#
# The sibling file drives scan_forbidden_markers (certification) without filter-repo. These drive
# the WHOLE script against a LOCAL bare fixture (git clone accepts a path: --forge <dir>), with a
# real git-filter-repo when one is available — FILTER_REPO_BIN, or on PATH — and SKIP otherwise:
# the transform's callback (author:=committer, the auto_init root case, the trailer rewrite) had
# ZERO test while being the one piece that rewrites history for publication.
# The linearize tests (lot D2) need NO filter-repo: pure git, driven through the source guard.

SYSTEM_EMAIL="system_starfleet@lcars.local"

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-to-github.sh"
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

# A work-forge shaped fixture: auto_init root (author AND committer = system), an onboard commit
# (author = system, committer = HUMAN — the GitOps shape), a work commit (human + role trailer).
make_fixture() {
  local src="$TMP/src" bare="$TMP/forge/fleet/demo.git"
  mkdir -p "$src"
  git -C "$src" init -q -b main
  printf 'seed' > "$src/README.md"
  git_sys "$src" add -A
  GIT_AUTHOR_NAME=system_starfleet GIT_AUTHOR_EMAIL="$SYSTEM_EMAIL" \
    git_sys "$src" commit -q -m "Initial commit"
  printf '{}' > "$src/.lcars.json"
  git_h "$src" add -A
  GIT_AUTHOR_NAME=system_starfleet GIT_AUTHOR_EMAIL="$SYSTEM_EMAIL" \
    git_h "$src" commit -q -m "chore(onboard): declaration"
  printf 'work' > "$src/f.txt"
  git_h "$src" add -A
  git_h "$src" commit -q -m "$(printf 'feat: work\n\nCo-authored-by: LCARS-engineer <engineer@lcars.local>')"
  mkdir -p "$(dirname "$bare")"
  git clone -q --bare "$src" "$bare"
  printf 'NAME="Claude Opus"\nEMAIL="noreply@anthropic.com"\n' > "$TMP/vendor.identity"
  printf 'not-a-real-token\n' > "$TMP/token"
}

run_transform() {
  run "$SCRIPT" --repo fleet/demo --forge "$TMP/forge" --token-file "$TMP/token" \
    --out "$TMP/out" --vendor-identity "$TMP/vendor.identity" --filter-repo-bin "$FR" "$@"
}

@test "D1: la transformation complete — les 3 reecritures, mesurees sur l'historique produit" {
  need_filter_repo
  make_fixture
  run_transform
  [ "$status" -eq 0 ]

  # root auto_init: author AND committer deviennent l'humain pre-scanne
  root_ids="$(git -C "$TMP/out" log --format='%an|%ae|%cn|%ce' --reverse | head -1)"
  [ "$root_ids" = "Lord Zurp|human@example.com|Lord Zurp|human@example.com" ]

  # commit onboard (author systeme, committer humain): author := committer
  onboard="$(git -C "$TMP/out" log --format='%ae' --grep 'onboard')"
  [ "$onboard" = "human@example.com" ]

  # trailer de role -> vendor, et la certification l'a garanti : zero attribution interne
  msgs="$(git -C "$TMP/out" log --format='%B')"
  [[ "$msgs" == *"Co-Authored-By: Claude Opus <noreply@anthropic.com>"* ]]
  [[ "$msgs" != *"LCARS-engineer"* ]]
  [[ "$msgs" != *"@lcars.local"* ]]
}

@test "D1: historique 100% systeme → exit 2 (l'humain ne peut pas etre derive)" {
  need_filter_repo
  local src="$TMP/src" bare="$TMP/forge/fleet/demo.git"
  mkdir -p "$src"; git -C "$src" init -q -b main
  printf 'seed' > "$src/README.md"; git_sys "$src" add -A
  GIT_AUTHOR_NAME=system_starfleet GIT_AUTHOR_EMAIL="$SYSTEM_EMAIL" git_sys "$src" commit -q -m "Initial commit"
  mkdir -p "$(dirname "$bare")"; git clone -q --bare "$src" "$bare"
  printf 'NAME="V"\nEMAIL="v@e"\n' > "$TMP/vendor.identity"; printf 't\n' > "$TMP/token"
  run_transform
  [ "$status" -eq 2 ]
}

# ─── D2 — linearize_first_parent, pur git (pas de filter-repo, pas de skip) ─────────────────────

make_bubble() { # un main avec une bulle de resolution (la forme que le rail conflit produit)
  local d="$TMP/lin"
  mkdir -p "$d"; git -C "$d" init -q -b main
  printf 'base\n' > "$d/f.txt"; git_h "$d" add -A; git_h "$d" commit -q -m base
  git -C "$d" checkout -q -b feature
  printf 'feat\n' > "$d/f.txt"; git_h "$d" commit -qam feat
  git -C "$d" checkout -q main
  printf 'mainchange\n' > "$d/f.txt"; git_h "$d" commit -qam mainchange
  git -C "$d" merge feature >/dev/null 2>&1 || true
  printf 'resolved\n' > "$d/f.txt"; git_h "$d" add -A
  git_h "$d" commit -q -m "resolve conflict"
  echo "$d"
}

@test "D2: la linearisation aplatit la bulle, arbre final BYTE-IDENTIQUE, zero merge survivant" {
  d="$(make_bubble)"
  before_tree="$(git -C "$d" rev-parse 'main^{tree}')"
  source "$SCRIPT"
  run linearize_first_parent "$d" main
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-parse 'main^{tree}')" = "$before_tree" ]
  [ -z "$(git -C "$d" rev-list --merges main)" ]
  # le point de merge est devenu un commit ORDINAIRE qui porte la resolution
  [ "$(git -C "$d" show main:f.txt)" = "resolved" ]
  # auteurs et messages preserves sur la ligne first-parent
  [[ "$(git -C "$d" log --format='%s' main)" == *"resolve conflict"* ]]
}

@test "D2: une branche inconnue est refusee, rien n'est ecrit" {
  d="$(make_bubble)"
  tip="$(git -C "$d" rev-parse main)"
  source "$SCRIPT"
  run linearize_first_parent "$d" nope
  [ "$status" -ne 0 ]
  [ "$(git -C "$d" rev-parse main)" = "$tip" ]
}

@test "D2: un historique deja lineaire ressort a tip IDENTIQUE en contenu (idempotence de forme)" {
  local d="$TMP/linear"
  mkdir -p "$d"; git -C "$d" init -q -b main
  printf 'a\n' > "$d/f.txt"; git_h "$d" add -A; git_h "$d" commit -q -m a
  printf 'b\n' > "$d/f.txt"; git_h "$d" commit -qam b
  before_tree="$(git -C "$d" rev-parse 'main^{tree}')"
  source "$SCRIPT"
  run linearize_first_parent "$d" main
  [ "$status" -eq 0 ]
  [ "$(git -C "$d" rev-parse 'main^{tree}')" = "$before_tree" ]
  [ "$(git -C "$d" rev-list --count main)" = "2" ]
}
