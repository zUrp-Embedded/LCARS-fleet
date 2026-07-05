#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/40-claude-bin.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — binaire claude PER-HUMAIN (~/.local/bin) via l'installer officiel, staging jetable
# SUBSTRATE: any
# NEEDS: human
#
# Frontière vendor N1 : ce module est le SEUL du provisioning à connaître Anthropic. Le contrat
# aval est bin/claude_launch.sh (runtime) : binaire résolu via LCARS_CLAUDE_BIN sinon PATH du pod
# (~/.local/bin en tête) — « JAMAIS le /usr/local apt ». Le /usr/local/bin/claude system-wide de
# la v1 est le VIEUX modèle (users-par-rôle partageant un binaire root) : ici, per-humain, sous
# SON UID, dans SON home (le pod bwrap bind le home ⇒ le binaire suit l'humain).
#
# Méthode (pattern v1 conservé — le seul bon de provision-claude-bin) : l'installer officiel
# tourne dans un HOME de staging JETABLE (il pose wrappers/état à sa guise SANS toucher le vrai
# home), puis on copie le binaire RÉSOLU (readlink -f) vers ~/.local/bin/claude. L'ancien binaire
# n'est remplacé QU'APRÈS un download réussi (la v1 faisait rm AVANT download : échec réseau =
# plus d'outil du tout).
#
# Pas de pin/sha : Anthropic ne publie ni hash ni signature (risque supply-chain ASSUMÉ et
# documenté depuis la v0 — la sonde d'intégrité est fonctionnelle : le binaire répond --version).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

INSTALL_URL="https://claude.ai/install.sh"

human_bin() { echo "$(human_home)/.local/bin/claude"; }

claude_ok() {
  local bin; bin="$(human_bin)"
  [[ -x "$bin" ]] && as_human "$bin" --version >/dev/null 2>&1
}

check() {
  local bin; bin="$(human_bin)"
  if claude_ok; then
    p_ok "claude répond ($bin, version $(as_human "$bin" --version 2>/dev/null | head -1))"
  elif [[ -e "$bin" ]]; then
    p_drift "$bin présent mais ne répond pas à --version (binaire cassé ?)"
  else
    p_drift "claude absent pour $PROV_HUMAN ($bin)"
  fi
  verdict_check
}

apply() {
  if claude_ok; then
    verdict_apply   # déjà bon : l'auto-update du binaire est le rail vendor, pas le nôtre
  fi
  local home bin staging
  home="$(human_home)"
  [[ -n "$home" && -d "$home" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_apply; }
  bin="$(human_bin)"

  as_human mkdir -p "$home/.local/bin" || { p_fail "mkdir ~/.local/bin"; verdict_apply; }
  staging="$(as_human mktemp -d "${TMPDIR:-/tmp}/claude-install.XXXXXX")" || { p_fail "staging mktemp"; verdict_apply; }

  # Download-puis-exécute (JAMAIS curl|bash : on veut un artefact inspectable et un échec net).
  # Deux gestes ARGV séparés — pas de string composée passée à bash -c.
  if ! run_quiet as_human curl -fsSL --proto '=https' -m 300 -o "$staging/install.sh" "$INSTALL_URL"; then
    as_human rm -rf "$staging"
    p_fail "download de l'installer en échec ($INSTALL_URL) — l'ancien binaire, s'il existait, est INTACT"
    verdict_apply
  fi
  if ! run_quiet as_human env HOME="$staging" bash "$staging/install.sh"; then
    as_human rm -rf "$staging"
    p_fail "installer officiel en échec — l'ancien binaire, s'il existait, est INTACT"
    verdict_apply
  fi

  # Le binaire résolu du staging (l'installer pose ~/.local/bin/claude, souvent un symlink).
  local staged resolved
  staged="$staging/.local/bin/claude"
  if [[ ! -e "$staged" ]]; then
    as_human rm -rf "$staging"
    p_fail "l'installer n'a pas posé .local/bin/claude dans le staging (layout vendor changé ?)"
    verdict_apply
  fi
  resolved="$(readlink -f "$staged")"

  # Remplacement ATOMIQUE dans le vrai home : cp vers tmp du même dossier puis mv.
  local tmp="$home/.local/bin/.claude.new.$$"
  if ! as_human cp -a "$resolved" "$tmp"; then
    as_human rm -rf "$staging"; p_fail "copie du binaire vers $tmp"; verdict_apply
  fi
  as_human chmod 0755 "$tmp"
  as_human mv -f "$tmp" "$bin"
  as_human rm -rf "$staging"

  if claude_ok; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "claude posé pour $PROV_HUMAN ($bin, version $(as_human "$bin" --version 2>/dev/null | head -1))"
  else
    p_fail "claude posé mais --version ne répond pas ($bin)"
  fi
  verdict_apply
}

case "${1:?usage: 40-claude-bin.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
