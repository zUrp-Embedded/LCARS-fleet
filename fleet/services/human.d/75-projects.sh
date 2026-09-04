#!/usr/bin/env bash
# SOURCE: fleet/services/human.d/75-projects.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — les faces locales des projets, convergees depuis la forge
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
# AFTER: 45-catalogues 63-forge-tokens 70-human
# JOUE COMME L'HUMAIN. Les faces lui appartiennent (owner `$PROV_HUMAN`, groupe `fleet`), et un
# import joue en root les poserait root:root — un `/home` que le proprietaire ne peut plus ecrire.
# C'est aussi son `~/.lcars/fleet_v2.env` qui porte l'adresse de la forge et le jeton.

set -euo pipefail
# Le protocole des modules per-humain, cote PRODUIT (Q3, 2026-09-04) : l'hote — le convergeur, ou
# un temoin — nomme le fichier. Ce module sourcait la lib de l'INSTALLEUR, que son hote reel ne
# posait pas : il mourait ici, a chaque humain, sur les deux rails.
# shellcheck source=../lib/human-protocol.sh
. "${LCARS_HUMAN_PROTOCOL:?LCARS_HUMAN_PROTOCOL non posé — lance via human-converger, pas le module nu}"

LCARS_CLI="$PROV_LINK_DIR/lcars"

#
# Sortie : les lignes de verdict sur stdout, la sortie brute du release sur stderr. Les deux sont
# separees DELIBEREMENT — un `2>&1` melangerait les avertissements du BEAM aux verdicts et les
# ferait lire comme des projets. Rendu : le code de la porte (0 tout converge · 1 au moins un
# ECHEC · 2 au moins un MANQUE), ou 127 si la porte n'a meme pas pu etre jouee.
#
# ⚠ CETTE FONCTION TOURNE DANS UNE SUBSHELL chez ses appelants (`out="$(door check)"`), donc elle
# n'utilise que `p_warn` : les compteurs de `p_fail`/`p_drift` s'incrementeraient dans la subshell
# et seraient perdus au retour. Le verdict se rend chez l'appelant, jamais ici.
door() { # <check|apply>  → verdicts sur stdout
  local mode="$1" err out rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/prov-reconcile.XXXXXX")"

  out="$("$LCARS_CLI" project reconcile "$mode" 2>"$err")" || rc=$?
  printf '%s\n' "$out"

  if [[ -z "$out" || "$rc" -gt 2 ]] && [[ -s "$err" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && p_warn "porte reconcile : $line"
    done < "$err"
  fi

  rm -f "$err"
  return "$rc"
}

render() { # <mode> ; lit les verdicts sur stdin
  local mode="$1" word repo rest seen=0
  while read -r word repo rest; do
    [[ -n "$word" ]] || continue
    seen=1
    case "$word" in
      RIEN)    p_ok "aucun projet declare dans les catalogues installes" ;;
      DEJA)    p_ok "$repo" ;;
      IMPORTE) p_chg "$repo — trois faces posees depuis la forge" ;;
      MANQUE)  p_drift "$repo est sur la forge et absent de cette boite — « lcars project reconcile apply »" ;;
      ECHEC)   p_fail "$repo : ${rest#— }" ;;
      *)       p_fail "verdict illisible de la porte reconcile ($mode) : $word $repo $rest" ;;
    esac
  done
  [[ "$seen" -eq 1 ]]
}

#
# Deux absences, deux traitements. Sans forge il n'y a pas d'autorite a comparer : on le DIT et on
# sort conforme — une boite hors ligne n'est pas une boite en derive. Sans release il n'y a pas de
# porte du tout, et `60-deploy` a deja drifte dessus : le redire en echec ici ferait deux alarmes
# pour une panne.
usable() {
  # shellcheck disable=SC2119 # argument OPTIONNEL : sans lui la fonction sonde l'uid COURANT,
  # ce qui est exactement la question posee ici.
  if ! is_fleet_human; then
    p_ok "$PROV_HUMAN n'est pas un humain de fleet (compte systeme ou sysadmin) — les projets sont converges par les humains, pas par ce cycle"
    return 1
  fi
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_warn "FORGE_BASE_URL non posé — les projets de cette boite n'ont pas d'autorite a suivre"
    return 1
  fi
  if [[ ! -x "$LCARS_CLI" ]]; then
    p_warn "$LCARS_CLI absent — le release n'est pas installe (cf. 60-deploy)"
    return 1
  fi
  return 0
}

check() {
  usable || verdict_check

  local out rc=0
  out="$(door check)" || rc=$?

  if [[ "$rc" -gt 2 ]]; then
    p_fail "la porte reconcile a echoue (code $rc) — l'etat des projets n'a pas pu etre lu"
    verdict_check
  fi

  render check <<< "$out" || p_fail "la porte reconcile n'a rien rendu (code $rc)"
  verdict_check
}

apply() {
  usable || verdict_apply

  local out rc=0
  out="$(door apply)" || rc=$?

  if [[ "$rc" -gt 2 ]]; then
    p_fail "la porte reconcile a echoue (code $rc) — aucun projet n'a ete importe"
    verdict_apply
  fi

  render apply <<< "$out" || p_fail "la porte reconcile n'a rien rendu (code $rc)"
  verdict_apply
}

case "${1:?usage: 75-projects.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
