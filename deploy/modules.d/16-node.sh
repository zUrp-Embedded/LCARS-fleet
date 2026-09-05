#!/usr/bin/env bash
# SOURCE: deploy/modules.d/16-node.sh
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
# Vu : « ERREUR 16-node: MORT avant de rendre son verdict (rc=127) », seul echec
# des 20 modules, et il suffisait a rendre la boite non convergee.
node_version_posee() {
  [[ -x "$NODE_LINK_DIR/node" ]] || return 0
  "$NODE_LINK_DIR/node" --version 2>/dev/null | sed 's/^v//'
}

# ─── DANS LA BOITE, L'ETAT-CIBLE EST LA DOC, PAS L'OUTIL QUI LA PRODUIT ──────────────────────────
# node n'existe ici que le temps du stage « site » de l'image : il y fait `npm run build` sur la
# source du runtime (`COPY fleet /src/runtime`), et seul le RESULTAT est copie dans le runtime. La doc
# est donc bâtie a partir de la revision exacte que la boite servira, et node n'a rien a y faire
# ensuite. Verifier node ici mesurait un moyen absent PAR CONSTRUCTION, et rendait un echec que nul
# `apply` ne pouvait reparer (APPLY-ON=wsl linux).
#
# Ce que cette sonde NE prouve pas : que la doc corresponde a la revision courante. Rien dans
# l'image ne le dit tant que `.source-revision` n'y est pas — c'est le sujet de 62-runtime-helpers,
# pas celui-ci.
# La racine du produit DERIVE (`$PROV_ROOT`) : trois modules la redefinissaient en dur, ce qui fait
# trois endroits a corriger le jour ou elle bouge — et deux qu'on oublie. Un mur le tient.
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

# ⚠ DEUX CHEMINS, UNE SEULE QUESTION : « y a-t-il quelque chose a batir ici ? ». Le substrat docker
# repondait non depuis toujours (la doc sort du stage « site » de l'image) ; une livraison BINAIRE
# repond non pour la meme raison, sur un poste — `pack.sh` a bati la doc en meme temps que la release.
# Les separer produirait un poste qui telecharge 60 Mo de toolchain node pour ne rien batir.
rien_a_batir() { [[ "${PROV_SUBSTRATE:-}" == "docker" ]] || prov_delivery_is_binary; }
rien_a_batir_car() {
  if [[ "${PROV_SUBSTRATE:-}" == "docker" ]]; then echo "stage « site » de l'image"
  else echo "livraison binaire — bâtie par pack.sh"; fi
}

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
  # Le symetrique du `check` : ce qu'on ne mesure pas ici, on ne le pose pas non plus. Un `apply`
  # qui poserait node quand le `check` declare n'avoir rien a batir ferait diverger les deux verbes
  # du meme module — et c'est `apply` qui a le dernier mot sur ce que la machine porte.
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

  local tgz="/opt/.node-${NODE_VERSION}.tar.xz"
  ensure_dir /opt 0755 root:root || verdict_apply
  fetch_verify "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
    "$want_sha" "$tgz" 0644 || verdict_apply

  # Un crash au milieu ne laisse jamais un NODE_HOME à moitié écrit qui répondrait à `--version`.
  rm -rf "${NODE_HOME}.partial"
  prov_scaffold_dir "${NODE_HOME}.partial" 0755 root:root || verdict_apply   # hors journal (M8)
  p_step "node $NODE_VERSION — décompression du précompilé officiel"
  if ! run_quiet tar -xJf "$tgz" -C "${NODE_HOME}.partial" --strip-components=1; then
    rm -rf "${NODE_HOME}.partial" "$tgz"; p_fail "extraction du précompilé node"; verdict_apply
  fi
  prov_promote_dir "${NODE_HOME}.partial" "$NODE_HOME" || verdict_apply   # journalise le nom FINAL
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
