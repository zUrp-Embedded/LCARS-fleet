#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/40-claude-bin.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — binaire claude PER-HUMAIN (~/.local/bin) via l'installer officiel
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
#
# Frontière vendor N1 : ce module est le SEUL du provisioning à connaître Anthropic. Le contrat
# aval est bin/claude_launch.sh (runtime) : binaire résolu via LCARS_CLAUDE_BIN sinon PATH du pod
# (~/.local/bin en tête) — « JAMAIS le /usr/local apt ». Le /usr/local/bin/claude system-wide de
# la v1 est le VIEUX modèle (users-par-rôle partageant un binaire root) : ici, per-humain, sous
# SON UID, dans SON home (le pod bwrap bind le home ⇒ le binaire suit l'humain).
#
# Méthode : DEUX GESTES. On télécharge l'installeur officiel, on l'exécute. Rien d'autre.
#
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
#
# ⚖ ARBITRAGE USER : « on ne cache pas un binaire anthropic, on fait UNIQUEMENT l'install
# officielle », et pour le banc : « il ne devrait PAS copier le binaire local, il DOIT dérouler le
# compose entièrement et re-dl à chaque tour. C'est moi qui paye la BP, j'ai jamais demandé à
# l'économiser pour 300 Mo. »
#
# LE MOTIF EST UNE QUESTION DE MESURE, pas d'économie. Un banc semé n'exerce pas le chemin de
# déploiement qu'il existe pour mesurer : il rend vert un chemin qu'il n'a pas parcouru, et c'est
# exactement la classe de défaut que ce dépôt traque partout ailleurs. Le motif d'origine de la
# graine — « une boîte NEUVE sans réseau n'obtient aucun binaire, donc aucun pod ne démarre, et la
# fleet a l'air saine en ne produisant rien » — reste VRAI comme description ; ce qui change est la
# réponse. Le bon comportement d'une boîte sans réseau n'est pas de se rabattre sur une copie
# cachée, c'est de REFUSER FORT (cf. le verdict de provisioning publié par l'entrypoint).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

INSTALL_URL="https://claude.ai/install.sh"

human_bin() { echo "$(human_home)/.local/bin/claude"; }

claude_ok() {
  local bin; bin="$(human_bin)"
  # stderr NON étouffé sur la jambe as_human : un doctor lancé par un user tiers échouait
  # l'impersonation en silence et posait un FAUX diagnostic (« binaire cassé ? ») — la vraie
  # cause (identité, p_fail d'as_human) doit atteindre l'opérateur. Révélé par la première
  # passe de parité WSL/docker.
  [[ -x "$bin" ]] && as_human "$bin" --version >/dev/null
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

  local tmp
  tmp="$(as_human mktemp -d "${TMPDIR:-/tmp}/claude-install.XXXXXX")" \
    || { p_fail "tmp d'installeur impossible"; verdict_apply; }

  # DEUX GESTES, DEUX VERDICTS. `curl … | bash` est la forme que le vendor publie ; la séparer est
  # la seule chose que l'ancien échafaudage achetait vraiment — « le réseau n'a pas répondu » et
  # « l'installeur a refusé » appellent deux gestes différents, et un pipe les confond.
  if ! run_quiet as_human curl -fsSL --proto '=https' -m 300 -o "$tmp/install.sh" "$INSTALL_URL"; then
    as_human rm -rf "$tmp"
    p_fail "download de l'installeur en échec ($INSTALL_URL)"
    verdict_apply
  fi

  # ⚠ `</dev/null` : LE BINAIRE VENDOR PORTE UNE TUI, et un tty sur stdin la fait démarrer. Ce
  # module tourne sous `runuser`, donc en ARRIÈRE-PLAN du terminal — un programme qui configure le
  # tty depuis là reçoit `SIGTTOU` et le noyau l'ARRÊTE. Mesuré le 2026-08-22 : 23 minutes en
  # `State: T`, 16 ticks de CPU, et le `timeout 600` d'alors stoppé avec lui, donc incapable de
  # tuer quoi que ce soit. Sans tty, l'installeur reste non interactif et rend un CODE.
  if ! run_quiet as_human bash "$tmp/install.sh" </dev/null; then
    as_human rm -rf "$tmp"
    p_fail "installeur officiel en échec"
    verdict_apply
  fi
  as_human rm -rf "$tmp"

  if claude_ok; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "claude posé pour $PROV_HUMAN ($(human_bin), version $(as_human "$(human_bin)" --version 2>/dev/null | head -1))"
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
