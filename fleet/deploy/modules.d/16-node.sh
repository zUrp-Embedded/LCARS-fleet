#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/16-node.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — Node précompilé PINNÉ : le toolchain qui bâtit la DOC du produit
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# ⚠ COREPACK N'EST PAS LA TROISIÈME VOIE QU'IL SEMBLE ÊTRE. Il est là (`node-corepack` chez apt, et
# le tarball en porte un aussi) et il sait servir npm — mais il le TÉLÉCHARGE depuis le registre au
# premier usage. Ce serait un troisième mécanisme d'approvisionnement, non épinglé, pour obtenir ce
# que le tarball apporte déjà signé et vérifié. On n'y gagne rien qu'une pièce mobile.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

NODE_VERSION="${LCARS_NODE_VERSION:-24.20.0}"
NODE_SHA256_X64=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
NODE_SHA256_ARM64=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7

NODE_HOME="${LCARS_NODE_HOME:-/opt/node-${NODE_VERSION}}"
NODE_BINS=(node npm npx)
NODE_LINK_DIR="${LCARS_NODE_LINK_DIR:-/usr/local/bin}"

node_arch() { arch_tag node; }

# ⚠ ON N'EXECUTE PAS UN BINAIRE ABSENT, ON CONSTATE SON ABSENCE. Sous `set -euo pipefail`, un
# binaire introuvable fait rendre 127 au PIPELINE — que `2>/dev/null` n'attenue pas, il ne cache
# que le message — et `v="$(node_version_posee)"` propage ce 127 : le module MEURT avant son
# `p_drift`, sans une ligne pour le dire. Le rendu vide est un ETAT, pas une erreur : c'est
# precisement ce que `check` sait traiter (« node absent »).
#
# ⚠ ET CE MODULE EST « APPLY-ON: wsl linux · CHECK-ON: any » : il VERIFIE sur un substrat ou il ne
# POSE jamais. Dans la boite, node n'est donc jamais la — l'etat nominal du check y est l'absence.
# Mesure du 2026-08-30 : « ERREUR 16-node: MORT avant de rendre son verdict (rc=127) », seul echec
# des 20 modules, et il suffisait a rendre la boite non convergee.
node_version_posee() {
  [[ -x "$NODE_LINK_DIR/node" ]] || return 0
  "$NODE_LINK_DIR/node" --version 2>/dev/null | sed 's/^v//'
}

check() {
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

  local tgz="/opt/.node-${NODE_VERSION}.tar.xz"
  ensure_dir /opt 0755 root:root || verdict_apply
  fetch_verify "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
    "$want_sha" "$tgz" 0644 || verdict_apply

  # Un crash au milieu ne laisse jamais un NODE_HOME à moitié écrit qui répondrait à `--version`.
  rm -rf "${NODE_HOME}.partial"
  ensure_dir "${NODE_HOME}.partial" 0755 root:root || verdict_apply
  p_step "node $NODE_VERSION — décompression du précompilé officiel"
  if ! run_quiet tar -xJf "$tgz" -C "${NODE_HOME}.partial" --strip-components=1; then
    rm -rf "${NODE_HOME}.partial" "$tgz"; p_fail "extraction du précompilé node"; verdict_apply
  fi
  rm -rf "$NODE_HOME"
  mv "${NODE_HOME}.partial" "$NODE_HOME"
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
