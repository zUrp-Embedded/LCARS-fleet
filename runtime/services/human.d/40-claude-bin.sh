#!/usr/bin/env bash
# SOURCE: runtime/services/human.d/40-claude-bin.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — binaire claude PER-HUMAIN (~/.local/bin) via l'installer officiel
# JOUE PAR : le convergeur d'humains, pour chaque humain de la fleet, dans l'ordre des noms.
# Ni terrain ni dependance ne se declarent ici : ces en-tetes ne sont lus que dans
# `deploy/modules.d`, et les recopier ici promettait une mecanique que personne ne joue.
# ⚠ TOUTE MACHINERIE AJOUTÉE ICI DOUBLE LA SIENNE ET NE PEUT QUE DIVERGER D'ELLE. L'installeur
# vérifie son sha256 contre un manifeste signé, nettoie derrière lui sur CHAQUE branche d'échec,
# installe pour l'utilisateur courant et nomme ses morts (dont l'OOM killer). Un staging, un
# remplacement atomique ou une sonde de hash de notre côté ne rendent aucune de ces propriétés
# meilleure : ils en fabriquent une seconde version, plus faible, qui vieillit toute seule.
# Notre seule sonde est FONCTIONNELLE et reste à nous : le binaire répond --version.
#
# ⚠ UNE SEULE SOURCE, L'INSTALLEUR OFFICIEL. Pas de seconde source — un `$LCARS_CLAUDE_SEED`, binaire
# déjà posé sur la machine par un geste extérieur (un semis de banc) que ce module préférerait au
# réseau : elle vieillirait seule, et le module devrait alors choisir entre deux vérités.
# `claude_bin.bats` tient cette occurrence-ci pour la seule.

set -euo pipefail
# L'hote nomme le protocole per-humain (LCARS_HUMAN_PROTOCOL) : le convergeur, ou un temoin. Le
# contrat de ce dialecte est dans le fichier source, il ne se recopie pas ici.
# shellcheck source=../lib/human-protocol.sh
. "${LCARS_HUMAN_PROTOCOL:?LCARS_HUMAN_PROTOCOL non posé — lance via human-converger, pas le module nu}"

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
    p_drift "claude absent pour $LCARS_LOGIN ($bin)"
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
    # ⚠ SA CAUSE LA PLUS FRÉQUENTE NE SE VOIT PAS DANS SA PLAINTE. L'installeur prend l'artefact
    # COMPRESSÉ quand `zstd` est là, et le binaire NU sinon — 230 Mo. Sur un lien ordinaire le
    # téléchargement n'aboutit pas, et il le dit en « somme de contrôle » sur un fichier qui
    # n'existe même pas (mesuré le 2026-09-17 sur LCARS-beta : aucun humain n'avait `claude`).
    # `10-packages` pose `zstd` ; une machine qui ne l'a pas mérite de l'entendre ici.
    if ! command -v zstd >/dev/null 2>&1; then
      p_fail "installeur officiel en échec, et « zstd » manque a cette machine — sans lui il telecharge le binaire NU (230 Mo) au lieu de l'artefact compresse, et sa plainte parle d'une somme de controle. Poser zstd (10-packages le declare), puis rejouer"
    else
      p_fail "installeur officiel en échec"
    fi
    verdict_apply
  fi
  rm -rf "$tmp"

  if claude_ok; then
    LCARS_CHANGED=$((LCARS_CHANGED + 1))
    p_chg "claude posé pour $LCARS_LOGIN ($(human_bin), version $("$(human_bin)" --version 2>/dev/null | head -1))"
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
