#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/30-wsl.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du substrat WSL — wsl.conf clé par clé, C: sondé, hostname, snapd, gpg-agent, credsStore, docker.io
#
# Le module est joué entier sous unshare -Ur (wsl.conf est root:root) avec dpkg-query, apt-get,
# getent et hostname doublés ; le lecteur C: et la CLI de Docker Desktop sont des chemins du décor.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/30-wsl.sh"; [ -f "$MOD" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=30-wsl PROV_SUBSTRATE=wsl PROV_HUMAN=root PROV_FORGE_BASE=bob_9
  export LCARS_WSL_CONF="$BATS_TEST_TMPDIR/wsl.conf"
  export LCARS_C_DRIVE="$BATS_TEST_TMPDIR/absent-c"
  export LCARS_DOCKER_MOUNT_CLI="$BATS_TEST_TMPDIR/desktop-cli"
  export HOME_DIR="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME_DIR"
  export INSTALLES="$BATS_TEST_TMPDIR/installes"; : > "$INSTALLES"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export STUB_HOSTNAME=bob-9
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
pkg="${@: -1}"; grep -qx "$pkg" "$INSTALLES" && printf 'installed' || printf 'not-installed'
EOF
  cat > "$BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "APT:$*" >> "$CALLS"
[[ "$1" == purge ]] && sed -i '/^snapd$/d' "$INSTALLES"
exit 0
EOF
  printf '#!/usr/bin/env bash\n[[ "$1" == passwd ]] && printf "%%s:x:0:0::%s:/bin/bash\\n" "$2"\nexit 0\n' "$HOME_DIR" > "$BIN/getent"
  printf '#!/usr/bin/env bash\necho "$STUB_HOSTNAME"\n' > "$BIN/hostname"
  chmod 0755 "$BIN"/*
  export PATH="$BIN:$PATH"
}

mod() {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le module ne se joue pas ici"
  run unshare -Ur bash "$MOD" "$@"
}
masque_pose() { mkdir -p "$HOME_DIR/.config/systemd/user"; ln -sf /dev/null "$HOME_DIR/.config/systemd/user/gpg-agent-ssh.socket"; }
cle() { awk -v S="$1" -v K="$2" '/^\[/{s=$0; gsub(/[][]/,"",s)} s==S && $0 ~ "^"K"=" {sub(/^[^=]*=/,""); print; exit}' "$LCARS_WSL_CONF"; }

@test "check : tout posé — snapd absent, masque gpg, wsl.conf conforme clé par clé, C: fermé, hostname du projet — conforme" {
  masque_pose
  printf '[boot]\nsystemd=true\n[automount]\nenabled=false\nmountFsTab=true\n[interop]\nenabled=false\nappendWindowsPath=false\n[network]\nhostname=bob-9\n' > "$LCARS_WSL_CONF"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"snapd absent"*"gpg-agent-ssh.socket masqué (root)"*"[boot] systemd=true"*"[network] hostname=bob-9"*"C: fermé"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "check : sans wsl.conf, chaque clé de l'état-cible est un drift qui dit l'attendu ; C: ouvert et non conforme, le lockdown n'est pas armé" {
  masque_pose
  mkdir -p "$LCARS_C_DRIVE"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 30-wsl: $LCARS_WSL_CONF : [boot] systemd=<absent> — attendu true"*"[interop] enabled=<absent> — attendu false"*"[network] hostname=<absent> — attendu bob-9"* ]]
  [[ "$output" == *"C: OUVERT (sonde réelle) et wsl.conf non conforme — le lockdown n'est pas armé"* ]]
}

@test "apply : les clés se posent dans un wsl.conf existant, [user] et les clés de l'opérateur restent" {
  printf '[user]\ndefault=bob\n\n[boot]\nsystemd=false\ncommand=/usr/bin/true\n\n[automount]\nenabled=true\noptions=metadata\n' > "$LCARS_WSL_CONF"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cle user default)" = "bob" ]
  [ "$(cle boot systemd)" = "true" ]
  [ "$(cle boot command)" = "/usr/bin/true" ]
  [ "$(cle automount enabled)" = "false" ]
  [ "$(cle automount mountFsTab)" = "true" ]
  [ "$(cle automount options)" = "metadata" ]
  [ "$(cle interop enabled)" = "false" ]
  [ "$(cle interop appendWindowsPath)" = "false" ]
  [ "$(cle network hostname)" = "bob-9" ]
  [ "$(grep -c '^systemd=' "$LCARS_WSL_CONF")" -eq 1 ]
  [ "$(head -1 "$LCARS_WSL_CONF")" = "[user]" ]
  [[ "$output" == *"POSÉ  30-wsl: $LCARS_WSL_CONF"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"$LCARS_WSL_CONF conforme, clé par clé"* ]]
}

@test "apply : sans wsl.conf, le fichier naît avec son en-tête et les six clés, en 0644 root" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(head -1 "$LCARS_WSL_CONF")" == "# /etc/wsl.conf — les clés ci-dessous sont tenues par LCARS"* ]]
  [ "$(cle boot systemd)" = "true" ]
  [ "$(cle interop appendWindowsPath)" = "false" ]
  [ "$(cle network hostname)" = "bob-9" ]
  [ "$(stat -c '%a %U' "$LCARS_WSL_CONF")" = "644 $(id -un)" ]
  [[ "$output" == *"C: fermé (sonde réelle)"* ]]
}

@test "apply : le hostname vient de la base du projet, tirets pour les tirets bas ; s'il ne prend pas encore, le redémarrage est dit" {
  STUB_HOSTNAME=Nico-SuperCharged mod apply
  [ "$status" -eq 0 ]
  [ "$(cle network hostname)" = "bob-9" ]
  [[ "$output" == *"WARN  30-wsl: hostname « Nico-SuperCharged » — « bob-9 » prendra après « wsl --shutdown »"* ]]
  PROV_FORGE_BASE=lcars STUB_HOSTNAME=lcars mod apply
  [ "$(cle network hostname)" = "lcars" ]
  [[ "$output" != *"prendra après"* ]]
}

@test "apply : C: encore ouvert après la pose est un avertissement qui dit le redémarrage, pas un échec" {
  mkdir -p "$LCARS_C_DRIVE"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  30-wsl: wsl.conf posé mais C: encore OUVERT — « wsl --shutdown »"* ]]
  [ -z "$(ls -A "$LCARS_C_DRIVE")" ]
}

@test "apply : snapd présent est purgé avec ses arbres, et le masque gpg de l'humain est posé" {
  echo snapd > "$INSTALLES"
  mkdir -p "$BATS_TEST_TMPDIR/snap/x" "$BATS_TEST_TMPDIR/var-snap"
  LCARS_SNAP_DIRS="$BATS_TEST_TMPDIR/snap $BATS_TEST_TMPDIR/var-snap" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^APT:purge -y snapd' "$CALLS"
  [[ "$output" == *"POSÉ  30-wsl: snapd purgé"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/snap" ]
  [ ! -e "$BATS_TEST_TMPDIR/var-snap" ]
  [ "$(readlink "$HOME_DIR/.config/systemd/user/gpg-agent-ssh.socket")" = "/dev/null" ]
  mod check
  [[ "$output" == *"snapd absent"* ]]
}

@test "docker.io à côté de Docker Desktop : échec au check et à l'apply, le geste entier dit, rien n'est enlevé" {
  echo docker.io > "$INSTALLES"; printf '#!/bin/sh\n' > "$LCARS_DOCKER_MOUNT_CLI"; chmod 0755 "$LCARS_DOCKER_MOUNT_CLI"
  mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  30-wsl: docker.io est posé À CÔTÉ de Docker Desktop"*"apt purge docker.io containerd runc"*"WSL integration"*"dpkg --configure -a"* ]]
  mod apply
  [ "$status" -eq 1 ]
  refute grep -q '^APT:' "$CALLS"
  rm -f "$LCARS_DOCKER_MOUNT_CLI"
  mod check
  [[ "$output" == *"docker.io (ou docker-ce) est le daemon, c'est voulu"* ]]
}

@test "credsStore : retiré quand il désigne le helper Windows, les autres clés survivent, rien n'est inventé" {
  mkdir -p "$HOME_DIR/.docker"
  printf '{"auths":{"reg.example":{"auth":"eyJ="}},"credsStore":"desktop.exe"}' > "$HOME_DIR/.docker/config.json"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local apres; apres="$(cat "$HOME_DIR/.docker/config.json")"
  [[ "$apres" == *'"auths"'*'reg.example'* && "$apres" != *credsStore* ]]
  [[ "$output" == *"credsStore retiré"*"docker login"* ]]
  printf '{"auths":{}}' > "$HOME_DIR/.docker/config.json"
  mod apply
  [ "$(cat "$HOME_DIR/.docker/config.json")" = '{"auths":{}}' ]
  [[ "$output" != *"credsStore retiré"* ]]
  rm -f "$HOME_DIR/.docker/config.json"
  mod apply
  [ ! -e "$HOME_DIR/.docker/config.json" ]
}
