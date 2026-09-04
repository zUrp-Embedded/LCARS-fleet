#!/usr/bin/env bash
# SOURCE: deploy/lib/provision-audit.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — l'audit de la machine (`provision audit`) de `provision`, sourcé par lui (lot 10 : le runner ne porte plus que le runner)
#
# Ce fichier n'est pas un programme : `provision` le source apres sa lib, avec ses globales
# (SUBSTRATE, JOURNAL_FILE, SELF, les drapeaux) en place. Il n'a pas de garde `PROVISION_LIB:?`
# parce qu'il n'est lisible que par le runner qui le source.

# ─── audit — LA TABLE CONTRE LA MACHINE ─────────────────────────────────────────────────────────
audit_run() {
  local avant="${1:-}" apres="${2:-}"
  [[ -r "$avant" && -r "$apres" ]] \
    || die "audit attend deux instantanes lisibles : provision audit --before <f> --after <f>"
  [[ -r "$MANIFEST_FILE" ]] || die "manifeste introuvable ($MANIFEST_FILE)"

  local rows; rows="$(grep -vE '^\s*#|^\s*$' "$MANIFEST_FILE")"
  local -a declares=()
  local cls obj _mode _owner sub
  # shellcheck disable=SC2034
  while read -r cls obj _mode _owner sub; do declares+=("$obj"); done <<<"$rows"  # le trait ne change pas la couverture

  couvert() {
    local p="$1" d
    for d in "${declares[@]}"; do
      # ⚠ UN JOKER EN TETE (`person <human>`) N'EST PAS UN CHEMIN, ET SON PREFIXE VIDE COUVRAIT
      # L'UNIVERS : `[[ "$p" == ""* ]]` est vrai de tout. Relecture hostile du 2026-09-04 : deux
      # chemins bidon rendaient « la machine ne porte rien que la table ne declare ».
      [[ "$d" == /* ]] || continue
      case "$d" in
        *"<"*) d="${d%%<*}"; [[ -n "$d" && "$p" == "$d"* ]] && return 0 ;;
        *)     [[ "$p" == "$d" || "$p" == "$d"/* ]] && return 0 ;;
      esac
    done
    return 1
  }

  # ⚠ ET IL SE JOUE SUR LA MACHINE DANS L'ETAT QUE DECRIT SON « APRES », PAS PLUS TARD : `dpkg -L`
  # interroge ce qui est installe MAINTENANT. Rejoue apres une desinstallation, il ne rend plus rien
  # et les fichiers des paquets ressortent tous comme non declares.
  local -A _apt=()
  local _dpkg="${LCARS_DPKG:-dpkg}"
  if [[ -r "$JOURNAL_FILE" ]] && command -v "$_dpkg" >/dev/null 2>&1; then
    local _pkg _f
    # ⚠ ECLATEMENT VOULU : `apt_installed` porte UNE ligne de noms separes par des espaces, et c'est
    # le mot qu'on veut, pas la ligne. Un `while read` lirait la ligne entiere comme un seul paquet.
    # shellcheck disable=SC2013
    for _pkg in $(awk '$1=="apt_installed"{ $1=""; print }' "$JOURNAL_FILE"); do
      while read -r _f; do [[ -n "$_f" ]] && _apt["$_f"]=1; done < <("$_dpkg" -L "$_pkg" 2>/dev/null || true)
    done
  fi

  local n_apparu=0 n_nu=0 n_apt=0 p
  while read -r _t _m _o p; do
    [[ -n "$p" ]] || continue
    n_apparu=$((n_apparu + 1))
    [[ -n "${_apt[$p]:-}" ]] && { n_apt=$((n_apt + 1)); continue; }
    couvert "$p" || { n_nu=$((n_nu + 1)); printf '  %s\n' "$p"; }
  done < <(comm -13 <(sort "$avant") <(sort "$apres"))

  echo ""
  printf '  %d objet(s) apparu(s), %d appartenant a un paquet apt journalise, %d NON couvert(s) par la table.\n' \
    "$n_apparu" "$n_apt" "$n_nu"
  [[ -r "$JOURNAL_FILE" ]] \
    || echo "  ${_PA}⚠ journal illisible ($JOURNAL_FILE) — les fichiers des paquets apt sont comptes comme non declares${_PN}"
  [[ "$n_nu" -eq 0 ]] || {
    echo "  ${_PA}Chacun est un DEFAUT : soit on le declare, soit on cesse de le poser.${_PN}"
    return 1
  }
  echo "  ${_PG}La machine ne porte rien que la table ne declare.${_PN}"
}
