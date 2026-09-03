#!/usr/bin/env bash
# SOURCE: deploy/modules.d/40-claude-bin.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — binaire claude PER-HUMAIN (~/.local/bin) via l'installer officiel
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
# AFTER: 20-groups
# ⚠ TOUTE MACHINERIE AJOUTÉE ICI DOUBLE LA SIENNE ET NE PEUT QUE DIVERGER D'ELLE. L'installeur
# vérifie son sha256 contre un manifeste signé, nettoie derrière lui sur CHAQUE branche d'échec,
# installe pour l'utilisateur courant et nomme ses morts (dont l'OOM killer). Un staging, un
# remplacement atomique ou une sonde de hash de notre côté ne rendent aucune de ces propriétés
# meilleure : ils en fabriquent une seconde version, plus faible, qui vieillit toute seule.
# Notre seule sonde est FONCTIONNELLE et reste à nous : le binaire répond --version.
#
# ⚠ UNE SECONDE SOURCE A VÉCU ICI ET N'EXISTE PLUS (2026-08-17) : `$PROV_CLAUDE_SEED`, un binaire
# déjà posé sur la machine par un geste extérieur — un semis de banc — que ce module préférait au
# réseau. NE PAS LA RÉINTRODUIRE.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

INSTALL_URL="https://claude.ai/install.sh"

human_bin() { echo "$(human_home)/.local/bin/claude"; }

claude_ok() {
  local bin; bin="$(human_bin)"
  # stderr NON étouffé : un binaire qui meurt le DIT, et sa plainte est le seul indice qui
  # sépare « cassé » de « absent ». L'étouffer produit un diagnostic qui a l'air sûr et ne l'est pas.
  [[ -x "$bin" ]] && "$bin" --version >/dev/null
}

check() {
  local bin; bin="$(human_bin)"
  if claude_ok; then
    p_ok "claude répond ($bin, version $("$bin" --version 2>/dev/null | head -1))"
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

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-install.XXXXXX")" \
    || { p_fail "tmp d'installeur impossible"; verdict_apply; }

  if ! run_quiet curl -fsSL --proto '=https' -m 300 -o "$tmp/install.sh" "$INSTALL_URL"; then
    rm -rf "$tmp"
    p_fail "download de l'installeur en échec ($INSTALL_URL)"
    verdict_apply
  fi

  # ⚠ `</dev/null` : LE BINAIRE VENDOR PORTE UNE TUI, et un tty sur stdin la fait démarrer. Ce
  # module tourne sous `runuser`, donc en ARRIÈRE-PLAN du terminal — un programme qui configure le
  # tty depuis là reçoit `SIGTTOU` et le noyau l'ARRÊTE. Mesuré le 2026-08-22 : 23 minutes en
  # `State: T`, 16 ticks de CPU, et le `timeout 600` d'alors stoppé avec lui, donc incapable de
  # tuer quoi que ce soit. Sans tty, l'installeur reste non interactif et rend un CODE.
  if ! run_quiet bash "$tmp/install.sh" </dev/null; then
    rm -rf "$tmp"
    p_fail "installeur officiel en échec"
    verdict_apply
  fi
  rm -rf "$tmp"

  if claude_ok; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "claude posé pour $PROV_HUMAN ($(human_bin), version $("$(human_bin)" --version 2>/dev/null | head -1))"
  else
    p_fail "l'installeur a rendu 0 mais $(human_bin) ne répond pas à --version"
  fi
  verdict_apply
}

case "${1:?usage: 40-claude-bin.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
