#!/usr/bin/env bash
# SOURCE: etc/install.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: v2 deployment — builds the prod release and puts EVERYTHING under $PREFIX (default
#         /local/LCARS_v2). Self-contained: the runtime runs WITHOUT the repo (bundled priv, embedded
#         ERTS). Idempotent, and CRASH-SAFE: a build or copy failure never destroys the live install.
#
# Three-zone model: SOURCE (this repo, build only) → INSTALL ($PREFIX, RO, system-owned) → STATE
# (~/.lcars, per-human, RW). `v2` means cohabiting with the v1 runtime (/local/LCARS); eventually
# PREFIX=/local/lcars, which is one `mv` plus a symlink repoint, with no edit.
#
# TWO env knobs, not one — the header used to claim PREFIX was the only parameter, and it is not:
#   LCARS_INSTALL_PREFIX    where everything is installed (default /local/LCARS_v2)
#   LCARS_INSTALL_LINK_DIR  where the PATH symlinks go (default /usr/local/bin)
# And several things ARE hardcoded, deliberately: the `fleet` group, the `fleet_umbrella` release name
# (kept at the app collapse, cf. mix.exs), the two symlink names, and the list of non-BEAM scripts
# copied into bin/.
#
# ATOMICITY: the old flow did `rm -rf $PREFIX/rel` then a multi-second `cp -a`, and overwrote each
# launcher in place. An error mid-copy lost the last good build; a reader mid-copy saw a mixed
# assembly. Now every replacement stages a sibling on the SAME filesystem, verifies it, then `mv`s it
# into place (an atomic rename at the directory-entry level) — keeping the previous generation as
# `<name>.prev` for rollback. The live target is never a half-copied tree.
#
# Usage: etc/install.sh                        # → /local/LCARS_v2
#        LCARS_INSTALL_PREFIX=/x etc/install.sh
#        LCARS_INSTALL_LINK_DIR=~/bin etc/install.sh
set -euo pipefail

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

# Atomic directory replace: stage `src` into a sibling of `dst` (same FS → rename is atomic), verify
# it holds `probe` (a relative path that must exist + be executable), then swap — moving any live `dst`
# aside to `dst.prev` first (rollback kept). A reader sees the OLD tree or the NEW tree under `dst`,
# never a partial one; a verify failure leaves the live install untouched.
atomic_swap_dir() {
  local src="$1" dst="$2" probe="$3"
  local stage="${dst}.staging.$$" prev="${dst}.prev"

  rm -rf "$stage"
  cp -a "$src" "$stage" || { rm -rf "$stage"; die "copie du build vers le staging echouee ($stage)"; }

  [[ -x "$stage/$probe" ]] || { rm -rf "$stage"; die "build stage invalide : $probe absent ou non-executable"; }

  # Two renames, ordered so `dst` is never a partial tree: move the old aside, move the new in. The
  # sliver between them is a clean absence (ENOENT), not a mixed assembly. rm the prior .prev first so
  # the rollback slot always holds exactly the generation we just replaced.
  rm -rf "$prev"
  [[ -e "$dst" ]] && mv "$dst" "$prev"
  mv "$stage" "$dst"
}

# Atomic file replace: copy to a sibling temp, then rename over `dst` (a single atomic rename — a reader
# sees the old file or the new file, never a truncated copy). No .prev for the small scripts (the
# release dir is the one worth a rollback slot).
atomic_swap_file() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$"

  cp -a "$src" "$tmp" || { rm -f "$tmp"; die "copie de $(basename "$dst") vers le staging echouee"; }
  mv "$tmp" "$dst"
}

