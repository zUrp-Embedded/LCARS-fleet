#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/claude_bin_seed.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for 40-claude-bin — the seed short-circuits the network
#
# WHY THIS EXISTS. A fresh box with no network gets no `claude` binary, so `Credentials.Gate`
# refuses at the spawn-boundary and NO pod starts: the fleet looks healthy and produces nothing.
# `$PROV_CLAUDE_SEED` lets an outside gesture (a bench seeding, a preloaded image) put a binary on
# the machine; the module must PREFER it over the official installer. What is proven here is the
# short-circuit itself — "a real box boots offline" is integration and needs a box.
#
# ONE THING IS FAKED, deliberately: `human_home`, pointed at a sandbox. `as_human` stays the REAL
# one (it runs the command directly when PROV_HUMAN is the current user). Without that override the
# module would install into the tester's OWN ~/.local/bin/claude and overwrite their tool — a test
# that damages the machine it runs on is not a test.
#
# The `curl` stub is the network detector: if it is ever called, the module went to the network and
# the whole point was missed. It records the call and fails loudly rather than silently succeeding.

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  SANDBOX="$BATS_TEST_TMPDIR/box"
  HOMEDIR="$SANDBOX/home"
  BINDIR="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$SANDBOX/lib" "$HOMEDIR/.local/bin" "$BINDIR"

  # The real lib, plus the single override. Appended rather than edited: what the module calls is
  # the shipped code, and the diff between it and what runs here is these three lines.
  cp "$SRC/lib/provision-lib.sh" "$SANDBOX/lib/provision-lib.sh"
  cat >> "$SANDBOX/lib/provision-lib.sh" <<EOF

human_home() { echo "$HOMEDIR"; }
EOF

  CURL_LOG="$BATS_TEST_TMPDIR/curl.calls"
  : > "$CURL_LOG"

  export PROVISION_LIB="$SANDBOX/lib/provision-lib.sh"
  export PROV_HUMAN="$(id -un)"
  export PROV_CLAUDE_SEED="$SANDBOX/claude-seed"
  export PATH="$BINDIR:$PATH"
}

# A binary is a thing that answers --version. The fake is a script, which `cp -a`, `chmod` and the
# functional probe all treat exactly like the real static ELF.
fake_claude() {
  local path="$1" version="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "--version" ]] && echo "$version" && exit 0
exit 3
EOF
  chmod 0755 "$path"
}

# `curl` is the network. The stub logs the call so a test can assert it never happened, and still
# behaves like the installer download so the fallback path stays exercisable.
stub_curl() {
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CURL_LOG"
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$out" ]] || exit 0
# The vendor installer, reduced to its contract: it puts .local/bin/claude in \$HOME.
cat > "\$out" <<'INNER'
#!/usr/bin/env bash
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\n[[ "\$1" == "--version" ]] && echo "from-installer" && exit 0\nexit 3\n' \
  > "\$HOME/.local/bin/claude"
chmod 0755 "\$HOME/.local/bin/claude"
INNER
exit 0
EOF
  chmod 0755 "$BINDIR/curl"
}

run_apply() {
  run bash "$SRC/modules.d/40-claude-bin.sh" apply
}

@test "a live seed is used and the network is NEVER touched" {
  fake_claude "$PROV_CLAUDE_SEED" "from-seed"
  stub_curl

  run_apply

  [ "$status" -eq 0 ]
  [ "$("$HOMEDIR/.local/bin/claude" --version)" = "from-seed" ]
  # The whole point. A seeded box that still downloads has gained nothing offline.
  [ ! -s "$CURL_LOG" ]
  [[ "$output" == *"aucun réseau"* ]]
}

@test "a seed that does NOT answer --version is refused, and the installer takes over" {
  # An executable file is not a binary. Existence is the check that would have let a truncated
  # docker cp — zero bytes, exit 0 on the amputated relay — pass for a working tool.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$PROV_CLAUDE_SEED"
  chmod 0755 "$PROV_CLAUDE_SEED"
  stub_curl

  run_apply

  [ "$status" -eq 0 ]
  [ "$("$HOMEDIR/.local/bin/claude" --version)" = "from-installer" ]
  [ -s "$CURL_LOG" ]
}

@test "no seed at all → the installer path, exactly as before" {
  stub_curl

  run_apply

  [ "$status" -eq 0 ]
  [ "$("$HOMEDIR/.local/bin/claude" --version)" = "from-installer" ]
  [ -s "$CURL_LOG" ]
}

@test "the seed install leaves no half-written binary behind" {
  fake_claude "$PROV_CLAUDE_SEED" "from-seed"
  stub_curl

  run_apply

  # `install_bin` copies to a tmp IN THE SAME DIRECTORY then `mv`s — atomic only within one
  # filesystem, and a 100 MB half-written file named `claude` is indistinguishable from a good one.
  run bash -c "ls $HOMEDIR/.local/bin/.claude.new.* 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "an already-good binary short-circuits everything — no seed read, no network" {
  fake_claude "$HOMEDIR/.local/bin/claude" "already-there"
  fake_claude "$PROV_CLAUDE_SEED" "from-seed"
  stub_curl

  run_apply

  # The vendor auto-update is the vendor's rail, not ours: a module that reinstalls on every boot
  # would fight it.
  [ "$status" -eq 0 ]
  [ "$("$HOMEDIR/.local/bin/claude" --version)" = "already-there" ]
  [ ! -s "$CURL_LOG" ]
}
