#!/usr/bin/env bash
# SOURCE: runtime/services/forge.d/ops-repo.sh
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: PROTO-V2 — le depot du systeme (`<org systeme>/_ops`) : APPELANT MINCE de la porte du release
# JOUE PAR : le boot du conteneur (a chaque demarrage) et l'installeur d'un poste, par un
# appelant mince. Ni terrain ni ordre ne se declarent ici : ces en-tetes ne sont lus que dans
# `deploy/modules.d`, et les recopier ici promettait une mecanique que personne ne joue.
#
# ─── LA RECETTE POSE, CE GESTE VERIFIE ──────────────────────────────────────────────────────────
# Le depot, ses trois branches et la protection de `tool_request` sont declares dans la recette de
# la forge (`forge-recipe/ops.tf`) et poses par `forge-gestures apply` — l'org systeme seule. Ce
# geste ne cree RIEN : un runtime ou un geste qui pose ses propres branches est ce qu'on a mesure sur
# le banc beta (⚖ user 2026-09-16) — un registre ecrit sur une branche que rien n'avait creee, 380
# echecs. Ici, ce qui manque est NOMME, et le remede est toujours le meme : rejouer la recette.
#
# ─── LA MESURE VIT DANS LE RELEASE, PAS ICI (phase 7) ───────────────────────────────────────────
# Le client de forge du BEAM est le seul client de la forge ; ce fichier n'est plus qu'un APPELANT
# MINCE. Il rassemble ce qu'il faut pour ouvrir la porte, la joue UNE fois, et relaie chacun de ses
# constats dans le dialecte du protocole. Il ne juge rien : la porte mesure, le protocole compte.
#
# ⚠ UN SEUL EVAL, ET C'EST POURQUOI LA PORTE REND TOUT D'UN COUP. Un `lcars_fleet eval` coute
# 0,27 s et 89 Mo ; un appelant qui en ferait un par question paierait ce prix dix fois.
#
# ⚠ LE JETON PART PAR L'ENVIRONNEMENT, JAMAIS PAR L'ARGV. `/proc/<pid>/environ` n'est lisible que
# par le proprietaire et root ; un argv l'est par tout le monde. Meme forme que
# `forge-gestures.sh` pour `tool catalogue-source`.
#
# `check` et `apply` font la meme mesure : il n'y a rien a appliquer. Le verdict est celui du
# protocole : apply 0 conforme · 1 echec · 2 drift ; check 0 · 1 drift · 2 echec.

set -euo pipefail

# L'hote nomme le protocole (LCARS_MODULE_PROTOCOL) : le boot du conteneur, un module de
# l'installeur, ou un temoin. Le contrat de ce dialecte est dans le fichier source.
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:?LCARS_MODULE_PROTOCOL non pose — lance via un module de l installeur ou le boot du conteneur, pas le geste nu}"

: "${LCARS_OPS_REPO:=${LCARS_FORGE_ORG}/_ops}"

# La CLI du release vient du protocole (`lcars_cli`) : celle que l'appelant designe, celle du PATH,
# sinon la voisine de cet arbre — un seul corps pour tous les gestes.

REMEDE_RELEASE="la release n'est pas posée : sur un poste, « deploy/workstation up » la pose ; dans un conteneur, l'image la porte"

mesure() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || { p_drift "FORGE_BASE_URL non posé — le dépôt du système n'a pas pu être vérifié"; return 0; }

  local cli; cli="$(lcars_cli)"
  [[ -r "$cli" ]] || { p_drift "porte ops-repo injouable ($cli illisible) — $REMEDE_RELEASE"; return 0; }

  # Le jeton SYSTEME : la protection ne se lit qu'avec un droit d'administration sur le depot, et le
  # compte systeme est proprietaire de l'org. Son absence n'est pas une non-conformite du depot :
  # c'est une mesure qu'on ne peut pas faire, et le geste des jetons la rendra possible.
  [[ -r "$LCARS_SYSTEM_TOKEN_FILE" ]] || {
    p_drift "protection de $LCARS_OPS_REPO non sondable — jeton système absent ($LCARS_SYSTEM_TOKEN_FILE), le geste des jetons le minte"
    return 0; }
  local tok; tok="$(tr -d '[:space:]' < "$LCARS_SYSTEM_TOKEN_FILE" || true)"
  [[ -n "$tok" ]] || {
    p_drift "protection de $LCARS_OPS_REPO non sondable — jeton système VIDE ($LCARS_SYSTEM_TOKEN_FILE), le geste des jetons le remintera"
    return 0; }

  # ⚠ STDOUT PORTE LA MESURE, STDERR LA PLAINTE, ET ON NE LES MELANGE PAS : la porte reclame stdout
  # pour elle seule, precisement pour qu'une ligne de journal du BEAM ne passe pas devant un constat.
  local err out rc=0
  err="$(mktemp)" || { p_fail "fichier temporaire impossible à créer (mktemp) — la porte ops-repo n'a pas été jouée"; return 0; }
  out="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN="$tok" bash "$cli" tool ops-repo 2>"$err")" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    p_fail "porte ops-repo en échec (code $rc) — rien n'est conclu sur $LCARS_OPS_REPO : $(tr '\n' ' ' < "$err" | cut -c1-300)"
    rm -f "$err"; return 0
  fi
  rm -f "$err"

  # ⚠ LE SILENCE SE LIRAIT COMME UNE CONFORMITE. Une porte qui ne rend rien n'a rien mesure.
  [[ -n "$out" ]] || { p_fail "porte ops-repo : AUCUNE mesure rendue — rien n'en est conclu sur $LCARS_OPS_REPO"; return 0; }

  local g p
  while IFS=$'\t' read -r g p; do
    [[ -n "$g$p" ]] || continue
    case "$g" in
      ok)    p_ok    "$p" ;;
      drift) p_drift "$p" ;;
      fail)  p_fail  "$p" ;;
      *)     p_fail "porte ops-repo : ligne illisible « $(printf '%s' "$g" | cut -c1-60) » — la mesure n'est pas relayée" ;;
    esac
  done <<< "$out"
}

case "${1:?usage: ops-repo.sh <check|apply>}" in
  check) mesure; verdict_check ;;
  apply) mesure; verdict_apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
