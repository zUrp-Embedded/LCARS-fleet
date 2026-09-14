#!/usr/bin/env bash
# SOURCE: deploy/modules.d/16-node.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: node précompilé épinglé — le toolchain qui bâtit la doc du deck, sur une livraison source seulement
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
#
# Le tarball officiel apporte npm signé et vérifié ; corepack le retéléchargerait depuis le
# registre au premier usage, une pièce mobile de plus. C'est la livraison qui décide, jamais le
# substrat : une livraison binaire porte la doc déjà bâtie, node n'y a rien à faire.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

NODE_VERSION=24.20.0
NODE_SHA256_X64=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
NODE_SHA256_ARM64=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7
NODE_HOME="$(prov_decor "/opt/node-${NODE_VERSION}")"
NODE_BINS=(node npm npx)

# un binaire absent ou qui échoue est un état : sous set -e, son code tuerait le module avant son verdict
node_version_posee() {
  [[ -x "$PROV_LINK_DIR/node" ]] || return 0
  { "$PROV_LINK_DIR/node" --version 2>/dev/null || true; } | sed 's/^v//'
}

rien_a_batir() { prov_delivery_is_binary; }

check() {
  if rien_a_batir; then
    p_ok "node non requis — livraison binaire, la doc du deck arrive bâtie (44-media la pose)"
    verdict_check
  fi
  local v; v="$(node_version_posee)"
  if [[ -z "$v" ]]; then
    p_drift "node absent ($PROV_LINK_DIR/node) — la doc du deck ne peut pas être bâtie, /doc/ rendra 404"
  elif [[ "$v" != "$NODE_VERSION" ]]; then
    p_drift "node $v ≠ pin $NODE_VERSION ($NODE_HOME) — la doc serait bâtie par un autre toolchain que la CI et l'image"
  else
    p_ok "node $v posé ($NODE_HOME)"
  fi
  verdict_check
}

apply() {
  if rien_a_batir; then
    p_ok "node non posé — livraison binaire, rien à bâtir sur cette machine"
    verdict_apply
  fi
  local arch want_sha
  arch="$(arch_tag node)"
  case "$arch" in
    x64)   want_sha="$NODE_SHA256_X64" ;;
    arm64) want_sha="$NODE_SHA256_ARM64" ;;
    *) p_fail "arch non épinglée pour node : « $(arch_tag raw) » (attendu amd64 ou arm64)"; verdict_apply ;;
  esac
  if [[ "$(node_version_posee)" == "$NODE_VERSION" ]]; then
    p_ok "node $NODE_VERSION déjà posé"
    verdict_apply
  fi
  # un crash au milieu ne laisse pas un NODE_HOME à moitié écrit qui répondrait à --version
  local tgz; tgz="$(dirname "$NODE_HOME")/.node-${NODE_VERSION}.tar.xz"
  ensure_dir "$(dirname "$NODE_HOME")" 0755 root:root || verdict_apply
  fetch_verify "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
    "$want_sha" "$tgz" 0644 || verdict_apply
  rm -rf "${NODE_HOME}.partial"
  prov_scaffold_dir "${NODE_HOME}.partial" 0755 root:root || verdict_apply
  p_step "node $NODE_VERSION — décompression du précompilé officiel"
  if ! run_capture tar -xJf "$tgz" -C "${NODE_HOME}.partial" --strip-components=1; then
    rm -rf "${NODE_HOME}.partial" "$tgz"; p_fail "extraction du précompilé node"; prov_dump_last; verdict_apply
  fi
  prov_promote_dir "${NODE_HOME}.partial" "$NODE_HOME" || verdict_apply
  rm -f "$tgz"
  local b
  for b in "${NODE_BINS[@]}"; do
    ensure_symlink "$PROV_LINK_DIR/$b" "$NODE_HOME/bin/$b" || verdict_apply
  done
  p_chg "node $NODE_VERSION posé ($NODE_HOME)"
  verdict_apply
}

"$1"
