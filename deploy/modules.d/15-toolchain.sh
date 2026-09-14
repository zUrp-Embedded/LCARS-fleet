#!/usr/bin/env bash
# SOURCE: deploy/modules.d/15-toolchain.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la toolchain de build — Erlang/OTP par apt, à la majeure du précompilé ; Elixir par le zip officiel épinglé
# APPLY-ON: wsl linux docker
# CHECK-ON: wsl linux docker
# NEEDS: root
#
# Elixir vient du zip précompilé officiel d'une majeure OTP, épinglé par version et sha256 dans
# installer-constants.env : la distro LTS sert une minor qu'Elixir ne corrige plus. Erlang est celui
# de la distro, et sa majeure doit être celle du zip. Le module retire les arbres /opt/elixir-* qu'il a
# posés pour une autre version, et les liens de PROV_LINK_DIR qui pointent sous ce préfixe ailleurs que
# sur le pin — jamais un lien de l'opérateur (c'est la cible du lien qui décide), jamais un paquet apt.
# Une livraison binaire n'a rien à compiler : la release embarque son ERTS.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# un binaire présent qui échoue est un état : sous set -e, son code tuerait le module avant son verdict
otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo absent; }
elixir_version() { elixir --short-version 2>/dev/null || echo absent; }

ELIXIR_BINS=(elixir elixirc mix iex)
ELIXIR_PREFIX="$(prov_decor /opt/elixir-)"
ELIXIR_HOME="${ELIXIR_PREFIX}${PROV_ELIXIR_PIN}"
ELIXIR_ZIP_URL="https://github.com/elixir-lang/elixir/releases/download/v${PROV_ELIXIR_PIN}/elixir-otp-${PROV_ELIXIR_OTP_MAJOR}.zip"
# la marque qu'un arbre a été posé ici : sans elle, un /opt/elixir-* n'est jamais retiré
ELIXIR_MARK=.lcars-pose

elixir_version_posee() {
  [[ -x "$ELIXIR_HOME/bin/elixir" ]] || return 0
  "$ELIXIR_HOME/bin/elixir" --short-version 2>/dev/null || true
}

