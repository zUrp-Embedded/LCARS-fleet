#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/40-claude-bin.sh
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
# DEUX SOURCES, et la GRAINE passe avant le réseau. `$PROV_CLAUDE_SEED` (défaut dans provision-lib)
# est un binaire déjà posé sur la machine par un geste EXTÉRIEUR — un semis de banc, une image
# pré-chargée. S'il répond `--version`, on le copie et on ne télécharge rien. Raison d'être : une
# boîte NEUVE sans réseau n'obtient aucun binaire, donc aucun pod ne démarre, et la fleet a l'air
# saine en ne produisant rien. La graine est root-owned et HORS de tout home : l'humain du runtime
# n'existe pas encore quand un semis extérieur la pose (l'entrypoint le crée au boot).
#
# La graine est une SOURCE, jamais une destination : le binaire final vit dans le home de l'humain
# comme avant, posé par le même remplacement atomique. Les deux chemins partagent `install_bin` —
# un `mv` non atomique sur l'un des deux serait un binaire tronqué que rien ne distingue.

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
# Partagé par les deux sources (graine et installeur) : un des deux chemins non atomique poserait
# exactement le défaut que l'autre évite.
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

  # LA GRAINE D'ABORD. Un binaire déjà sur la machine rend le réseau inutile ; l'ordre est le
  # contrat, pas une optimisation (cf. en-tête). La sonde est fonctionnelle — un fichier exécutable
  # qui ne répond pas à `--version` n'est pas un binaire, c'est un piège, et on retombe sur
  # l'installeur plutôt que de poser ça dans le home de l'humain.
  local seed="${PROV_CLAUDE_SEED:-}"
  # Sonde NUE, jamais `run_quiet` : run_quiet compte tout échec via p_fail (« l'échec COMPTE »,
  # cf. lib B1), donc une graine qui répond « non » ferait échouer le module au lieu de le faire
  # retomber sur l'installeur. Une sonde qui répond non n'est pas une panne, c'est une réponse.
  if [[ -n "$seed" && -x "$seed" ]] && "$seed" --version >/dev/null 2>&1; then
    if install_bin "$seed" "$home" "$bin"; then
      if claude_ok; then
        PROV_CHANGED=$((PROV_CHANGED + 1))
        p_chg "claude posé depuis la graine $seed (aucun réseau) — $bin, version $(as_human "$bin" --version 2>/dev/null | head -1)"
        verdict_apply
      fi
      p_fail "graine $seed copiée mais --version ne répond pas depuis $bin"
      verdict_apply
    fi
    # Graine présente et vivante mais non copiable : c'est un défaut de la machine, pas une raison
    # de télécharger 100 Mo par-dessus. On le DIT et on s'arrête là.
    p_fail "graine $seed lisible mais non copiable vers $bin"
    verdict_apply
  fi

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
