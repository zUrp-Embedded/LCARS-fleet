#!/usr/bin/env bash
# SOURCE: runtime/services/forge.d/ops-repo.sh
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: PROTO-V2 — le depot du systeme (`<org systeme>/_ops`) : VERIFIE, jamais pose ici
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
# `check` et `apply` font la meme mesure : il n'y a rien a appliquer. Le verdict est celui du
# protocole : apply 0 conforme · 1 echec (la forge ne repond pas de facon lisible) · 2 drift (un
# objet manque, la recette le pose) ; check 0 · 1 drift · 2 echec (`verdict_check`).

set -euo pipefail

# L'hote nomme le protocole (LCARS_MODULE_PROTOCOL) : le boot du conteneur, un module de
# l'installeur, ou un temoin. Le contrat de ce dialecte est dans le fichier source.
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:?LCARS_MODULE_PROTOCOL non pose — lance via un module de l installeur ou le boot du conteneur, pas le geste nu}"

# Nue, pas `readonly` : les temoins sourcent la tete d'un module pour epingler une fonction, et un
# second `source` dans le meme shell mourrait en « readonly variable ». Le gel du nom est tenu par
# le contrat `toolchain.branch_single_source`, pas par l'attribut.
OPS_BRANCH="tool_request"
# La branche du registre d'incidents — meme nom que `Fleet.Pilot.IncidentRegistry.Store` (defaut de
# `:pilot_incident_registry_branch`), tenu par ops-repo.bats.
INCIDENTS_BRANCH="incidents"
: "${LCARS_OPS_REPO:=${LCARS_FORGE_ORG}/_ops}"

# Le depot et ses branches sont publics : aucune autorite pour les lire. La protection, elle, ne se
# lit qu'avec un droit d'administration sur le depot — le compte systeme en est proprietaire.
code_of() { # code_of <chemin d'API> → le code HTTP, ou vide si la forge ne repond pas
  curl -sS -o /dev/null -w '%{http_code}' -m 10 "${FORGE_BASE_URL%/}/api/v1$1" 2>/dev/null || true
}

# Le code HTTP est lu AVEC le corps : la forge rend un JSON sur 404 (« The target couldn't be
# found ») comme sur 200, et un corps seul ferait passer une protection ABSENTE pour une protection
# AUTRE. Rendu : « <code> <corps> », code vide si la forge ne repond pas.
protection_of() {
  [[ -r "$LCARS_SYSTEM_TOKEN_FILE" ]] || return 0
  local out
  out="$(forge_curl "$LCARS_SYSTEM_TOKEN_FILE" -sS -m 10 -w '\n%{http_code}' \
       "${FORGE_BASE_URL%/}/api/v1/repos/$LCARS_OPS_REPO/branch_protections/$OPS_BRANCH" 2>/dev/null)" || return 0
  printf '%s %s' "${out##*$'\n'}" "${out%$'\n'*}"
}

REMEDE="la recette de la forge le pose : sur un poste, « deploy/workstation up » ; pour un conteneur, « deploy/container forge-apply » depuis l'hôte"

mesure() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || { p_drift "FORGE_BASE_URL non posé — le dépôt du système n'a pas pu être vérifié"; return 0; }
  if ! curl -fsS -m 10 -o /dev/null "${FORGE_BASE_URL%/}/api/v1/version" 2>/dev/null; then
    p_drift "forge injoignable ($FORGE_BASE_URL) — état du dépôt $LCARS_OPS_REPO INCONNU (ce geste ne conclut pas sans mesure)"
    return 0
  fi

  local code
  code="$(code_of "/repos/$LCARS_OPS_REPO")"
  case "$code" in
    200) ;;
    404) p_drift "dépôt $LCARS_OPS_REPO ABSENT — sans lui aucune demande d'outillage, aucun registre d'incidents, aucune escalade ; $REMEDE"; return 0 ;;
    *)   p_fail "$LCARS_OPS_REPO : la forge ne dit pas s'il existe (HTTP ${code:-sans réponse}) — rien n'est conclu"; return 0 ;;
  esac

  local b manque=0
  for b in "$OPS_BRANCH" "$INCIDENTS_BRANCH"; do
    code="$(code_of "/repos/$LCARS_OPS_REPO/branches/$b")"
    case "$code" in
      200) ;;
      404) manque=1; p_drift "$LCARS_OPS_REPO:$b ABSENTE — $(pourquoi "$b") ; $REMEDE" ;;
      *)   manque=1; p_fail "$LCARS_OPS_REPO:$b : la forge ne dit pas si elle existe (HTTP ${code:-sans réponse})" ;;
    esac
  done
  [[ "$manque" -eq 0 ]] || return 0

  # La protection : sans elle, une demande d'outillage se merge sans signature — un manifeste
  # applique par root sur le conteneur, que personne n'a lu.
  local prot ra ds wl pcode
  [[ -r "$LCARS_SYSTEM_TOKEN_FILE" ]] || {
    p_drift "protection de $LCARS_OPS_REPO:$OPS_BRANCH non sondable — jeton système absent ($LCARS_SYSTEM_TOKEN_FILE), le geste des jetons le minte"
    return 0; }
  prot="$(protection_of)"; pcode="${prot%% *}"; prot="${prot#* }"
  case "$pcode" in
    200) ;;
    404) p_drift "$LCARS_OPS_REPO:$OPS_BRANCH SANS protection — une PR d'outillage se mergerait sans signature ; $REMEDE"; return 0 ;;
    *)   p_fail "protection de $LCARS_OPS_REPO:$OPS_BRANCH illisible (HTTP ${pcode:-sans réponse}) — rien n'est conclu (le compte système lit la protection en tant que propriétaire de l'org)"; return 0 ;;
  esac
  ra="$(jq -r '.required_approvals // empty' <<<"$prot" 2>/dev/null || true)"
  # pas `// empty` : en jq, `false // x` rend x — un `false` lu serait effacé
  ds="$(jq -r 'if .dismiss_stale_approvals == null then "" else (.dismiss_stale_approvals | tostring) end' <<<"$prot" 2>/dev/null || true)"
  wl="$(jq -r '(.approvals_whitelist_username // []) | join(" ")' <<<"$prot" 2>/dev/null || true)"
  if [[ "$ra" == "1" && "$ds" == "true" && -n "$wl" ]]; then
    p_ok "$LCARS_OPS_REPO : dépôt, branches $OPS_BRANCH et $INCIDENTS_BRANCH, protection de $OPS_BRANCH (une approbation de : $wl, réapprobation à chaque push)"
  else
    p_drift "$LCARS_OPS_REPO:$OPS_BRANCH protégée AUTREMENT que la recette ne le dit (approbations « ${ra:-?} », réapprobation « ${ds:-?} », approbateurs « ${wl:-aucun} ») ; $REMEDE"
  fi
}

pourquoi() { # pourquoi <branche> → ce qui manque sans elle
  case "$1" in
    "$OPS_BRANCH")       printf '%s' "un pod qui demande un outil n'a pas de base de PR, et le réconciliateur échoue à chaque tick sur son head" ;;
    "$INCIDENTS_BRANCH") printf '%s' "le pilote ne peut pas écrire son registre d'incidents, et le dira à chaque synchronisation" ;;
  esac
}

case "${1:?usage: ops-repo.sh <check|apply>}" in
  check) mesure; verdict_check ;;
  apply) mesure; verdict_apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
