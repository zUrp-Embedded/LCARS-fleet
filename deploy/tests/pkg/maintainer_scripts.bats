#!/usr/bin/env bats
# SOURCE: deploy/tests/pkg/maintainer_scripts.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: temoins des maintainer scripts dpkg (deploy/pkg/<paquet>/{preinst,postinst,prerm,postrm}),
#         joues avec un `provision` DOUBLE qui trace ses arguments, son environnement, et l'etat
#         du canal AU MOMENT de l'appel
#
# ─── CE QUE CES TEMOINS TIENNENT ────────────────────────────────────────────────────────────────
#
# Les scripts n'ont AUCUNE logique a eux : ils nomment le siege, le substrat, le canal, et
# appellent le provisionnement. Ce qui se mesure est donc : les `--only` exacts, le canal ecrit
# AVANT l'apply (contrat du lot 2), les refus nommes (pas de siege, pas de forge, mauvais canal),
# les codes (2 = drift residuel, pas un echec ; 1 = echec), la rejouabilite (deux `configure` de
# suite), et jamais une question. Aucun temoin ne touche la machine : tout vit sous
# BATS_TEST_TMPDIR, par les coutures LCARS_* que chaque script expose.

# ⚠ SC2016 : ces temoins ECRIVENT des doublures dont les `$1` doivent atteindre bash tels quels.
# shellcheck disable=SC2016
load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PKG="$REPO/deploy/pkg"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/opt/deploy/modules.d" "$T/etc/lcars" "$T/opt/lcars/var" "$T/bin"
  cp -a "$REPO/deploy/lib" "$T/opt/deploy/lib"
  cp "$REPO/deploy/system.manifest" "$T/opt/deploy/system.manifest"

  # LA DOUBLURE DE `provision` : elle trace, elle ne fait rien. `CHANNEL` est lu AU MOMENT de
  # l'appel — c'est ainsi qu'on mesure l'ordre « canal AVANT apply ».
  export TRACE="$T/trace"; : > "$TRACE"
  cat > "$T/opt/deploy/provision" <<'DBL'
#!/usr/bin/env bash
{
  printf 'ARGS %s\n' "$*"
  printf 'CHANNEL %s\n' "$(cat "${LCARS_CHANNEL_FILE:-/nonexistent}" 2>/dev/null || echo ABSENT)"
  printf 'ENV FORGE_BASE_URL=%s LCARS_BUILTIN_HUMAN=%s LCARS_ALLOW_ANY_HOST=%s LCARS_SYSADMIN_UID=%s PROV_FORGE_MONTEE=%s\n' \
    "${FORGE_BASE_URL:-}" "${LCARS_BUILTIN_HUMAN:-}" "${LCARS_ALLOW_ANY_HOST:-}" "${LCARS_SYSADMIN_UID:-}" "${PROV_FORGE_MONTEE:-}"
} >> "$TRACE"
exit "${FAKE_PROVISION_RC:-0}"
DBL
  chmod +x "$T/opt/deploy/provision"

  export LCARS_PROVISION_BIN="$T/opt/deploy/provision"
  export LCARS_CHANNEL_FILE="$T/etc/lcars/channel"
  export LCARS_UNINSTALL_STASH="$T/stash"
  export PROV_ROOT="$T/opt/lcars"
  export LCARS_ETC_DIR="$T/etc/lcars"
  export LCARS_DEMO_HUMAN_FILE="$T/opt/lcars/var/demo-human"
  export LCARS_SEAT_UID_FILE="$T/etc/lcars/seat.uid"
  export LCARS_FORGE_CONF="$T/etc/lcars/forge.conf"
  export LCARS_JOURNAL_FILE="$T/opt/lcars/var/install.journal"
  export SUDO_USER; SUDO_USER="$(id -un)"
  unset LCARS_SYSADMIN_UID FORGE_BASE_URL PROV_DEMO_HUMAN LCARS_BUILTIN_HUMAN FAKE_PROVISION_RC 2>/dev/null || true

  # dpkg-query double : l'etat voulu des paquets se dicte par FAKE_WANT_<paquet>
  cat > "$T/bin/dpkg-query" <<'DQ'
