#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/45-sudoers-toolchain.sh
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — les quatre ancrages systeme du domaine admiral (sudoers etroit, etat
#         conteneur, projection du login du siege, skill du siege)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
#   2. l'ETAT CONTENEUR du reconciliateur (`/run/lcars/toolchain` — un TMPFS : il meurt avec le
#      conteneur PAR CONSTRUCTION, et aucun volume ne peut le recouvrir ; 2775 root:fleet) : le
#      marqueur `toolchain.applied` decrit L'ETAT DE /usr, qui meurt avec le conteneur. Le poser
#      sur le magasin (volume externe, survit au rebuild) faisait dire « a jour » a une boite
#      reconstruite dont /usr etait revenu a la baseline — l'exact mensonge que `01` §4.5 refuse.
#
#   4. le SKILL `system-issues` dans le `~/.claude` du SIEGE (`05` §7) : la boite de reception
#      d'admiral, posee par le provisioning et JAMAIS par le catalogue — un skill du catalogue
#      serait montable dans un pod par deux fautes de frappe ; celui-ci ne vit que chez le siege.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

SUDOERS_DIR="${LCARS_SUDOERS_DIR:-/etc/sudoers.d}"
SUDOERS_FILE="$SUDOERS_DIR/lcars-toolchain"
RUN_STATE="${LCARS_TOOLCHAIN_RUN_STATE:-/run/lcars/toolchain}"
SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
SKILL_SRC="${LCARS_ADMIRAL_SKILLS_SRC:-}"
if [[ -z "$SKILL_SRC" ]]; then
  _skills_image="${LCARS_HELPERS_DIR:-/opt/lcars}/admiral-skills"
  if [[ -d "$_skills_image" ]]; then
    SKILL_SRC="$_skills_image"
  else
    SKILL_SRC="$(repo_root)/fleet/deploy/admiral/skills"
  fi
fi

check() {
  if [[ -e "$SUDOERS_FILE" ]]; then
    p_drift "IL RESTE UN CHEMIN groupe → root : $SUDOERS_FILE existe encore — l'apply le retire (le geste d'outillage passe par toolchain.sock depuis ce chantier)"
  else
    p_ok "aucune règle sudoers pour l'outillage ($SUDOERS_FILE absent)"
  fi
  if [[ -d "$RUN_STATE" ]]; then
    p_ok "etat conteneur du reconciliateur ($RUN_STATE)"
  else
    p_drift "etat conteneur absent ($RUN_STATE) — le reconciliateur n'aura pas de memoire"
  fi
  local _uid; _uid="$(id -u -- "$PROV_HUMAN" 2>/dev/null || true)"
  if [[ "$_uid" == "$SYSADMIN_UID" ]]; then
    local _home; _home="${LCARS_SIEGE_HOME:-$(getent passwd -- "$PROV_HUMAN" | cut -d: -f6)}"
    if [[ -x "$_home/.claude/skills/system-issues/list.sh" ]]; then
      p_ok "skill system-issues present chez $PROV_HUMAN"
    else
      p_drift "skill system-issues ABSENT chez $PROV_HUMAN — la boite de reception est illisible depuis sa session"
    fi
  fi

  if [[ -n "${LCARS_STORE_ROOT:-}" && -d "${LCARS_STORE_ROOT:-/nonexistent}" ]]; then
    if [[ -s "$LCARS_STORE_ROOT/state/pilot.assignee" ]]; then
      p_ok "projection du siege ($(cat "$LCARS_STORE_ROOT/state/pilot.assignee"))"
    else
      p_drift "projection du siege absente — les issues systeme s'ouvriront sans assignee"
    fi
  else
    p_ok "magasin non monte — projection du siege inerte (DR-023, nominal avant le lot F)"
  fi
  verdict_check
}

apply() {
  if [[ -e "$SUDOERS_FILE" ]]; then
    if rm -f "$SUDOERS_FILE"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "chemin groupe → root RETIRÉ ($SUDOERS_FILE) — le geste d'outillage passe par toolchain.sock"
    else
      p_fail "$SUDOERS_FILE non retiré — le groupe $PROV_FLEET_GROUP garde un NOPASSWD root"
      verdict_apply
    fi
  fi

  # ⚠ LE GROUPE RESTE UN GESTE SEPARE ET TOLERANT, ET C'EST DELIBERE. `ensure_dir … "root:$GROUPE"`
  # etait la forme evidente : elle `p_fail`-e des que le chown est refuse, donc elle transforme en
  # ECHEC ce que ce module classe en DERIVE depuis toujours — un reconciliateur qui ne peut pas
  # noter n'est pas une machine cassee. (Et `ensure_mode` ne sait comparer que `<user>:`, pas
  # `:<groupe>` : lui apprendre la forme miroir pour un seul appelant serait une capacite pour rien.)
  ensure_dir "$RUN_STATE" 2775 \
    || p_drift "etat conteneur ($RUN_STATE) non convergé — le reconciliateur de toolchain ne pourra pas noter"
  chgrp "$PROV_FLEET_GROUP" "$RUN_STATE" 2>/dev/null \
    || p_drift "etat conteneur: chgrp $PROV_FLEET_GROUP a echoue — le reconciliateur ne pourra pas noter"

  local uid
  uid="$(id -u -- "$PROV_HUMAN" 2>/dev/null || true)"
  if [[ "$uid" == "$SYSADMIN_UID" ]]; then
    if [[ -d "$SKILL_SRC/system-issues" ]]; then
      local home skdst
      home="${LCARS_SIEGE_HOME:-$(getent passwd -- "$PROV_HUMAN" | cut -d: -f6)}"
      if [[ -n "$home" && -d "$home" ]]; then
        skdst="$home/.claude/skills/system-issues"
        if ensure_dir "$skdst" 0755 "$PROV_HUMAN:"; then
          write_atomic "$skdst/SKILL.md" 0644 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/SKILL.md" || p_fail "skill system-issues: SKILL.md"
          write_atomic "$skdst/list.sh"  0755 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/list.sh"  || p_fail "skill system-issues: list.sh"
          # `-h` : on ne dereference pas. `ensure_dir` a deja refuse les liens du chemin, ceci ferme
          # la fenetre entre les deux gestes — et ne coute rien sur un vrai repertoire.
          chown -h "$PROV_HUMAN:" "$home/.claude" "$home/.claude/skills" "$skdst" 2>/dev/null || true
          p_ok "skill system-issues pose chez $PROV_HUMAN"
        else
          p_drift "skill system-issues: $skdst non convergé — RIEN n'est posé chez $PROV_HUMAN"
        fi
      else
        p_drift "skill system-issues: home de $PROV_HUMAN introuvable"
      fi
    else
      p_drift "skill system-issues: source absente ($SKILL_SRC) — image sans les sources admiral ?"
    fi

    if [[ -n "${LCARS_STORE_ROOT:-}" && -d "$LCARS_STORE_ROOT" ]]; then
      # ⚠ LA TOLERANCE EST DELIBEREE — le volume peut etre monte en lecture seule, et la projection
      # n'est pas vitale. Mais elle ne dispense pas de la GARDE : `prov_refuse_symlink_path` refuse
      # un lien dans le chemin AVANT qu'un `install -d` en root le suive. `ensure_dir` ne convient
      # pas ici : il `p_fail`-e, donc il ferait compter un echec la ou on en tolere un.
      # shellcheck disable=SC2015 # `install -d` PEUT echouer, et le `|| true` est justement le
      # contrat : ce pas est tolere. Un if/then/else le ferait tuer le module sous `set -e`.
      prov_refuse_symlink_path "$LCARS_STORE_ROOT/state" \
        && install -d -m 2775 "$LCARS_STORE_ROOT/state" 2>/dev/null || true
      if write_atomic "$LCARS_STORE_ROOT/state/pilot.assignee" 0644 <<<"$PROV_HUMAN"; then
        p_ok "projection du siege : $PROV_HUMAN -> pilot.assignee"
      else
        p_fail "projection du siege : ecriture impossible"
      fi
    else
      p_ok "magasin non monte — projection du siege inerte (DR-023)"
    fi
  fi

  verdict_apply
}

case "${1:?usage: 45-sudoers-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
