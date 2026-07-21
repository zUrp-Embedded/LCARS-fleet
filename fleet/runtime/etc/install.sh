#!/usr/bin/env bash
# SOURCE: etc/install.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: v2 deployment — builds the prod release and puts EVERYTHING under $PREFIX (default
#         /local/LCARS_v2). Self-contained: the runtime runs WITHOUT the repo (bundled priv, embedded
#         ERTS). Idempotent.
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
# Usage: etc/install.sh                        # → /local/LCARS_v2
#        LCARS_INSTALL_PREFIX=/x etc/install.sh
#        LCARS_INSTALL_LINK_DIR=~/bin etc/install.sh
set -euo pipefail

PREFIX="${LCARS_INSTALL_PREFIX:-/local/LCARS_v2}"

SELF="$(readlink -f "$0")"
ETC_DIR="$(dirname "$SELF")"
RUNTIME_DIR="$(dirname "$ETC_DIR")"          # etc/.. = the source runtime root
SRC_BIN="$RUNTIME_DIR/bin"

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

[[ -f "$RUNTIME_DIR/mix.exs" ]] || die "pas la racine du runtime source ($RUNTIME_DIR/mix.exs absent)"
command -v mix >/dev/null 2>&1 || die "mix introuvable (Elixir requis pour construire la release)"

# --- 1. Build the prod release (self-contained, bundled ERTS). The contracts lock runs as a release
#        STEP (mix.exs `verrou_contracts/1`, first in `steps:`), so a red contract fails the build here.
say "build release prod (MIX_ENV=prod mix release --overwrite)…"
(
  cd "$RUNTIME_DIR"
  MIX_ENV=prod mix deps.get >/dev/null
  MIX_ENV=prod mix release --overwrite
) || die "mix release n'a pas abouti (verrou contracts rouge ? warnings ?)"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/fleet_umbrella"
[[ -x "$REL_SRC/bin/fleet_umbrella" ]] || die "release introuvable une fois le build fini ($REL_SRC)"

# --- 2. $PREFIX layout (idempotent) ----------------------------------------------------------------
say "pose sous $PREFIX…"
mkdir -p "$PREFIX/bin" "$PREFIX/etc"

# The release goes under `$PREFIX/rel/fleet_umbrella/` (EXPLICIT destination: `cp -a src dir/` would
# rename if dir did not exist). rm + cp -a = a clean replacement, no leftovers from an earlier version.
rm -rf "$PREFIX/rel"
mkdir -p "$PREFIX/rel"
cp -a "$REL_SRC" "$PREFIX/rel/fleet_umbrella"

# NON-BEAM scripts (outside the release): the human launcher + the CLI + the pod launchers + the MCP
# bridge. The bridge is NOT chmod +x below and does not need to be: it is invoked as `python3 <path>`
# (config/runtime.exs mcp_server_spec) after pod.ex copies it per-pod. It does need to be READABLE by
# the human's BEAM, which is what the group-read in step 3 provides.
for f in fleet_v2 lcars bwrap_launch.sh host_launch.sh claude_launch.sh fleet_mcp_stdio_bridge.py; do
  [[ -e "$SRC_BIN/$f" ]] || die "manquant dans le source bin/: $f"
  cp -a "$SRC_BIN/$f" "$PREFIX/bin/$f"
done
chmod +x "$PREFIX/bin/"*.sh "$PREFIX/bin/fleet_v2" "$PREFIX/bin/lcars" 2>/dev/null || true

# Template d'env humain.
cp -a "$RUNTIME_DIR/etc/fleet_v2.env.template" "$PREFIX/etc/"

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
