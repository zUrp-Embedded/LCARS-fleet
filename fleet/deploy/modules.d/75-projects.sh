#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/75-projects.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — les faces locales des projets, convergees depuis la forge
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
#
# LA FORGE SAIT QUELS PROJETS EXISTENT, LE DISQUE NE LE SAIT PLUS.
#
# Un projet vit en deux moities : le depot sur la forge (l'autorite : issues, PR, branches,
# historique) et ses trois faces locales sous /home/projects{,.ops,.workshop} (le plan de travail
# des pods). La seconde moitie est reconstructible depuis la premiere — c'est exactement ce que
# `import/2` fait, et il est idempotent. Ce module est ce qui la reconstruit sans qu'on le demande.
#
# ⚠ L'INVENTAIRE N'EXISTAIT NULLE PART. Le runtime enumere ses projets depuis le DISQUE
# (`Onboard.list_projects/1` lit `code_root`) : sur une boite neuve, apres un nuke, ou pour un
# second humain qui arrive sur une fleet deja peuplee, il n'y a rien a enumerer — alors que les
# projets, eux, sont intacts sur la forge. La liste ne pouvait donc pas venir d'ici.
#
# CE MODULE N'A AUCUNE LOGIQUE DE PROJET, ET C'EST VOULU. Il relaie une porte du release
# (`Fleet.Project.Onboard.eval_reconcile/1`, via `lcars project reconcile`), qui parle en MOTS —
# DEJA / MANQUE / IMPORTE / ECHEC, un par ligne. Reimplementer ici le filtre « qu'est-ce qui est un
# projet » mettrait une seconde autorite a cote de celle qui cree les projets, dans un autre
# langage : c'est le tour exact que `45-catalogues` a paye en lisant l'etat installe deux fois.
#
# JOUE COMME L'HUMAIN. Les faces lui appartiennent (owner `$PROV_HUMAN`, groupe `fleet`), et un
# import joue en root les poserait root:root — un `/home` que le proprietaire ne peut plus ecrire.
# C'est aussi son `~/.lcars/fleet_v2.env` qui porte l'adresse de la forge et le jeton.
#
# APRES 45-catalogues (le materiel des catalogues installes, dont ce module tire la liste des orgs),
# 50-forge (les comptes et les jetons) et 70-human (le compte Unix, son HOME et son env).
#
# `APPLY-ON: any` et pas l'enumeration des trois substrats, qui vaudrait pourtant la meme chose
# aujourd'hui : les faces ne sont bâties NULLE PART ailleurs — ni au stage image, ni au build —
# donc ce module doit muter partout. Une liste exhaustive ferait taire son apply le jour ou un
# quatrieme substrat apparait, sans un mot.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

LCARS_CLI="$PROV_LINK_DIR/lcars"

# ─── la porte, et rien d'autre ────────────────────────────────────────────────────────────────────
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

  out="$(as_human "$LCARS_CLI" project reconcile "$mode" 2>"$err")" || rc=$?
  printf '%s\n' "$out"

  # LE CRI DE LA PORTE EST REPRIS DES QU'ON NE PEUT PAS LIRE SON VERDICT, et la condition est
  # « aucune ligne rendue », PAS un code de sortie particulier. Mesure du 2026-08-17 : la porte est
  # morte en plein import sur `no process` (une VM `eval` n'a pas de superviseur de spawn), avec un
  # rc de 1 — dans la fourchette normale — et ZERO ligne sur stdout. Le module a rendu « la porte
  # n'a rien rendu (code 1) » et a jete la seule chose qui disait pourquoi.
  if [[ -z "$out" || "$rc" -gt 2 ]] && [[ -s "$err" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && p_warn "porte reconcile : $line"
    done < "$err"
  fi

  rm -f "$err"
  return "$rc"
}

# Les mots de la porte deviennent les verdicts du provisioning. UNE ligne inconnue est un echec, pas
# un silence : un format qui derive doit se voir au premier run, pas se lire comme « rien a faire ».
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

# ─── la garde commune ─────────────────────────────────────────────────────────────────────────────
#
# Deux absences, deux traitements. Sans forge il n'y a pas d'autorite a comparer : on le DIT et on
# sort conforme — une boite hors ligne n'est pas une boite en derive. Sans release il n'y a pas de
# porte du tout, et `60-deploy` a deja drifte dessus : le redire en echec ici ferait deux alarmes
# pour une panne.
usable() {
  # ⚠ LE CYCLE DE BOOT NE PARLE PAS D'UN HUMAIN DE FLEET. L'entrypoint conteneur joue tous les
  # modules `# NEEDS: human` avec `--human <sysadmin>` — juste pour ce qui appartient au sysadmin,
  # faux pour des faces de projet : elles seraient posees sous le seul compte qui ne peut pas
  # lancer de fleet, et le git de l'humain qui les utilise ensuite les refuserait (proprietaire
  # different). Les vrais humains passent par `human-converger.sh`, qui calcule sa liste de modules
  # depuis ce meme en-tete `# NEEDS: human` : ce module les atteint sans etre nomme nulle part.
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
