#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/16-node.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — Node précompilé PINNÉ : le toolchain qui bâtit la DOC du produit
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# ─── POURQUOI NODE EST DU TOOLCHAIN PRODUIT, PAS DU CONFORT ─────────────────────────────────────
#
# ⚖ USER 2026-08-22 : « personne, sauf quelqu'un qui veut avoir la doc locale dispo dans le deck.
# quelqu'un comme moi. j'ai pas envie de taper un site remote pour afficher la doc locale ».
#
# La doc du deck (`/doc/`) est le site d'`assets/github.io`. Son build LIT l'arbre — `fleet/priv/
# catalogue` pour les cartes et les sièges, `fleet/lib/fleet/mcp/pod_tools.ex` pour les outils : même
# arbre, même commit, « aucune question d'épinglage, aucune péremption possible ». C'est la même
# nature qu'Elixir sur ce rail — le toolchain qui bâtit LE PRODUIT — et pas la même que le socle de
# compilation des pods, qui lui a été retiré.
#
# ⚠ ET C'EST POURQUOI CE N'EST PAS `apt install nodejs npm`. Mesuré sur Ubuntu 26.04 vierge :
#   nodejs npm  →  459 paquets      (l'empaquetage Debian de npm traîne tout l'écosystème node-*)
#   nodejs seul →   21 paquets      mais alors pas de npm, donc pas de build
# 459, c'est quatre fois le socle de compilation des pods qu'on vient de couper du rail.
#
# Le tarball officiel EMBARQUE npm : zéro paquet apt, une version épinglée, un sha256 vérifié. C'est
# exactement le mécanisme que ce dépôt emploie déjà pour Elixir, ttyd et tofu.
#
# ⚠ LE RÉSEAU N'EST PAS UNE RÉSERVE ICI, et l'invoquer était un réflexe de prudence sans objet
# (⚖ user : « une install hors ligne bloque déjà au apt primaire »). `npm ci` va sur le réseau comme
# `apt`, comme le précompilé Elixir, comme le miroir de providers. Il n'y a pas de mode hors-ligne à
# préserver.
#
# ─── POURQUOI 16 ────────────────────────────────────────────────────────────────────────────────
#
# `44-media` bâtit la doc et la pose ; il lui faut node AVANT. 16 le met juste après `15-toolchain`,
# dont il est le jumeau : deux précompilés épinglés, une seule raison — ce poste bâtit le produit.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚠ LA VERSION SUIT LES DEUX AUTRES BUILDS, ET UN TÉMOIN L'ÉPINGLE — CE QUI ÉTAIT FAUX QUAND CETTE
# PHRASE A ÉTÉ ÉCRITE. Le Dockerfile bâtit le site sous `node:<majeure>-slim`, le workflow GitHub
# sous `node-version: <majeure>` : trois producteurs de la MÊME doc, et rien ne les confrontait. Le
# témoin existe maintenant (`node_pin.bats`), et c'est lui qui rend cette ligne vraie.
#
# ⚠ 20 ÉTAIT EN FIN DE VIE. « Iron » est sorti de support en avril 2026 ; son dernier patch date du
# 2026-03-24 et il n'en aura plus. Un toolchain de produit qui ne reçoit plus de correctif n'est pas
# un pin stable, c'est un pin ARRÊTÉ — la différence ne se voit pas tant qu'aucun CVE ne tombe.
# 24 « Krypton » est la LTS courante (relevé sur `nodejs.org/dist/index.json` le 2026-08-28).
#
# ⚠ ET CE BUMP-CI EST UN SAUT DE MAJEURE, PAS DE L'ENTRETIEN (⚖ user 2026-08-28 : « node, on
# bump »). Il est ARBITRÉ, à la différence du pin Elixir qui est tombé parce que la distro servait
# déjà la bonne minor. Les sha256 sont ceux de `SHASUMS256.txt` de la release, relevés le 2026-08-28.
NODE_VERSION="${LCARS_NODE_VERSION:-24.20.0}"
NODE_SHA256_X64=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
NODE_SHA256_ARM64=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7

NODE_HOME="${LCARS_NODE_HOME:-/opt/node-${NODE_VERSION}}"
NODE_BINS=(node npm npx)
NODE_LINK_DIR="${LCARS_NODE_LINK_DIR:-/usr/local/bin}"

# L'arch au vocabulaire de nodejs.org, jamais `uname -m` — qui répond `x86_64` là où les tarballs
# disent `x64`. Même règle que `46-tofu`, et même refus sur une arch non épinglée.
node_arch() {
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64) echo x64 ;; arm64) echo arm64 ;; *) echo "" ;;
  esac
}

node_version_posee() { "$NODE_LINK_DIR/node" --version 2>/dev/null | sed 's/^v//'; }

check() {
  local v; v="$(node_version_posee)"
  if [[ -z "$v" ]]; then
    p_drift "node absent ($NODE_LINK_DIR/node) — la doc du deck ne peut pas être bâtie, /doc/ rendra 404"
  elif [[ "$v" != "$NODE_VERSION" ]]; then
    # ⚠ LA VERSION SE SONDE, PAS LA PRÉSENCE : un node du système bâtirait le site avec un autre
    # résolveur de modules que les deux autres producteurs de cette doc.
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
    *) p_fail "arch non épinglée pour node : « $(dpkg --print-architecture 2>/dev/null) » (attendu amd64 ou arm64)"; verdict_apply ;;
  esac

  if [[ "$(node_version_posee)" == "$NODE_VERSION" ]]; then
    p_ok "node $NODE_VERSION déjà posé"
    verdict_apply
  fi

  local tgz="/opt/.node-${NODE_VERSION}.tar.xz"
  ensure_dir /opt 0755 root:root || verdict_apply
  fetch_verify "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
    "$want_sha" "$tgz" 0644 || verdict_apply

  # Même forme que le précompilé Elixir : extraction dans un `.partial` jetable, puis `mv` atomique.
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

  # Verdict RÉEL : la version qui répond EST le pin. Un PATH parasite (un node d'apt devant
  # /usr/local) rendrait la pose vraie et le résultat faux.
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
