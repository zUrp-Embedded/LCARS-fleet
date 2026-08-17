#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/40-claude-bin.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — binaire claude PER-HUMAIN (~/.local/bin) via l'installer officiel, staging jetable
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
# Méthode (pattern v1 conservé — le seul bon de provision-claude-bin) : l'installer officiel
# tourne dans un HOME de staging JETABLE (il pose wrappers/état à sa guise SANS toucher le vrai
# home), puis on copie le binaire RÉSOLU (readlink -f) vers ~/.local/bin/claude. L'ancien binaire
# n'est remplacé QU'APRÈS un download réussi (la v1 faisait rm AVANT download : échec réseau =
# plus d'outil du tout).
#
# Pas de pin/sha : Anthropic ne publie ni hash ni signature (risque supply-chain ASSUMÉ et
# documenté depuis la v0 — la sonde d'intégrité est fonctionnelle : le binaire répond --version).
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

# Remplacement ATOMIQUE dans le home de l'humain : copie vers un tmp DU MÊME DOSSIER puis `mv`.
# Le même dossier n'est pas un détail — `mv` n'est atomique qu'à l'intérieur d'un système de
# fichiers, et un binaire de ~100 Mo à moitié écrit sous le nom `claude` est indiscernable d'un bon.
# ATOMIQUE, et ça reste vrai avec une seule source : un binaire de ~100 Mo à moitié écrit sous le
# nom `claude` est indiscernable d'un bon.
install_bin() {
  local src="$1" home="$2" dest="$3"
  local tmp="$home/.local/bin/.claude.new.$$"
  as_human cp -a "$src" "$tmp" || return 1
  as_human chmod 0755 "$tmp" || { as_human rm -f "$tmp"; return 1; }
  as_human mv -f "$tmp" "$dest" || { as_human rm -f "$tmp"; return 1; }
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
  # timeout EXTERNE : le script vendor télécharge le binaire (~100 Mo) par un curl SANS timeout
  # à lui — le premier drill docker a laissé l'entrypoint wedgé >5 min dessus. Borne dure,
  # échec verbeux, le boot continue (fail-loud, pas fail-wedged).
  if ! run_quiet as_human timeout 600 env HOME="$staging" bash "$staging/install.sh"; then
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

  if ! install_bin "$resolved" "$home" "$bin"; then
    as_human rm -rf "$staging"; p_fail "copie du binaire vers $bin"; verdict_apply
  fi
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