#!/usr/bin/env bash
# -W -f '${db:Status-Want}' <paquet>
p="${*: -1}"; v="FAKE_WANT_${p//-/_}"
printf '%s' "${!v:-}"
DQ
  chmod +x "$T/bin/dpkg-query"; export LCARS_DPKG_QUERY="$T/bin/dpkg-query"
}

script() { run bash "$PKG/$1" "${@:2}"; }
trace_args() { sed -n 's/^ARGS //p' "$TRACE"; }
trace_env()  { sed -n 's/^ENV //p' "$TRACE"; }
only_of() { # only_of <ligne ARGS> -> les modules --only, dans l'ordre
  printf '%s\n' "$1" | tr ' ' '\n' | awk 'p {print; p=0} /^--only$/ {p=1}' | paste -sd' ' -
}

# ─── FORME : tous les scripts ───────────────────────────────────────────────────────────────────

all_scripts() { find "$PKG" -mindepth 2 -maxdepth 2 -type f \( -name preinst -o -name postinst -o -name prerm -o -name postrm \) | sort; }

@test "FORME : chaque script est executable, sous set -euo pipefail, avec l'en-tete LCARS, et ne pose JAMAIS de question" {
  local f n=0
  while read -r f; do
    [ -x "$f" ]
    head -1 "$f" | grep -q '^#!/bin/bash$'
    grep -q '^set -euo pipefail$' "$f"
    head -6 "$f" | grep -q '^# SOURCE: deploy/pkg/'
    head -6 "$f" | grep -q '^# STARDATE:'
    # jamais une question : ni read sur le terminal, ni debconf
    grep -vE '^\s*#' "$f" | refute_out 'read -p|db_input|db_get|debconf|/dev/tty'
    n=$((n + 1))
  done < <(all_scripts)
  [ "$n" -eq 14 ]
}

@test "FORME : un argument que dpkg passe et que le script ne traite pas rend 0 — jamais un echec sur abort-upgrade" {
  local f
  while read -r f; do
    run bash "$f" abort-upgrade 1.0
    [ "$status" -eq 0 ] || { echo "$f abort-upgrade : $status — $output" >&2; return 1; }
    run bash "$f" failed-upgrade 1.0
    [ "$status" -eq 0 ]
  done < <(all_scripts)
  [ ! -s "$TRACE" ]
}

# ─── lcars/preinst ──────────────────────────────────────────────────────────────────────────────

@test "preinst : un canal qui n'est pas « deb » est REFUSE avant tout depaquetage, avec le geste" {
  printf 'kit\n' > "$LCARS_CHANNEL_FILE"
  script lcars/preinst install
  [ "$status" -eq 1 ]
  [[ "$output" == *"canal « kit »"* ]]
  [[ "$output" == *"provision uninstall --yes"* ]]
}

@test "preinst : le groupe du prefixe est cree au GID de la table quand il manque — et rien quand il est la" {
  # getent et groupadd doubles : la machine n'est pas touchee
  printf '#!/usr/bin/env bash\n[[ "$1" == group ]] && exit 2\nexec /usr/bin/getent "$@"\n' > "$T/bin/getent"
  printf '#!/usr/bin/env bash\necho "groupadd $*" >> "$TRACE"\n' > "$T/bin/groupadd"
  chmod +x "$T/bin/getent" "$T/bin/groupadd"
  PATH="$T/bin:$PATH" script lcars/preinst install
  [ "$status" -eq 0 ]
  local gid; gid="$(awk '$1=="group" && $2=="fleet" {print $3}' "$REPO/deploy/system.manifest")"
  [ -n "$gid" ]
  grep -qx "groupadd -g $gid fleet" "$TRACE"
  [[ "$output" == *"groupe fleet cree (gid $gid, la table)"* ]]
  # present : aucun groupadd
  : > "$TRACE"
  printf '#!/usr/bin/env bash\n[[ "$1" == group ]] && { echo "fleet:x:%s:"; exit 0; }\nexec /usr/bin/getent "$@"\n' "$gid" > "$T/bin/getent"
  PATH="$T/bin:$PATH" script lcars/preinst upgrade 0.9.0
  [ "$status" -eq 0 ]
  [ ! -s "$TRACE" ]
  [[ "$output" == *"groupe fleet present"* ]]
}

