#!/usr/bin/env bash
# SOURCE: deploy/modules.d/15-toolchain.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la toolchain de build — Erlang/OTP par apt, au plancher de sa majeure ; Elixir par le zip officiel épinglé
# APPLY-ON: wsl linux docker
# CHECK-ON: wsl linux docker
# NEEDS: root
#
# Elixir vient du zip précompilé officiel (un par majeure OTP), épinglé par version et sha256 dans
# installer-constants.env : la distro LTS sert une minor qu'Elixir ne corrige plus. Erlang reste celui de la distro
# tant que sa majeure est dans la fenêtre du pin. Le module retire les arbres /opt/elixir-* d'une
# autre version et les liens de PROV_LINK_DIR qui pointent ailleurs que sur le pin — jamais un lien
# de l'opérateur (c'est la cible du lien qui décide), jamais un paquet apt. Une livraison binaire
# n'a rien à compiler : la release embarque son ERTS ; il ne reste que le nettoyage des reliquats.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0; }
elixir_version() { elixir --short-version 2>/dev/null || echo absent; }

ELIXIR_BINS=(elixir elixirc mix iex)
ELIXIR_PREFIX="$(prov_decor /opt/elixir-)"
ELIXIR_HOME="${ELIXIR_PREFIX}${PROV_ELIXIR_PIN}"
ELIXIR_ZIP_URL="https://github.com/elixir-lang/elixir/releases/download/v${PROV_ELIXIR_PIN}/elixir-otp-${PROV_ELIXIR_OTP_MAJOR}.zip"

elixir_version_posee() {
  [[ -x "$ELIXIR_HOME/bin/elixir" ]] || return 0
  "$ELIXIR_HOME/bin/elixir" --short-version 2>/dev/null
}

