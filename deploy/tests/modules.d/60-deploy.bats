#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/60-deploy.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for 60-deploy — le raccourci « rien a batir » lit le VRAI arbre du runtime
#
# Relecture hostile 2026-09-04 : `git diff --quiet HEAD -- fleet` rendait toujours 0 (un pathspec
# vide n'est pas une erreur pour git diff), donc « l'arbre du runtime est propre » etait
# inconditionnellement vrai, et un apply sur un checkout modifie sautait la construction.

load ../refute

setup() { MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"; [ -f "$MOD" ]; }

@test "le pathspec du raccourci est runtime/ — un arbre qui n'existe pas rendrait toujours « propre »" {
  grep -vE '^\s*#' "$MOD" | grep -qE 'diff --quiet HEAD -- runtime'
  refute grep -qE 'diff --quiet HEAD -- fleet' <(grep -vE '^\s*#' "$MOD")
  [ -d "$BATS_TEST_DIRNAME/../../../runtime" ]
}

@test "TEMOIN DU TEMOIN : sur ce depot, un pathspec inexistant rend 0 et le vrai rend un verdict" {
  local repo; repo="$BATS_TEST_DIRNAME/../../.."
  git -C "$repo" diff --quiet HEAD -- nexistepas ; [ "$?" -eq 0 ]
  git -C "$repo" ls-files runtime | grep -q .
}

# ─── S4 : LE DOCTOR VOIT CE QUI EST LA EN TROP, ET NOMME LA GENERATION PRECEDENTE ───────────────
#
# ⚠ RELECTURE HOSTILE DU 2026-09-04. La sonde iterait sur les entrees de `release.manifest`, donc
# elle ne regardait jamais ce que `$PROV_PREFIX/bin` porte EN PLUS : au banc, `fleet_v2` (renomme
# `fleet`) et son symlink `/usr/local/bin/fleet_v2` survivaient, et `60-deploy=OK`. Et `.prev`,
# 31 Mo de rollback poses par `atomic_swap_dir`, n'etait nomme nulle part.
#
# Le module se source SANS son dispatch, dans un decor : le prefixe et le PATH sont des
# repertoires de BATS_TEST_TMPDIR, le manifeste est le VRAI (c'est lui qui dit qui est intrus).

decor() {
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/path"
  # Le CANAL est a nous : absent = « aucun », le module pose comme aujourd'hui (voir runtime_helpers.bats).
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  mkdir -p "$PROV_PREFIX/bin" "$PROV_PREFIX/rel/lcars_fleet/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  # tout ce que le manifeste nomme est la : ce qui se mesure ensuite est le SENS INVERSE
  local n
  while read -r n _; do
    [[ -n "$n" && "$n" != \#* ]] || continue
    printf '#!/bin/sh\n' > "$PROV_PREFIX/bin/$n"; chmod +x "$PROV_PREFIX/bin/$n"
  done < "$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest"
  DECOR_MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$MOD" > "$DECOR_MOD"
}
mod() { run bash -c "set -euo pipefail; source '$DECOR_MOD' >/dev/null 2>&1; $1"; }

@test "S4 : un intrus sous \$PROV_PREFIX/bin est un DRIFT, et le symlink du PATH qui le vise aussi" {
  decor
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  mod check
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"*"intrus $PROV_PREFIX/bin/fleet_v2"* ]]
  [[ "$output" == *"DRIFT"*"symlink intrus $PROV_LINK_DIR/fleet_v2"* ]]
}

@test "S4 : sans intrus, pas de ligne intrus — et un lien du PATH qui vise ailleurs n'est pas a nous" {
  decor
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  mod check
  refute grep -q 'intrus' <<<"$output"
}

@test "S4 : la generation precedente (.prev) est NOMMEE, avec sa taille" {
  decor
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet.prev/bin"
  head -c 4096 /dev/zero > "$PROV_PREFIX/rel/lcars_fleet.prev/bin/lcars_fleet"
  mod check
  [[ "$output" == *"génération précédente gardée : $PROV_PREFIX/rel/lcars_fleet.prev ("* ]]
  [[ "$output" == *"rm -rf $PROV_PREFIX/rel/lcars_fleet.prev"* ]]
}

@test "S4 : l'apply retire les intrus des deux cotes, une ligne par retrait, et rien d'autre" {
  decor
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet" "$PROV_LINK_DIR/fleet"
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  mod 'prune_intrus; echo "rc=$?"'
  [[ "$output" == *"retiré $PROV_PREFIX/bin/fleet_v2"* ]]
  [[ "$output" == *"retiré symlink $PROV_LINK_DIR/fleet_v2"* ]]
  [[ "$output" == *"rc=0"* ]]
  [ ! -e "$PROV_PREFIX/bin/fleet_v2" ]
  [ ! -L "$PROV_LINK_DIR/fleet_v2" ]
  [ -e "$PROV_PREFIX/bin/fleet" ]
  [ -L "$PROV_LINK_DIR/fleet" ]
  [ -L "$PROV_LINK_DIR/quelconque" ]
}

@test "RELEASE A DEUX LIBS : le build annonce est celui qui DEMARRE, et la lib morte est un DRIFT nomme" {
  decor
  local rel="$PROV_PREFIX/rel/lcars_fleet"
  mkdir -p "$rel/lib/lcars_fleet-0.1.0/priv/api" "$rel/lib/lcars_fleet-0.9.0/priv/api" "$rel/releases"
  printf 'sha=9ee4a4bcd\n' > "$rel/lib/lcars_fleet-0.1.0/priv/api/build_info.txt"
  printf 'sha=d4d23d792\n' > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
  printf '15.2.7.4 0.9.0\n' > "$rel/releases/start_erl.data"
  mod 'build_sha; release_libs_count'
  [ "$status" -eq 0 ]
  [[ "$output" == *"d4d23d792"* ]]
  refute_out '9ee4a4bcd' <<<"$output"
  [[ "$output" == *"2"* ]]
  mod check
  [[ "$output" == *"DRIFT"*"porte 2 lib/lcars_fleet-*"*"lcars_fleet-0.9.0"* ]]
}

# ─── LE CANAL : SOUS `deb` CE MODULE NE POSE RIEN, ET SOUS `source`/`kit` IL ECRIT QUI A POSE ───
#
# Lot 2 du chantier release (2026-09-05). Le decor possede sa RACINE : la lib est COPIEE (c'est
# elle qui donne `repo_root()`), `deploy-release.sh` est une DOUBLURE qui laisse un marqueur si on
# l'appelle, `runtime/etc` est lie au depot (le manifeste de release est le vrai), et le canal comme
# `dpkg` sont a nous. Un temoin qui lirait le canal ou le dpkg de la machine mesurerait la machine.

decor_canal() { # decor_canal <source|kit|deb|snap|aucun>
  decor
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy" "$RACINE/runtime"
  cp -a "$BATS_TEST_DIRNAME/../../lib" "$RACINE/deploy/lib"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/etc" "$RACINE/runtime/etc"
  MARQUEUR="$BATS_TEST_TMPDIR/POSE-APPELEE"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$MARQUEUR" > "$RACINE/deploy/lib/deploy-release.sh"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"; mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"
  export LCARS_CHANNEL_OWNER; LCARS_CHANNEL_OWNER="$(id -un):$(id -gn)"
  case "$1" in aucun) rm -f "$LCARS_CHANNEL_FILE" ;; *) printf '%s\n' "$1" > "$LCARS_CHANNEL_FILE" ;; esac
}
dpkg_double() { # dpkg_double <lignes de dpkg -V…> — un `dpkg` du PATH qui dit le paquet installe et rend ces lignes
  local d="$BATS_TEST_TMPDIR/dpkgbin"; mkdir -p "$d"
  { echo '#!/usr/bin/env bash'
    echo 'case "$1" in -s) echo "Status: install ok installed"; exit 0 ;; -V) : ;; *) exit 2 ;; esac'
    local l; for l in "$@"; do printf "printf '%%s\\\\n' '%s'\n" "$l"; done
    echo 'exit 0'
  } > "$d/dpkg"; chmod 0755 "$d/dpkg"
  export PATH="$d:$PATH"
}
empreinte() { find "$PROV_PREFIX" "$PROV_LINK_DIR" -printf '%p %m %s %y\n' | sort; }
module() { run bash "$MOD" "$1"; }   # le dispatch ENTIER : c'est lui qui lit le canal

@test "CANAL source/kit : le canal s'ecrit APRES la pose, et il dit KIT quand la release venait d'un paquet" {
  decor_canal aucun
  DECOR_MOD="$BATS_TEST_TMPDIR/mod.sh"; sed '/^case "${1:?usage/,$d' "$MOD" > "$DECOR_MOD"
  mod 'poser_canal'
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "source" ]
  printf 'cafe1234\n' > "$RACINE/.source-revision"    # LE discriminant de prov_delivery, pas un second
  mod 'poser_canal'
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "kit" ]
  # ⚠ L'ORDRE, dans apply() : le canal vient APRES la pose ET apres le re-verrouillage — un canal
  # ecrit avant une pose ratee dirait « kit » d'une machine qui n'a rien.
  local corps; corps="$(sed -n '/^apply()/,/^}/p' "$MOD" | grep -vE '^\s*#')"
  local n_pose n_verrou n_canal
  n_pose="$(grep -n 'deploy-release.sh' <<<"$corps" | tail -1 | cut -d: -f1)"
  n_verrou="$(grep -n 'chmod -R u=rwX' <<<"$corps" | tail -1 | cut -d: -f1)"
  n_canal="$(grep -n 'poser_canal' <<<"$corps" | tail -1 | cut -d: -f1)"
  [ -n "$n_pose" ]
  [ -n "$n_verrou" ]
  [ -n "$n_canal" ]
  [ "$n_pose" -lt "$n_verrou" ]
  [ "$n_verrou" -lt "$n_canal" ]
  # et sur les DEUX autres sorties ou la release est deja en place (rejeu depuis la copie, raccourci)
  [ "$(grep -c 'poser_canal || verdict_apply' <<<"$corps")" -eq 3 ]
  # le seul ecrivain est poser_canal : aucun prov_channel_write nu dans apply
  refute grep -q 'prov_channel_write' <<<"$corps"
}
