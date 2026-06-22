#!/usr/bin/env bash
# SOURCE: etc/install.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: déploiement v2 — bâtit la release prod + pose TOUT sous $PREFIX (défaut /local/LCARS_v2).
#         Étanche : le runtime tourne SANS le repo (priv bundlé, ERTS embarqué). Idempotent.
#
# Modèle 3 zones : SOURCE (ce repo, build-only) → INSTALL ($PREFIX, RO owner système) → STATE (~/.lcars
# per-humain, RW). `v2` = cohabitation avec le runtime v1 (/local/LCARS) ; à terme PREFIX=/local/lcars
# (un seul `mv` + repointage symlink, zéro édit). Le PREFIX est le SEUL paramètre — rien n'est hardcodé.
#
# Usage : etc/install.sh                       # → /local/LCARS_v2
#         LCARS_INSTALL_PREFIX=/x etc/install.sh
set -euo pipefail

PREFIX="${LCARS_INSTALL_PREFIX:-/local/LCARS_v2}"

SELF="$(readlink -f "$0")"
ETC_DIR="$(dirname "$SELF")"
RUNTIME_DIR="$(dirname "$ETC_DIR")"          # etc/.. = l'umbrella source
SRC_BIN="$RUNTIME_DIR/bin"

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

[[ -f "$RUNTIME_DIR/mix.exs" ]] || die "pas l'umbrella source ($RUNTIME_DIR/mix.exs absent)"
command -v mix >/dev/null 2>&1 || die "mix introuvable (Elixir requis pour bâtir la release)"

# --- 1. Build la release prod (self-contained, ERTS bundlé ; verrou contracts R7 = gate) ------------
say "build release prod (MIX_ENV=prod mix release --overwrite)…"
(
  cd "$RUNTIME_DIR"
  MIX_ENV=prod mix deps.get >/dev/null
  MIX_ENV=prod mix release --overwrite
) || die "mix release a échoué (verrou contracts rouge ? warnings ?)"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/fleet_umbrella"
[[ -x "$REL_SRC/bin/fleet_umbrella" ]] || die "release introuvable après build ($REL_SRC)"

# --- 2. Layout $PREFIX (idempotent) ----------------------------------------------------------------
say "pose sous $PREFIX…"
mkdir -p "$PREFIX/bin" "$PREFIX/etc"

# La release sous `$PREFIX/rel/fleet_umbrella/` (dest EXPLICITE : `cp -a src dir/` renommerait si dir
# absent). rm + cp -a = remplacement propre, pas de reliquat d'une version antérieure.
rm -rf "$PREFIX/rel"
mkdir -p "$PREFIX/rel"
cp -a "$REL_SRC" "$PREFIX/rel/fleet_umbrella"

# Scripts NON-BEAM (hors release) : le launcher humain + le CLI + les launchers pod + le bridge MCP.
for f in fleet_v2 lcars bwrap_launch.sh host_launch.sh claude_launch.sh fleet_mcp_stdio_bridge.py; do
  [[ -e "$SRC_BIN/$f" ]] || die "manquant dans le source bin/: $f"
  cp -a "$SRC_BIN/$f" "$PREFIX/bin/$f"
done
chmod +x "$PREFIX/bin/"*.sh "$PREFIX/bin/fleet_v2" "$PREFIX/bin/lcars" 2>/dev/null || true

# Template d'env humain.
cp -a "$RUNTIME_DIR/etc/fleet_v2.env.template" "$PREFIX/etc/"

# --- 3. Perms : RO pour les humains (group fleet r-x), owner = installeur (système) -----------------
# Le BEAM écrit son tmp/état dans ~/.lcars (RELEASE_TMP, posé par fleet_v2) → l'install reste RO.
if chgrp -R fleet "$PREFIX" 2>/dev/null; then
  chmod -R g-w,o-rwx "$PREFIX" 2>/dev/null || true
  say "perms : group fleet r-x, others none (RO humains)"
else
  say "chgrp fleet sauté (droits ?) — à régler au deploy système"
fi

# --- 4. Symlinks PATH (lancer de n'importe où) — POINTEURS, pas copies -----------------------------
LINK_DIR="${LCARS_INSTALL_LINK_DIR:-/usr/local/bin}"
if ln -sf "$PREFIX/bin/fleet_v2" "$LINK_DIR/fleet_v2" 2>/dev/null \
   && ln -sf "$PREFIX/bin/lcars" "$LINK_DIR/lcars" 2>/dev/null; then
  say "symlinks $LINK_DIR/{fleet_v2,lcars} → $PREFIX/bin/"
else
  say "symlinks $LINK_DIR sautés (droits ?). Manuel : sudo ln -sf $PREFIX/bin/{fleet_v2,lcars} $LINK_DIR/"
fi

say "OK — installé sous $PREFIX (release : $(cat "$PREFIX/rel/fleet_umbrella/releases/start_erl.data" 2>/dev/null || echo '?'))."
say "Lancer : fleet_v2 start   (état per-humain en ~/.lcars/* ; le repo n'est PAS requis au runtime)."