@test "preinst : le GID ecrit dans le script EST celui de la table — deux copies, un mur" {
  local gid; gid="$(awk '$1=="group" && $2=="fleet" {print $3}' "$REPO/deploy/system.manifest")"
  grep -qE "^FLEET_GID=$gid\b" "$PKG/lcars/preinst"
}

# ─── lcars/postinst ─────────────────────────────────────────────────────────────────────────────

@test "postinst lcars : le CANAL est ecrit AVANT l'apply, et l'apply est le socle sans 10-packages" {
  script lcars/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "deb" ]
  # au moment de l'appel, le canal valait deja « deb »
  grep -qx 'CHANNEL deb' "$TRACE"
  local a; a="$(trace_args)"
  [[ "$a" == "apply --substrate "*" --human $(id -un) --only 00 --only 05 --only 20 --only 21 --only 22 --only 25 --only 30" ]]
  [ "$(only_of "$a")" = "00 05 20 21 22 25 30" ]
  refute grep -q -- '--only 10' <<<"$a"
  [[ "$a" == *"--substrate wsl"* || "$a" == *"--substrate linux"* ]]
  # le consentement voyage, et le siege est l'uid de SUDO_USER
  grep -q "LCARS_ALLOW_ANY_HOST=1" "$TRACE"
  grep -q "LCARS_SYSADMIN_UID=$(id -u)" "$TRACE"
}

@test "postinst lcars : REJOUABLE — deux configure de suite, meme canal, deux applies" {
  script lcars/postinst configure; [ "$status" -eq 0 ]
  script lcars/postinst configure 0.9.0; [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "deb" ]
  [ "$(trace_args | wc -l)" -eq 2 ]
}

@test "postinst lcars : rc 2 du provisionnement = drift residuel, DIT, pas un echec ; rc 1 = echec avec le geste de rejeu" {
  FAKE_PROVISION_RC=2 script lcars/postinst configure
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift residuel"* ]]
  FAKE_PROVISION_RC=1 script lcars/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"ECHEC"*"dpkg --configure lcars"* ]]
}

@test "postinst lcars : sans siege (ni SUDO_USER ni LCARS_SYSADMIN_UID) c'est un REFUS nomme, jamais root" {
  unset SUDO_USER
  script lcars/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun siege"* ]]
  [ ! -s "$TRACE" ]
  # et LCARS_SYSADMIN_UID suffit, sans SUDO_USER
  LCARS_SYSADMIN_UID="$(id -u)" script lcars/postinst configure
  [ "$status" -eq 0 ]
  grep -q -- "--human $(id -un) " "$TRACE"
}

@test "postinst lcars : SUDO_USER=root n'est pas un siege" {
  SUDO_USER=root script lcars/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun siege"* ]]
}

# ─── lcars/prerm + postrm : le plan, la copie, puis remove / purge ──────────────────────────────

@test "prerm lcars : le PLAN s'imprime sans --yes, avec les drapeaux du postrm, et le desinstalleur est COPIE" {
  script lcars/prerm remove
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(trace_args)" = "uninstall --keep-state --dpkg lcars" ]
  [ -x "$LCARS_UNINSTALL_STASH/deploy/provision" ]
  [ -f "$LCARS_UNINSTALL_STASH/deploy/system.manifest" ]
  [ -d "$LCARS_UNINSTALL_STASH/deploy/lib" ]
  # 0700, a root (ici : a l'appelant) — et jamais un mkdir -p sur un chemin pre-existant
  [ "$(stat -c '%a' "$LCARS_UNINSTALL_STASH")" = "700" ]
  grep -q 'mkdir -m 0700 -- "$STASH"' "$PKG/lcars/prerm"
  refute grep -q 'mkdir -p -- "$STASH"$' "$PKG/lcars/prerm"
}

