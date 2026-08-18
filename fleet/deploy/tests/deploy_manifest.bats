#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/deploy_manifest.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for 60-deploy check — manifest-driven, source-independent
#
# Contract under test: the doctor side of 60-deploy is as BLIND to content as the installer —
# what it probes under $PREFIX/bin comes from etc/install.manifest, and it needs NO source
# checkout beyond etc/ (first real container boot proved the old mix.exs guard broke the probe
# exactly where it matters most). The RO-lock probe (root:fleet) inevitably drifts in an
# unprivileged sandbox — assertions therefore target the bin/link lines, not the exit code,
# except where the exit code is the contract (missing manifest = probe ERROR = rc 2).

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/fleet/deploy/lib" "$ROOT/fleet/etc"
  cp "$SRC/lib/provision-lib.sh" "$ROOT/fleet/deploy/lib/"
  cp "$SRC/modules.d/60-deploy.sh" "$BATS_TEST_TMPDIR/60-deploy.sh"

  cat > "$ROOT/fleet/etc/install.manifest" <<'EOF'
# test manifest
fleet_v2         exec   link
bwrap_launch.sh  exec
bridge.py        noexec
EOF

  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/linkdir"
  export PROVISION_LIB="$ROOT/fleet/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy

  # a "deployed" prefix: release marker + every manifest entry posed correctly
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet/bin" "$PROV_PREFIX/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  printf 'x\n' > "$PROV_PREFIX/bin/fleet_v2";        chmod +x "$PROV_PREFIX/bin/fleet_v2"
  printf 'x\n' > "$PROV_PREFIX/bin/bwrap_launch.sh"; chmod +x "$PROV_PREFIX/bin/bwrap_launch.sh"
  printf 'x\n' > "$PROV_PREFIX/bin/bridge.py"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
}

run_check() { run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check; }

@test "manifest-driven check: fully posed prefix has zero bin/link drift" {
  run_check
  [[ "$output" == *"bin/fleet_v2"* ]]
  [[ "$output" == *"bin/bridge.py"* ]]
  [[ "$output" == *"symlink $PROV_LINK_DIR/fleet_v2"* ]]
  [[ "$output" != *"DRIFT 60-deploy: bin/"* ]]
  [[ "$output" != *"symlink vers"* ]]
}

@test "manifest-driven check: a missing exec entry drifts by name" {
  rm "$PROV_PREFIX/bin/bwrap_launch.sh"
  run_check
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"bin/bwrap_launch.sh absent"* ]]
}

@test "manifest-driven check: a noexec entry only needs to be readable" {
  chmod -x "$PROV_PREFIX/bin/bridge.py"
  run_check
  [[ "$output" != *"bridge.py absent"* ]]
}

@test "manifest-driven check: a wrong link target drifts" {
  ln -sfn /somewhere/else "$PROV_LINK_DIR/fleet_v2"
  run_check
  [[ "$output" == *"$PROV_LINK_DIR/fleet_v2 ≠ symlink vers"* ]]
}

@test "manifest-driven check: a dead copy of a non-link entry warns (D3)" {
  printf 'x\n' > "$PROV_LINK_DIR/bwrap_launch.sh"
  run_check
  [[ "$output" == *"copie morte $PROV_LINK_DIR/bwrap_launch.sh"* ]]
}

@test "source-independence: check runs WITHOUT mix.exs (only etc/ ships in the image)" {
  # setup() never created mix.exs — a green-path check proves no source-tree dependency
  run_check
  [[ "$output" != *"introuvable"* ]]
}

@test "missing manifest is a probe ERROR (rc 2), not a silent pass" {
  rm "$BATS_TEST_TMPDIR/repo/fleet/etc/install.manifest"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest introuvable"* ]]
}

# ─── L'OUTILLAGE DU GATE : UNE EGALITE DE LISTES, TENUE PAR UN TEMOIN ───────────────────────────
#
# Le Dockerfile porte en commentaire « Liste = celle de 10-packages + les 2 du gate ». C'etait une
# affirmation que rien ne verifiait, et elle avait deja derive : le stage build installe TROIS
# paquets de plus (python3-pytest, bats, procps), et le rail natif n'en installait aucun.
#
# Mesure du 2026-08-18, Ubuntu 26.04 LTS neuve : « ECHEC: pytest absent — les lcars_tests de
# token-saver ne peuvent pas tourner (pas de skip silencieux) ». Gate rouge, release non posee,
# install natif mort. La liste vivait a un seul endroit, et c'etait le Dockerfile.

@test "tout paquet exige par le gate est installe DES DEUX COTES (image et rail natif)" {
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  MOD="$BATS_TEST_DIRNAME/../modules.d/60-deploy.sh"
  PKG="$BATS_TEST_DIRNAME/../modules.d/10-packages.sh"
  [ -f "$DOCKERFILE" ] && [ -f "$MOD" ] && [ -f "$PKG" ]

  # ce que le rail natif installe : les paquets runtime + l'outillage du gate
  runtime="$(sed -n 's/^PACKAGES=(\(.*\))$/\1/p' "$PKG")"
  gate="$(sed -n 's/^  GATE_PACKAGES=(\(.*\))$/\1/p' "$MOD")"
  [ -n "$runtime" ]
  [ -n "$gate" ]

  # le stage build de l'image DOIT contenir chacun d'eux
  for p in $runtime $gate; do
    grep -q -- " $p " "$DOCKERFILE" || grep -q -- " $p\\\\" "$DOCKERFILE" || {
      echo "paquet '$p' absent du stage build du Dockerfile" >&2; false; }
  done
}

@test "le gate a bien ses trois outils nommes — un ajout silencieux ne passe pas" {
  MOD="$BATS_TEST_DIRNAME/../modules.d/60-deploy.sh"
  gate="$(sed -n 's/^  GATE_PACKAGES=(\(.*\))$/\1/p' "$MOD")"
  [[ "$gate" == *"python3-pytest"* ]]   # shell_gate: les lcars_tests de token-saver
  [[ "$gate" == *"bats"* ]]             # BATS_MISSING_FATAL=1 pose par mix.exs
  [[ "$gate" == *"procps"* ]]           # les sondes qui lisent pgrep
}

@test "install.sh fait TRAVERSER ses reglages a l'escalade sudo" {
  # `sudo` remet l'environnement a zero. Un reglage pose avant l'escalade (PROV_COLOR, PROV_VERBOSE)
  # meurt en la traversant : mesure du 2026-08-18, `PROV_COLOR=1 bash install.sh` colorisait le
  # preflight puis rendait un provisionnement blanc, sans un mot pour dire pourquoi. Troisieme
  # incarnation de ce piege dans la meme journee (le shim docker, le temp root de bench-swap).
  SH="$BATS_TEST_DIRNAME/../../../install.sh"
  [ -f "$SH" ]
  grep -q 'REEXEC_ENV+=' "$SH"
  grep -q 'exec sudo "${REEXEC_ENV\[@\]}"' "$SH"
  for v in PROV_COLOR NO_COLOR PROV_VERBOSE; do
    grep -q "$v" "$SH" || { echo "reglage $v non transmis a travers sudo" >&2; false; }
  done
}
