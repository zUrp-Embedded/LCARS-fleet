#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/deploy_manifest.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for 60-deploy check — manifest-driven, source-independent

# shellcheck disable=SC2016

# shellcheck disable=SC1003,SC2020

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../.."
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/deploy/lib" "$ROOT/runtime/etc"
  cp "$SRC"/lib/*.sh "$ROOT/deploy/lib/"
  cp "$SRC/installer-constants.env" "$SRC/system.manifest" "$ROOT/deploy/"
  cp "$SRC/modules.d/60-deploy.sh" "$BATS_TEST_TMPDIR/60-deploy.sh"

  cat > "$ROOT/runtime/etc/release.manifest" <<'EOF'
# test manifest
fleet         exec   link
bwrap_launch.sh  exec
bridge.py        noexec
EOF

  decor_pose
  PREFIX="$LCARS_DECOR_ROOT/opt/lcars/runtime"
  LINKS="$LCARS_DECOR_ROOT/usr/local/bin"
  export PROVISION_LIB="$ROOT/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy

  # a "deployed" prefix: release marker + every manifest entry posed correctly
  mkdir -p "$PREFIX/rel/lcars_fleet/bin" "$PREFIX/bin" "$LINKS"
  printf '#!/bin/sh\n' > "$PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  printf 'x\n' > "$PREFIX/bin/fleet";        chmod +x "$PREFIX/bin/fleet"
  printf 'x\n' > "$PREFIX/bin/bwrap_launch.sh"; chmod +x "$PREFIX/bin/bwrap_launch.sh"
  printf 'x\n' > "$PREFIX/bin/bridge.py"
  ln -s "$PREFIX/bin/fleet" "$LINKS/fleet"
}

run_check() { run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check; }

@test "manifest-driven check: fully posed prefix has zero bin/link drift" {
  run_check
  [[ "$output" == *"bin/fleet"* ]]
  [[ "$output" == *"bin/bridge.py"* ]]
  [[ "$output" == *"symlink $LINKS/fleet"* ]]
  [[ "$output" != *"DRIFT 60-deploy: bin/"* ]]
  [[ "$output" != *"symlink vers"* ]]
}

@test "manifest-driven check: a missing exec entry drifts by name" {
  rm "$PREFIX/bin/bwrap_launch.sh"
  run_check
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"bin/bwrap_launch.sh absent"* ]]
}

@test "manifest-driven check: a noexec entry only needs to be readable" {
  chmod -x "$PREFIX/bin/bridge.py"
  run_check
  [[ "$output" != *"bridge.py absent"* ]]
}

@test "manifest-driven check: a wrong link target drifts" {
  ln -sfn /somewhere/else "$LINKS/fleet"
  run_check
  [[ "$output" == *"$LINKS/fleet ≠ symlink vers"* ]]
}

@test "source-independence: check runs WITHOUT mix.exs (only etc/ ships in the image)" {
  # setup() never created mix.exs — a green-path check proves no source-tree dependency
  run_check
  [[ "$output" != *"introuvable"* ]]
}

@test "missing manifest is a probe ERROR (rc 2), not a silent pass" {
  rm "$BATS_TEST_TMPDIR/repo/runtime/etc/release.manifest"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest introuvable"* ]]
}


@test "le rail natif n'installe pas d'outillage de gate — l'install ne re-atteste pas la source" {
  MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"
  [ -f "$MOD" ]
  local code; code="$(grep -vE '^\s*#' "$MOD")"
  refute grep -q 'GATE_PACKAGES' <<<"$code"
  refute grep -qE 'shellcheck|ruff' <<<"$code"
  grep -vE '^\s*#' "$BATS_TEST_DIRNAME/../../lib/deploy-release.sh" | refute_out 'mix gate|MIX_ENV="?test'
  # et `procps`, qui vivait dans cette liste pour le gate, est un besoin RUNTIME : il a rejoint 10-packages
  PKG="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"
  [[ " $(native_list 'PACKAGES' "$PKG") " == *" procps "* ]]
}


native_list() { # native_list <NOM_DU_TABLEAU> <fichier> — le contenu, commentaires retires
  awk -v n="$1" '
    !inside && $0 ~ "^[[:space:]]*" n "=\\(" { inside = 1; sub("^[[:space:]]*" n "=\\(", "") }
    inside {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /\)[[:space:]]*$/) { sub(/\)[[:space:]]*$/, "", line); print line; exit }
      print line
    }
  ' "$2" | tr '\n' ' '
}

@test "l'image ne pose par apt qu'un SOCLE — chaque paquet est sur le rail (10-packages), ou image-only et NOMME" {
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  PKG="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"

  local image
  image="$(grep -vE '^\s*#' "$DOCKERFILE" \
    | sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt/p' \
    | tr ' \\' '\n\n' \
    | grep -vE '^$|apt-get|install|-y|--no-install-recommends|DEBIAN_FRONTEND|&&|^rm$|-rf|/var/lib/apt' \
    | sort -u)"
  [ -n "$image" ] || { echo "aucune liste apt lue dans le Dockerfile — l'instrument est casse"; return 1; }

  local native; native=" $(native_list 'PACKAGES' "$PKG") "
  # tini — PID 1 d'un conteneur, c'est systemd sur une machine ; openssh-server — la porte d'admin du conteneur, hors du poste
  local exempt=" tini openssh-server "
  local miss=""
  for p in $image; do
    [[ "$native" == *" $p "* || "$exempt" == *" $p "* ]] || miss+=" $p"
  done
  [ -z "$miss" ] || { echo "dans le socle de l'image mais ni sur le rail ni image-only nomme :$miss" >&2; return 1; }
  # et le rail, lui, ne demande AUCUN paquet image-only
  for p in tini openssh-server; do
    [[ "$native" != *" $p "* ]] || { echo "$p est sur le rail poste — il n'a rien a y faire" >&2; return 1; }
  done
}

pkg_mod()    { echo "$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"; }
engine_mod() { echo "$BATS_TEST_DIRNAME/../../modules.d/12-docker-engine.sh"; }

@test "docker n'est PAS dans la liste des deux rails — il n'a rien a faire dans l'image" {
  run native_list 'PACKAGES' "$(pkg_mod)"
  [ -n "$output" ]
  [[ "$output" != *"docker"* ]]
}

@test "docker-ce vit dans 12-docker-engine, sur le substrat linux seul ; 10-packages n'en parle plus" {
  grep -q '^# APPLY-ON: linux$' "$(engine_mod)"
  grep -q '^# CHECK-ON: linux$' "$(engine_mod)"
  grep -q 'docker-ce' "$(engine_mod)"
  grep -q '^PACKAGES=(' "$(pkg_mod)"
  grep -vE '^\s*#' "$(pkg_mod)" | refute_out 'docker-ce|ensure_docker_repo|LINUX_PACKAGES'
}
