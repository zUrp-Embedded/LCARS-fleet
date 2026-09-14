#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/container_privileges.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-14
# STATUS: bats tests — les privilèges du conteneur sont les plus étroits qui laissent tourner bwrap

# le compose qui accorde SYS_ADMIN sous ce profil se joue dans docker/compose_context.bats

load ../refute

setup() {
  HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  DOCKER_DIR="$(cd "$HERE/../../docker" && pwd)"
  PROFILE="$DOCKER_DIR/lcars-hardened-seccomp.json"
}

@test "le profil seccomp est un JSON valide, refuse par défaut et porte des règles" {
  [ "$(jq -r '.defaultAction' "$PROFILE")" = SCMP_ACT_ERRNO ]
  [ "$(jq '.syscalls | length' "$PROFILE")" -gt 0 ]
}

@test "le profil autorise chaque appel système que bwrap demande, pivot_root compris, et refuse keyctl" {
  local permis n
  permis="$(jq -r '.syscalls[] | select(.action == "SCMP_ACT_ALLOW") | .names[]?' "$PROFILE" | sort -u)"
  for n in unshare mount umount2 setns pivot_root clone; do
    grep -qx "$n" <<<"$permis" || { echo "appel système refusé par le profil : $n"; return 1; }
  done
  refute grep -qx keyctl <<<"$permis"
}
