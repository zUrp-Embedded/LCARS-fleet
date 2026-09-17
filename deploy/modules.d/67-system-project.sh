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
# ⚠ ET IL PASSE SA SOURCE, `--from $(repo_root)` : l'arbre dont cette machine a été installée. OÙ la
# face de code va (`/home/projects/<projet>`) reste une décision de `Fleet.Layout` — la recomposer
# ici en ferait une seconde écriture. Le rail conteneur clone cette face à l'init ; le rail POSTE
# n'y mettait rien, et l'adoption refusait en `no_local_main` à chaque passe (mesuré le 2026-09-17,
# banc 2003). Une face déjà en place n'est jamais touchée : la porte ne sème que dans le vide.
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
# ⚠ ET IL PASSE LA TABLE DE TRANSPORT (MUR 7). La porte parle a la forge : sans `FORGE_BASE_URL`,
# elle refuse en « missing :base_url » — mesure du 2026-09-17 sur le banc 2003, ou le semis de la
# face avait reussi et l'adoption tombait juste apres. Ce que l'installeur DECIDE et que le produit
# lit voyage par cette table, jamais par une variable recomposee ici.
as_siege() { PROV_HUMAN="$SIEGE" as_human env ${PROV_PRODUCT_ENV[@]+"${PROV_PRODUCT_ENV[@]}"} "$@"; }

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

# ⚠ LE VERDICT EST SUR STDOUT, LE RESTE SUR STDERR, ET ON NE LES MELANGE PAS. La porte reclame
# stdout pour elle seule (`ReleaseDoor.claim_stdout!`) precisement pour qu'une ligne de journal ne
# passe pas devant : le BEAM en emet, et fusionner les deux flux mettait « [warning] Authority… »
# avant « SEEDED … », donc aucun motif ne correspondait et le module rendait OK sur une ligne VIDE
# (mesure du 2026-09-17, banc 2003). Le flux d'erreur sert a NOMMER une cause, jamais a lire un
# verdict.
#
# La sortie de la porte est UNE ligne : « ADOPTED <org>/<nom> », « ALREADY <org>/<nom> »,
# « SEEDED <org>/<nom> », ou un refus sur stderr. On la relaie telle quelle : elle nomme son objet,
# et un module qui la reformulerait perdrait l'adresse exacte.
porte_dit() { # porte_dit <arg…> → stdout de la porte dans PORTE_OUT, sa plainte dans PORTE_ERR ; rend son code
  local err; err="$(mktemp)" || { p_fail "aucun fichier temporaire — la plainte de la porte serait perdue"; return 1; }
  local rc=0
  PORTE_OUT="$(as_siege "$CLI" project "$@" 2>"$err")" || rc=$?
  PORTE_ERR="$(tail -n1 "$err" 2>/dev/null || true)"
  rm -f "$err"
  return "$rc"
}

jouer() { # jouer <verbe> — 0 conforme · 1 drift
  local out rc=0
  prov_product_env
  porte_dit adopt-system --from "$(repo_root)" || rc=$?
  out="$PORTE_OUT"

  case "$rc" in
    0)
      case "$out" in
        ADOPTED*) PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "${out#ADOPTED } publié — la source de cette machine est un projet de sa fleet" ;;
        ALREADY*) p_ok "${out#ALREADY } déjà publié" ;;
        # LE DEPOT A SON POSEUR : `61-forge-structure` joue le geste qui le crée et y pousse la
        # source, avec le jeton master. Ce module tient la FACE LOCALE, et le dit comme tel.
        SEEDED*)  p_ok "${out#SEEDED } : face de code en place — le dépôt est posé par la structure de la forge (61)" ;;
        # une porte qui rend 0 SANS RIEN DIRE n'est pas une porte conforme : un statut nu ne dit
        # rien a qui lit un journal, et c'est exactement ce qu'un flux fusionne produisait
        *)        p_drift "verdict illisible du projet du système : « ${out:-<rien>} »${PORTE_ERR:+ — $PORTE_ERR}"; return 1 ;;
      esac
      return 0
      ;;
    *)
      p_drift "projet du système NON publié — ${PORTE_ERR:-${out:-aucune plainte}}"
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
  prov_product_env
  porte_dit adopt-system --check --from "$(repo_root)" || rc=$?
  out="$PORTE_OUT"
  [[ "$rc" -eq 0 ]] || { p_fail "mesure du projet du système impossible — ${PORTE_ERR:-aucune plainte}"; verdict_check; }

  case "$out" in
    ALREADY*)    p_ok "${out#ALREADY } déjà publié" ;;
    SEEDED*)     p_ok "${out#SEEDED } : face de code en place — le dépôt est posé par la structure de la forge (61)" ;;
    ABSENT*)     p_drift "${out#ABSENT } absent de la forge — « lcars project adopt-system » le publie (l'apply de ce module le fait)" ;;
    NOSOURCE*)   p_warn "${out#NOSOURCE } : cette machine ne porte pas la source dont elle a été installée — rien à publier (kit sans arbre, ou clone jamais posé)" ;;
    UNREADABLE*) p_drift "état de ${out#UNREADABLE } NON mesurable — la forge n'a pas répondu, rien n'est conclu" ;;
    *)           p_fail "mesure illisible du projet du système : « ${out:-<rien>} »${PORTE_ERR:+ — $PORTE_ERR}" ;;
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