# Builds the prod release, TIED to the full gate on the SAME source tree. `mix release` only replays
# the contracts lock (mix.exs step) — the SHA in build-info identifies the artifact, it does not
# QUALIFY it (compile-strict / ExUnit / bats / topology / Dialyzer are not re-run at build). So this
# runs `mix gate` FIRST, a direct gate→build continuation: the bits installed are the bits the gate
# passed. LCARS_INSTALL_SKIP_GATE=1 is an explicit escape (an operator who just ran the gate) — it
# must be a stated choice, never the default. Runs in `runtime_dir`; dies on a red gate or build.
build_release() {
  local runtime_dir="$1"

  # `set -e` explicit in the subshell: bats' `run` disables errexit in the caller and a subshell
  # inherits that, so each critical command is ALSO guarded with `|| exit` — a red gate must stop the
  # build regardless of the caller's errexit state.
  (
    set -e
    cd "$runtime_dir"
    MIX_ENV=prod mix deps.get >/dev/null || exit 1

    if [[ "${LCARS_INSTALL_SKIP_GATE:-0}" == "1" ]]; then
      echo "install: ATTENTION — gate saute (LCARS_INSTALL_SKIP_GATE=1) : la release n'est PAS attestee par le gate de ce commit" >&2
    else
      echo "install: gate complet sur l'arbre source (compile-strict + tests + bats + topologie + dialyzer)…" >&2
      MIX_ENV=test mix gate || exit 1
    fi

    MIX_ENV=prod mix release --overwrite || exit 1
  )
}

# ROOT IS REFUSED, and the reason is not caution -- it is that this script RUNS THE GATE, and the
# gate is not valid under root. Measured on a real run: `rm_terminal_artifacts` asserts `:eacces` on
# a chmod-000 directory, root bypasses permissions, `rm_rf` succeeds and the test reports a FAILURE
# that is an artifact of the runner, not of the code. A gate whose verdict depends on who invoked it
# attests nothing. Sudo also leaves the build tree littered with root-owned ExUnit artifacts (13167
# files under tmp/ on that run) which then break the next ordinary `mix compile` on File.touch!.
#
# The privileged half is the FILE PLACEMENT, not the build. Run this as the account that owns the
# install (or grant it write on the prefix); elevate only the copy, as etc/README.md's manual
# procedure does. Elevating the whole script is what conflates the two.
refuse_root() {
  local uid="${1:-${EUID:-$(id -u)}}"
  [[ "$uid" -ne 0 ]] || die "lance en root — le gate n'est pas valide sous root (il outrepasse les permissions que des tests verifient) et le build laisserait des artefacts root dans l'arbre source. Lance-le sous le compte proprietaire de l'install ; seule la POSE demande des droits (cf. etc/README.md)"
}

# Fail on the prefix BEFORE spending several minutes on a gate + release. The old flow discovered the
# permission at the copy, i.e. after the expensive part, and died with a staging error that named the
# symptom rather than the cause.
require_prefix_writable() {
  local prefix="$1" probe="$1"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || die "prefix non inscriptible : $probe (destination $prefix). Lance-le sous le compte proprietaire, ou donne-toi le droit d'ecriture — ne relance PAS en sudo, cf. refuse_root"
}

# Source guard (standard idiom): sourcing loads the functions WITHOUT running the deploy — the bats
# suite drives atomic_swap_dir / atomic_swap_file directly, without a mix build.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

PREFIX="${LCARS_INSTALL_PREFIX:-/local/LCARS_v2}"

SELF="$(readlink -f "$0")"
ETC_DIR="$(dirname "$SELF")"
RUNTIME_DIR="$(dirname "$ETC_DIR")"          # etc/.. = the source runtime root
SRC_BIN="$RUNTIME_DIR/bin"

[[ -f "$RUNTIME_DIR/mix.exs" ]] || die "pas la racine du runtime source ($RUNTIME_DIR/mix.exs absent)"
command -v mix >/dev/null 2>&1 || die "mix introuvable (Elixir requis pour construire la release)"

# Both guards BEFORE the build: a refusal must cost a second, not a full gate.
refuse_root
require_prefix_writable "$PREFIX"

# --- 1. Build the prod release (self-contained, bundled ERTS), TIED to the full gate on the same
#        source tree (build_release: gate → release). A red gate or a failed build dies here.
say "build release prod (gate complet puis MIX_ENV=prod mix release)…"
build_release "$RUNTIME_DIR" || die "gate rouge ou build KO — la release n'est PAS posee (arbre source non atteste)"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/fleet_umbrella"
[[ -x "$REL_SRC/bin/fleet_umbrella" ]] || die "release introuvable une fois le build fini ($REL_SRC)"

