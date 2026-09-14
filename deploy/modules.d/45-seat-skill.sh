#!/usr/bin/env bash
# SOURCE: deploy/modules.d/45-seat-skill.sh
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: le skill system-issues dans le ~/.claude du siège — la boîte de réception d'admiral, posée chez lui seul
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
SKILL_SRC="${LCARS_ADMIRAL_SKILLS_SRC:-$(product_tree)/services/admiral/skills}"

HUMAN_UID="$(id -u -- "$PROV_HUMAN" 2>/dev/null || true)"
est_le_siege() { [[ "$HUMAN_UID" == "$SYSADMIN_UID" ]]; }
pas_le_siege() { p_ok "$PROV_HUMAN (uid ${HUMAN_UID:-inconnu}) n'est pas le siège (uid $SYSADMIN_UID) — rien à poser"; }
siege_home() { getent passwd -- "$PROV_HUMAN" | cut -d: -f6 || true; }   # un compte inconnu rend un home vide, que l'apply nomme
skill_pose() { # skill_pose → 0 si le skill posé chez le siège est celui de la source, list.sh exécutable
  local d f; d="$(siege_home)/.claude/skills/system-issues"
  for f in SKILL.md list.sh; do cmp -s "$SKILL_SRC/system-issues/$f" "$d/$f" || return 1; done
  [[ -x "$d/list.sh" ]]
}

check() {
  if ! est_le_siege; then
    pas_le_siege
  elif skill_pose; then
    p_ok "skill system-issues posé chez $PROV_HUMAN"
  else
    p_drift "skill system-issues absent, incomplet ou différent de sa source ($SKILL_SRC/system-issues) chez $PROV_HUMAN — la boîte de réception d'admiral ne se lit pas depuis sa session"
  fi
  verdict_check
}

apply() {
  est_le_siege || { pas_le_siege; verdict_apply; }
  [[ -d "$SKILL_SRC/system-issues" ]] || { p_fail "source du skill absente ($SKILL_SRC/system-issues)"; verdict_apply; }
  local home skdst
  home="$(siege_home)"
  [[ -n "$home" && -d "$home" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_apply; }
  skdst="$home/.claude/skills/system-issues"
  ensure_dir "$skdst" 0755 "$PROV_HUMAN:" || verdict_apply
  write_atomic "$skdst/SKILL.md" 0644 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/SKILL.md" || verdict_apply
  write_atomic "$skdst/list.sh"  0755 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/list.sh"  || verdict_apply
  if chown -h "$(prov_owner "$PROV_HUMAN:")" "$home/.claude" "$home/.claude/skills" "$skdst" 2>/dev/null; then
    p_ok "skill system-issues posé chez $PROV_HUMAN"
  else
    p_drift "skill system-issues posé chez $PROV_HUMAN, mais $home/.claude et $home/.claude/skills n'ont pas pu lui être rendus"
  fi
  verdict_apply
}

case "${1:?usage: 45-seat-skill.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
