#!/usr/bin/env bash
# SOURCE: deploy/modules.d/67-system-project.sh
# AUTHOR: bob
# STARDATE: 2026-09-17
# STATUS: LCARS est un projet de la fleet qu'il installe — l'arbre dont cette machine a été installée est publié sur sa propre forge
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 10-packages 25-directories 48-forge-host 60-deploy 61-forge-structure 63-forge-tokens 65-ops-repo
#
# ⚠ CE MODULE N'A PAS DE GESTE `forge.d` : il appelle une PORTE DU RELEASE (« lcars project
# adopt-system »), parce que l'adoption d'un projet est du runtime — trois faces, des labels, une
# protection, un architecte différé. La réécrire en shell serait une seconde implémentation d'un
# geste que le produit tient déjà, et c'est exactement ce que ce chantier retire.
#
# ⚠ ET IL SE JOUE SOUS LE SIÈGE, PAS SOUS ROOT. La porte pose les trois faces locales sous
# `/home/projects*`, qui appartiennent au groupe `fleet` : un git joué en root les poserait
# root:root, et le propriétaire ne pourrait plus y écrire. Même règle que `75-projects` côté humain.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

CLI="$PROV_LINK_DIR/lcars"
# LE SIEGE, LU PAR LA MEME POLITIQUE QUE TOUT L'INSTALLEUR (`prov_seat_uid` : le fichier que
# l'installation pose, puis `LCARS_SYSADMIN_UID`). Le recomposer ici en ferait une seconde lecture.
SIEGE=""
if _uid="$(prov_seat_uid)"; then SIEGE="$(getent passwd "$_uid" | cut -d: -f1 || true)"; fi
as_siege() { PROV_HUMAN="$SIEGE" as_human "$@"; }

usable() {
  if [[ -z "$SIEGE" ]]; then
    p_fail "siège non établi ($PROV_SEAT_UID_FILE absent, et LCARS_SYSADMIN_UID non posé) — les faces du projet lui appartiennent, elles ne se posent pas en root"
    return 1
  fi
  if [[ ! -x "$CLI" ]]; then
    p_drift "$CLI absent — la release n'est pas posée (cf. 60-deploy) ; le projet du système se publiera à la passe suivante"
    return 1
  fi
  if ! forge_up; then
    p_drift "forge muette ($PROV_FORGE_URL) — le projet du système n'a pas de forge où être publié"
    return 1
  fi
  return 0
}

# La sortie de la porte est UNE ligne : « ADOPTED <org>/<nom> », « ALREADY <org>/<nom> », ou un
# refus sur stderr. On la relaie telle quelle : elle nomme son objet, et un module qui la
# reformulerait perdrait l'adresse exacte.
jouer() { # jouer <verbe> — 0 conforme · 1 drift
  local out rc=0
  out="$(as_siege "$CLI" project adopt-system 2>&1)" || rc=$?

  case "$rc" in
    0)
      case "$out" in
        ADOPTED*) PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "${out#ADOPTED } publié — la source de cette machine est un projet de sa fleet" ;;
        ALREADY*) p_ok "${out#ALREADY } déjà publié" ;;
        *)        p_ok "projet du système : $out" ;;
      esac
      return 0
      ;;
    *)
      p_drift "projet du système NON publié — $(printf '%s' "$out" | tail -n1)"
      return 1
      ;;
  esac
}

check() {
  usable || verdict_check
  # `check` ne publie pas : il demande à la porte ce qu'elle ferait. La porte étant idempotente,
  # la seule question mesurable sans écrire est « la forge le porte-t-elle ? », et c'est elle qui
  # répond — un module qui recomposerait l'adresse ici en aurait une seconde écriture.
  local out rc=0
  out="$(as_siege "$CLI" project adopt-system --check 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || { p_fail "mesure du projet du système impossible — $(printf '%s' "$out" | tail -n1)"; verdict_check; }

  case "$out" in
    ALREADY*)    p_ok "${out#ALREADY } déjà publié" ;;
    ABSENT*)     p_drift "${out#ABSENT } absent de la forge — « lcars project adopt-system » le publie (l'apply de ce module le fait)" ;;
    NOSOURCE*)   p_warn "${out#NOSOURCE } : cette machine ne porte pas la source dont elle a été installée — rien à publier (kit sans arbre, ou clone jamais posé)" ;;
    UNREADABLE*) p_drift "état de ${out#UNREADABLE } NON mesurable — la forge n'a pas répondu, rien n'est conclu" ;;
    *)           p_fail "mesure illisible du projet du système : $out" ;;
  esac
  verdict_check
}

apply() {
  usable || verdict_apply
  jouer apply || true
  verdict_apply
}

case "${1:?usage: 67-system-project.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