@test "prerm lcars : upgrade et deconfigure ne planifient rien" {
  script lcars/prerm upgrade 0.9.1; [ "$status" -eq 0 ]
  script lcars/prerm deconfigure in-favour x; [ "$status" -eq 0 ]
  [ ! -s "$TRACE" ]; [ ! -e "$LCARS_UNINSTALL_STASH" ]
}

@test "postrm lcars remove : le desinstalleur de la COPIE tourne avec --yes --keep-state --dpkg lcars ; la copie reste pour le purge" {
  script lcars/prerm remove; [ "$status" -eq 0 ]; : > "$TRACE"
  script lcars/postrm remove
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(trace_args)" = "uninstall --yes --dpkg lcars --keep-state" ]
  [[ "$output" == *"l'etat reste"* ]]
  [ -x "$LCARS_UNINSTALL_STASH/deploy/provision" ]
}

@test "postrm lcars purge : sans --keep-state, et la copie est effacee apres" {
  script lcars/prerm remove; [ "$status" -eq 0 ]; : > "$TRACE"
  script lcars/postrm purge
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(trace_args)" = "uninstall --yes --dpkg lcars" ]
  [ ! -e "$LCARS_UNINSTALL_STASH" ]
}

@test "postrm lcars purge SANS copie : le repli retire l'etat lui-meme et DIT ce qui reste" {
  mkdir -p "$PROV_ROOT/var/tokens"; : > "$PROV_ROOT/var/tokens/x"; : > "$LCARS_ETC_DIR/services.env"
  script lcars/postrm purge
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$PROV_ROOT/var" ]
  [ ! -e "$LCARS_ETC_DIR" ]
  [ ! -e "$PROV_ROOT" ]           # vide : rmdir
  [[ "$output" == *"aucun desinstalleur"*"RESTENT : les comptes et groupes de service"* ]]
  [ ! -s "$TRACE" ]
}

@test "postrm lcars remove SANS copie : rien n'est retire, et le geste manuel est nomme" {
  script lcars/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"RIEN n'a ete retire"*"provision uninstall --yes --keep-state --dpkg lcars"* ]]
}

# ─── lcars-workstation ──────────────────────────────────────────────────────────────────────────

@test "postinst workstation : lcars-forge VOULU par dpkg (meme pas encore configure) = 48 49 rejoints au rail, tries" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  FAKE_WANT_lcars_forge=install script lcars-workstation/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(only_of "$(trace_args)")" = "44 45 46 48 49 60 61 62 63 64 65 66" ]
  [[ "$output" == *"forge est MONTEE ici"* ]]
}

@test "postinst workstation : sans lcars-forge, FORGE_BASE_URL (env) suffit — 48 49 absents, l'URL voyage" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  FORGE_BASE_URL=https://forge.exemple script lcars-workstation/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(only_of "$(trace_args)")" = "44 45 46 60 61 62 63 64 65 66" ]
  grep -q 'FORGE_BASE_URL=https://forge.exemple' "$TRACE"
  [[ "$output" == *"forge FOURNIE"* ]]
}

@test "postinst workstation : sans lcars-forge, /etc/lcars/forge.conf (l'administrateur) donne l'URL" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  printf 'FORGE_BASE_URL=https://forge.conf.exemple\n' > "$LCARS_FORGE_CONF"
  script lcars-workstation/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -q 'FORGE_BASE_URL=https://forge.conf.exemple' "$TRACE"
}

@test "postinst workstation : ni lcars-forge ni URL = REFUS avec les deux gestes ; rien n'est applique" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  script lcars-workstation/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune forge"*"apt install lcars-forge"*"forge.conf"* ]]
  [ ! -s "$TRACE" ]
}

@test "postinst workstation : sans canal deb, REFUS — lcars n'est pas configure" {
  rm -f "$LCARS_CHANNEL_FILE"
  FAKE_WANT_lcars_forge=install script lcars-workstation/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"canal n'est pas « deb »"* ]]
}

