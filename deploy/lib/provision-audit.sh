#!/usr/bin/env bash
# SOURCE: deploy/lib/provision-audit.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: `provision audit` — ce qui est apparu sur la machine entre deux instantanés et que system.manifest ne déclare pas ; sourcé par provision

audit_run() {
  local avant="${1:-}" apres="${2:-}"
  [[ -r "$avant" && -r "$apres" ]] \
    || die "audit attend deux instantanés lisibles : provision audit --before <f> --after <f>"
  [[ -r "$PROV_MANIFEST_FILE" ]] || die "manifeste introuvable ($PROV_MANIFEST_FILE)"

  local rows; rows="$(grep -vE '^\s*#|^\s*$' "$PROV_MANIFEST_FILE")"
  local -a declares=()
  local obj
  while read -r _ obj _; do declares+=("$obj"); done <<<"$rows"

  couvert() {
    local p="$1" d
    for d in "${declares[@]}"; do
      [[ "$d" == /* ]] || continue
      case "$d" in
        *"<"*) d="${d%%<*}"; [[ -n "$d" && "$p" == "$d"* ]] && return 0 ;;
        *)     [[ "$p" == "$d" || "$p" == "$d"/* ]] && return 0 ;;
      esac
    done
    return 1
  }

  local -A _apt=()
  if [[ -r "$PROV_JOURNAL_FILE" ]] && command -v dpkg >/dev/null 2>&1; then
    local _pkg _f
    # shellcheck disable=SC2013
    for _pkg in $(awk '$1=="apt_installed"{ $1=""; print }' "$PROV_JOURNAL_FILE"); do
      while read -r _f; do [[ -n "$_f" ]] && _apt["$_f"]=1; done < <(dpkg -L "$_pkg" 2>/dev/null || true)
    done
  fi

  local n_apparu=0 n_nu=0 n_apt=0 p
  while read -r p; do
    [[ -n "$p" ]] || continue
    n_apparu=$((n_apparu + 1))
    [[ -n "${_apt[$p]:-}" ]] && { n_apt=$((n_apt + 1)); continue; }
    couvert "$p" || { n_nu=$((n_nu + 1)); printf '  %s\n' "$p"; }
  done < <(comm -13 <(cut -d' ' -f4- "$avant" | sort) <(cut -d' ' -f4- "$apres" | sort))

  echo ""
  printf '  %d objet(s) apparu(s), %d appartenant à un paquet apt journalisé, %d non couvert(s) par la table.\n' \
    "$n_apparu" "$n_apt" "$n_nu"
  [[ -r "$PROV_JOURNAL_FILE" ]] \
    || echo "  ${_PA}journal illisible ($PROV_JOURNAL_FILE) — les fichiers des paquets apt sont comptés comme non déclarés${_PN}"
  [[ "$n_nu" -eq 0 ]] || {
    echo "  ${_PA}Chacun est un défaut : soit il se déclare, soit il cesse d'être posé.${_PN}"
    return 1
  }
  echo "  ${_PG}Rien n'est apparu entre les deux instantanés que la table ne déclare.${_PN}"
}
