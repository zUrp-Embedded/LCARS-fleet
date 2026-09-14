#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/container_privileges.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-14
# STATUS: bats tests for 6-071 — the container's privileges are the narrowest that let bwrap run

# le compose qui accorde SYS_ADMIN sous ce profil se joue dans docker/compose_context.bats

setup() {
  HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  DOCKER_DIR="$(cd "$HERE/../../docker" && pwd)"
  PROFILE="$DOCKER_DIR/lcars-hardened-seccomp.json"
}

@test "6-071: the profile exists, is valid JSON, and refuses by default" {
  [[ -f "$PROFILE" ]]
  python3 -c "
import json, sys
d = json.load(open('$PROFILE'))
assert d.get('defaultAction') == 'SCMP_ACT_ERRNO', d.get('defaultAction')
assert d.get('syscalls'), 'no syscall block'
"
}

@test "6-071: the profile allows every syscall bwrap needs — and pivot_root is the one that bit" {
  # Le run 4 de la mesure est mort exactement la : « pivot_root: Operation not permitted ». Les
  # autres sont la parce qu'un profil qui perd l'un d'eux echoue plus loin, et moins clairement.
  python3 -c "
import json, sys
d = json.load(open('$PROFILE'))
allowed = set()
for b in d['syscalls']:
    if b.get('action') == 'SCMP_ACT_ALLOW':
        allowed |= set(b.get('names', []))
need = ['unshare', 'mount', 'umount2', 'setns', 'pivot_root', 'clone']
missing = [n for n in need if n not in allowed]
assert not missing, 'syscalls manquants: %r' % missing
assert 'keyctl' not in allowed, 'le profil autorise keyctl — ce n est plus un durcissement'
"
}
