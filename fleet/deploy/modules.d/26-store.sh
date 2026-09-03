#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/26-store.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — les MODES du magasin d'outillage, sur les quatre volumes externes
# APPLY-ON: docker
# CHECK-ON: docker
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non pose — lance via ./provision, pas le module nu}"
# shellcheck source=../lib/store.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/store.sh"

store_root() { printf '%s' "${LCARS_STORE_ROOT:-}"; }

prov_store_dirs() {
  printf '%s\n' \
    "cache      2775 root:$PROV_FLEET_GROUP" \
    "toolchains 0755 root:root" \
    "sysroots   0755 root:root" \
    "state      DELEGUE 45-sudoers-toolchain"
}

store_completeness() {
  local tabled declared missing=() extra=()
  tabled="$(prov_store_dirs | awk '{print $1}' | sort)"
  declared="$(printf '%s\n' "${LCARS_STORE_TREES[@]}" | sort)"
  mapfile -t missing < <(set_diff "$tabled" "$declared")
  mapfile -t extra   < <(set_diff "$declared" "$tabled")
  (( ${#missing[@]} == 0 )) || { p_fail "volume sans mode declare ici : ${missing[*]}"; return 1; }
  (( ${#extra[@]} == 0 ))   || { p_fail "mode sans volume dans lib/store.sh : ${extra[*]}"; return 1; }
  return 0
}

check() {
  local root spec sub mode owner path cur
  root="$(store_root)"
  [[ -n "$root" ]] || { p_fail "LCARS_STORE_ROOT absent — le compose ne l'a pas pose"; verdict_check; }
  store_completeness || { verdict_check; }
  while read -r spec; do
    read -r sub mode owner <<< "$spec"
    path="$root/$sub"
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent — volume non monte ?"
      continue
    fi
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$mode" == "DELEGUE" ]]; then
      p_ok "$path ($cur) — mode delegue a $owner"
    elif [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done < <(prov_store_dirs)
  verdict_check
}

apply() {
  local root spec sub mode owner
  root="$(store_root)"
  [[ -n "$root" ]] || { p_fail "LCARS_STORE_ROOT absent — le compose ne l'a pas pose"; verdict_apply; }
  store_completeness || { verdict_apply; }
  while read -r spec; do
    read -r sub mode owner <<< "$spec"
    if [[ "$mode" == "DELEGUE" ]]; then
      [[ -d "$root/$sub" ]] || p_drift "$root/$sub absent — $owner le pose, volume non monte ?"
      continue
    fi
    ensure_dir "$root/$sub" "$mode" "$owner" || verdict_apply
  done < <(prov_store_dirs)
  verdict_apply
}

case "${1:?usage: 26-store.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) echo "26-store.sh: verbe inconnu: $1" >&2; exit 2 ;;
esac
