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

NODE_VERSION="${LCARS_NODE_VERSION:-24.20.0}"
NODE_SHA256_X64=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
NODE_SHA256_ARM64=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7
NODE_HOME="${LCARS_NODE_HOME:-/opt/node-${NODE_VERSION}}"
NODE_BINS=(node npm npx)
NODE_LINK_DIR="${LCARS_NODE_LINK_DIR:-/usr/local/bin}"

node_arch() { arch_tag node; }

# un binaire absent est un état, pas une erreur : sous set -e, l'exécuter tuerait le module avant son verdict
node_version_posee() {
  [[ -x "$NODE_LINK_DIR/node" ]] || return 0
  "$NODE_LINK_DIR/node" --version 2>/dev/null | sed 's/^v//'
}

DECK_DOC="${LCARS_DECK_DOC:-$PROV_ROOT/share/doc}"
check_doc_batie() {
  local n
  if [[ ! -s "$DECK_DOC/index.html" ]]; then
    p_drift "doc du deck absente ($DECK_DOC/index.html) — /doc/ rendra 404 ; sur cette machine elle arrive bâtie ($(rien_a_batir_car)), elle ne se bâtit jamais ici"
    return 0
  fi
  n="$(find "$DECK_DOC" -type f 2>/dev/null | wc -l)" || n="?"
  p_ok "doc du deck bâtie et posée ($DECK_DOC, $n fichiers)"
}

rien_a_batir() { prov_delivery_is_binary; }
rien_a_batir_car() { echo "livraison binaire — bâtie par pack.sh"; }

check() {
  if rien_a_batir; then
    check_doc_batie
    verdict_check
  fi
  local v; v="$(node_version_posee)"
  if [[ -z "$v" ]]; then
    p_drift "node absent ($NODE_LINK_DIR/node) — la doc du deck ne peut pas être bâtie, /doc/ rendra 404"
  elif [[ "$v" != "$NODE_VERSION" ]]; then
    p_drift "node $v ≠ pin $NODE_VERSION ($NODE_HOME) — la doc serait bâtie par un autre toolchain que la CI et l'image"
  else
    p_ok "node $v posé ($NODE_HOME)"
  fi
  verdict_check
}

apply() {
  if rien_a_batir; then
    p_ok "node non posé — rien à bâtir sur cette machine ($(rien_a_batir_car))"
    verdict_apply
  fi
  local arch want_sha
  arch="$(node_arch)"
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
  local tgz="/opt/.node-${NODE_VERSION}.tar.xz"
  ensure_dir /opt 0755 root:root || verdict_apply
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
    ensure_symlink "$NODE_LINK_DIR/$b" "$NODE_HOME/bin/$b" || verdict_apply
  done
  local v; v="$(node_version_posee)"
  if [[ "$v" == "$NODE_VERSION" ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "node $v posé ($NODE_HOME) — npm $("$NODE_LINK_DIR/npm" --version 2>/dev/null || echo '?') embarqué"
  else
    p_fail "node répond « ${v:-rien} » après pose ≠ pin $NODE_VERSION (PATH parasite ? node d'apt devant $NODE_LINK_DIR ?)"
  fi
  verdict_apply
}

case "${1:?usage: 16-node.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
