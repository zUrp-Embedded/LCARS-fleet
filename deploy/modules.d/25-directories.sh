#!/usr/bin/env bash
# SOURCE: deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: l'arborescence système — /opt/lcars et ses zones, les zones de face sous /home, les dossiers de /run et leur déclaration tmpfiles
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups 21-service-accounts

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

_PROV_CONSOLE_HUMAN=""
prov_console_human() { # prov_console_human → l'humain intégré si le geste de forge le nomme et qu'il existe, sinon l'humain de la passe
  [[ -n "$_PROV_CONSOLE_HUMAN" ]] && { echo "$_PROV_CONSOLE_HUMAN"; return 0; }
  local h
  h="$(bash "$(product_tree)/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  if [[ -z "$h" ]] || ! id -u -- "$h" >/dev/null 2>&1; then
    h="$PROV_HUMAN"
  fi
  _PROV_CONSOLE_HUMAN="$h"
  echo "$h"
}

# /run est un tmpfs : rien au build de l'image (l'init de l'instance le pose au boot), et sans systemd aucune déclaration tmpfiles n'a de sens
prov_runtime_dirs() {
  [[ "${PROV_SUBSTRATE:-$(detect_substrate)}" != docker ]] || return 0
  local h; h="$(prov_console_human)"
  printf '%s\n' \
    "/run/lcars 0755 root:root" \
    "/run/lcars/console 0711 root:root" \
    "/run/lcars/console/$h 2710 $h:$PROV_CONSOLE_GROUP" \
    "/run/lcars/authority 0750 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    "/run/lcars/privileged 0750 root:$PROV_FLEET_GROUP" \
    "/run/lcars/toolchain 2775 root:$PROV_FLEET_GROUP"
}

prov_dirs() {
  printf '%s\n' \
    "$PROV_ROOT 0755 root:root" \
    "$PROV_PREFIX 0750 root:$PROV_FLEET_GROUP" \
    "$PROV_TOKENS_DIR 0710 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_DIR 0750 root:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_WORK 0700 $PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" \
    "/home/projects 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.ops 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.workshop 2775 root:$PROV_FLEET_GROUP" \
    "/var/lib/lcars 0755 root:root" \
    "/var/tmp/lcars 0755 root:root" \
    "/var/tmp/lcars/toolchain-work 0700 root:root" \
    "/etc/lcars 0755 root:root"
  prov_runtime_dirs
}

# le substrat d'une entrée se lit dans system.manifest (cinquième colonne), pas dans une seconde table ici
prov_container_volumes() { printf '%s\n' /home "$PROV_ROOT/var"; }

prov_dir_scope() { # prov_dir_scope <chemin> → here | substrate | volume
  local path="$1" sub col v
  sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  col="$(prov_manifest_substrate "$path")"
  if [[ -n "$col" ]] && ! prov_substrate_satisfait "$col" "$sub"; then
    echo substrate; return 0
  fi
  if [[ "$sub" == docker ]]; then
    while read -r v; do
      if [[ "$path" == "$v" || "$path" == "$v"/* ]]; then echo volume; return 0; fi
    done < <(prov_container_volumes)
  fi
  echo here
}

say_unmeasured() { # say_unmeasured <hors substrat> <sur volume> — ce qui n'est pas mesuré se dit, sans compter
  local sub; sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  if [[ -n "$1" ]]; then p_warn "hors substrat $sub selon le manifeste — non mesuré :$1"; fi
  if [[ -n "$2" ]]; then p_warn "sur un volume du conteneur — pas de vérité au build, l'init de l'instance les pose :$2"; fi
  return 0
}

prov_tmpfiles_conf() { echo "${LCARS_TMPFILES_CONF:-/etc/tmpfiles.d/lcars-console.conf}"; }

prov_tmpfiles_body() {
  echo "# Généré par 25-directories.sh — /run est un tmpfs, ces dossiers s'y refont à chaque boot."
  echo "# Ne pas éditer : la source est la table prov_runtime_dirs du module."
  local path mode owner
  while read -r path mode owner; do
    printf 'd %s %s %s %s -\n' "$path" "$mode" "${owner%%:*}" "${owner##*:}"
  done < <(prov_runtime_dirs)
}

check() {
  local spec path mode owner cur hors_substrat="" hors_build=""
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    case "$(prov_dir_scope "$path")" in
      substrate) hors_substrat="$hors_substrat $path"; continue ;;
      volume)    hors_build="$hors_build $path"; continue ;;
    esac
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent"
      continue
    fi
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done < <(prov_dirs)
  say_unmeasured "$hors_substrat" "$hors_build"
  check_tmpfiles
  verdict_check
}

runtime_dirs_declared() { [[ -n "$(prov_runtime_dirs)" ]]; }

check_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  if ! runtime_dirs_declared; then
    [[ -e "$conf" ]] && p_drift "tmpfiles: $conf présent alors que ce substrat ne le porte pas"
    return 0
  fi
  if [[ ! -f "$conf" ]]; then
    p_drift "tmpfiles: $conf absent — /run/lcars/console ne se refera pas au reboot, et la fleet ne démarrera pas"
  elif [[ "$(cat "$conf")" != "$(prov_tmpfiles_body)" ]]; then
    p_drift "tmpfiles: $conf ne correspond plus à la table du module"
  else
    p_ok "tmpfiles: $conf"
  fi
}

apply() {
  local spec path mode owner hors_substrat="" hors_build=""
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    case "$(prov_dir_scope "$path")" in
      substrate) hors_substrat="$hors_substrat $path"; continue ;;
      volume)    hors_build="$hors_build $path"; continue ;;
    esac
    ensure_dir "$path" "$mode" "$owner" || true
  done < <(prov_dirs)
  say_unmeasured "$hors_substrat" "$hors_build"
  apply_tmpfiles
  verdict_apply
}

# le fichier vaut pour le prochain boot ; ce boot-ci est déjà convergé par apply, et --create jugerait tout /etc/tmpfiles.d
apply_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  local body; body="$(prov_tmpfiles_body)"
  if [[ -z "${body//[$'\n'[:space:]#]/}" ]] || ! runtime_dirs_declared; then
    if [[ -e "$conf" ]]; then
      if rm -f "$conf"; then p_ok "tmpfiles: déclaration retirée ($conf) — ce substrat ne la porte pas"
      else p_fail "tmpfiles: déclaration périmée ($conf) impossible à retirer — le boot suivant obéira encore à un ordre que ce module a désavoué"
      fi
    fi
    return 0
  fi
  if [[ ! -d "$(dirname "$conf")" ]]; then
    p_drift "tmpfiles: $(dirname "$conf") absent — les dossiers de /run ne se referont pas au reboot"
    return 0
  fi
  write_atomic "$conf" 0644 <<<"$body" || { p_fail "tmpfiles: $conf"; return 1; }
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    p_ok "tmpfiles: $conf posé — /run/lcars/console se refera au reboot"
  else
    p_drift "tmpfiles: $conf posé mais systemd-tmpfiles est absent — au reboot, /run/lcars/console ne sera pas recréé et la fleet ne démarrera pas tant que « provision apply » n'aura pas rejoué"
  fi
}

case "${1:?usage: 25-directories.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
