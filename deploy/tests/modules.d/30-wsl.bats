#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/30-wsl.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins du substrat WSL — wsl.conf clé par clé, C: sondé, hostname, les projets ouverts au compte de Windows, snapd, gpg-agent, credsStore, docker.io

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/30-wsl.sh"; [ -f "$MOD" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=30-wsl PROV_SUBSTRATE=wsl PROV_HUMAN=root PROV_FORGE_BASE=bob_9
  decor_pose
  WSL_CONF="$LCARS_DECOR_ROOT/etc/wsl.conf"
  C_DRIVE="$LCARS_DECOR_ROOT/mnt/c"
  DESKTOP_CLI="$LCARS_DECOR_ROOT/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"
  export HOME_DIR="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME_DIR"
  export INSTALLES="$BATS_TEST_TMPDIR/installes"; : > "$INSTALLES"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export STUB_HOSTNAME=bob-9
  BIN="$DECOR_BIN"
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
  # tout compte existe et habite HOME_DIR, sauf « inconnu »
  printf '#!/usr/bin/env bash\n[[ "$1" == passwd && "$2" != inconnu ]] && printf "%%s:x:0:0::%s:/bin/bash\\n" "$2"\nexit 0\n' "$HOME_DIR" > "$BIN/getent"
  printf '#!/usr/bin/env bash\necho "$STUB_HOSTNAME"\n' > "$BIN/hostname"
  chmod 0755 "$BIN"/*
}

mod() { run unshare -Ur bash "$MOD" "$@"; }
masque_pose() { mkdir -p "$HOME_DIR/.config/systemd/user"; ln -sf /dev/null "$HOME_DIR/.config/systemd/user/gpg-agent-ssh.socket"; }
# les racines de face, telles que 25-directories les pose avant que ce module se joue
faces_posees() { mkdir -p "$LCARS_DECOR_ROOT"/home/projects{,.ops,.workshop}; }
# posée dans le même espace d'uid que le module : « root » y désigne le compte qui joue les témoins
acl_pose() { unshare -Ur setfacl -m u:root:rwx -m d:u:root:rwx "$@"; }
acl_lue() { unshare -Ur getfacl -pcE "$1"; }
cle() { awk -v S="$1" -v K="$2" '/^\[/{s=$0; gsub(/[][]/,"",s)} s==S && $0 ~ "^"K"=" {sub(/^[^=]*=/,""); print; exit}' "$WSL_CONF"; }
desktop_monte() { mkdir -p "$(dirname "$DESKTOP_CLI")"; printf '#!/bin/sh\n' > "$DESKTOP_CLI"; chmod 0755 "$DESKTOP_CLI"; }

@test "check : tout posé — snapd absent, masque gpg, wsl.conf conforme clé par clé, C: fermé, hostname du projet — conforme" {
  masque_pose
  faces_posees
  acl_pose "$LCARS_DECOR_ROOT"/home/projects{,.ops,.workshop}
  printf '[user]\ndefault=root\n[boot]\nsystemd=true\n[automount]\nenabled=false\nmountFsTab=true\n[interop]\nenabled=false\nappendWindowsPath=false\n[network]\nhostname=bob-9\n' > "$WSL_CONF"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"snapd absent"*"gpg-agent-ssh.socket masqué (root)"*"[boot] systemd=true"*"[network] hostname=bob-9"*"C: fermé"* ]]
  [[ "$output" == *"/home/projects.workshop : « root » y écrit (ACL nominative, accès et défaut)"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "check : sans wsl.conf, chaque clé de l'état-cible est un drift qui dit l'attendu ; C: ouvert et non conforme, le lockdown n'est pas armé" {
  masque_pose
  mkdir -p "$C_DRIVE"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 30-wsl: $WSL_CONF : [boot] systemd=<absent> — attendu true"*"[interop] enabled=<absent> — attendu false"*"[network] hostname=<absent> — attendu bob-9"* ]]
  [[ "$output" == *"C: OUVERT (sonde réelle) et wsl.conf non conforme — le lockdown n'est pas armé"* ]]
}

@test "apply : les clés se posent dans un wsl.conf existant, [user] et les clés de l'opérateur restent" {
  printf '[user]\ndefault=bob\n\n[boot]\nsystemd=false\ncommand=/usr/bin/true\n\n[automount]\nenabled=true\noptions=metadata\n' > "$WSL_CONF"
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
  [ "$(grep -c '^systemd=' "$WSL_CONF")" -eq 1 ]
  [ "$(head -1 "$WSL_CONF")" = "[user]" ]
  [[ "$output" == *"POSÉ  30-wsl: $WSL_CONF"* ]]
  local avant; avant="$(cat "$WSL_CONF")"
  mod apply
  [ "$status" -eq 0 ]
  [ "$(cat "$WSL_CONF")" = "$avant" ]
  refute_out "POSÉ  30-wsl: $WSL_CONF" <<<"$output"
}

@test "C: sondé pour un humain que as_human ne peut pas jouer : l'échec est dit, jamais « C: fermé »" {
  mkdir -p "$C_DRIVE"
  PROV_HUMAN=inconnu mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  30-wsl: as_human: user inconnu: inconnu"* ]]
  refute_out 'C: fermé' <<<"$output"
}

@test "C: sondé pour un humain sans home : non sondé, et dit — jamais muet, jamais « C: fermé »" {
  mkdir -p "$C_DRIVE"
  rm -rf "$HOME_DIR"
  mod check
  [[ "$output" == *"WARN  30-wsl: C: non sondé — le home de root ($HOME_DIR) n'existe pas"* ]] || { echo "$output"; return 1; }
  refute_out 'C: fermé|C: OUVERT' <<<"$output"
  mod apply
  [[ "$output" == *"WARN  30-wsl: C: non sondé"* ]]
}

@test "apply : sans wsl.conf, le fichier naît sous le décor avec son en-tête et les six clés, en 0644 root" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(head -1 "$WSL_CONF")" == "# /etc/wsl.conf — les clés ci-dessous sont tenues par LCARS"* ]]
  [ "$(cle boot systemd)" = "true" ]
  [ "$(cle interop appendWindowsPath)" = "false" ]
  [ "$(cle network hostname)" = "bob-9" ]
  [ "$(stat -c '%a %U' "$WSL_CONF")" = "644 $(id -un)" ]
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
  mkdir -p "$C_DRIVE"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  30-wsl: wsl.conf posé mais C: encore OUVERT — « wsl --shutdown »"* ]]
  [ -z "$(ls -A "$C_DRIVE")" ]
}

@test "apply : snapd présent est purgé avec ses arbres du décor, et le masque gpg de l'humain est posé" {
  echo snapd > "$INSTALLES"
  mkdir -p "$LCARS_DECOR_ROOT/snap/x" "$LCARS_DECOR_ROOT/var/snap" "$LCARS_DECOR_ROOT/var/lib/snapd"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^APT:purge -y snapd' "$CALLS"
  [[ "$output" == *"POSÉ  30-wsl: snapd purgé"* ]]
  [ ! -e "$LCARS_DECOR_ROOT/snap" ]
  [ ! -e "$LCARS_DECOR_ROOT/var/snap" ]
  [ ! -e "$LCARS_DECOR_ROOT/var/lib/snapd" ]
  [ "$(readlink "$HOME_DIR/.config/systemd/user/gpg-agent-ssh.socket")" = "/dev/null" ]
  mod check
  [[ "$output" == *"snapd absent"* ]]
}

@test "docker.io à côté de Docker Desktop : un état de la machine, dérive au check et échec à l'apply, le geste entier dit, rien n'est enlevé" {
  echo docker.io > "$INSTALLES"; desktop_monte
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 30-wsl: docker.io est posé À CÔTÉ de Docker Desktop"*"apt purge docker.io containerd runc"*"WSL integration"*"dpkg --configure -a"* ]]
  mod apply
  [ "$status" -eq 1 ]
  refute grep -q '^APT:' "$CALLS"
  rm -f "$DESKTOP_CLI"
  mod check
  [[ "$output" == *"docker.io (ou docker-ce) est le daemon, c'est voulu"* ]]
}

@test "credsStore en dernière clé, dans la forme sur plusieurs lignes qu'écrit docker : le fichier reste un JSON valide" {
  mkdir -p "$HOME_DIR/.docker"
  printf '{\n\t"auths": {},\n\t"credsStore": "desktop.exe"\n}\n' > "$HOME_DIR/.docker/config.json"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run jq -c . "$HOME_DIR/.docker/config.json"
  [ "$status" -eq 0 ]
  [ "$output" = '{"auths":{}}' ]
}

@test "un ~/.config que l'humain a restreint garde son mode ; les dossiers absents naissent en 0700" {
  mkdir -p "$HOME_DIR/.config"; chmod 0770 "$HOME_DIR/.config"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c '%a' "$HOME_DIR/.config")" = 770 ]
  [ "$(stat -c '%a' "$HOME_DIR/.config/systemd")" = 700 ]
  [ "$(stat -c '%a' "$HOME_DIR/.config/systemd/user")" = 700 ]
}

@test "credsStore : retiré quand il désigne le helper Windows, les autres clés survivent, rien n'est inventé" {
  mkdir -p "$HOME_DIR/.docker"
  printf '{"auths":{"reg.example":{"auth":"eyJ="}},"credsStore":"desktop.exe"}' > "$HOME_DIR/.docker/config.json"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local apres; apres="$(cat "$HOME_DIR/.docker/config.json")"
  [[ "$apres" == *'"auths"'*'reg.example'* ]]
  [[ "$apres" != *credsStore* ]]
  [[ "$output" == *"credsStore retiré"*"docker login"* ]]
  printf '{"auths":{}}' > "$HOME_DIR/.docker/config.json"
  mod apply
  [ "$(cat "$HOME_DIR/.docker/config.json")" = '{"auths":{}}' ]
  [[ "$output" != *"credsStore retiré"* ]]
  rm -f "$HOME_DIR/.docker/config.json"
  mod apply
  [ ! -e "$HOME_DIR/.docker/config.json" ]
}

@test "les projets : sans ACL, chaque racine de face est une dérive qui nomme le compte de Windows" {
  faces_posees
  printf '[user]\ndefault=root\n' > "$WSL_CONF"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 30-wsl: $LCARS_DECOR_ROOT/home/projects : « root » (le compte de Windows) n'y écrit pas — ACL nominative absente"* ]]
  [[ "$output" == *"$LCARS_DECOR_ROOT/home/projects.ops : « root »"*"$LCARS_DECOR_ROOT/home/projects.workshop : « root »"* ]]
}

@test "les projets : l'apply pose l'entrée en accès ET par défaut, ce qui naît ensuite en hérite, le groupe ne gagne rien, la seconde passe ne repose rien" {
  faces_posees
  chmod 2775 "$LCARS_DECOR_ROOT/home/projects"
  printf '[user]\ndefault=root\n' > "$WSL_CONF"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"POSÉ  30-wsl: $LCARS_DECOR_ROOT/home/projects : « root » y écrit désormais"* ]]
  local lue; lue="$(acl_lue "$LCARS_DECOR_ROOT/home/projects")"
  [[ "$lue" == *"user:root:rwx"*"default:user:root:rwx"* ]]
  [[ "$lue" == *"group::rwx"* ]]
  [[ "$lue" == *"other::r-x"* ]]
  unshare -Ur mkdir "$LCARS_DECOR_ROOT/home/projects/neuf"
  [[ "$(acl_lue "$LCARS_DECOR_ROOT/home/projects/neuf")" == *"user:root:rwx"*"default:user:root:rwx"* ]]
  mod apply
  [ "$status" -eq 0 ]
  refute_out 'y écrit désormais' <<<"$output"
  [[ "$output" == *"OK    30-wsl: $LCARS_DECOR_ROOT/home/projects : « root » y écrit"* ]]
}

@test "les projets : wsl.conf qui ne nomme personne et pas de siège — dit, et rien n'est posé à l'aveugle" {
  faces_posees
  printf '[boot]\nsystemd=true\n' > "$WSL_CONF"
  mod check
  [[ "$output" == *"WARN  30-wsl: compte de Windows inconnu"*"lecture seule depuis Windows"* ]] || { echo "$output"; return 1; }
  refute_out "ACL nominative absente" <<<"$output"
  refute_out "user:root:rwx" <<<"$(acl_lue "$LCARS_DECOR_ROOT/home/projects")"
}

@test "les projets : sans [user] default, le siège prend sa place" {
  faces_posees
  printf '#!/usr/bin/env bash\nprintf "root:x:0:0::%%s:/bin/bash\\n" "$HOME_DIR"\nexit 0\n' > "$BIN/getent"
  chmod 0755 "$BIN/getent"
  printf '[boot]\nsystemd=true\n' > "$WSL_CONF"
  LCARS_SYSADMIN_UID=0 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$LCARS_DECOR_ROOT/home/projects : « root » (le compte de Windows) n'y écrit pas"* ]] || { echo "$output"; return 1; }
}

@test "les projets : un setfacl qui refuse est un échec nommé, jamais un silence" {
  faces_posees
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/setfacl"
  chmod 0755 "$BIN/setfacl"
  printf '[user]\ndefault=root\n' > "$WSL_CONF"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  30-wsl: $LCARS_DECOR_ROOT/home/projects : ACL refusée pour « root » (setfacl)"* ]]
}
