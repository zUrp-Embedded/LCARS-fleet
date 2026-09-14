#!/usr/bin/env bash
# SOURCE: deploy/modules.d/16-node.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: node précompilé épinglé — le toolchain qui bâtit la doc du deck, sur une livraison source seulement
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 10-packages
#
# Le tarball officiel apporte npm signé et vérifié ; corepack le retéléchargerait depuis le
# registre au premier usage, une pièce mobile de plus. C'est la livraison qui décide, jamais le
# substrat : une livraison binaire porte la doc déjà bâtie, node n'y a rien à faire.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

NODE_HOME="$(prov_decor "/opt/node-${PROV_NODE_PIN}")"
NODE_BINS=(node npm npx)

node_version_posee() { # node_version_posee → la version que rend le node du PATH des liens ; rc 1 s'il est absent ou ne répond pas
  local v
  v="$("$PROV_LINK_DIR/node" --version 2>/dev/null)" || return 1
  printf '%s\n' "${v#v}"
}

check() {
  if prov_delivery_is_binary; then
    p_ok "node non requis — livraison binaire, la doc du deck arrive bâtie (44-media la pose)"
    verdict_check
  fi
  local v
  if [[ ! -e "$PROV_LINK_DIR/node" ]]; then
    p_drift "node absent ($PROV_LINK_DIR/node) — la doc du deck ne peut pas être bâtie, /doc/ rendra 404"
  elif ! v="$(node_version_posee)"; then
    p_drift "node posé ($PROV_LINK_DIR/node) mais ne répond pas à --version — la doc du deck ne peut pas être bâtie ; l'apply repose le pin"
  elif [[ "$v" != "$PROV_NODE_PIN" ]]; then
    p_drift "node $v ≠ pin $PROV_NODE_PIN ($NODE_HOME) — la doc serait bâtie par un autre toolchain que la CI et l'image"
  else
    p_ok "node $v posé ($NODE_HOME)"
  fi
  verdict_check
}

apply() {
  if prov_delivery_is_binary; then
    p_ok "node non posé — livraison binaire, rien à bâtir sur cette machine"
    verdict_apply
  fi
  local arch want_sha
  arch="$(arch_tag node)"
  case "$arch" in
    x64)   want_sha="$PROV_NODE_PIN_SHA256_X64" ;;
    arm64) want_sha="$PROV_NODE_PIN_SHA256_ARM64" ;;
    *) p_fail "arch non épinglée pour node : « $(arch_tag raw) » (attendu amd64 ou arm64)"; verdict_apply ;;
  esac
  if [[ "$(node_version_posee || true)" == "$PROV_NODE_PIN" ]]; then
    p_ok "node $PROV_NODE_PIN déjà posé"
    verdict_apply
  fi
  # un crash au milieu ne laisse pas un NODE_HOME à moitié écrit qui répondrait à --version
  local tgz; tgz="$(dirname "$NODE_HOME")/.node-${PROV_NODE_PIN}.tar.xz"
  ensure_dir "$(dirname "$NODE_HOME")" 0755 root:root || verdict_apply
  fetch_verify "https://nodejs.org/dist/v${PROV_NODE_PIN}/node-v${PROV_NODE_PIN}-linux-${arch}.tar.xz" \
    "$want_sha" "$tgz" 0644 || verdict_apply
  rm -rf "${NODE_HOME}.partial"
  prov_scaffold_dir "${NODE_HOME}.partial" 0755 root:root || verdict_apply
  p_step "node $PROV_NODE_PIN — décompression du précompilé officiel"
  if ! run_capture tar -xJf "$tgz" -C "${NODE_HOME}.partial" --strip-components=1; then
    rm -rf "${NODE_HOME}.partial" "$tgz"; p_fail "extraction du précompilé node"; prov_dump_last; verdict_apply
  fi
  prov_promote_dir "${NODE_HOME}.partial" "$NODE_HOME" || verdict_apply
  rm -f "$tgz"
  local b
  for b in "${NODE_BINS[@]}"; do
    ensure_symlink "$PROV_LINK_DIR/$b" "$NODE_HOME/bin/$b" || verdict_apply
  done
  p_chg "node $PROV_NODE_PIN posé ($NODE_HOME)"
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