elixir_links_stale() { # les liens de PROV_LINK_DIR qui pointent sous notre préfixe, ailleurs que sur l'arbre du pin
  local b t
  for b in "${ELIXIR_BINS[@]}"; do
    [[ -L "$PROV_LINK_DIR/$b" ]] || continue
    t="$(readlink -m "$PROV_LINK_DIR/$b" 2>/dev/null || true)"
    [[ "$t" == "$ELIXIR_PREFIX"*/* ]] || continue
    [[ "$t" == "$ELIXIR_HOME"/* && -e "$t" ]] || printf '%s\n' "$PROV_LINK_DIR/$b"
  done
  return 0
}

# un glob sans correspondance rend son propre motif : sans -d, un rm -rf recevrait « /opt/elixir-* »
elixir_trees_other() { # les arbres marqués d'une autre version que le pin
  local d
  for d in "$ELIXIR_PREFIX"*; do
    [[ -d "$d" && -f "$d/$ELIXIR_MARK" && "$d" != "$ELIXIR_HOME" ]] && printf '%s\n' "$d"
  done
  return 0
}

elixir_built_for() {
  { elixir --version 2>/dev/null || true; } \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p' | head -1
}

rien_a_batir() { prov_delivery_is_binary; }

mesure_vm() { # mesure_vm <p_drift|p_fail>
  local otp; otp="$(otp_release)"
  if [[ "$otp" == "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    p_ok "Erlang/OTP $otp (paquet apt erlang)"
  else
    "$1" "Erlang/OTP « $otp » — le précompilé d'Elixir est celui de la majeure $PROV_ELIXIR_OTP_MAJOR (paquet apt erlang)"
  fi
}

mesure_elixir() { # mesure_elixir <p_drift|p_fail> — le pin étant posé : l'elixir qui répond, et sa variante
  local ev qui built otp
  ev="$(elixir_version)"
  if [[ "$ev" != "$PROV_ELIXIR_PIN" ]]; then
    # deux causes, deux gestes opposés : refaire notre lien, ou retirer ce qui le masque dans le PATH
    qui="$(command -v elixir 2>/dev/null || true)"
    if [[ -n "$qui" && "$qui" == "$PROV_LINK_DIR"/* ]]; then
      "$1" "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} — c'est NOTRE lien $qui qui pointe sur un autre arbre ($(readlink -f "$qui" 2>/dev/null || echo '?')) ; l'apply le refait pointer sur le pin"
    else
      "$1" "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} (${qui:-introuvable}) — un autre elixir est devant $PROV_LINK_DIR dans le PATH ; c'est LUI qui compile"
    fi
    return 0
  fi
  built="$(elixir_built_for)"; otp="$(otp_release)"
  if [[ "$built" == "$otp" ]]; then
    p_ok "Elixir $ev posé ($ELIXIR_HOME), variante OTP $built (= la VM qui répond)"
  else
    "$1" "Elixir $ev compilé pour OTP « ${built:-illisible} », VM OTP « $otp » — le zip du pin n'est pas celui de cette VM"
  fi
}

check_reliquats() {
  local -a old_links old_trees
  mapfile -t old_links < <(elixir_links_stale)
  mapfile -t old_trees < <(elixir_trees_other)
  if [[ "${#old_links[@]}" -gt 0 ]]; then
    p_drift "lien(s) Elixir vers un arbre qui n'est pas le pin, DEVANT apt dans le PATH : ${old_links[*]} — c'est LUI qui compile"
  fi
  if [[ "${#old_trees[@]}" -gt 0 ]]; then
    p_drift "arbre(s) Elixir d'une autre version que le pin $PROV_ELIXIR_PIN : ${old_trees[*]} — « provision apply » les retire (rm -rf) une fois le pin debout"
  fi
}

check() {
  if rien_a_batir; then
    p_ok "toolchain non requise — livraison binaire, la release est bâtie et embarque son ERTS"
    verdict_check
  fi
  mesure_vm p_drift
  if [[ "$(elixir_version_posee)" != "$PROV_ELIXIR_PIN" ]]; then
    p_drift "Elixir $PROV_ELIXIR_PIN non posé ($ELIXIR_HOME) — l'apply le télécharge (zip officiel, sha256 épinglé)"
  else
    mesure_elixir p_drift
  fi
  check_reliquats
  verdict_check
}

apply() {
  if rien_a_batir; then
    p_ok "erlang et elixir non posés — livraison binaire, rien à bâtir ici"
    verdict_apply
  fi
  # les liens périmés d'abord : tant qu'un lien pointe ailleurs, « elixir » mesure cet ailleurs
  local -a old_links old_trees; local o
  mapfile -t old_links < <(elixir_links_stale)
  for o in "${old_links[@]}"; do
    if rm -f "$o"; then
      p_chg "retiré : $o (lien Elixir vers un arbre qui n'est pas le pin)"
    else
      p_fail "rm $o"; verdict_apply
    fi
  done

  apt_ensure erlang || verdict_apply

  if [[ "$(elixir_version_posee)" == "$PROV_ELIXIR_PIN" ]]; then
    p_ok "Elixir $PROV_ELIXIR_PIN déjà posé ($ELIXIR_HOME)"
  else
    # le zip à côté de l'arbre, jamais dans /tmp ; un crash ne laisse pas un ELIXIR_HOME à moitié écrit
    local parent zip; parent="$(dirname "$ELIXIR_HOME")"; zip="$parent/.elixir-${PROV_ELIXIR_PIN}.zip"
    ensure_dir "$parent" 0755 root:root || verdict_apply
    fetch_verify "$ELIXIR_ZIP_URL" "$PROV_ELIXIR_PIN_SHA256" "$zip" 0644 || verdict_apply
    rm -rf "${ELIXIR_HOME}.partial"
    prov_scaffold_dir "${ELIXIR_HOME}.partial" 0755 root:root || verdict_apply
    p_step "Elixir $PROV_ELIXIR_PIN — décompression du précompilé officiel (OTP $PROV_ELIXIR_OTP_MAJOR)"
    if ! run_capture unzip -q "$zip" -d "${ELIXIR_HOME}.partial"; then
      rm -rf "${ELIXIR_HOME}.partial" "$zip"; p_fail "extraction du précompilé Elixir"; prov_dump_last; verdict_apply
    fi
    : > "${ELIXIR_HOME}.partial/$ELIXIR_MARK" || { rm -rf "${ELIXIR_HOME}.partial" "$zip"; p_fail "marque de pose impossible dans ${ELIXIR_HOME}.partial"; verdict_apply; }
    prov_promote_dir "${ELIXIR_HOME}.partial" "$ELIXIR_HOME" || verdict_apply
    rm -f "$zip"
  fi
  local b
  for b in "${ELIXIR_BINS[@]}"; do
    ensure_symlink "$PROV_LINK_DIR/$b" "$ELIXIR_HOME/bin/$b" || verdict_apply
  done

  # les autres arbres après le pin : on ne détruit l'ancien qu'une fois le nouveau debout
  mapfile -t old_trees < <(elixir_trees_other)
  for o in "${old_trees[@]}"; do
    if rm -rf "$o"; then
      p_chg "retiré : $o (arbre Elixir d'une autre version que le pin $PROV_ELIXIR_PIN)"
    else
      p_fail "rm -rf $o"; verdict_apply
    fi
  done

  mesure_vm p_fail
  mesure_elixir p_fail
  verdict_apply
}

"$1"