# --- 2. $PREFIX layout (idempotent) ----------------------------------------------------------------
say "pose sous $PREFIX…"
mkdir -p "$PREFIX/bin" "$PREFIX/etc" "$PREFIX/rel"

# The release lands under `$PREFIX/rel/fleet_umbrella/` via a staged, verified, atomic swap — the live
# tree is never destroyed before the new one is proven good, and the previous stays as `.prev`.
atomic_swap_dir "$REL_SRC" "$PREFIX/rel/fleet_umbrella" "bin/fleet_umbrella"

# NON-BEAM scripts (outside the release): the human launcher + the CLI + the pod launchers + the MCP
# bridge. The bridge is NOT chmod +x below and does not need to be: it is invoked as `python3 <path>`
# (config/runtime.exs mcp_server_spec) after pod.ex copies it per-pod. It does need to be READABLE by
# the human's BEAM, which is what the group-read in step 3 provides. Each is swapped atomically so a
# reader never catches a half-written launcher.
for f in fleet_v2 lcars bwrap_launch.sh host_launch.sh claude_launch.sh fleet_mcp_stdio_bridge.py; do
  [[ -e "$SRC_BIN/$f" ]] || die "manquant dans le source bin/: $f"
  atomic_swap_file "$SRC_BIN/$f" "$PREFIX/bin/$f"
done
chmod +x "$PREFIX/bin/"*.sh "$PREFIX/bin/fleet_v2" "$PREFIX/bin/lcars" 2>/dev/null || true

# Template d'env humain (swap atomique aussi — un lecteur ne voit jamais un template tronque).
atomic_swap_file "$RUNTIME_DIR/etc/fleet_v2.env.template" "$PREFIX/etc/fleet_v2.env.template"

# --- 3. Perms: RO for humans (group fleet r-x), owner = the installer (system) ----------------------
# The BEAM writes its tmp/state into ~/.lcars (RELEASE_TMP, set by fleet_v2), so the install stays RO.
#
# The mode is ADDITIVE + subtractive, and the additive half matters: `g-w,o-rwx` alone only REMOVES
# group-write and other-access. It never GRANTS group read or traverse — those were inherited from
# whatever the source tree happened to carry, so the announced "group fleet r-x" was true by accident of
# the repo's umask rather than by anything this script did. `g+rX` establishes it (capital X = execute
# on directories and on files that already carry an execute bit, so it does not make data executable).
# This is the same policy the manual procedure in etc/README.md applies with `chmod g+rx`.
#
# The message is only printed when the chmod ACTUALLY applied: a `|| true` used to hide a failed chmod
# behind a success line — an access policy announced but not applied.
if chgrp -R fleet "$PREFIX" 2>/dev/null; then
  if chmod -R g+rX,g-w,o-rwx "$PREFIX" 2>/dev/null; then
    say "perms : group fleet r-x, others none (RO humains)"
  else
    say "chmod perms KO — la politique RO (group r-x, others none) n'est PAS en place ; le deploy doit la poser"
  fi
else
  say "chgrp fleet KO (droits ?) — le deploy doit le poser"
fi

# --- 4. PATH symlinks (launch from anywhere) — POINTERS, not copies --------------------------------
LINK_DIR="${LCARS_INSTALL_LINK_DIR:-/usr/local/bin}"
if ln -sf "$PREFIX/bin/fleet_v2" "$LINK_DIR/fleet_v2" 2>/dev/null \
   && ln -sf "$PREFIX/bin/lcars" "$LINK_DIR/lcars" 2>/dev/null; then
  say "symlinks $LINK_DIR/{fleet_v2,lcars} → $PREFIX/bin/"
else
  say "symlinks $LINK_DIR KO (droits ?). Manuel : sudo ln -sf $PREFIX/bin/{fleet_v2,lcars} $LINK_DIR/"
fi

say "OK — install en place sous $PREFIX (release : $(cat "$PREFIX/rel/fleet_umbrella/releases/start_erl.data" 2>/dev/null || echo '?'))."
say "Lancer : fleet_v2 start   (tout le per-humain vit en ~/.lcars/* ; le repo n'est PAS requis au runtime)."