elixir_links_ours() { # les liens de PROV_LINK_DIR qui pointent sous notre préfixe, toute version
  local b t
  for b in "${ELIXIR_BINS[@]}"; do
    [[ -L "$PROV_LINK_DIR/$b" ]] || continue
    t="$(readlink -m "$PROV_LINK_DIR/$b" 2>/dev/null || true)"
    [[ "$t" == "$ELIXIR_PREFIX"*/* ]] && printf '%s\n' "$PROV_LINK_DIR/$b"
  done
  return 0
}

elixir_links_stale() { # ceux des nôtres qui ne pointent pas sur l'arbre du pin
  local l t
  while IFS= read -r l; do
    t="$(readlink -m "$l" 2>/dev/null || true)"
    [[ "$t" == "$ELIXIR_HOME"/* && -e "$t" ]] || printf '%s\n' "$l"
  done < <(elixir_links_ours)
  return 0
}

# un glob sans correspondance rend son propre motif : sans -d, un rm -rf recevrait « /opt/elixir-* »
elixir_trees() {
  local d
  for d in "$ELIXIR_PREFIX"*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
  return 0
}

elixir_trees_other() {
  local d
  while IFS= read -r d; do [[ "$d" == "$ELIXIR_HOME" ]] || printf '%s\n' "$d"; done < <(elixir_trees)
  return 0
}

elixir_built_for() {
  elixir --version 2>/dev/null \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p' | head -1
}

rien_a_batir() { prov_delivery_is_binary; }
reliquats_liens() { if rien_a_batir; then elixir_links_ours; else elixir_links_stale; fi; }
reliquats_arbres() { if rien_a_batir; then elixir_trees; else elixir_trees_other; fi; }

check_reliquats() {
  local -a old_links old_trees
  mapfile -t old_links < <(reliquats_liens)
  mapfile -t old_trees < <(reliquats_arbres)
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
    check_reliquats
    verdict_check
  fi
  if command -v erl >/dev/null; then
    local otp; otp="$(otp_release)"
    if [[ "$otp" -ge "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Erlang/OTP $otp (plancher $PROV_ELIXIR_OTP_MAJOR, paquet apt erlang)"
    else
      p_drift "Erlang/OTP $otp < plancher $PROV_ELIXIR_OTP_MAJOR"
    fi
  else
    p_drift "erl absent (paquet apt erlang)"
  fi
  local posee; posee="$(elixir_version_posee)"
  local ev; ev="$(elixir_version)"
  if [[ "$posee" != "$PROV_ELIXIR_PIN" ]]; then
    p_drift "Elixir $PROV_ELIXIR_PIN non posé ($ELIXIR_HOME) — l'apply le télécharge (zip officiel, sha256 épinglé)"
  elif [[ "$ev" != "$PROV_ELIXIR_PIN" ]]; then
    # deux causes, deux gestes opposés : refaire notre lien, ou retirer ce qui le masque dans le PATH
    local qui; qui="$(command -v elixir 2>/dev/null || true)"
    if [[ -n "$qui" && "$qui" == "$PROV_LINK_DIR"/* ]]; then
      p_drift "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} — c'est NOTRE lien $qui qui pointe sur un autre arbre ($(readlink -f "$qui" 2>/dev/null || echo '?')) ; l'apply le refait pointer sur le pin"
    else
      p_drift "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} (${qui:-introuvable}) — un autre elixir est devant $PROV_LINK_DIR dans le PATH ; c'est LUI qui compile"
    fi
  else
    local built otp; built="$(elixir_built_for)"; otp="$(otp_release)"
    if [[ "$built" == "$otp" ]]; then
      p_ok "Elixir $ev posé ($ELIXIR_HOME), variante OTP $built (= la VM qui répond)"
    elif [[ -z "$built" ]]; then
      p_drift "Elixir $ev : variante de build illisible (« elixir --version » n'annonce plus son OTP ?)"
    else
      p_drift "Elixir $ev compilé pour OTP $built, VM OTP $otp — le zip du pin n'est pas celui de cette majeure OTP"
    fi
  fi
  check_reliquats
  verdict_check
}

apply() {
  # les liens périmés d'abord : tant qu'un lien pointe ailleurs, « elixir » mesure cet ailleurs
  local -a old_links old_trees; local o
  mapfile -t old_links < <(reliquats_liens)
  for o in "${old_links[@]}"; do
    if rm -f "$o"; then
      p_chg "retiré : $o (lien Elixir vers un arbre qui n'est pas le pin)"
    else
      p_fail "rm $o"; verdict_apply
    fi
  done
  if rien_a_batir; then
    mapfile -t old_trees < <(reliquats_arbres)
    for o in "${old_trees[@]}"; do
      if rm -rf "$o"; then p_chg "retiré : $o (arbre Elixir sur une machine qui ne bâtit pas)"; else p_fail "rm -rf $o"; verdict_apply; fi
    done
    p_ok "erlang et elixir non posés — livraison binaire, rien à bâtir ici"
    p_ok "plancher OTP/Elixir non vérifié — la release embarque son ERTS, rien ne compile ici"
    verdict_apply
  fi

  if ! command -v erl >/dev/null || [[ "$(otp_release)" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    apt_ensure erlang || verdict_apply
  else
    prov_journal_note apt_already erlang
    p_ok "Erlang/OTP déjà au plancher — trouvé, pas posé"
  fi

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

  local otp ev built; otp="$(otp_release)"; ev="$(elixir_version)"
  if [[ "$otp" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    p_fail "Erlang/OTP « $otp » toujours sous le plancher $PROV_ELIXIR_OTP_MAJOR après apt (distro trop vieille ?)"
  elif [[ "$ev" != "$PROV_ELIXIR_PIN" ]]; then
    p_fail "« elixir » répond « $ev » après pose ≠ pin $PROV_ELIXIR_PIN (PATH parasite ? un elixir d'apt ou d'ailleurs devant $PROV_LINK_DIR : $(command -v elixir 2>/dev/null || echo 'introuvable'))"
  else
    built="$(elixir_built_for)"
    if [[ -n "$built" && "$built" != "$otp" ]]; then
      p_fail "Elixir $ev compilé pour OTP $built, VM OTP $otp — le zip du pin n'est pas celui de cette majeure OTP"
    else
      p_ok "Erlang/OTP $otp, Elixir $ev ($ELIXIR_HOME ; plancher OTP $PROV_ELIXIR_OTP_MAJOR)"
    fi
  fi
  verdict_apply
}

case "${1:?usage: 15-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