@test "postrm workstation : les unites de la TABLE sont arretees (disable --now) PUIS retirees, et daemon-reload suit" {
  # un manifeste de decor : des unites sous $T, jamais celles de la machine
  cat > "$T/opt/deploy/system.manifest" <<EOM
# SOURCE: decor
anchor    $T/etc/systemd/system/lcars-landing.service    0644  root:root  wsl+linux
anchor    $T/etc/systemd/system/lcars-converger.service  0644  root:root  wsl+linux
anchor    $T/etc/lcars/services.env                      0640  root:fleet wsl+linux
link      $T/etc/systemd/system/multi-user.target.wants/lcars-landing.service - - wsl+linux
EOM
  mkdir -p "$T/etc/systemd/system"; : > "$T/etc/systemd/system/lcars-landing.service"; : > "$T/etc/systemd/system/lcars-converger.service"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$TRACE"\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
  export LCARS_SYSTEMCTL="$T/bin/systemctl"
  [[ -d /run/systemd/system ]] || skip "pas de systemd sur ce poste (/run/systemd/system) — la branche « pas de systemd » est jouee ci-dessous"
  script lcars-workstation/postrm remove
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qx 'systemctl disable --now lcars-landing.service' "$TRACE"
  grep -qx 'systemctl disable --now lcars-converger.service' "$TRACE"
  grep -qx 'systemctl daemon-reload' "$TRACE"
  refute grep -q 'services.env' "$TRACE"
  [ ! -e "$T/etc/systemd/system/lcars-landing.service" ]
  [[ "$output" == *"2 unite(s) arretee(s) et retiree(s)"* ]]
  # l'ordre : disable AVANT le retrait du fichier — la ligne du script le tient
  local n_dis n_rm
  n_dis="$(grep -n 'disable --now' "$PKG/lcars-workstation/postrm" | head -1 | cut -d: -f1)"
  n_rm="$(grep -n 'rm -f -- "$unit"' "$PKG/lcars-workstation/postrm" | head -1 | cut -d: -f1)"
  [ "$n_dis" -lt "$n_rm" ]
}

@test "postrm workstation : sans la table (lcars deja parti), rien, et c'est dit" {
  rm -f "$T/opt/deploy/system.manifest"
  script lcars-workstation/postrm purge
  [ "$status" -eq 0 ]
  [[ "$output" == *"table introuvable"* ]]
}

# ─── lcars-forge ────────────────────────────────────────────────────────────────────────────────

@test "postinst forge : 48 49 61, la forge est MONTEE (PROV_FORGE_MONTEE=1)" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  script lcars-forge/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(only_of "$(trace_args)")" = "48 49 61" ]
  grep -q 'PROV_FORGE_MONTEE=1' "$TRACE"
}

docker_decor() { # une CLI docker de decor jointe par la sonde de la lib (meme forme que uninstall.bats S3)
  export DOCKER_LOG="$T/docker.log"; : > "$DOCKER_LOG"
  cat > "$T/bin/docker-decor" <<'CLI'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  version) exit "${FAKE_DOCKER_RC:-0}" ;;
  compose) exit 0 ;;
  ps)      for c in ${FAKE_CTRS:-}; do echo "$c"; done; exit 0 ;;
  volume)  case "$2" in ls) for v in ${FAKE_VOLS:-}; do echo "$v"; done ;; rm) ;; esac; exit 0 ;;
esac
exit 0
CLI
  chmod +x "$T/bin/docker-decor"
  export PROV_DOCKER_BIN="$T/bin/docker-decor"
  export DOCKER_HOST="unix://$T/decor.sock" LCARS_DOCKER_SOCKETS="$T/absent.sock"
}

@test "postrm forge remove : forge ET runner descendent par la sonde de la lib, les volumes sont GARDES et nommes" {
  docker_decor
  printf 'params PROV_FORGE_BASE=bob PROV_DECK_PORT=20999\n' > "$LCARS_JOURNAL_FILE"
  FAKE_VOLS="bob-forge_data" script lcars-forge/postrm remove
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qx 'compose -p bob-forge down' "$DOCKER_LOG"
  grep -qx 'compose -p bob-runner down' "$DOCKER_LOG"
  refute grep -q 'volume rm' "$DOCKER_LOG"
  [[ "$output" == *"volume bob-forge_data GARDE"* ]]
}

