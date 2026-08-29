#!/usr/bin/env bats
# SOURCE: LCARS-bob
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: temoins de 30-wsl.sh — le module n'avait aucune suite

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../modules.d/30-wsl.sh"
  [ -f "$MOD" ]
}

@test "gpg_socket_mask_path : un humain SANS home rend vide et 0 — la sonde derive, elle ne meurt pas" {
  # `[[ -n "$home" ]] && echo …` rendait 1 sur un home vide ; check() fait `mask="$(…)"`, une
  # affectation, et set -e le tuait AVANT le if qui savait dire la derive. Mur I3 (idiom_walls).
  eval "$(sed -n '/^gpg_socket_mask_path()/,/^}/p' "$MOD")"
  human_home() { echo ""; }
  run gpg_socket_mask_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  human_home() { echo /home/x; }
  run gpg_socket_mask_path
  [ "$status" -eq 0 ]
  [ "$output" = "/home/x/.config/systemd/user/gpg-agent-ssh.socket" ]
}
