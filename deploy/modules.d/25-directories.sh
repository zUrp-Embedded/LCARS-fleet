#!/usr/bin/env bash
# SOURCE: deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: l'arborescence système — /opt/lcars et ses zones, les zones de face sous /home, les dossiers de /run et leur déclaration tmpfiles
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups 21-service-accounts
#
# Ce module dit quels dossiers il pose ; mode, propriétaire et substrat de chacun se lisent dans
# system.manifest.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# l'humain de la console : l'humain de démonstration que le geste de forge nomme, même pas encore créé (64 le
# crée), sinon l'humain de la passe
console_human() {
  local h
  prov_product_env
  h="$(env "${PROV_PRODUCT_ENV[@]}" bash "$(product_tree)/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  printf '%s\n' "${h:-$PROV_HUMAN}"
}
# lu une fois : les tables se lisent dans des sous-shells
CONSOLE_HUMAN="$(console_human)"

TMPFILES_CONF="$(prov_decor /etc/tmpfiles.d/lcars-console.conf)"

# /run est un tmpfs : rien au build de l'image (l'init de l'instance le pose au boot), et sans systemd aucune déclaration tmpfiles n'a de sens
prov_runtime_dirs() {
  [[ "$PROV_SUBSTRATE" != docker ]] || return 0
  printf '%s\n' \
    "$(prov_decor /run/lcars)" \
    "$(prov_decor /run/lcars/console)" \
    "$(prov_decor '/run/lcars/console/<human>')" \
    "$(prov_decor /run/lcars/authority)" \
    "$(prov_decor /run/lcars/privileged)" \
    "$(prov_decor /run/lcars/toolchain)"
}

prov_dirs() {
  printf '%s\n' \
    "$PROV_ROOT" \
    "$PROV_ROOT/var" \
    "$PROV_PREFIX" \
    "$PROV_TOKENS_DIR" \
    "$PROV_CATALOGUES_DIR" \
    "$PROV_CATALOGUES_WORK" \
    "$(prov_decor /home/projects)" \
    "$(prov_decor /home/projects.ops)" \
    "$(prov_decor /home/projects.workshop)" \
    "$PROV_STORE_ROOT" \
    "$(prov_decor /var/tmp/lcars)" \
    "$(prov_decor /var/tmp/lcars/toolchain-work)" \
    "$(prov_decor /etc/lcars)"
  prov_runtime_dirs
}

# lit des chemins sur stdin → « chemin mode propriétaire » ; le joker <human> vaut l'humain de la console
dir_specs() {
  local p mode owner
  while read -r p; do
    mode="$(prov_manifest_mode "$p")"
    owner="$(prov_manifest_owner "$p")"
    printf '%s %s %s\n' "${p//<human>/$CONSOLE_HUMAN}" "${mode:--}" "${owner//<human>/$CONSOLE_HUMAN}"
  done
}

prov_container_volumes() { printf '%s\n' "$(prov_decor /home)" "$PROV_ROOT/var"; }

prov_dir_scope() { # prov_dir_scope <chemin> → here | substrate | volume
  local path="$1" col v
  col="$(prov_manifest_substrate "$path")"
  if [[ -n "$col" ]] && ! prov_substrate_satisfait "$col" "$PROV_SUBSTRATE"; then
    echo substrate; return 0
  fi
  if [[ "$PROV_SUBSTRATE" == docker ]]; then
    while read -r v; do
      if [[ "$path" == "$v" || "$path" == "$v"/* ]]; then echo volume; return 0; fi
    done < <(prov_container_volumes)
  fi
  echo here
}

say_unmeasured() { # say_unmeasured <hors substrat> <sur volume> — ce qui n'est pas mesuré se dit, sans compter
  if [[ -n "$1" ]]; then p_warn "hors substrat $PROV_SUBSTRATE selon le manifeste — non mesuré :$1"; fi
  if [[ -n "$2" ]]; then p_warn "sur un volume du conteneur — pas de vérité au build, l'init de l'instance les pose :$2"; fi
  return 0
}

prov_tmpfiles_body() {
  echo "# Généré par 25-directories.sh — /run est un tmpfs, ces dossiers s'y refont à chaque boot."
  echo "# Ne pas éditer : la source est deploy/system.manifest."
  local path mode owner
  while read -r path mode owner; do
    printf 'd %s %s %s %s -\n' "$(prov_canon "$path")" "$mode" "${owner%%:*}" "${owner##*:}"
  done < <(prov_runtime_dirs | dir_specs)
}

# joue <check|apply> sur chaque dossier de la table ; un dossier que le manifeste ne déclare pas est un échec
parcourir() {
  local verbe="$1" path mode owner cur hors_substrat="" hors_build=""
  while read -r path mode owner; do
    case "$(prov_dir_scope "$path")" in
      substrate) hors_substrat="$hors_substrat $path"; continue ;;
      volume)    hors_build="$hors_build $path"; continue ;;
    esac
    if [[ "$mode" == - ]]; then
      p_fail "$path : absent de system.manifest — ni mode ni propriétaire à poser"
    elif [[ "$verbe" == apply && "${owner%%:*}" == "$CONSOLE_HUMAN" ]] && ! id -u -- "$CONSOLE_HUMAN" >/dev/null 2>&1; then
      p_warn "$path : le compte « $CONSOLE_HUMAN » n'existe pas encore (le convergeur des humains le crée) — le dossier se pose à la passe suivante, ou au boot par tmpfiles"
    elif [[ "$verbe" == apply ]]; then
      ensure_dir "$path" "$mode" "$owner" || true
    elif [[ ! -d "$path" ]]; then
      p_drift "$path absent"
    else
      cur="$(stat -c '%a %U:%G' "$path")"
      owner="$(prov_owner "$owner")"
      if [[ "$cur" == "${mode#0} $owner" ]]; then
        p_ok "$path ($cur)"
      else
        p_drift "$path : $cur ≠ ${mode#0} $owner"
      fi
    fi
  done < <(prov_dirs | dir_specs)
  say_unmeasured "$hors_substrat" "$hors_build"
}

check_tmpfiles() {
  [[ "$PROV_SUBSTRATE" != docker ]] || return 0
  if [[ ! -f "$TMPFILES_CONF" ]]; then
    p_drift "tmpfiles: $TMPFILES_CONF absent — /run/lcars/console ne se refera pas au reboot, et la fleet ne démarrera pas"
  elif [[ "$(cat "$TMPFILES_CONF")" != "$(prov_tmpfiles_body)" ]]; then
    p_drift "tmpfiles: $TMPFILES_CONF ne correspond plus au manifeste"
  else
    p_ok "tmpfiles: $TMPFILES_CONF"
  fi
}

# le fichier vaut pour le prochain boot ; ce boot-ci est déjà convergé par apply, et --create jugerait tout /etc/tmpfiles.d
apply_tmpfiles() {
  [[ "$PROV_SUBSTRATE" != docker ]] || return 0
  local avant="$PROV_CHANGED"
  write_atomic "$TMPFILES_CONF" 0644 <<<"$(prov_tmpfiles_body)" || return 1
  [[ "$PROV_CHANGED" -ne "$avant" ]] || p_ok "tmpfiles: $TMPFILES_CONF conforme"
}

check() {
  parcourir check
  check_tmpfiles
  verdict_check
}

apply() {
  parcourir apply
  apply_tmpfiles || true
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