@test "postrm forge purge : les volumes partent, et chacun est dit" {
  docker_decor
  FAKE_VOLS="lcars-forge_data" script lcars-forge/postrm purge
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qx 'compose -p lcars-forge down' "$DOCKER_LOG"      # la base par defaut de la lib
  grep -qx 'volume rm lcars-forge_data' "$DOCKER_LOG"
  [[ "$output" == *"volume lcars-forge_data RETIRE (purge)"* ]]
}

@test "postrm forge : daemon injoignable = rien de touche, la cause (PROV_DOCKER_WHY) et les projets sont dits, rc 0" {
  docker_decor
  FAKE_DOCKER_RC=1 script lcars-forge/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker injoignable"*"lcars-forge"*"lcars-runner"* ]]
  refute grep -q 'compose -p' "$DOCKER_LOG"     # la sonde de la lib, elle, a le droit de parler a la CLI
}

# ─── lcars-container ────────────────────────────────────────────────────────────────────────────

@test "postrm container purge : l'instance et ses volumes sont LISTES, jamais detruits — et remove pareil" {
  docker_decor
  FAKE_CTRS="c0ffee" FAKE_VOLS="lcars-fleet_home" script lcars-container/postrm purge
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"lcars-fleet TOURNE ENCORE"*"docker compose -p lcars-fleet down"* ]]
  [[ "$output" == *"volumes de lcars-fleet GARDES"*"lcars-fleet_home"* ]]
  refute grep -qE 'volume rm|compose .* down|rm ' "$DOCKER_LOG"
  : > "$DOCKER_LOG"
  script lcars-container/postrm remove
  [ "$status" -eq 0 ]
  refute grep -qE 'volume rm|down' "$DOCKER_LOG"
}

@test "postrm container : aucune instance = rien a dire, rc 0" {
  docker_decor
  script lcars-container/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucune instance"* ]]
}

# ─── lcars-bench : PROV_DEMO_HUMAN ──────────────────────────────────────────────────────────────

@test "postinst bench : sur le rail natif, l'humain de demo (defaut lcars) part a la recette par LCARS_BUILTIN_HUMAN, 61 63 64, et le nom est note dans l'etat" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  FAKE_WANT_lcars_workstation=install script lcars-bench/postinst configure
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(only_of "$(trace_args)")" = "61 63 64" ]
  grep -q 'LCARS_BUILTIN_HUMAN=lcars ' "$TRACE"
  grep -q 'PROV_FORGE_MONTEE=1' "$TRACE"
  [ "$(cat "$LCARS_DEMO_HUMAN_FILE")" = "lcars" ]
}

@test "postinst bench : PROV_DEMO_HUMAN nomme l'humain ; un nom qui n'est pas un login est refuse" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  FAKE_WANT_lcars_workstation=install PROV_DEMO_HUMAN=zoe script lcars-bench/postinst configure
  [ "$status" -eq 0 ]
  grep -q 'LCARS_BUILTIN_HUMAN=zoe ' "$TRACE"
  [ "$(cat "$LCARS_DEMO_HUMAN_FILE")" = "zoe" ]
  FAKE_WANT_lcars_workstation=install PROV_DEMO_HUMAN='Zoé Bidule' script lcars-bench/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un login"* ]]
}

@test "postinst bench : l'humain de demo ne peut pas etre le SIEGE — le postrm le retirerait avec son home" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  FAKE_WANT_lcars_workstation=install PROV_DEMO_HUMAN="$(id -un)" script lcars-bench/postinst configure
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne peut pas etre le siege"* ]]
  [ ! -s "$TRACE" ]
}

@test "postinst bench : sur le rail conteneur (pas de lcars-workstation), il ne seme rien, le dit, et sort a 0" {
  printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  script lcars-bench/postinst configure
  [ "$status" -eq 0 ]
  [[ "$output" == *"bench-up.sh"* ]]
  [ ! -s "$TRACE" ]
  [ ! -e "$LCARS_DEMO_HUMAN_FILE" ]
}

