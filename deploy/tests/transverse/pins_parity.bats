#!/usr/bin/env bats
# SOURCE: deploy/tests/transverse/pins_parity.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — les pins (version + sha256) de tofu et de xterm sont les MEMES sur le poste et dans l'image
#
# DI-09 (lot 11). Deux poseurs pour un meme objet : `46-tofu` (poste) et le Dockerfile (image) pour
# OpenTofu ; `62-runtime-helpers` (poste) et le Dockerfile pour xterm. Un pin qui bouge d'un seul
# cote donne deux rails qui ne servent pas la meme chose sans qu'aucun verdict ne le dise.

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DF="$REPO/deploy/docker/Dockerfile"
  TOFU="$REPO/deploy/modules.d/46-tofu.sh"
  HELPERS="$REPO/deploy/modules.d/62-runtime-helpers.sh"
}
arg_of() { sed -nE "s/^ARG $1=(.*)$/\1/p" "$DF" | head -1; }
var_of() { sed -nE "s/^$2=\"?\\$\{[A-Z_]+:-([^}]*)\}\"?$/\1/p; s/^$2=([^\"\$][^ ]*)$/\1/p" "$1" | head -1; }

@test "tofu : version et les deux sha256 (amd64, arm64) s'accordent entre 46-tofu et le Dockerfile" {
  local k
  for k in TOFU_VERSION TOFU_SHA256_AMD64 TOFU_SHA256_ARM64; do
    [ -n "$(arg_of $k)" ] || { echo "Dockerfile : ARG $k illisible" >&2; return 1; }
    [ "$(var_of "$TOFU" $k)" = "$(arg_of $k)" ] || { echo "$k : poste=$(var_of "$TOFU" $k) image=$(arg_of $k)" >&2; return 1; }
  done
}

@test "xterm : les deux versions et les trois sha256 s'accordent entre 62-runtime-helpers et le Dockerfile" {
  local k
  for k in XTERM_VERSION XTERM_FIT_VERSION XTERM_JS_SHA256 XTERM_CSS_SHA256 XTERM_FIT_SHA256; do
    [ -n "$(arg_of $k)" ] || { echo "Dockerfile : ARG $k illisible" >&2; return 1; }
    [ "$(var_of "$HELPERS" $k)" = "$(arg_of $k)" ] || { echo "$k : poste=$(var_of "$HELPERS" $k) image=$(arg_of $k)" >&2; return 1; }
  done
}

@test "TEMOIN DU TEMOIN : le lecteur voit bien une valeur de chaque cote (une regex morte rendrait vert par vide)" {
  [[ "$(var_of "$TOFU" TOFU_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ "$(var_of "$HELPERS" XTERM_JS_SHA256)" =~ ^[0-9a-f]{64}$ ]]
  [[ "$(arg_of TOFU_SHA256_ARM64)" =~ ^[0-9a-f]{64}$ ]]
}