ids_decor() { # id / getent / userdel / pkill doubles : « zoe » existe (uid 1500), le reste est reel
  cat > "$T/bin/id" <<'ID'
#!/usr/bin/env bash
if [[ "$1" == -u && "$2" == -- ]]; then
  case "$3" in zoe) echo 1500; exit 0 ;; siege) echo 1000; exit 0 ;; *) exit 1 ;; esac
fi
exec /usr/bin/id "$@"
ID
  cat > "$T/bin/getent" <<'GE'
#!/usr/bin/env bash
if [[ "$1" == passwd ]]; then echo "${*: -1}:x:1500:1500::/home/${*: -1}:/bin/bash"; exit 0; fi
exec /usr/bin/getent "$@"
GE
  printf '#!/usr/bin/env bash\necho "userdel $*" >> "$TRACE"\nexit "${FAKE_USERDEL_RC:-0}"\n' > "$T/bin/userdel"
  printf '#!/usr/bin/env bash\necho "pkill $*" >> "$TRACE"\n' > "$T/bin/pkill"
  chmod +x "$T/bin/id" "$T/bin/getent" "$T/bin/userdel" "$T/bin/pkill"
  printf '1000\n' > "$LCARS_SEAT_UID_FILE"
}

@test "postrm bench : l'humain note dans l'etat est retire AVEC son home (userdel -r), ses process tues avant, et la note effacee" {
  ids_decor; printf 'zoe\n' > "$LCARS_DEMO_HUMAN_FILE"
  PATH="$T/bin:$PATH" script lcars-bench/postrm remove
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qx 'pkill -u zoe' "$TRACE"
  grep -qx 'userdel -r -- zoe' "$TRACE"
  [[ "$output" == *"« zoe » retire, home compris (/home/zoe)"* ]]
  [ ! -e "$LCARS_DEMO_HUMAN_FILE" ]
}

@test "postrm bench : le SIEGE, root ou l'appelant ne sont JAMAIS retires, meme notes comme humain de demo" {
  ids_decor; printf 'siege\n' > "$LCARS_DEMO_HUMAN_FILE"     # uid 1000 = seat.uid
  PATH="$T/bin:$PATH" script lcars-bench/postrm purge
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFUS"*"le siege ou l'appelant"* ]]
  refute grep -q 'userdel' "$TRACE"
  [ -e "$LCARS_DEMO_HUMAN_FILE" ]
  : > "$TRACE"; printf '%s\n' "$(id -un)" > "$LCARS_DEMO_HUMAN_FILE"
  PATH="$T/bin:$PATH" script lcars-bench/postrm remove
  [ "$status" -eq 0 ]
  refute grep -q 'userdel' "$TRACE"
}

@test "postrm bench : compte deja absent = rien, la note part ; userdel qui refuse = dit, la note reste" {
  ids_decor; printf 'inconnu\n' > "$LCARS_DEMO_HUMAN_FILE"
  PATH="$T/bin:$PATH" script lcars-bench/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"n'existe pas"* ]]
  [ ! -e "$LCARS_DEMO_HUMAN_FILE" ]
  printf 'zoe\n' > "$LCARS_DEMO_HUMAN_FILE"
  FAKE_USERDEL_RC=8 PATH="$T/bin:$PATH" script lcars-bench/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"a refuse"* ]]
  [ -e "$LCARS_DEMO_HUMAN_FILE" ]
}

@test "postrm bench : sans note, personne n'est retire" {
  script lcars-bench/postrm remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun humain de demo enregistre"* ]]
}

@test "prerm bench et prerm forge : ils DISENT, ils ne font rien" {
  printf 'zoe\n' > "$LCARS_DEMO_HUMAN_FILE"
  script lcars-bench/prerm remove
  [ "$status" -eq 0 ]; [[ "$output" == *"« zoe » sera retire AVEC son home"* ]]
  [ -e "$LCARS_DEMO_HUMAN_FILE" ]
  script lcars-forge/prerm remove
  [ "$status" -eq 0 ]; [[ "$output" == *"VOLUMES restent"* ]]
  [ ! -s "$TRACE" ]
}
